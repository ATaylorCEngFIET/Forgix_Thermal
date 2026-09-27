library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.lepton_pkg.all;

entity uart_rx is
  generic (
    G_CLOCKS_PER_BIT : positive := 6
  );
  port (
    i_clk           : in  std_logic;
    i_rst           : in  std_logic;
    i_rx            : in  std_logic;
    o_data          : out t_byte;
    o_valid         : out std_logic;
    o_framing_error : out std_logic
  );
end entity;

architecture rtl of uart_rx is
  type t_state is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
  signal s_state     : t_state := IDLE;
  signal s_rx_meta   : std_logic := '1';
  signal s_rx_sync   : std_logic := '1';
  signal s_divider   : natural range 0 to G_CLOCKS_PER_BIT - 1 := 0;
  signal s_bit_index : natural range 0 to 7 := 0;
  signal s_data      : t_byte := (others => '0');
begin
  o_data <= s_data;

  p_rx : process (i_clk)
  begin
    if rising_edge(i_clk) then
      s_rx_meta <= i_rx;
      s_rx_sync <= s_rx_meta;
      o_valid <= '0';
      o_framing_error <= '0';

      if i_rst = '1' then
        s_state <= IDLE;
        s_divider <= 0;
        s_bit_index <= 0;
        s_data <= (others => '0');
        s_rx_meta <= '1';
        s_rx_sync <= '1';
      else
        case s_state is
          when IDLE =>
            s_divider <= 0;
            if s_rx_sync = '0' then
              s_state <= START_BIT;
            end if;

          when START_BIT =>
            if s_divider = (G_CLOCKS_PER_BIT - 1) / 2 then
              s_divider <= 0;
              if s_rx_sync = '0' then
                s_bit_index <= 0;
                s_state <= DATA_BITS;
              else
                s_state <= IDLE;
              end if;
            else
              s_divider <= s_divider + 1;
            end if;

          when DATA_BITS =>
            if s_divider = G_CLOCKS_PER_BIT - 1 then
              s_divider <= 0;
              s_data(s_bit_index) <= s_rx_sync;
              if s_bit_index = 7 then
                s_state <= STOP_BIT;
              else
                s_bit_index <= s_bit_index + 1;
              end if;
            else
              s_divider <= s_divider + 1;
            end if;

          when STOP_BIT =>
            if s_divider = G_CLOCKS_PER_BIT - 1 then
              s_divider <= 0;
              if s_rx_sync = '1' then
                o_valid <= '1';
              else
                o_framing_error <= '1';
              end if;
              s_state <= IDLE;
            else
              s_divider <= s_divider + 1;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
