library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.lepton_pkg.all;

entity uart_tx is
  generic (
    G_CLOCKS_PER_BIT : positive := 4
  );
  port (
    i_clk   : in  std_logic;
    i_rst   : in  std_logic;
    i_data  : in  t_byte;
    i_valid : in  std_logic;
    o_ready : out std_logic;
    o_tx    : out std_logic
  );
end entity;

architecture rtl of uart_tx is
  signal s_busy      : std_logic := '0';
  signal s_shift     : std_logic_vector(9 downto 0) := (others => '1');
  signal s_bit_index : natural range 0 to 9 := 0;
  signal s_divider   : natural range 0 to G_CLOCKS_PER_BIT - 1 := 0;
begin
  o_ready <= not s_busy;
  o_tx    <= '1' when s_busy = '0' else s_shift(s_bit_index);

  p_tx : process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        s_busy      <= '0';
        s_shift     <= (others => '1');
        s_bit_index <= 0;
        s_divider   <= 0;
      elsif s_busy = '0' then
        if i_valid = '1' then
          -- start, eight data bits LSB first, stop
          s_shift     <= '1' & i_data & '0';
          s_bit_index <= 0;
          s_divider   <= 0;
          s_busy      <= '1';
        end if;
      elsif s_divider = G_CLOCKS_PER_BIT - 1 then
        s_divider <= 0;
        if s_bit_index = 9 then
          s_busy <= '0';
        else
          s_bit_index <= s_bit_index + 1;
        end if;
      else
        s_divider <= s_divider + 1;
      end if;
    end if;
  end process;
end architecture;
