library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.lepton_pkg.all;

entity tb_uart_tx is
end entity;

architecture sim of tb_uart_tx is
  constant C_CLOCK_PERIOD : time := 31.25 ns;
  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal tx_data  : t_byte := (others => '0');
  signal tx_valid : std_logic := '0';
  signal tx_ready : std_logic;
  signal tx       : std_logic;
begin
  clk <= not clk after C_CLOCK_PERIOD / 2;

  u_dut : entity work.uart_tx(rtl)
    generic map (
      G_CLOCKS_PER_BIT => 4
    )
    port map (
      i_clk   => clk,
      i_rst   => rst,
      i_data  => tx_data,
      i_valid => tx_valid,
      o_ready => tx_ready,
      o_tx    => tx
    );

  p_stimulus : process
    variable received : t_byte := (others => '0');
  begin
    wait for 5 * C_CLOCK_PERIOD;
    rst <= '0';
    wait until rising_edge(clk) and tx_ready = '1';
    tx_data  <= x"A5";
    tx_valid <= '1';
    wait until rising_edge(clk);
    tx_valid <= '0';

    wait until tx = '0';
    wait for (4 * C_CLOCK_PERIOD) + (2 * C_CLOCK_PERIOD);
    for bit_index in 0 to 7 loop
      received(bit_index) := tx;
      wait for 4 * C_CLOCK_PERIOD;
    end loop;
    assert tx = '1' report "UART stop bit was not high" severity failure;
    assert received = x"A5" report "UART data mismatch" severity failure;
    report "tb_uart_tx passed" severity note;
    std.env.finish;
    wait;
  end process;
end architecture;
