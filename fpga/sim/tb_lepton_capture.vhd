library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.lepton_pkg.all;

entity tb_lepton_capture is
end entity;

architecture sim of tb_lepton_capture is
  constant C_CLOCK_PERIOD : time := 31.25 ns;
  signal clk          : std_logic := '0';
  signal rst          : std_logic := '1';
  signal cam_cs_n     : std_logic;
  signal cam_sck      : std_logic;
  signal cam_miso     : std_logic := '0';
  signal fifo_mark    : std_logic;
  signal fifo_commit  : std_logic;
  signal fifo_rollback: std_logic;
  signal fifo_write   : std_logic;
  signal fifo_data    : t_byte;
  signal desc_valid   : std_logic;
  signal desc_segment : unsigned(2 downto 0);
  signal desc_frame   : unsigned(15 downto 0);
  signal sync_pulse   : std_logic;
  signal error_pulse  : std_logic;
  signal write_count  : natural := 0;
  signal mark_count   : natural := 0;
  signal commit_count : natural := 0;
  signal rollback_count : natural := 0;
  signal desc_count   : natural := 0;
begin
  clk <= not clk after C_CLOCK_PERIOD / 2;

  u_dut : entity work.lepton_vospi_capture(rtl)
    generic map (
      G_INITIAL_RESYNC_CYCLES => 16,
      G_RESYNC_CYCLES  => 16,
      G_PACKET_GAP_CYCLES => 16,
      G_SEARCH_PACKETS => 2
    )
    port map (
      i_clk           => clk,
      i_rst           => rst,
      o_cam_cs_n      => cam_cs_n,
      o_cam_sck       => cam_sck,
      i_cam_miso      => cam_miso,
      i_fifo_full     => '0',
      i_fifo_empty    => '1',
      o_fifo_mark     => fifo_mark,
      o_fifo_commit   => fifo_commit,
      o_fifo_rollback => fifo_rollback,
      o_fifo_write    => fifo_write,
      o_fifo_data     => fifo_data,
      i_desc_ready    => '1',
      o_desc_valid    => desc_valid,
      o_desc_segment  => desc_segment,
      o_desc_frame    => desc_frame,
      o_sync_pulse    => sync_pulse,
      o_error_pulse   => error_pulse,
      o_error_code    => open
    );

  p_monitor : process (clk)
  begin
    if rising_edge(clk) then
      if fifo_write = '1' then
        if write_count = 0 then
          assert fifo_data = x"00" report "packed byte 0 mismatch" severity failure;
        elsif write_count = 1 then
          assert fifo_data = x"00" report "packed byte 1 mismatch" severity failure;
        elsif write_count = 2 then
          assert fifo_data = x"80" report "packed byte 2 mismatch" severity failure;
        end if;
        write_count <= write_count + 1;
      end if;
      if fifo_mark = '1' then
        mark_count <= mark_count + 1;
      end if;
      if fifo_commit = '1' then
        commit_count <= commit_count + 1;
      end if;
      if fifo_rollback = '1' then
        rollback_count <= rollback_count + 1;
      end if;
      if desc_valid = '1' then
        desc_count <= desc_count + 1;
        assert desc_segment = 1 report "wrong descriptor segment" severity failure;
        assert desc_frame = 1 report "wrong descriptor frame" severity failure;
      end if;
      if rst = '0' then
        assert error_pulse = '0' report "unexpected capture error" severity failure;
      end if;
    end if;
  end process;

  p_stimulus : process
    procedure send_byte(constant value : in t_byte) is
    begin
      for bit_index in 7 downto 0 loop
        wait until falling_edge(cam_sck);
        cam_miso <= value(bit_index);
      end loop;
      wait until rising_edge(cam_sck);
    end procedure;

    procedure send_packet(
      constant packet_number : in natural;
      constant segment_number: in natural;
      constant discard       : in boolean := false
    ) is
      variable id_high : t_byte;
      variable id_low  : t_byte;
    begin
      if discard then
        id_high := x"0F";
        id_low  := x"00";
      else
        id_high := std_logic_vector(to_unsigned((packet_number / 256) mod 16, 8));
        if packet_number = 20 then
          id_high := std_logic_vector(to_unsigned(segment_number * 16 +
                                                   ((packet_number / 256) mod 16), 8));
        end if;
        id_low := std_logic_vector(to_unsigned(packet_number mod 256, 8));
      end if;

      send_byte(id_high);
      send_byte(id_low);
      send_byte(x"00");
      send_byte(x"00");
      for payload_index in 0 to C_PACKET_PAYLOAD - 1 loop
        send_byte(std_logic_vector(to_unsigned((packet_number + payload_index) mod 256, 8)));
      end loop;
    end procedure;
  begin
    wait for 8 * C_CLOCK_PERIOD;
    rst <= '0';
    wait until cam_cs_n = '0';

    -- Two unmatched packets exercise the bounded long-resync path before
    -- packet 0 establishes alignment.
    send_packet(17, 0);
    send_packet(18, 0);
    for packet_index in 0 to 20 loop
      send_packet(packet_index, 1);
    end loop;
    wait for 1 ns;
    assert desc_count = 1
      report "descriptor was not published when packet 20 identified the segment" severity failure;

    for packet_index in 21 to C_PACKETS_PER_SEGMENT - 1 loop
      send_packet(packet_index, 1);
    end loop;
    wait for 1 ns;

    assert cam_cs_n = '1'
      report "/CS was not released at the segment boundary" severity failure;

    assert mark_count = 1 report "valid segment was not checkpointed" severity failure;
    assert commit_count = 1 report "valid segment was not committed" severity failure;
    assert rollback_count = 0 report "valid segment was rolled back" severity failure;
    assert desc_count = 1 report "valid segment descriptor count is wrong" severity failure;
    assert write_count = C_SEGMENT_BYTES - 1 report "wrong valid payload byte count before the monitor catches the final pulse: " & integer'image(write_count) severity failure;

    -- Segment zero is part of an invalid Lepton 3.x frame.  The first twenty
    -- payload packets are speculative and must be rolled back at packet 20.
    -- The capture engine starts the next transaction after its short gap.
    wait until cam_cs_n = '0';
    for packet_index in 0 to C_PACKETS_PER_SEGMENT - 1 loop
      send_packet(packet_index, 0);
    end loop;
    wait for 1 ns;

    assert mark_count = 2 report "invalid segment was not checkpointed" severity failure;
    assert commit_count = 1 report "invalid segment was committed" severity failure;
    assert rollback_count = 1 report "invalid segment was not rolled back" severity failure;
    assert desc_count = 1 report "invalid segment generated a descriptor" severity failure;
    assert write_count = C_SEGMENT_BYTES + 20 * C_STREAM_PACKET_PAYLOAD
      report "wrong speculative payload byte count" severity failure;

    report "tb_lepton_capture passed" severity note;
    std.env.finish;
    wait;
  end process;
end architecture;
