library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.lepton_pkg.all;

entity lcd_streamer is
  generic (
    G_GC9A01A              : boolean := false;
    G_UART_CLOCKS_PER_BIT   : positive := 6;
    G_SPI_HALF_CLOCKS       : positive := 2;
    G_RESET_PRE_HIGH_CYCLES : positive := 5000000;
    G_RESET_LOW_CYCLES      : positive := 5000000;
    G_RESET_HIGH_CYCLES     : positive := 10000000;
    G_SOFTWARE_RESET_CYCLES : positive := 7500000;
    G_SLEEP_OUT_CYCLES      : positive := 6000000;
    G_DISPLAY_ON_CYCLES     : positive := 5000000;
    G_CLEAR_BYTES           : positive := 40960;
    G_FRAME_BYTES           : positive := 38400
  );
  port (
    i_clk        : in  std_logic;
    i_rst        : in  std_logic;
    i_uart_rx    : in  std_logic;
    o_lcd_din    : out std_logic;
    o_lcd_clk    : out std_logic;
    o_lcd_cs_n   : out std_logic;
    o_lcd_dc     : out std_logic;
    o_lcd_rst_n  : out std_logic;
    o_lcd_bl     : out std_logic;
    o_ready      : out std_logic;
    o_rx_error   : out std_logic
  );
end entity;

architecture rtl of lcd_streamer is
  type t_rom is array (natural range <>) of std_logic_vector(8 downto 0);

  constant C_DELAY_DIVISOR : positive := 1024;

  function delay_ticks(cycles : positive) return positive is
  begin
    return (cycles + C_DELAY_DIVISOR - 1) / C_DELAY_DIVISOR;
  end function;

  function max_positive(left_value : positive;
                        right_value : positive) return positive is
  begin
    if left_value > right_value then return left_value; end if;
    return right_value;
  end function;

  constant C_DELAY_MAX_TICKS : positive := max_positive(
      max_positive(delay_ticks(G_RESET_PRE_HIGH_CYCLES),
                   delay_ticks(G_RESET_LOW_CYCLES)),
      max_positive(
          max_positive(delay_ticks(G_RESET_HIGH_CYCLES),
                       delay_ticks(G_SOFTWARE_RESET_CYCLES)),
          max_positive(delay_ticks(G_SLEEP_OUT_CYCLES),
                       delay_ticks(G_DISPLAY_ON_CYCLES))));

  -- Bit 8 is D/C; bits 7:0 are the ST7735S byte. This is the Waveshare-style
  -- power, frame-rate, RGB565, and landscape setup sequence.
  constant C_INIT_ST7735 : t_rom := (
    '0' & x"B1", '1' & x"01", '1' & x"2C", '1' & x"2D",
    '0' & x"B2", '1' & x"01", '1' & x"2C", '1' & x"2D",
    '0' & x"B3", '1' & x"01", '1' & x"2C", '1' & x"2D",
                  '1' & x"01", '1' & x"2C", '1' & x"2D",
    '0' & x"B4", '1' & x"07",
    '0' & x"C0", '1' & x"A2", '1' & x"02", '1' & x"84",
    '0' & x"C1", '1' & x"C5",
    '0' & x"C2", '1' & x"0A", '1' & x"00",
    '0' & x"C3", '1' & x"8A", '1' & x"2A",
    '0' & x"C4", '1' & x"8A", '1' & x"EE",
    '0' & x"C5", '1' & x"0E",
    '0' & x"20",
    '0' & x"3A", '1' & x"05",
    '0' & x"36", '1' & x"A0"
  );

  -- GC9A01A vendor initialization used by the Adafruit 1.28-inch 240x240
  -- round display. Sleep-out and display-on are sent and timed separately.
  constant C_INIT_GC9A01A : t_rom := (
    '0' & x"EF", '0' & x"EB", '1' & x"14", '0' & x"FE",
    '0' & x"EF", '0' & x"EB", '1' & x"14",
    '0' & x"84", '1' & x"40", '0' & x"85", '1' & x"FF",
    '0' & x"86", '1' & x"FF", '0' & x"87", '1' & x"FF",
    '0' & x"88", '1' & x"0A", '0' & x"89", '1' & x"21",
    '0' & x"8A", '1' & x"00", '0' & x"8B", '1' & x"80",
    '0' & x"8C", '1' & x"01", '0' & x"8D", '1' & x"01",
    '0' & x"8E", '1' & x"FF", '0' & x"8F", '1' & x"FF",
    '0' & x"B6", '1' & x"00", '1' & x"00",
    '0' & x"36", '1' & x"48", '0' & x"3A", '1' & x"05",
    '0' & x"90", '1' & x"08", '1' & x"08", '1' & x"08", '1' & x"08",
    '0' & x"BD", '1' & x"06", '0' & x"BC", '1' & x"00",
    '0' & x"FF", '1' & x"60", '1' & x"01", '1' & x"04",
    '0' & x"C3", '1' & x"13", '0' & x"C4", '1' & x"13",
    '0' & x"C9", '1' & x"22", '0' & x"BE", '1' & x"11",
    '0' & x"E1", '1' & x"10", '1' & x"0E",
    '0' & x"DF", '1' & x"21", '1' & x"0C", '1' & x"02",
    '0' & x"F0", '1' & x"45", '1' & x"09", '1' & x"08", '1' & x"08", '1' & x"26", '1' & x"2A",
    '0' & x"F1", '1' & x"43", '1' & x"70", '1' & x"72", '1' & x"36", '1' & x"37", '1' & x"6F",
    '0' & x"F2", '1' & x"45", '1' & x"09", '1' & x"08", '1' & x"08", '1' & x"26", '1' & x"2A",
    '0' & x"F3", '1' & x"43", '1' & x"70", '1' & x"72", '1' & x"36", '1' & x"37", '1' & x"6F",
    '0' & x"ED", '1' & x"1B", '1' & x"0B",
    '0' & x"AE", '1' & x"77", '0' & x"CD", '1' & x"63",
    '0' & x"E8", '1' & x"34",
    '0' & x"62", '1' & x"18", '1' & x"0D", '1' & x"71", '1' & x"ED", '1' & x"70", '1' & x"70",
                  '1' & x"18", '1' & x"0F", '1' & x"71", '1' & x"EF", '1' & x"70", '1' & x"70",
    '0' & x"63", '1' & x"18", '1' & x"11", '1' & x"71", '1' & x"F1", '1' & x"70", '1' & x"70",
                  '1' & x"18", '1' & x"13", '1' & x"71", '1' & x"F3", '1' & x"70", '1' & x"70",
    '0' & x"64", '1' & x"28", '1' & x"29", '1' & x"F1", '1' & x"01", '1' & x"F1", '1' & x"00", '1' & x"07",
    '0' & x"66", '1' & x"3C", '1' & x"00", '1' & x"CD", '1' & x"67", '1' & x"45", '1' & x"45",
                  '1' & x"10", '1' & x"00", '1' & x"00", '1' & x"00",
    '0' & x"67", '1' & x"00", '1' & x"3C", '1' & x"00", '1' & x"00", '1' & x"00", '1' & x"01",
                  '1' & x"54", '1' & x"10", '1' & x"32", '1' & x"98",
    '0' & x"74", '1' & x"10", '1' & x"85", '1' & x"80", '1' & x"00", '1' & x"00", '1' & x"4E", '1' & x"00",
    '0' & x"98", '1' & x"3E", '1' & x"07", '0' & x"35", '0' & x"21"
  );

  -- Landscape 160x128 window. Native ST7735S RAM has a one-pixel offset in
  -- the short axis on this Waveshare module.
  constant C_FULL_WINDOW_ST7735 : t_rom := (
    '0' & x"2A", '1' & x"00", '1' & x"01", '1' & x"00", '1' & x"A0",
    '0' & x"2B", '1' & x"00", '1' & x"02", '1' & x"00", '1' & x"81",
    '0' & x"2C"
  );

  -- The 160x120 Lepton image is centered vertically: logical rows 4..123,
  -- which become controller rows 6..125 after the module offset.
  constant C_IMAGE_WINDOW_ST7735 : t_rom := (
    '0' & x"2A", '1' & x"00", '1' & x"01", '1' & x"00", '1' & x"A0",
    '0' & x"2B", '1' & x"00", '1' & x"06", '1' & x"00", '1' & x"7D"
  );

  constant C_FULL_WINDOW_GC9A01A : t_rom := (
    '0' & x"2A", '1' & x"00", '1' & x"00", '1' & x"00", '1' & x"EF",
    '0' & x"2B", '1' & x"00", '1' & x"00", '1' & x"00", '1' & x"EF",
    '0' & x"2C"
  );

  -- A centered 192x144 4:3 image fits inside the circular aperture.
  constant C_IMAGE_WINDOW_GC9A01A : t_rom := (
    '0' & x"2A", '1' & x"00", '1' & x"18", '1' & x"00", '1' & x"D7",
    '0' & x"2B", '1' & x"00", '1' & x"30", '1' & x"00", '1' & x"BF"
  );

  function init_high(round_display : boolean) return natural is
  begin
    if round_display then return C_INIT_GC9A01A'high; end if;
    return C_INIT_ST7735'high;
  end function;

  function init_byte(index : natural; round_display : boolean) return std_logic_vector is
  begin
    if round_display then return C_INIT_GC9A01A(index); end if;
    return C_INIT_ST7735(index);
  end function;

  function full_window_byte(index : natural; round_display : boolean) return std_logic_vector is
  begin
    if round_display then return C_FULL_WINDOW_GC9A01A(index); end if;
    return C_FULL_WINDOW_ST7735(index);
  end function;

  function image_window_byte(index : natural; round_display : boolean) return std_logic_vector is
  begin
    if round_display then return C_IMAGE_WINDOW_GC9A01A(index); end if;
    return C_IMAGE_WINDOW_ST7735(index);
  end function;

  type t_state is (
    RESET_PRE_HIGH, RESET_LOW, RESET_HIGH, SEND_SWRESET, DELAY_SWRESET,
    SEND_SLPOUT, DELAY_SLPOUT, INIT_SEQUENCE, SEND_DISPON, DELAY_DISPLAY_ON,
    FULL_WINDOW, CLEAR_SCREEN, IMAGE_WINDOW, READY,
    FRAME_RAMWR, FRAME_PIXELS, FRAME_FINISH
  );
  signal s_state : t_state := RESET_PRE_HIGH;

  signal s_uart_data  : t_byte;
  signal s_uart_valid : std_logic;
  signal s_uart_error : std_logic;

  signal s_spi_busy      : std_logic := '0';
  signal s_spi_shift     : t_byte := (others => '0');
  signal s_spi_bit       : natural range 0 to 7 := 0;
  signal s_spi_phase     : std_logic := '0';
  signal s_spi_divider   : natural range 0 to G_SPI_HALF_CLOCKS - 1 := 0;
  signal s_spi_clk       : std_logic := '0';
  signal s_spi_din       : std_logic := '0';
  signal s_spi_dc        : std_logic := '0';
  signal s_spi_cs_n      : std_logic := '1';
  signal s_spi_command_gap : std_logic := '0';
  signal s_spi_end       : std_logic := '0';
  signal s_tx_start      : std_logic := '0';
  signal s_tx_data       : t_byte := (others => '0');
  signal s_tx_dc         : std_logic := '0';
  signal s_tx_end        : std_logic := '0';
  signal s_tx_pending    : std_logic := '0';

  signal s_delay_div     : natural range 0 to C_DELAY_DIVISOR - 1 := 0;
  signal s_delay_count   : natural range 0 to C_DELAY_MAX_TICKS - 1 := 0;
  signal s_init_index    : natural range 0 to C_INIT_GC9A01A'high := 0;
  signal s_window_index  : natural range 0 to C_FULL_WINDOW_ST7735'high := 0;
  signal s_clear_count   : natural range 0 to G_CLEAR_BYTES - 1 := 0;
  signal s_frame_count   : natural range 0 to G_FRAME_BYTES - 1 := 0;
  signal s_magic         : std_logic_vector(31 downto 0) := (others => '0');
  signal s_header_index  : natural range 0 to 3 := 0;
  signal s_header_active : std_logic := '0';
  signal s_ready         : std_logic := '0';
  signal s_rx_error      : std_logic := '0';

  function header_byte(index : natural) return t_byte is
  begin
    case index is
      when 0 => return x"01";
      when 1 => return x"A5";
      when 2 => return x"5A";
      when others => return x"C3";
    end case;
  end function;
begin
  o_lcd_din <= s_spi_din;
  o_lcd_clk <= s_spi_clk;
  o_lcd_dc <= s_spi_dc;
  o_lcd_cs_n <= s_spi_cs_n;
  o_lcd_rst_n <= '0' when s_state = RESET_LOW else '1';
  o_lcd_bl <= s_ready;
  o_ready <= s_ready;
  o_rx_error <= s_rx_error;

  u_uart_rx : entity work.uart_rx(rtl)
    generic map (
      G_CLOCKS_PER_BIT => G_UART_CLOCKS_PER_BIT
    )
    port map (
      i_clk           => i_clk,
      i_rst           => i_rst,
      i_rx            => i_uart_rx,
      o_data          => s_uart_data,
      o_valid         => s_uart_valid,
      o_framing_error => s_uart_error
    );

  p_spi : process (i_clk)
  begin
    if rising_edge(i_clk) then
      if i_rst = '1' then
        s_spi_busy <= '0';
        s_spi_shift <= (others => '0');
        s_spi_bit <= 0;
        s_spi_phase <= '0';
        s_spi_divider <= 0;
        s_spi_clk <= '0';
        s_spi_din <= '0';
        s_spi_dc <= '0';
        s_spi_cs_n <= '1';
        s_spi_command_gap <= '0';
        s_spi_end <= '0';
      elsif s_spi_busy = '0' then
        s_spi_clk <= '0';
        if s_tx_start = '1' then
          s_spi_busy <= '1';
          s_spi_shift <= s_tx_data;
          s_spi_bit <= 0;
          s_spi_phase <= '0';
          s_spi_divider <= 0;
          s_spi_din <= s_tx_data(7);
          s_spi_dc <= s_tx_dc;
          s_spi_end <= s_tx_end;
          if s_tx_dc = '0' then
            -- Delimit each command exactly as Adafruit_SPITFT does. Data
            -- arguments remain in the same active-low CS transaction.
            s_spi_cs_n <= '1';
            s_spi_command_gap <= '1';
          else
            s_spi_cs_n <= '0';
            s_spi_command_gap <= '0';
          end if;
        end if;
      elsif s_spi_command_gap = '1' then
        -- Provide a complete 50 MHz clock with CS high before the command.
        s_spi_cs_n <= '0';
        s_spi_command_gap <= '0';
        s_spi_clk <= '0';
        s_spi_divider <= 0;
      elsif s_spi_divider = G_SPI_HALF_CLOCKS - 1 then
        s_spi_divider <= 0;
        if s_spi_phase = '0' then
          s_spi_clk <= '1';
          s_spi_phase <= '1';
        else
          s_spi_clk <= '0';
          s_spi_phase <= '0';
          if s_spi_bit = 7 then
            s_spi_busy <= '0';
            if s_spi_end = '1' then
              s_spi_cs_n <= '1';
            end if;
          else
            s_spi_bit <= s_spi_bit + 1;
            s_spi_din <= s_spi_shift(6 - s_spi_bit);
          end if;
        end if;
      else
        s_spi_divider <= s_spi_divider + 1;
      end if;
    end if;
  end process;

  p_control : process (i_clk)
    variable v_magic : std_logic_vector(31 downto 0);
    variable v_byte  : std_logic_vector(8 downto 0);
  begin
    if rising_edge(i_clk) then
      s_tx_start <= '0';
      s_tx_end <= '0';

      if i_rst = '1' then
        s_state <= RESET_PRE_HIGH;
        s_tx_pending <= '0';
        s_tx_end <= '0';
        s_delay_div <= 0;
        s_delay_count <= 0;
        s_init_index <= 0;
        s_window_index <= 0;
        s_clear_count <= 0;
        s_frame_count <= 0;
        s_magic <= (others => '0');
        s_header_index <= 0;
        s_header_active <= '0';
        s_ready <= '0';
        s_rx_error <= '0';
      else
        if s_uart_error = '1' then
          s_rx_error <= '1';
        end if;

        case s_state is
          when RESET_PRE_HIGH =>
            -- Match Adafruit_SPITFT's hardware-reset sequence. Starting
            -- high first is important when the LCD and FPGA power up
            -- together and prevents a short configuration-time pulse from
            -- being mistaken for the controller reset.
            s_ready <= '0';
            if s_delay_div = C_DELAY_DIVISOR - 1 then
              s_delay_div <= 0;
              if s_delay_count = delay_ticks(G_RESET_PRE_HIGH_CYCLES) - 1 then
                s_delay_count <= 0;
                s_state <= RESET_LOW;
              else
                s_delay_count <= s_delay_count + 1;
              end if;
            else
              s_delay_div <= s_delay_div + 1;
            end if;

          when RESET_LOW =>
            s_ready <= '0';
            if s_delay_div = C_DELAY_DIVISOR - 1 then
              s_delay_div <= 0;
              if s_delay_count = delay_ticks(G_RESET_LOW_CYCLES) - 1 then
                s_delay_count <= 0;
                s_state <= RESET_HIGH;
              else
                s_delay_count <= s_delay_count + 1;
              end if;
            else
              s_delay_div <= s_delay_div + 1;
            end if;

          when RESET_HIGH =>
            if s_delay_div = C_DELAY_DIVISOR - 1 then
              s_delay_div <= 0;
              if s_delay_count = delay_ticks(G_RESET_HIGH_CYCLES) - 1 then
                s_delay_count <= 0;
                -- Use SWRESET after the hardware pulse as well. This is
                -- accepted by both controllers and makes startup independent
                -- of the breakout's automatic-reset supervisor timing.
                s_state <= SEND_SWRESET;
              else
                s_delay_count <= s_delay_count + 1;
              end if;
            else
              s_delay_div <= s_delay_div + 1;
            end if;

          when SEND_SWRESET =>
            if s_tx_pending = '0' and s_spi_busy = '0' then
              s_tx_data <= x"01";
              s_tx_dc <= '0';
              s_tx_end <= '1';
              s_tx_start <= '1';
              s_tx_pending <= '1';
            elsif s_tx_pending = '1' and s_spi_busy = '0' then
              s_tx_pending <= '0';
              s_delay_div <= 0;
              s_delay_count <= 0;
              s_state <= DELAY_SWRESET;
            end if;

          when DELAY_SWRESET =>
            if s_delay_div = C_DELAY_DIVISOR - 1 then
              s_delay_div <= 0;
              if s_delay_count = delay_ticks(G_SOFTWARE_RESET_CYCLES) - 1 then
                s_delay_count <= 0;
                s_init_index <= 0;
                if G_GC9A01A then
                  s_state <= INIT_SEQUENCE;
                else
                  s_state <= SEND_SLPOUT;
                end if;
              else
                s_delay_count <= s_delay_count + 1;
              end if;
            else
              s_delay_div <= s_delay_div + 1;
            end if;

          when SEND_SLPOUT =>
            if s_tx_pending = '0' and s_spi_busy = '0' then
              s_tx_data <= x"11";
              s_tx_dc <= '0';
              s_tx_end <= '1';
              s_tx_start <= '1';
              s_tx_pending <= '1';
            elsif s_tx_pending = '1' and s_spi_busy = '0' then
              s_tx_pending <= '0';
              s_delay_div <= 0;
              s_delay_count <= 0;
              s_state <= DELAY_SLPOUT;
            end if;

          when DELAY_SLPOUT =>
            if s_delay_div = C_DELAY_DIVISOR - 1 then
              s_delay_div <= 0;
              if s_delay_count = delay_ticks(G_SLEEP_OUT_CYCLES) - 1 then
                s_delay_count <= 0;
                if G_GC9A01A then
                  s_state <= SEND_DISPON;
                else
                  s_init_index <= 0;
                  s_state <= INIT_SEQUENCE;
                end if;
              else
                s_delay_count <= s_delay_count + 1;
              end if;
            else
              s_delay_div <= s_delay_div + 1;
            end if;

          when INIT_SEQUENCE =>
            if s_tx_pending = '0' and s_spi_busy = '0' then
              v_byte := init_byte(s_init_index, G_GC9A01A);
              s_tx_data <= v_byte(7 downto 0);
              s_tx_dc <= v_byte(8);
              if s_init_index = init_high(G_GC9A01A) then
                s_tx_end <= '1';
              elsif init_byte(s_init_index + 1, G_GC9A01A)(8) = '0' then
                s_tx_end <= '1';
              end if;
              s_tx_start <= '1';
              s_tx_pending <= '1';
            elsif s_tx_pending = '1' and s_spi_busy = '0' then
              s_tx_pending <= '0';
              if s_init_index = init_high(G_GC9A01A) then
                if G_GC9A01A then
                  s_state <= SEND_SLPOUT;
                else
                  s_state <= SEND_DISPON;
                end if;
              else
                s_init_index <= s_init_index + 1;
              end if;
            end if;

          when SEND_DISPON =>
            if s_tx_pending = '0' and s_spi_busy = '0' then
              s_tx_data <= x"29";
              s_tx_dc <= '0';
              s_tx_end <= '1';
              s_tx_start <= '1';
              s_tx_pending <= '1';
            elsif s_tx_pending = '1' and s_spi_busy = '0' then
              s_tx_pending <= '0';
              s_delay_div <= 0;
              s_delay_count <= 0;
              s_state <= DELAY_DISPLAY_ON;
            end if;

          when DELAY_DISPLAY_ON =>
            if s_delay_div = C_DELAY_DIVISOR - 1 then
              s_delay_div <= 0;
              if s_delay_count = delay_ticks(G_DISPLAY_ON_CYCLES) - 1 then
                s_delay_count <= 0;
                s_window_index <= 0;
                s_state <= FULL_WINDOW;
              else
                s_delay_count <= s_delay_count + 1;
              end if;
            else
              s_delay_div <= s_delay_div + 1;
            end if;

          when FULL_WINDOW =>
            if s_tx_pending = '0' and s_spi_busy = '0' then
              v_byte := full_window_byte(s_window_index, G_GC9A01A);
              s_tx_data <= v_byte(7 downto 0);
              s_tx_dc <= v_byte(8);
              if s_window_index < C_FULL_WINDOW_ST7735'high then
                if full_window_byte(s_window_index + 1, G_GC9A01A)(8) = '0' then
                  s_tx_end <= '1';
                end if;
              end if;
              s_tx_start <= '1';
              s_tx_pending <= '1';
            elsif s_tx_pending = '1' and s_spi_busy = '0' then
              s_tx_pending <= '0';
              if s_window_index = C_FULL_WINDOW_ST7735'high then
                s_clear_count <= 0;
                s_state <= CLEAR_SCREEN;
              else
                s_window_index <= s_window_index + 1;
              end if;
            end if;

          when CLEAR_SCREEN =>
            if s_tx_pending = '0' and s_spi_busy = '0' then
              -- Use a visible colour for the round display's initial clear.
              -- This leaves a diagnostic border outside the 192x144 image
              -- and proves controller initialization without relying on UART.
              if G_GC9A01A and (s_clear_count mod 2) = 0 then
                s_tx_data <= x"F8";
              else
                s_tx_data <= x"00";
              end if;
              s_tx_dc <= '1';
              if s_clear_count = G_CLEAR_BYTES - 1 then
                s_tx_end <= '1';
              end if;
              s_tx_start <= '1';
              s_tx_pending <= '1';
            elsif s_tx_pending = '1' and s_spi_busy = '0' then
              s_tx_pending <= '0';
              if s_clear_count = G_CLEAR_BYTES - 1 then
                s_window_index <= 0;
                s_state <= IMAGE_WINDOW;
              else
                s_clear_count <= s_clear_count + 1;
              end if;
            end if;

          when IMAGE_WINDOW =>
            if s_tx_pending = '0' and s_spi_busy = '0' then
              v_byte := image_window_byte(s_window_index, G_GC9A01A);
              s_tx_data <= v_byte(7 downto 0);
              s_tx_dc <= v_byte(8);
              if s_window_index = C_IMAGE_WINDOW_ST7735'high then
                s_tx_end <= '1';
              elsif image_window_byte(s_window_index + 1, G_GC9A01A)(8) = '0' then
                s_tx_end <= '1';
              end if;
              s_tx_start <= '1';
              s_tx_pending <= '1';
            elsif s_tx_pending = '1' and s_spi_busy = '0' then
              s_tx_pending <= '0';
              if s_window_index = C_IMAGE_WINDOW_ST7735'high then
                s_ready <= '1';
                s_magic <= (others => '0');
                s_header_active <= '0';
                s_state <= READY;
              else
                s_window_index <= s_window_index + 1;
              end if;
            end if;

          when READY =>
            if s_uart_valid = '1' then
              if s_header_active = '1' then
                if s_uart_data = header_byte(s_header_index) then
                  if s_header_index = 3 then
                    s_header_active <= '0';
                    s_frame_count <= 0;
                    s_state <= FRAME_RAMWR;
                  else
                    s_header_index <= s_header_index + 1;
                  end if;
                else
                  s_header_active <= '0';
                  s_header_index <= 0;
                  s_magic <= (others => '0');
                end if;
              else
                v_magic := s_magic(23 downto 0) & s_uart_data;
                s_magic <= v_magic;
                if v_magic = x"4C434430" then
                  s_header_active <= '1';
                  s_header_index <= 0;
                end if;
              end if;
            end if;

          when FRAME_RAMWR =>
            if s_tx_pending = '0' and s_spi_busy = '0' then
              s_tx_data <= x"2C";
              s_tx_dc <= '0';
              s_tx_end <= '0';
              s_tx_start <= '1';
              s_tx_pending <= '1';
            elsif s_tx_pending = '1' and s_spi_busy = '0' then
              s_tx_pending <= '0';
              s_state <= FRAME_PIXELS;
            end if;

          when FRAME_PIXELS =>
            if s_tx_pending = '1' and s_spi_busy = '0' then
              s_tx_pending <= '0';
            elsif s_uart_valid = '1' then
              if s_tx_pending = '0' and s_spi_busy = '0' then
                s_tx_data <= s_uart_data;
                s_tx_dc <= '1';
                if s_frame_count = G_FRAME_BYTES - 1 then
                  s_tx_end <= '1';
                end if;
                s_tx_start <= '1';
                s_tx_pending <= '1';
                if s_frame_count = G_FRAME_BYTES - 1 then
                  s_state <= FRAME_FINISH;
                else
                  s_frame_count <= s_frame_count + 1;
                end if;
              else
                s_rx_error <= '1';
                s_header_active <= '0';
                s_magic <= (others => '0');
                s_state <= READY;
              end if;
            end if;

          when FRAME_FINISH =>
            if s_tx_pending = '1' and s_spi_busy = '0' then
              s_tx_pending <= '0';
              s_magic <= (others => '0');
              s_state <= READY;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
