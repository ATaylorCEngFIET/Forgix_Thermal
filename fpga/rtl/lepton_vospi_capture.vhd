library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.lepton_pkg.all;

-- Lepton 3.x Raw14 VoSPI master.  The 50 MHz PLL fabric clock
-- toggles SCK every two cycles, producing an exact 12.5 MHz mode-3 SPI
-- clock. Packet headers are removed and Raw14 pixels are packed to 12 bits
-- for the FPGA-to-Pico stream FIFO.
entity lepton_vospi_capture is
  generic (
    G_INITIAL_RESYNC_CYCLES : positive := 350000000;
    G_RESYNC_CYCLES    : positive := 12500000;
    G_PACKET_GAP_CYCLES: positive := 50;
    G_CS_SETUP_CYCLES : positive := 50;
    G_SEARCH_PACKETS  : positive := 2048;
    G_WATCHDOG_CYCLES : positive := 50000000;
    G_PROBE_ENABLE     : boolean := false
  );
  port (
    i_clk          : in  std_logic;
    i_rst          : in  std_logic;
    o_cam_cs_n     : out std_logic;
    o_cam_sck      : out std_logic;
    i_cam_miso     : in  std_logic;
    i_fifo_full    : in  std_logic;
    i_fifo_empty   : in  std_logic;
    o_fifo_mark    : out std_logic;
    o_fifo_commit  : out std_logic;
    o_fifo_rollback: out std_logic;
    o_fifo_write   : out std_logic;
    o_fifo_data    : out t_byte;
    i_desc_ready   : in  std_logic;
    o_desc_valid   : out std_logic;
    o_desc_segment : out unsigned(2 downto 0);
    o_desc_frame   : out unsigned(15 downto 0);
    o_sync_pulse   : out std_logic;
    o_error_pulse  : out std_logic;
    o_error_code   : out unsigned(15 downto 0)
  );
end entity;

architecture rtl of lepton_vospi_capture is
  type t_capture_state is (resync_state, cs_hold_state, packet_gap_state,
                           cs_setup_state, drain_state, capture_state);
  type t_segment_state is (no_segment, segment_unknown, segment_accept, segment_drop);
  subtype t_resync_count is natural range 0 to G_INITIAL_RESYNC_CYCLES - 1;
  constant C_WATCHDOG_DIVISOR : positive := 256;
  constant C_WATCHDOG_TICKS   : positive :=
      (G_WATCHDOG_CYCLES + C_WATCHDOG_DIVISOR - 1) / C_WATCHDOG_DIVISOR;

  signal s_state          : t_capture_state := resync_state;
  signal s_segment_state  : t_segment_state := no_segment;
  signal s_resync_count   : t_resync_count := 0;
  signal s_initial_resync : std_logic := '1';
  signal s_sck            : std_logic := '1';
  signal s_spi_div        : natural range 0 to 1 := 0;
  signal s_hold_count     : natural range 0 to G_CS_SETUP_CYCLES - 1 := 0;
  signal s_gap_count      : natural range 0 to G_PACKET_GAP_CYCLES - 1 := 0;
  signal s_setup_count    : natural range 0 to G_CS_SETUP_CYCLES - 1 := 0;
  signal s_shift          : t_byte := (others => '0');
  signal s_bit_index      : natural range 0 to 7 := 0;
  signal s_byte_index     : natural range 0 to C_PACKET_BYTES - 1 := 0;
  signal s_id_high        : t_byte := (others => '0');
  signal s_packet_number  : natural range 0 to 4095 := 0;
  signal s_expected_packet: natural range 0 to C_PACKETS_PER_SEGMENT - 1 := 0;
  signal s_expected_segment : natural range 1 to 4 := 1;
  signal s_packet_discard : std_logic := '1';
  signal s_in_candidate   : std_logic := '0';
  signal s_frame_counter  : unsigned(15 downto 0) := (others => '0');
  signal s_probe_count    : natural range 0 to 4095 := 0;
  signal s_probe_header0  : std_logic := '0';
  signal s_search_count   : natural range 0 to G_SEARCH_PACKETS - 1 := 0;
  signal s_watchdog_div   : natural range 0 to C_WATCHDOG_DIVISOR - 1 := 0;
  signal s_watchdog_count : natural range 0 to C_WATCHDOG_TICKS - 1 := 0;
  signal s_watchdog_expired : std_logic := '0';
  signal s_pack_hi_a      : t_byte := (others => '0');
  signal s_pack_lo_a      : t_byte := (others => '0');
  signal s_pack_hi_b      : t_byte := (others => '0');

  procedure enter_resync(
    signal state          : out t_capture_state;
    signal segment_state  : out t_segment_state;
    signal sck            : out std_logic;
    signal in_candidate   : out std_logic;
    signal expected_seg   : out natural range 1 to 4
  ) is
  begin
    state         <= resync_state;
    segment_state <= no_segment;
    sck           <= '1';
    in_candidate  <= '0';
    expected_seg  <= 1;
  end procedure;
begin
  o_cam_cs_n <= '0' when s_state = cs_hold_state or
                           s_state = cs_setup_state or
                           s_state = capture_state else '1';
  o_cam_sck  <= s_sck;

  p_capture : process (i_clk)
    variable v_byte       : t_byte;
    variable v_packet     : natural range 0 to 4095;
    variable v_segment    : natural range 0 to 15;
    variable v_next_frame : unsigned(15 downto 0);
  begin
    if rising_edge(i_clk) then
      o_fifo_mark     <= '0';
      o_fifo_commit   <= '0';
      o_fifo_rollback <= '0';
      o_fifo_write    <= '0';
      o_desc_valid    <= '0';
      o_sync_pulse    <= '0';
      o_error_pulse   <= '0';

      -- Keep the long resynchronization counter at zero outside its state.
      -- This prevents unrelated packet-decode conditions from entering the
      -- counter clock-enable path.
      if s_state /= resync_state then
        s_resync_count <= 0;
      end if;

      if i_rst = '1' then
        s_state            <= resync_state;
        s_segment_state    <= no_segment;
        s_resync_count     <= 0;
        s_initial_resync   <= '1';
        s_sck              <= '1';
        s_spi_div          <= 0;
        s_hold_count       <= 0;
        s_gap_count        <= 0;
        s_setup_count      <= 0;
        s_shift            <= (others => '0');
        s_bit_index        <= 0;
        s_byte_index       <= 0;
        s_id_high          <= (others => '0');
        s_packet_number    <= 0;
        s_expected_packet  <= 0;
        s_expected_segment <= 1;
        s_packet_discard   <= '1';
        s_in_candidate     <= '0';
        s_frame_counter    <= (others => '0');
        s_probe_count      <= 0;
        s_probe_header0    <= '0';
        s_search_count     <= 0;
        s_watchdog_div     <= 0;
        s_watchdog_count   <= 0;
        s_watchdog_expired <= '0';
        s_pack_hi_a        <= (others => '0');
        s_pack_lo_a        <= (others => '0');
        s_pack_hi_b        <= (others => '0');
        o_fifo_data        <= (others => '0');
        o_desc_segment     <= (others => '0');
        o_desc_frame       <= (others => '0');
        o_error_code       <= (others => '0');
      elsif s_state /= resync_state and s_watchdog_expired = '1' then
        -- Periodic FFC can leave a no-VSYNC reader searching indefinitely.
        -- Force the documented /CS-high resynchronization when no numbered
        -- segment descriptor has appeared for one second.
        s_watchdog_div     <= 0;
        s_watchdog_count   <= 0;
        s_watchdog_expired <= '0';
        o_fifo_rollback  <= '1';
        o_error_code     <= to_unsigned(16#7000#, o_error_code'length);
        o_error_pulse    <= '1';
        enter_resync(s_state, s_segment_state,
                     s_sck, s_in_candidate, s_expected_segment);
      elsif s_state = resync_state then
        s_watchdog_div     <= 0;
        s_watchdog_count   <= 0;
        s_watchdog_expired <= '0';
        s_sck <= '1';
        s_spi_div <= 0;
        if (s_initial_resync = '1' and
            s_resync_count = G_INITIAL_RESYNC_CYCLES - 1) or
           (s_initial_resync = '0' and
            s_resync_count = G_RESYNC_CYCLES - 1) then
          s_state           <= cs_setup_state;
          s_setup_count     <= 0;
          s_resync_count    <= 0;
          s_bit_index       <= 0;
          s_byte_index      <= 0;
          s_in_candidate    <= '0';
          s_search_count    <= 0;
          s_segment_state   <= no_segment;
          s_expected_packet <= 0;
          s_initial_resync  <= '0';
          o_sync_pulse      <= '1';
        else
          s_resync_count <= s_resync_count + 1;
        end if;

      elsif s_state = cs_hold_state then
        -- Keep /CS asserted after the final sampling edge. Raising SCK and
        -- /CS in the same fabric cycle gives the Lepton no select hold time
        -- and eventually shifts its packet phase.
        s_sck     <= '1';
        s_spi_div <= 0;
        if s_hold_count = G_CS_SETUP_CYCLES - 1 then
          s_hold_count <= 0;
          s_gap_count  <= 0;
          s_state      <= packet_gap_state;
        else
          s_hold_count <= s_hold_count + 1;
        end if;

      elsif s_state = packet_gap_state then
        s_sck     <= '1';
        s_spi_div <= 0;
        if s_gap_count = G_PACKET_GAP_CYCLES - 1 then
          s_gap_count   <= 0;
          s_setup_count <= 0;
          s_state       <= cs_setup_state;
          s_bit_index <= 0;
          s_byte_index <= 0;
        else
          s_gap_count <= s_gap_count + 1;
        end if;

      elsif s_state = cs_setup_state then
        s_sck     <= '1';
        s_spi_div <= 0;
        if s_setup_count = G_CS_SETUP_CYCLES - 1 then
          s_setup_count <= 0;
          s_state       <= capture_state;
        else
          s_setup_count <= s_setup_count + 1;
        end if;

      elsif s_state = drain_state then
        -- Pause at a packet boundary while UART drains the committed segment.
        -- CS remains high for far less than the 250 ms SPI resync interval.
        s_sck     <= '1';
        s_spi_div <= 0;
        if i_fifo_empty = '1' then
          s_state           <= cs_setup_state;
          s_setup_count     <= 0;
          s_bit_index       <= 0;
          s_byte_index      <= 0;
          s_in_candidate    <= '0';
          s_segment_state   <= no_segment;
          s_expected_packet <= 0;
        end if;
      else
        -- Prescale the one-second watchdog so its terminal comparison does
        -- not sit on the state-machine reset path. Expiry is registered and
        -- acted on during the following clock cycle.
        if s_watchdog_div = C_WATCHDOG_DIVISOR - 1 then
          s_watchdog_div <= 0;
          if s_watchdog_count = C_WATCHDOG_TICKS - 1 then
            s_watchdog_count   <= 0;
            s_watchdog_expired <= '1';
          else
            s_watchdog_count <= s_watchdog_count + 1;
          end if;
        else
          s_watchdog_div <= s_watchdog_div + 1;
        end if;
        if s_spi_div = 1 then
          s_spi_div <= 0;
          -- Mode 3: falling edges ask the Lepton to change data and rising
          -- edges sample MISO. Two 50 MHz clocks per half-cycle yield
          -- an exact 12.5 MHz SCK.
          if s_sck = '1' then
            s_sck <= '0';
          else
            s_sck <= '1';
          v_byte := s_shift(6 downto 0) & i_cam_miso;
          s_shift <= v_byte;

          if s_bit_index = 7 then
            s_bit_index <= 0;

            if s_byte_index = 0 then
              s_id_high <= v_byte;
              if v_byte(3 downto 0) = "1111" then
                s_packet_discard <= '1';
              else
                s_packet_discard <= '0';
              end if;
            elsif s_byte_index = 1 then
              v_packet := to_integer(unsigned(s_id_high(3 downto 0) & v_byte));
              s_packet_number <= v_packet;

              -- Temporary SPI-only synchronization probe.  While searching,
              -- report the first and then one header every 4096 search packets without changing
              -- the capture state.  0x5xxx carries the 12-bit packet ID;
              -- 0x60xx carries the complete first header byte on the next
              -- sample.  A correctly aligned idle stream reports 0x5fff.
              if G_PROBE_ENABLE and s_segment_state = no_segment then
                if s_probe_count = 0 then
                  s_probe_count <= 1;
                  if s_probe_header0 = '0' then
                    o_error_code <= to_unsigned(16#5000# + v_packet,
                                                o_error_code'length);
                    s_probe_header0 <= '1';
                  else
                    o_error_code <= to_unsigned(16#6000# +
                                                to_integer(unsigned(s_id_high)),
                                                o_error_code'length);
                    s_probe_header0 <= '0';
                  end if;
                  o_error_pulse <= '1';
                elsif s_probe_count = 4095 then
                  s_probe_count <= 0;
                else
                  s_probe_count <= s_probe_count + 1;
                end if;
              end if;


              -- A discard header cannot belong to a numbered segment. Before
              -- packet 20 it can be a speculative false match; after commit
              -- it is a genuine truncated segment and must clear the
              -- published descriptor via hard resync.
              if s_packet_discard = '1' and s_in_candidate = '1' then
                if s_segment_state = segment_accept then
                  o_error_code <= to_unsigned(
                      16#1000# + (s_expected_packet mod 64) * 64 + 63,
                      o_error_code'length);
                  o_error_pulse <= '1';
                  enter_resync(s_state, s_segment_state,
                               s_sck, s_in_candidate, s_expected_segment);
                else
                  o_fifo_rollback   <= '1';
                  s_in_candidate    <= '0';
                  s_segment_state   <= no_segment;
                  s_expected_packet <= 0;
                end if;
              end if;

              if s_packet_discard = '0' then
                if v_packet = 0 and s_in_candidate = '0' then
                  s_in_candidate    <= '1';
                  s_segment_state   <= segment_unknown;
                  s_expected_packet <= 0;
                  o_fifo_mark       <= '1';
                elsif s_in_candidate = '1' and v_packet /= s_expected_packet then
                  if s_segment_state = segment_unknown then
                    -- A zero-valued word in discard/image data can look like
                    -- packet 0 while SPI-only synchronization is searching.
                    -- Roll it back and continue on the same 164-byte cadence;
                    -- forcing a 250 ms reset here would repeatedly restart the
                    -- search before a real 0,1 packet pair is confirmed.
                    o_fifo_rollback  <= '1';
                    s_in_candidate   <= '0';
                    s_segment_state  <= no_segment;
                    s_expected_packet <= 0;
                  else
                    -- Once packet 20 has committed the segment tag, a sequence
                    -- break is genuine corruption and requires hard resync.
                    o_error_code  <= to_unsigned(
                        16#1000# + (s_expected_packet mod 64) * 64 +
                        (v_packet mod 64),
                        o_error_code'length);
                    o_error_pulse <= '1';
                    enter_resync(s_state, s_segment_state,
                                 s_sck, s_in_candidate, s_expected_segment);
                  end if;
                end if;

                if v_packet = 20 and s_in_candidate = '1' then
                  -- Lepton 3.x declares segment 1..4 in packet 20 bits 14:12.
                  v_segment := to_integer(unsigned(s_id_high(6 downto 4)));
                  if v_segment >= 1 and v_segment <= 4 then
                    if v_segment = 4 and s_expected_segment = 1 then
                      -- A repeated segment 4 is the only valid-tag burst seen
                      -- between Lepton frames. Discard it before it can push
                      -- the faster SPI producer beyond the FIFO's burst room.
                      o_fifo_rollback  <= '1';
                      s_segment_state <= segment_drop;
                    elsif i_desc_ready = '1' then
                      -- Packet 20 reveals the segment number.  Publish now
                      -- so UART drains packets 0..19 while SPI continues
                      -- capturing packets 20..59 into the same FIFO.  Do not
                      -- reject an otherwise valid segment solely because its
                      -- tag is out of sequence: the Lepton can expose repeats
                      -- around startup/FFC, and frame assembly is deliberately
                      -- handled by the Pico using the transmitted tag.
                      o_fifo_commit   <= '1';
                      s_segment_state <= segment_accept;
                      -- Delay the next search probe until the segment UART
                      -- payload has been completely drained.
                      s_probe_count   <= 1;
                      s_search_count  <= 0;
                      o_desc_valid     <= '1';
                      s_watchdog_div   <= 0;
                      s_watchdog_count <= 0;
                      s_watchdog_expired <= '0';
                      o_desc_segment  <= to_unsigned(v_segment, o_desc_segment'length);
                      if v_segment = 1 then
                        v_next_frame := s_frame_counter + 1;
                        s_frame_counter <= v_next_frame;
                        o_desc_frame <= v_next_frame;
                      else
                        o_desc_frame <= s_frame_counter;
                      end if;
                      if v_segment = 4 then
                        s_expected_segment <= 1;
                      else
                        s_expected_segment <= v_segment + 1;
                      end if;
                    else
                      o_fifo_rollback <= '1';
                      o_error_code    <= x"4000";
                      o_error_pulse   <= '1';
                      enter_resync(s_state, s_segment_state,
                                   s_sck, s_in_candidate, s_expected_segment);
                    end if;
                  else
                    -- Tag zero is duplicate output; other tags are invalid.
                    o_fifo_rollback <= '1';
                    s_segment_state <= segment_drop;
                    if v_segment > 4 then
                      o_error_code  <= to_unsigned(16#2000# + (v_segment mod 64),
                                                  o_error_code'length);
                      o_error_pulse <= '1';
                    end if;
                  end if;
                end if;
              end if;
            elsif s_byte_index >= C_PACKET_HEADER then
              if s_packet_discard = '0' and
                 (s_segment_state = segment_unknown or s_segment_state = segment_accept) then
                -- Pack two Raw14 pixels into three bytes after dropping the
                -- two least-significant bits from each pixel.
                case (s_byte_index - C_PACKET_HEADER) mod 4 is
                  when 0 =>
                    s_pack_hi_a <= v_byte;
                  when 1 =>
                    s_pack_lo_a <= v_byte;
                    if i_fifo_full = '0' then
                      o_fifo_write <= '1';
                      o_fifo_data  <= s_pack_hi_a(5 downto 0) & v_byte(7 downto 6);
                    end if;
                  when 2 =>
                    s_pack_hi_b <= v_byte;
                    if i_fifo_full = '0' then
                      o_fifo_write <= '1';
                      o_fifo_data  <= s_pack_lo_a(5 downto 2) & v_byte(5 downto 2);
                    end if;
                  when others =>
                    if i_fifo_full = '0' then
                      o_fifo_write <= '1';
                      o_fifo_data  <= s_pack_hi_b(1 downto 0) & v_byte(7 downto 2);
                    end if;
                end case;
                if i_fifo_full = '1' and
                   (s_byte_index - C_PACKET_HEADER) mod 4 /= 0 then
                  if s_segment_state = segment_unknown then
                    o_fifo_rollback <= '1';
                  end if;
                  o_error_code  <= x"3000";
                  o_error_pulse <= '1';
                  enter_resync(s_state, s_segment_state,
                               s_sck, s_in_candidate, s_expected_segment);
                end if;
              end if;
            end if;

            if s_byte_index = C_PACKET_BYTES - 1 then
              s_byte_index <= 0;
              if s_packet_discard = '0' and s_in_candidate = '1' then
                if s_packet_number = C_PACKETS_PER_SEGMENT - 1 then
                  s_in_candidate  <= '0';
                  s_segment_state <= no_segment;
                  -- Once packet zero establishes alignment, keep /CS low for
                  -- the complete 60-packet segment. End the transaction only
                  -- after packet 59, with the explicit post-clock hold time.
                  s_hold_count <= 0;
                  s_state      <= cs_hold_state;
                else
                  s_expected_packet <= s_packet_number + 1;
                end if;
              end if;

              -- Bound the packet search; the independent watchdog performs
              -- the documented long /CS-high resynchronization if no segment
              -- descriptor is produced.
              if s_segment_state = no_segment then
                if s_search_count = G_SEARCH_PACKETS - 1 then
                  s_search_count <= 0;
                else
                  s_search_count <= s_search_count + 1;
                end if;
              end if;

              -- Without VSYNC, frame each discard/search packet separately so
              -- packet zero remains discoverable. After packet zero is found,
              -- the segment state is no longer no_segment and /CS stays low
              -- continuously through packet 59.
              if s_segment_state = no_segment then
                s_hold_count <= 0;
                s_state      <= cs_hold_state;
              end if;
            else
              s_byte_index <= s_byte_index + 1;
            end if;
          else
            s_bit_index <= s_bit_index + 1;
          end if;
          end if;
        else
          s_spi_div <= s_spi_div + 1;
        end if;
      end if;
    end if;
  end process;
end architecture;
