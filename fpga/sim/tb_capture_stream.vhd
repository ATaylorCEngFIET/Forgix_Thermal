library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.lepton_pkg.all;

entity tb_capture_stream is
end entity;

architecture sim of tb_capture_stream is
  constant C_CLOCK_PERIOD : time := 20 ns;
  constant C_UART_BIT     : time := 6 * C_CLOCK_PERIOD;

  signal clk           : std_logic := '0';
  signal rst           : std_logic := '1';
  signal cam_cs_n      : std_logic;
  signal cam_sck       : std_logic;
  signal cam_miso      : std_logic := '1';
  signal fifo_full     : std_logic;
  signal fifo_empty    : std_logic;
  signal fifo_mark     : std_logic;
  signal fifo_commit   : std_logic;
  signal fifo_rollback : std_logic;
  signal fifo_write    : std_logic;
  signal fifo_data     : t_byte;
  signal desc_ready    : std_logic;
  signal desc_valid    : std_logic;
  signal desc_segment  : unsigned(2 downto 0);
  signal desc_frame    : unsigned(15 downto 0);
  signal sync_pulse    : std_logic;
  signal error_pulse   : std_logic;
  signal error_code    : unsigned(15 downto 0);
  signal uart_tx       : std_logic;
  signal stream_active : std_logic;
  signal overflow      : std_logic;
begin
  clk <= not clk after C_CLOCK_PERIOD / 2;

  u_capture : entity work.lepton_vospi_capture(rtl)
    generic map (
      G_INITIAL_RESYNC_CYCLES => 16,
      G_RESYNC_CYCLES         => 16,
      G_PACKET_GAP_CYCLES     => 50,
      G_CS_SETUP_CYCLES       => 4,
      G_SEARCH_PACKETS        => 1024,
      G_PROBE_ENABLE          => false
    )
    port map (
      i_clk            => clk,
      i_rst            => rst,
      o_cam_cs_n       => cam_cs_n,
      o_cam_sck        => cam_sck,
      i_cam_miso       => cam_miso,
      i_fifo_full      => fifo_full,
      i_fifo_empty     => fifo_empty,
      o_fifo_mark      => fifo_mark,
      o_fifo_commit    => fifo_commit,
      o_fifo_rollback  => fifo_rollback,
      o_fifo_write     => fifo_write,
      o_fifo_data      => fifo_data,
      i_desc_ready     => desc_ready,
      o_desc_valid     => desc_valid,
      o_desc_segment   => desc_segment,
      o_desc_frame     => desc_frame,
      o_sync_pulse     => sync_pulse,
      o_error_pulse    => error_pulse,
      o_error_code     => error_code
    );

  u_formatter : entity work.lepton_stream_formatter(rtl)
    generic map (
      G_FIFO_DEPTH          => 11520,
      G_UART_CLOCKS_PER_BIT => 6
    )
    port map (
      i_clk                => clk,
      i_rst                => rst,
      i_capture_error      => error_pulse,
      i_capture_error_code => error_code,
      i_fifo_mark          => fifo_mark,
      i_fifo_commit        => fifo_commit,
      i_fifo_rollback      => fifo_rollback,
      i_fifo_write         => fifo_write,
      i_fifo_data          => fifo_data,
      o_fifo_full          => fifo_full,
      o_fifo_empty         => fifo_empty,
      i_desc_valid         => desc_valid,
      i_desc_segment       => desc_segment,
      i_desc_frame         => desc_frame,
      o_desc_ready         => desc_ready,
      o_uart_tx            => uart_tx,
      o_active             => stream_active,
      o_overflow           => overflow
    );

  p_no_errors : process (clk)
  begin
    if rising_edge(clk) and rst = '0' then
      assert error_pulse = '0'
        report "integrated capture error 0x" & to_hstring(error_code)
        severity failure;
      assert overflow = '0'
        report "integrated formatter overflow"
        severity failure;
    end if;
  end process;

  p_camera : process
    procedure send_byte(constant value : in t_byte) is
    begin
      for bit_index in 7 downto 0 loop
        wait until falling_edge(cam_sck);
        cam_miso <= value(bit_index);
      end loop;
      wait until rising_edge(cam_sck);
    end procedure;

    procedure send_packet(
      constant packet_number  : in natural;
      constant segment_number : in natural
    ) is
      variable id_high : t_byte;
      variable id_low  : t_byte;
    begin
      id_high := std_logic_vector(to_unsigned((packet_number / 256) mod 16, 8));
      if packet_number = 20 then
        id_high := std_logic_vector(to_unsigned(segment_number * 16 +
                                                 ((packet_number / 256) mod 16), 8));
      end if;
      id_low := std_logic_vector(to_unsigned(packet_number mod 256, 8));

      send_byte(id_high);
      send_byte(id_low);
      send_byte(x"00");
      send_byte(x"00");
      for payload_index in 0 to C_PACKET_PAYLOAD - 1 loop
        send_byte(std_logic_vector(to_unsigned(
          (segment_number * 61 + packet_number + payload_index) mod 256, 8)));
      end loop;
    end procedure;
  begin
    wait for 8 * C_CLOCK_PERIOD;
    wait until rising_edge(clk);
    rst <= '0';
    wait until cam_cs_n = '0';

    for segment_number in 1 to 4 loop
      for packet_number in 0 to C_PACKETS_PER_SEGMENT - 1 loop
        send_packet(packet_number, segment_number);
      end loop;
    end loop;

    -- Model the disturbance seen around a long-running/FFC boundary: a
    -- repeated segment 4 followed by the tag-zero segments that the Lepton
    -- emits between unique frames. The repeat and tag zero must be dropped.
    for packet_number in 0 to C_PACKETS_PER_SEGMENT - 1 loop
      send_packet(packet_number, 4);
    end loop;
    for invalid_segment in 1 to 8 loop
      for packet_number in 0 to C_PACKETS_PER_SEGMENT - 1 loop
        send_packet(packet_number, 0);
      end loop;
    end loop;

    -- Start a partial frame, then skip segment 2. Preserve its valid tags so
    -- the Pico can abandon that frame and recover at the following segment 1.
    for packet_number in 0 to C_PACKETS_PER_SEGMENT - 1 loop
      send_packet(packet_number, 1);
    end loop;
    for packet_number in 0 to C_PACKETS_PER_SEGMENT - 1 loop
      send_packet(packet_number, 3);
    end loop;
    for packet_number in 0 to C_PACKETS_PER_SEGMENT - 1 loop
      send_packet(packet_number, 4);
    end loop;
    for invalid_segment in 1 to 8 loop
      for packet_number in 0 to C_PACKETS_PER_SEGMENT - 1 loop
        send_packet(packet_number, 0);
      end loop;
    end loop;

    for segment_number in 1 to 4 loop
      for packet_number in 0 to C_PACKETS_PER_SEGMENT - 1 loop
        send_packet(packet_number, segment_number);
      end loop;
    end loop;

    cam_miso <= '1';
    wait;
  end process;

  p_receiver : process
    procedure receive_byte(variable value : out t_byte) is
    begin
      wait until falling_edge(uart_tx);
      wait for C_UART_BIT + C_UART_BIT / 2;
      for bit_index in 0 to 7 loop
        value(bit_index) := uart_tx;
        wait for C_UART_BIT;
      end loop;
      assert uart_tx = '1' report "UART stop bit was not high" severity failure;
    end procedure;

    variable received         : t_byte;
    variable expected_segment : natural;
    variable expected_frame   : natural;
  begin
    for record_index in 0 to 10 loop
      case record_index is
        when 0 to 3 =>
          expected_segment := record_index + 1;
          expected_frame := 1;
        when 4 =>
          expected_segment := 1;
          expected_frame := 2;
        when 5 =>
          expected_segment := 3;
          expected_frame := 2;
        when 6 =>
          expected_segment := 4;
          expected_frame := 2;
        when others =>
          expected_segment := record_index - 6;
          expected_frame := 3;
      end case;

      for byte_index in 0 to 15 loop
        receive_byte(received);
        case byte_index is
          when 0  => assert received = x"4C" report "bad header magic byte 0" severity failure;
          when 1  => assert received = x"50" report "bad header magic byte 1" severity failure;
          when 2  => assert received = x"54" report "bad header magic byte 2" severity failure;
          when 3  => assert received = x"4E" report "bad header magic byte 3" severity failure;
          when 5  => assert received = std_logic_vector(to_unsigned(expected_segment, 8))
                       report "wrong segment descriptor at record " & integer'image(record_index)
                       severity failure;
          when 6  => assert received = x"04" report "wrong packed format marker" severity failure;
          when 8  => assert received = std_logic_vector(to_unsigned(expected_frame, 8))
                       report "wrong frame counter low" severity failure;
          when 9  => assert received = x"00" report "wrong frame counter high" severity failure;
          when 10 => assert received = x"20" report "wrong payload length low" severity failure;
          when 11 => assert received = x"1C" report "wrong payload length high" severity failure;
          when others => null;
        end case;
      end loop;

      for payload_index in 0 to C_SEGMENT_BYTES - 1 loop
        receive_byte(received);
      end loop;
    end loop;

    assert overflow = '0' report "formatter overflowed" severity failure;
    report "tb_capture_stream passed" severity note;
    std.env.finish;
    wait;
  end process;

  p_watchdog : process
  begin
    wait for 300 ms;
    assert false report "integrated capture stream timed out" severity failure;
    std.env.finish;
    wait;
  end process;
end architecture;