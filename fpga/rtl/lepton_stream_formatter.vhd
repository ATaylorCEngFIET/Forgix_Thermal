library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.lepton_pkg.all;

entity lepton_stream_formatter is
  generic (
    G_FIFO_DEPTH          : positive := 10240;
    G_UART_CLOCKS_PER_BIT : positive := 10
  );
  port (
    i_clk           : in  std_logic;
    i_rst           : in  std_logic;
    i_capture_error : in  std_logic;
    i_capture_error_code : in unsigned(15 downto 0);
    i_fifo_mark     : in  std_logic;
    i_fifo_commit   : in  std_logic;
    i_fifo_rollback : in  std_logic;
    i_fifo_write    : in  std_logic;
    i_fifo_data     : in  t_byte;
    o_fifo_full     : out std_logic;
    o_fifo_empty    : out std_logic;
    i_desc_valid    : in  std_logic;
    i_desc_segment  : in  unsigned(2 downto 0);
    i_desc_frame    : in  unsigned(15 downto 0);
    o_desc_ready    : out std_logic;
    o_uart_tx       : out std_logic;
    o_active        : out std_logic;
    o_overflow      : out std_logic
  );
end entity;

architecture rtl of lepton_stream_formatter is
  constant C_DESCRIPTOR_DEPTH : natural := 8;
  constant C_HEADER_BYTES     : natural := 16;

  type t_segment_array is array (0 to C_DESCRIPTOR_DEPTH - 1) of unsigned(2 downto 0);
  type t_frame_array is array (0 to C_DESCRIPTOR_DEPTH - 1) of unsigned(15 downto 0);
  type t_stream_state is (wait_descriptor, send_header, send_payload);

  signal s_desc_segments : t_segment_array := (others => (others => '0'));
  signal s_desc_frames   : t_frame_array := (others => (others => '0'));
  signal s_desc_write    : natural range 0 to C_DESCRIPTOR_DEPTH - 1 := 0;
  signal s_desc_read     : natural range 0 to C_DESCRIPTOR_DEPTH - 1 := 0;
  signal s_desc_count    : natural range 0 to C_DESCRIPTOR_DEPTH := 0;

  signal s_fifo_clear      : std_logic := '0';
  signal s_fifo_read       : std_logic := '0';
  signal s_fifo_read_data  : t_byte;
  signal s_fifo_read_valid : std_logic;
  signal s_fifo_empty      : std_logic;
  signal s_fifo_full       : std_logic;
  signal s_fifo_used       : natural range 0 to G_FIFO_DEPTH;

  signal s_state             : t_stream_state := wait_descriptor;
  signal s_current_segment   : unsigned(2 downto 0) := (others => '0');
  signal s_current_frame     : unsigned(15 downto 0) := (others => '0');
  signal s_header_index      : natural range 0 to C_HEADER_BYTES - 1 := 0;
  signal s_payload_remaining : natural range 0 to C_SEGMENT_BYTES := 0;
  signal s_payload_data      : t_byte := (others => '0');
  signal s_payload_valid     : std_logic := '0';
  signal s_read_pending      : std_logic := '0';
  signal s_error_count       : unsigned(15 downto 0) := (others => '0');
  signal s_overflow          : std_logic := '0';

  signal s_uart_data  : t_byte;
  signal s_uart_valid : std_logic;
  signal s_uart_ready : std_logic;

  function increment_descriptor(value : natural) return natural is
  begin
    if value = C_DESCRIPTOR_DEPTH - 1 then
      return 0;
    end if;
    return value + 1;
  end function;

  function header_byte(
    index       : natural;
    segment     : unsigned(2 downto 0);
    frame       : unsigned(15 downto 0);
    error_count : unsigned(15 downto 0)
  ) return t_byte is
    variable v_length_low  : t_byte;
    variable v_length_high : t_byte;
    variable v_checksum    : t_byte;
    variable v_segment     : t_byte;
  begin
    v_segment := "00000" & std_logic_vector(segment);
    if segment = 0 then
      v_length_low  := x"00";
      v_length_high := x"00";
    else
      v_length_low  := std_logic_vector(to_unsigned(C_SEGMENT_BYTES mod 256, 8));
      v_length_high := std_logic_vector(to_unsigned(C_SEGMENT_BYTES / 256, 8));
    end if;
    v_checksum := x"4C" xor x"50" xor x"54" xor x"4E" xor x"01" xor
                  v_segment xor x"04" xor x"10" xor
                  std_logic_vector(frame(7 downto 0)) xor
                  std_logic_vector(frame(15 downto 8)) xor
                  v_length_low xor v_length_high xor
                  std_logic_vector(error_count(7 downto 0)) xor
                  std_logic_vector(error_count(15 downto 8)) xor x"B5";

    case index is
      when 0  => return x"4C"; -- L
      when 1  => return x"50"; -- P
      when 2  => return x"54"; -- T
      when 3  => return x"4E"; -- N
      when 4  => return x"01";
      when 5  => return v_segment;
      when 6  => return x"04"; -- packed 12-bit Raw14 payload
      when 7  => return x"10";
      when 8  => return std_logic_vector(frame(7 downto 0));
      when 9  => return std_logic_vector(frame(15 downto 8));
      when 10 => return v_length_low;
      when 11 => return v_length_high;
      when 12 => return std_logic_vector(error_count(7 downto 0));
      when 13 => return std_logic_vector(error_count(15 downto 8));
      when 14 => return x"B5";
      when others => return v_checksum;
    end case;
  end function;
begin
  o_fifo_full <= s_fifo_full;
  o_fifo_empty <= s_fifo_empty;
  o_desc_ready <= '1' when s_desc_count < C_DESCRIPTOR_DEPTH - 1 and
                           s_overflow = '0' else '0';
  o_active   <= '1' when s_state /= wait_descriptor else '0';
  o_overflow <= s_overflow;

  s_uart_valid <= '1' when s_state = send_header else
                  s_payload_valid when s_state = send_payload else '0';
  s_uart_data <= header_byte(s_header_index, s_current_segment,
                             s_current_frame, s_error_count)
                 when s_state = send_header else s_payload_data;

  u_fifo : entity work.byte_fifo(rtl)
    generic map (
      G_DEPTH => G_FIFO_DEPTH
    )
    port map (
      i_clk        => i_clk,
      i_rst        => i_rst,
      i_clear      => s_fifo_clear,
      i_mark       => i_fifo_mark,
      i_commit     => i_fifo_commit,
      i_rollback   => i_fifo_rollback,
      i_write      => i_fifo_write,
      i_write_data => i_fifo_data,
      o_full       => s_fifo_full,
      o_used       => s_fifo_used,
      i_read       => s_fifo_read,
      o_read_data  => s_fifo_read_data,
      o_read_valid => s_fifo_read_valid,
      o_empty      => s_fifo_empty
    );

  u_uart : entity work.uart_tx(rtl)
    generic map (
      G_CLOCKS_PER_BIT => G_UART_CLOCKS_PER_BIT
    )
    port map (
      i_clk   => i_clk,
      i_rst   => i_rst,
      i_data  => s_uart_data,
      i_valid => s_uart_valid,
      o_ready => s_uart_ready,
      o_tx    => o_uart_tx
    );

  p_stream : process (i_clk)
    variable v_desc_write : natural range 0 to C_DESCRIPTOR_DEPTH - 1;
    variable v_desc_read  : natural range 0 to C_DESCRIPTOR_DEPTH - 1;
    variable v_desc_count : natural range 0 to C_DESCRIPTOR_DEPTH;
    variable v_buffer_valid : std_logic;
    variable v_read_pending : std_logic;
  begin
    if rising_edge(i_clk) then
      s_fifo_clear <= '0';
      s_fifo_read  <= '0';

      if i_rst = '1' then
        -- Reset the tiny descriptor table explicitly so synthesis uses
        -- flip-flops rather than consuming the T8's final block RAM.
        for descriptor_index in 0 to C_DESCRIPTOR_DEPTH - 1 loop
          s_desc_segments(descriptor_index) <= (others => '0');
          s_desc_frames(descriptor_index)   <= (others => '0');
        end loop;
        s_desc_write        <= 0;
        s_desc_read         <= 0;
        s_desc_count        <= 0;
        s_state             <= wait_descriptor;
        s_current_segment   <= (others => '0');
        s_current_frame     <= (others => '0');
        s_header_index      <= 0;
        s_payload_remaining <= 0;
        s_payload_data      <= (others => '0');
        s_payload_valid     <= '0';
        s_read_pending      <= '0';
        s_error_count       <= (others => '0');
        s_overflow          <= '0';
      else
        v_desc_write  := s_desc_write;
        v_desc_read   := s_desc_read;
        v_desc_count  := s_desc_count;
        v_buffer_valid := s_payload_valid;
        v_read_pending := s_read_pending;

        if i_capture_error = '1' then
          s_overflow          <= '0';
          s_error_count       <= s_error_count + 1;
          s_fifo_clear        <= '1';
          v_desc_write        := 0;
          v_desc_read         := 0;
          v_desc_count        := 0;
          v_buffer_valid      := '0';
          v_read_pending      := '0';
          s_current_segment   <= (others => '0');
          s_current_frame     <= i_capture_error_code;
          s_payload_remaining <= 0;
          s_header_index      <= 0;
          s_state             <= send_header;
        else
          if i_desc_valid = '1' then
            if v_desc_count < C_DESCRIPTOR_DEPTH then
              s_desc_segments(v_desc_write) <= i_desc_segment;
              s_desc_frames(v_desc_write)   <= i_desc_frame;
              v_desc_write := increment_descriptor(v_desc_write);
              v_desc_count := v_desc_count + 1;
            else
              s_overflow   <= '1';
              s_fifo_clear <= '1';
            end if;
          end if;

          case s_state is
            when wait_descriptor =>
              -- Use the registered count so a just-written descriptor RAM
              -- entry is not read until the following clock.
              if s_desc_count /= 0 then
                s_current_segment   <= s_desc_segments(v_desc_read);
                s_current_frame     <= s_desc_frames(v_desc_read);
                s_header_index      <= 0;
                s_payload_remaining <= C_SEGMENT_BYTES;
                v_desc_read := increment_descriptor(v_desc_read);
                v_desc_count := v_desc_count - 1;
                s_state <= send_header;
              end if;

            when send_header =>
              if s_uart_ready = '1' then
                if s_header_index = C_HEADER_BYTES - 1 then
                  s_header_index <= 0;
                  if s_current_segment = 0 then
                    s_state <= wait_descriptor;
                  else
                    s_state <= send_payload;
                  end if;
                else
                  s_header_index <= s_header_index + 1;
                end if;
              end if;

            when send_payload =>
              if s_payload_valid = '1' and s_uart_ready = '1' then
                v_buffer_valid := '0';
                if s_payload_remaining = 1 then
                  s_payload_remaining <= 0;
                  s_state <= wait_descriptor;
                else
                  s_payload_remaining <= s_payload_remaining - 1;
                end if;
              end if;

              if s_fifo_read_valid = '1' then
                s_payload_data  <= s_fifo_read_data;
                v_buffer_valid  := '1';
                v_read_pending  := '0';
              end if;

              if v_buffer_valid = '0' and v_read_pending = '0' and
                 s_fifo_empty = '0' and s_payload_remaining /= 0 and
                 not (s_payload_valid = '1' and s_uart_ready = '1' and
                      s_payload_remaining = 1) then
                s_fifo_read   <= '1';
                v_read_pending := '1';
              end if;
          end case;
        end if;

        s_desc_write    <= v_desc_write;
        s_desc_read     <= v_desc_read;
        s_desc_count    <= v_desc_count;
        s_payload_valid <= v_buffer_valid;
        s_read_pending  <= v_read_pending;
      end if;
    end if;
  end process;
end architecture;
