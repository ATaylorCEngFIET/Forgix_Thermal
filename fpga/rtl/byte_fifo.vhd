library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.lepton_pkg.all;

-- A synchronous byte FIFO with a speculative write checkpoint.  Lepton 3.x
-- does not reveal the segment number until packet 20, so packets 0..19 are
-- written speculatively and either committed or rolled back at packet 20.
entity byte_fifo is
  generic (
    G_DEPTH : positive := 10240
  );
  port (
    i_clk        : in  std_logic;
    i_rst        : in  std_logic;
    i_clear      : in  std_logic;
    i_mark       : in  std_logic;
    i_commit     : in  std_logic;
    i_rollback   : in  std_logic;
    i_write      : in  std_logic;
    i_write_data : in  t_byte;
    o_full       : out std_logic;
    o_used       : out natural range 0 to G_DEPTH;
    i_read       : in  std_logic;
    o_read_data  : out t_byte;
    o_read_valid : out std_logic;
    o_empty      : out std_logic
  );
end entity;

architecture rtl of byte_fifo is
  type t_memory is array (0 to G_DEPTH - 1) of t_byte;
  signal s_memory : t_memory;

  signal s_write_pointer : natural range 0 to G_DEPTH - 1 := 0;
  signal s_read_pointer  : natural range 0 to G_DEPTH - 1 := 0;
  signal s_mark_pointer  : natural range 0 to G_DEPTH - 1 := 0;
  signal s_used          : natural range 0 to G_DEPTH := 0;
  signal s_speculative   : natural range 0 to G_DEPTH := 0;
  signal s_mark_active   : std_logic := '0';

  function increment_pointer(value : natural) return natural is
  begin
    if value = G_DEPTH - 1 then
      return 0;
    end if;
    return value + 1;
  end function;
begin
  o_full  <= '1' when s_used = G_DEPTH else '0';
  o_empty <= '1' when s_used = 0 else '0';
  o_used  <= s_used;

  p_fifo : process (i_clk)
  begin
    if rising_edge(i_clk) then
      o_read_valid <= '0';

      if i_rst = '1' or i_clear = '1' then
        s_write_pointer <= 0;
        s_read_pointer  <= 0;
        s_mark_pointer  <= 0;
        s_used          <= 0;
        s_speculative   <= 0;
        s_mark_active   <= '0';
        o_read_data     <= (others => '0');
      elsif i_rollback = '1' and s_mark_active = '1' then
        -- Rollback is a single registered pointer/count update. Keeping it
        -- separate from ordinary reads and writes avoids a long chain of
        -- speculative arithmetic in the FIFO count path.
        s_write_pointer <= s_mark_pointer;
        if i_read = '1' and s_used > s_speculative then
          o_read_data    <= s_memory(s_read_pointer);
          o_read_valid   <= '1';
          s_read_pointer <= increment_pointer(s_read_pointer);
          s_used         <= s_used - s_speculative - 1;
        else
          s_used         <= s_used - s_speculative;
        end if;
        s_speculative   <= 0;
        s_mark_active   <= '0';
      elsif i_mark = '1' then
        -- If packet 0 restarts a damaged candidate, first discard the old
        -- speculative region and reuse its checkpoint.
        if s_mark_active = '1' then
          s_write_pointer <= s_mark_pointer;
          if i_read = '1' and s_used > s_speculative then
            o_read_data    <= s_memory(s_read_pointer);
            o_read_valid   <= '1';
            s_read_pointer <= increment_pointer(s_read_pointer);
            s_used         <= s_used - s_speculative - 1;
          else
            s_used         <= s_used - s_speculative;
          end if;
        else
          s_mark_pointer <= s_write_pointer;
          if i_read = '1' and s_used /= 0 then
            o_read_data    <= s_memory(s_read_pointer);
            o_read_valid   <= '1';
            s_read_pointer <= increment_pointer(s_read_pointer);
            s_used         <= s_used - 1;
          end if;
        end if;
        s_speculative <= 0;
        s_mark_active <= '1';
      elsif i_commit = '1' then
        s_speculative <= 0;
        s_mark_active <= '0';
        if i_read = '1' and s_used /= 0 then
          o_read_data    <= s_memory(s_read_pointer);
          o_read_valid   <= '1';
          s_read_pointer <= increment_pointer(s_read_pointer);
          s_used         <= s_used - 1;
        end if;
      elsif i_read = '1' and s_used /= 0 then
        o_read_data    <= s_memory(s_read_pointer);
        o_read_valid   <= '1';
        s_read_pointer <= increment_pointer(s_read_pointer);

        if i_write = '1' then
          -- A simultaneous read creates the space consumed by this write,
          -- including when the FIFO was full; occupancy is unchanged.
          s_memory(s_write_pointer) <= i_write_data;
          s_write_pointer <= increment_pointer(s_write_pointer);
          if s_mark_active = '1' then
            s_speculative <= s_speculative + 1;
          end if;
        else
          s_used <= s_used - 1;
        end if;
      elsif i_write = '1' and s_used < G_DEPTH then
        s_memory(s_write_pointer) <= i_write_data;
        s_write_pointer <= increment_pointer(s_write_pointer);
        s_used <= s_used + 1;
        if s_mark_active = '1' then
          s_speculative <= s_speculative + 1;
        end if;
      end if;
    end if;
  end process;end architecture;
