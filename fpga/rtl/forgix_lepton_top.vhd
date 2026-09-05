library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.lepton_pkg.all;

entity forgix_lepton is
  port (
    i_clk_32m       : in  std_logic;
    i_clk_100m      : in  std_logic;
    i_clk_50m       : in  std_logic;
    i_pll_locked    : in  std_logic;
    i_cfg_cs_n      : in  std_logic;
    i_cfg_uart_rx   : in  std_logic;
    i_cfg_uart_data : in  std_logic;
    o_cfg_uart_data : out std_logic;
    o_cfg_uart_oe   : out std_logic;
    o_cam_cs_n      : out std_logic;
    o_cam_sck       : out std_logic;
    i_cam_miso      : in  std_logic;
    o_led_r_n       : out std_logic;
    o_led_g_n       : out std_logic;
    o_led_b_n       : out std_logic
  );
end entity;

architecture rtl of forgix_lepton is
  constant C_POR_DONE : unsigned(7 downto 0) := (others => '1');
  signal s_por_count : unsigned(7 downto 0) := (others => '0');
  signal s_rst       : std_logic;

  signal s_fifo_mark     : std_logic;
  signal s_fifo_commit   : std_logic;
  signal s_fifo_rollback : std_logic;
  signal s_fifo_write    : std_logic;
  signal s_fifo_data     : t_byte;
  signal s_fifo_full     : std_logic;
  signal s_fifo_empty    : std_logic;
  signal s_desc_valid    : std_logic;
  signal s_desc_ready    : std_logic;
  signal s_desc_segment  : unsigned(2 downto 0);
  signal s_desc_frame    : unsigned(15 downto 0);
  signal s_sync_pulse    : std_logic;
  signal s_error_pulse   : std_logic;
  signal s_error_code    : unsigned(15 downto 0);
  signal s_stream_active : std_logic;
  signal s_stream_error  : std_logic;
  signal s_uart_tx       : std_logic;
  signal s_heartbeat     : unsigned(23 downto 0) := (others => '0');
  signal s_error_latched : std_logic := '0';
begin
  -- Configuration-only inputs are deliberately retained in the top-level
  -- interface so Efinity keeps the board's passive-SPI pin assignment.  Once
  -- configuration completes, CDI0 becomes the 5 Mbaud FPGA-to-RP2354 UART.
  o_cfg_uart_data <= s_uart_tx;
  o_cfg_uart_oe   <= '1';

  s_rst <= '1' when i_pll_locked = '0' or s_por_count /= C_POR_DONE else '0';

  p_housekeeping : process (i_clk_50m)
  begin
    if rising_edge(i_clk_50m) then
      if s_por_count /= C_POR_DONE then
        s_por_count <= s_por_count + 1;
      else
        s_heartbeat <= s_heartbeat + 1;
      end if;

      if s_rst = '1' then
        s_error_latched <= '0';
      elsif s_error_pulse = '1' or s_stream_error = '1' then
        s_error_latched <= '1';
      end if;
    end if;
  end process;

  u_capture : entity work.lepton_vospi_capture(rtl)
    generic map (
      G_PROBE_ENABLE => false
    )
    port map (
      i_clk           => i_clk_50m,
      i_rst           => s_rst,
      o_cam_cs_n      => o_cam_cs_n,
      o_cam_sck       => o_cam_sck,
      i_cam_miso      => i_cam_miso,
      i_fifo_full     => s_fifo_full,
      i_fifo_empty    => s_fifo_empty,
      o_fifo_mark     => s_fifo_mark,
      o_fifo_commit   => s_fifo_commit,
      o_fifo_rollback => s_fifo_rollback,
      o_fifo_write    => s_fifo_write,
      o_fifo_data     => s_fifo_data,
      i_desc_ready    => s_desc_ready,
      o_desc_valid    => s_desc_valid,
      o_desc_segment  => s_desc_segment,
      o_desc_frame    => s_desc_frame,
      o_sync_pulse    => s_sync_pulse,
      o_error_pulse   => s_error_pulse,
      o_error_code    => s_error_code
    );

  u_stream : entity work.lepton_stream_formatter(rtl)
    generic map (
      G_FIFO_DEPTH          => 11520,
      G_UART_CLOCKS_PER_BIT => 6
    )
    port map (
      i_clk           => i_clk_50m,
      i_rst           => s_rst,
      i_capture_error => s_error_pulse,
      i_capture_error_code => s_error_code,
      i_fifo_mark     => s_fifo_mark,
      i_fifo_commit   => s_fifo_commit,
      i_fifo_rollback => s_fifo_rollback,
      i_fifo_write    => s_fifo_write,
      i_fifo_data     => s_fifo_data,
      o_fifo_full     => s_fifo_full,
      o_fifo_empty    => s_fifo_empty,
      i_desc_valid    => s_desc_valid,
      i_desc_segment  => s_desc_segment,
      i_desc_frame    => s_desc_frame,
      o_desc_ready    => s_desc_ready,
      o_uart_tx       => s_uart_tx,
      o_active        => s_stream_active,
      o_overflow      => s_stream_error
    );

  -- Common-anode RGB LED: green heartbeat, blue while streaming, red latched
  -- after a capture/FIFO error.
  o_led_r_n <= not s_error_latched;
  o_led_g_n <= not s_heartbeat(23);
  o_led_b_n <= not s_stream_active;
end architecture;
