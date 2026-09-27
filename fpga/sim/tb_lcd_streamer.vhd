library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_lcd_streamer is
  generic (
    G_GC9A01A : boolean := false
  );
end entity;

architecture sim of tb_lcd_streamer is
  constant C_CLOCK_PERIOD : time := 20 ns;
  constant C_UART_BIT     : time := 6 * C_CLOCK_PERIOD;

  signal s_clk         : std_logic := '0';
  signal s_rst         : std_logic := '1';
  signal s_uart_rx     : std_logic := '1';
  signal s_lcd_din     : std_logic;
  signal s_lcd_clk     : std_logic;
  signal s_lcd_cs_n    : std_logic;
  signal s_lcd_dc      : std_logic;
  signal s_lcd_rst_n   : std_logic;
  signal s_lcd_bl      : std_logic;
  signal s_ready       : std_logic;
  signal s_rx_error    : std_logic;
  signal s_ramwr_count : natural range 0 to 7 := 0;

  procedure uart_send(signal line : out std_logic; value : std_logic_vector(7 downto 0)) is
  begin
    line <= '0';
    wait for C_UART_BIT;
    for bit_index in 0 to 7 loop
      line <= value(bit_index);
      wait for C_UART_BIT;
    end loop;
    line <= '1';
    wait for C_UART_BIT;
  end procedure;

  procedure send_frame(signal line : out std_logic) is
  begin
    uart_send(line, x"4C");
    uart_send(line, x"43");
    uart_send(line, x"44");
    uart_send(line, x"30");
    uart_send(line, x"01");
    uart_send(line, x"A5");
    uart_send(line, x"5A");
    uart_send(line, x"C3");
    uart_send(line, x"12");
    uart_send(line, x"34");
    uart_send(line, x"AB");
    uart_send(line, x"CD");
  end procedure;
begin
  s_clk <= not s_clk after C_CLOCK_PERIOD / 2;

  u_dut : entity work.lcd_streamer(rtl)
    generic map (
      G_GC9A01A              => G_GC9A01A,
      G_UART_CLOCKS_PER_BIT   => 6,
      G_SPI_HALF_CLOCKS       => 1,
      G_RESET_PRE_HIGH_CYCLES => 2,
      G_RESET_LOW_CYCLES      => 2,
      G_RESET_HIGH_CYCLES     => 2,
      G_SOFTWARE_RESET_CYCLES => 2,
      G_SLEEP_OUT_CYCLES      => 2,
      G_DISPLAY_ON_CYCLES     => 2,
      G_CLEAR_BYTES           => 8,
      G_FRAME_BYTES           => 4
    )
    port map (
      i_clk       => s_clk,
      i_rst       => s_rst,
      i_uart_rx   => s_uart_rx,
      o_lcd_din   => s_lcd_din,
      o_lcd_clk   => s_lcd_clk,
      o_lcd_cs_n  => s_lcd_cs_n,
      o_lcd_dc    => s_lcd_dc,
      o_lcd_rst_n => s_lcd_rst_n,
      o_lcd_bl    => s_lcd_bl,
      o_ready     => s_ready,
      o_rx_error  => s_rx_error
    );

  p_command_monitor : process
    variable v_shift : std_logic_vector(7 downto 0) := (others => '0');
    variable v_bit   : natural range 0 to 7 := 0;
  begin
    wait until rising_edge(s_lcd_clk);
    if s_lcd_dc = '0' then
      v_shift := v_shift(6 downto 0) & s_lcd_din;
      if v_bit = 7 then
        if v_shift = x"2C" then
          s_ramwr_count <= s_ramwr_count + 1;
        end if;
        v_bit := 0;
      else
        v_bit := v_bit + 1;
      end if;
    else
      v_bit := 0;
    end if;
  end process;

  p_stimulus : process
  begin
    wait for 5 * C_CLOCK_PERIOD;
    s_rst <= '0';
    wait until s_ready = '1';
    assert s_lcd_bl = '1' and s_lcd_cs_n = '0'
      report "LCD did not complete initialization" severity failure;
    assert s_ramwr_count = 1
      report "LCD clear did not issue RAMWR" severity failure;

    send_frame(s_uart_rx);
    wait for 2 us;
    send_frame(s_uart_rx);
    wait for 2 us;

    assert s_ramwr_count = 3
      report "Each LCD frame must issue its own RAMWR command" severity failure;
    assert s_rx_error = '0' report "LCD UART/SPI stream error" severity failure;
    report "tb_lcd_streamer passed" severity note;
    stop;
    wait;
  end process;
end architecture;
