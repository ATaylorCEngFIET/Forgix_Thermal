library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.lepton_pkg.all;

entity tb_byte_fifo is
end entity;

architecture sim of tb_byte_fifo is
  constant C_CLOCK_PERIOD : time := 20 ns;
  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';
  signal clear      : std_logic := '0';
  signal mark       : std_logic := '0';
  signal commit     : std_logic := '0';
  signal rollback   : std_logic := '0';
  signal write_en   : std_logic := '0';
  signal write_data : t_byte := (others => '0');
  signal full       : std_logic;
  signal used       : natural range 0 to 32;
  signal read_en    : std_logic := '0';
  signal read_data  : t_byte;
  signal read_valid : std_logic;
  signal empty      : std_logic;
begin
  clk <= not clk after C_CLOCK_PERIOD / 2;

  u_dut : entity work.byte_fifo(rtl)
    generic map (G_DEPTH => 32)
    port map (
      i_clk => clk, i_rst => rst, i_clear => clear,
      i_mark => mark, i_commit => commit, i_rollback => rollback,
      i_write => write_en, i_write_data => write_data,
      o_full => full, o_used => used,
      i_read => read_en, o_read_data => read_data,
      o_read_valid => read_valid, o_empty => empty
    );

  p_stimulus : process
    procedure tick is
    begin
      wait until rising_edge(clk);
      wait for 1 ns;
    end procedure;

    procedure push(constant value : in t_byte) is
    begin
      write_data <= value;
      write_en <= '1';
      tick;
      write_en <= '0';
    end procedure;
  begin
    wait for 4 * C_CLOCK_PERIOD;
    wait until falling_edge(clk);
    rst <= '0';
    tick;

    push(x"11");
    push(x"22");
    push(x"33");
    push(x"44");

    mark <= '1';
    read_en <= '1';
    tick;
    assert read_valid = '1' and read_data = x"11"
      report "mark dropped a simultaneous read" severity failure;
    mark <= '0';
    read_en <= '0';

    push(x"A1");
    push(x"A2");

    commit <= '1';
    read_en <= '1';
    tick;
    assert read_valid = '1' and read_data = x"22"
      report "commit dropped a simultaneous read" severity failure;
    commit <= '0';
    read_en <= '0';

    mark <= '1';
    read_en <= '1';
    tick;
    assert read_valid = '1' and read_data = x"33"
      report "second mark dropped a simultaneous read" severity failure;
    mark <= '0';
    read_en <= '0';

    push(x"B1");

    rollback <= '1';
    read_en <= '1';
    tick;
    assert read_valid = '1' and read_data = x"44"
      report "rollback dropped a simultaneous committed read" severity failure;
    rollback <= '0';

    tick;
    assert read_valid = '1' and read_data = x"A1"
      report "first committed post-rollback byte was wrong" severity failure;
    tick;
    assert read_valid = '1' and read_data = x"A2"
      report "second committed post-rollback byte was wrong" severity failure;
    read_en <= '0';
    tick;
    assert empty = '1' and used = 0
      report "FIFO occupancy was wrong after concurrent controls" severity failure;

    report "tb_byte_fifo passed" severity note;
    std.env.finish;
    wait;
  end process;
end architecture;
