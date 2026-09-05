library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.lepton_pkg.all;

entity tb_stream_formatter is
end entity;

architecture sim of tb_stream_formatter is
  constant C_CLOCK_PERIOD : time := 31.25 ns;
  constant C_UART_BIT     : time := 4 * C_CLOCK_PERIOD;

  type t_header is array (0 to 15) of t_byte;
  constant C_EXPECTED_HEADER : t_header := (
    x"4C", x"50", x"54", x"4E", x"01", x"01", x"04", x"10",
    x"34", x"12", x"20", x"1C", x"00", x"00", x"B5", x"BD"
  );

  signal clk           : std_logic := '0';
  signal rst           : std_logic := '1';
  signal fifo_write    : std_logic := '0';
  signal fifo_data     : t_byte := (others => '0');
  signal fifo_full     : std_logic;
  signal desc_valid    : std_logic := '0';
  signal desc_segment  : unsigned(2 downto 0) := (others => '0');
  signal desc_frame    : unsigned(15 downto 0) := (others => '0');
  signal desc_ready    : std_logic;
  signal uart_tx       : std_logic;
  signal stream_active : std_logic;
  signal overflow      : std_logic;
begin
  clk <= not clk after C_CLOCK_PERIOD / 2;

  u_dut : entity work.lepton_stream_formatter(rtl)
    generic map (
      G_UART_CLOCKS_PER_BIT => 4
    )
    port map (
      i_clk           => clk,
      i_rst           => rst,
      i_capture_error => '0',
      i_capture_error_code => x"0000",
      i_fifo_mark     => '0',
      i_fifo_commit   => '0',
      i_fifo_rollback => '0',
      i_fifo_write    => fifo_write,
      i_fifo_data     => fifo_data,
      o_fifo_full     => fifo_full,
      o_fifo_empty    => open,
      i_desc_valid    => desc_valid,
      i_desc_segment  => desc_segment,
      i_desc_frame    => desc_frame,
      o_desc_ready    => desc_ready,
      o_uart_tx       => uart_tx,
      o_active        => stream_active,
      o_overflow      => overflow
    );

  p_stimulus : process
  begin
    wait for 8 * C_CLOCK_PERIOD;
    wait until rising_edge(clk);
    rst <= '0';

    -- Match the capture block: the final payload byte and the completed
    -- segment descriptor are presented on the same clock.
    for index in 0 to C_SEGMENT_BYTES - 1 loop
      wait until rising_edge(clk);
      assert fifo_full = '0' report "formatter FIFO filled unexpectedly" severity failure;
      fifo_write <= '1';
      fifo_data <= std_logic_vector(to_unsigned(index mod 256, 8));
      if index = C_SEGMENT_BYTES - 1 then
        assert desc_ready = '1' report "descriptor FIFO was not ready" severity failure;
        desc_valid <= '1';
        desc_segment <= to_unsigned(1, desc_segment'length);
        desc_frame <= x"1234";
      end if;
    end loop;
    wait until rising_edge(clk);
    fifo_write <= '0';
    desc_valid <= '0';
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

    variable received : t_byte;
    variable expected : t_byte;
  begin
    for index in 0 to 15 + C_SEGMENT_BYTES loop
      receive_byte(received);
      if index < 16 then
        expected := C_EXPECTED_HEADER(index);
      else
        expected := std_logic_vector(to_unsigned((index - 16) mod 256, 8));
      end if;
      assert received = expected
        report "formatter byte mismatch at index " & integer'image(index)
        severity failure;
    end loop;

    assert overflow = '0' report "formatter overflowed" severity failure;
    report "tb_stream_formatter passed" severity note;
    std.env.finish;
    wait;
  end process;
end architecture;
