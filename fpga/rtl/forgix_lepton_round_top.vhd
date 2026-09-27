library ieee;
use ieee.std_logic_1164.all;

entity forgix_lepton_round is
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
    o_lcd_din       : out std_logic;
    o_lcd_clk       : out std_logic;
    o_lcd_cs_n      : out std_logic;
    o_lcd_dc        : out std_logic;
    o_lcd_rst_n     : out std_logic;
    o_lcd_bl        : out std_logic;
    o_led_r_n       : out std_logic;
    o_led_g_n       : out std_logic;
    o_led_b_n       : out std_logic
  );
end entity;

architecture rtl of forgix_lepton_round is
begin
  u_core : entity work.forgix_lepton(rtl)
    generic map (G_LCD_GC9A01A => true)
    port map (
      i_clk_32m => i_clk_32m,
      i_clk_100m => i_clk_100m,
      i_clk_50m => i_clk_50m,
      i_pll_locked => i_pll_locked,
      i_cfg_cs_n => i_cfg_cs_n,
      i_cfg_uart_rx => i_cfg_uart_rx,
      i_cfg_uart_data => i_cfg_uart_data,
      o_cfg_uart_data => o_cfg_uart_data,
      o_cfg_uart_oe => o_cfg_uart_oe,
      o_cam_cs_n => o_cam_cs_n,
      o_cam_sck => o_cam_sck,
      i_cam_miso => i_cam_miso,
      o_lcd_din => o_lcd_din,
      o_lcd_clk => o_lcd_clk,
      o_lcd_cs_n => o_lcd_cs_n,
      o_lcd_dc => o_lcd_dc,
      o_lcd_rst_n => o_lcd_rst_n,
      o_lcd_bl => o_lcd_bl,
      o_led_r_n => o_led_r_n,
      o_led_g_n => o_led_g_n,
      o_led_b_n => o_led_b_n
    );
end architecture;
