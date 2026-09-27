# Forgix + FLIR Lepton 3.5 standalone thermal imager

This repository implements a standalone 160 x 120 thermal imager using the
Forgix RP2354 + Efinix Trion T8 board, the official FLIR Lepton Breakout Board
v2.0, and either the Waveshare 1.8inch ST7735S LCD or the Adafruit 1.28inch
240x240 round GC9A01A LCD. USB-C can be used only for power: the selected LCD
shows the live thermal image without a PC. The existing USB CDC image stream
and Python viewer remain available when a computer is connected.

If a Lepton is absent or has not produced a complete frame for one second, the
LCD shows a moving color-bar and thermal-palette test pattern. Firmware retries
camera configuration every ten seconds, so a newly connected camera can take
over without reflashing.

The Lepton capture path has been verified on hardware at 9 complete frames per
second. Separate UF2 files embed the correct FPGA image and Pico display sizing
for each LCD; install only the UF2 matching the connected controller.

## Architecture

```text
FLIR Lepton 3.5 on Breakout Board v2.0
  | CCI/I2C, 100 kHz                 | VoSPI mode 3, 12.5 MHz
  v                                   v
Forgix RP2354                   Forgix Efinix T8 FPGA
  camera setup                   packet/segment validation
  FPGA configuration            11.25 KiB segment FIFO
  DMA UART RX  <--------------   8.333 Mbaud captured pixels
  frame assembly + palette
  DMA UART TX  -------------->   RGB565 stream + selected LCD controller
  | USB CDC (optional)                 | SPI mode 0, 12.5 MHz
  v                                    v
Python viewer                    ST7735S: 160x120 in 160x128 landscape
                                 GC9A01A: 192x144 centered in 240x240
```

The internal RP2354-to-FPGA runtime UART is full duplex. The FPGA sends packed
Lepton segments to the RP2354 on GPIO3. The RP2354 auto-contrasts and colorizes
a completed frame into RGB565, then a second DMA channel sends the display
bytes back to the FPGA on GPIO2. The Waveshare build sends 38,400 bytes at
160x120. The round build nearest-neighbour scales to 192x144 and sends 55,296
bytes. The FPGA initializes the selected controller and streams directly, so
no LCD frame buffer is required in the FPGA.

Because the Lepton breakout has no VSYNC connection, the FPGA searches using
individually framed discard packets until it finds packet zero. It then keeps
CS asserted continuously through the complete 60-packet segment and releases
it after a post-SCK hold interval. Raising CS on the final sampling edge can
shift the Lepton packet phase and eventually stop valid frames. A one-second
no-descriptor watchdog performs a 250 ms CS-high resynchronization after FFC or
a stalled stream.

## LCD wiring

These are the Forgix board-edge numbers printed on the IO ring, counting from
0. Pins 9 through 14 connect directly to unused 3.3 V FPGA IO and do not
conflict with the Lepton or RP2354 signals.

| Waveshare / Adafruit LCD pin | Forgix connection | FPGA package pin | Function |
|---|---|---|---|
| VCC | 3.3 V | - | Use 3.3 V, not 5 V. |
| GND | GND | - | Common ground. |
| DIN / MOSI | board pin 9 | D6 | SPI MOSI/data. |
| CLK / SCK | board pin 10 | G7 | SPI mode 0: 12.5 MHz Waveshare, 8.33 MHz round display. |
| CS / TFTCS | board pin 11 | G5 | Active-low chip select. |
| DC | board pin 12 | G2 | Command/data select. |
| RST | board pin 13 | F5 | Active-low hardware reset. |
| BL | board pin 14 | F6 | Backlight enable. |

The module accepts either 3.3 V or 5 V power, but its logic level follows its
supply. Powering it from 5 V would expose the FPGA to 5 V logic and is not
supported by this design. Keep the SPI wiring short and connect VCC/GND before
the signal wires.

The Waveshare variant uses landscape ST7735S mode (`MADCTL=0xA0`), RGB565, the
module-specific `+1,+2` offsets, and a centered 160x120 image. The Adafruit
variant initializes the GC9A01A and places a 192x144 4:3 image at x=24..215,
y=48..191 so all four corners remain inside the round aperture. Leave the
Adafruit MISO and SDCS pins unconnected; this design does not use the microSD
socket. Both modules use the same Forgix signal pins shown above.

## Lepton breakout wiring

The FLIR column uses the 20-pin, 0.1-inch header numbering from the official
Breakout Board v2.0 datasheet. Forgix numbers again count from 0.

| Forgix connection | FLIR breakout v2.0 | Direction | Notes |
|---|---|---|---|
| GND | pin 1 or 19, GND | - | Common ground is mandatory. |
| 3.3 V or suitable 5 V rail | pin 2, Power in | to camera | Input is 3 to 5.5 V; check the R120 erratum below. |
| board pin 2 / RP2354 GPIO22 | pin 5, SDA | bidirectional | Internal 3.3 V pull-up is enabled; external 4.7 kOhm to `VCC28_IO` is preferred. |
| board pin 3 / RP2354 GPIO23 | pin 8, SCL | bidirectional | Internal 3.3 V pull-up is enabled; external 4.7 kOhm to `VCC28_IO` is preferred. |
| board pin 4 / FPGA A5 | pin 10, `SPI_CS` | to camera | Use a 3.3 V to 2.8 V level translator. |
| board pin 5 / FPGA D7 | pin 7, `SPI_CLK` | to camera | Use a fast 3.3 V to 2.8 V translator. |
| board pin 6 / FPGA C7 | pin 12, `SPI_MISO` | from camera | A translator is the conservative choice. |
| GND | pin 9, `SPI_MOSI` | - | VoSPI does not use MOSI; hold it low. |

Leave J5-J9 in their factory positions so the breakout supplies the 1.2 V and
2.8 V rails, 25 MHz master clock, and normal power sequence. FLIR notes that
breakout assembly R120 has D1 reversed and cannot be powered through its usual
J2 pin 2; use the documented J3 pin 2 power point on that revision.

## Startup and fallback behavior

At power-up the RP2354 loads the FPGA image embedded in the UF2. The FPGA then
initializes and clears the LCD. The first test pattern is sent after one second,
so a screen is visible even without a camera or USB host.

After the Lepton's five-second boot/automatic-FFC interval, firmware tries CCI
address `0x2a` and configures telemetry off, AGC on, video enabled, RAW14 output,
and the known-good GPIO/VSYNC mode. A valid frame replaces the test pattern.
If no valid frame arrives for one second, the pattern returns. Failed camera
configuration is retried every ten seconds.

Type `FFC` followed by Enter on the USB serial port, or press `F` in the Python
viewer, to request a manual flat-field correction while a camera is configured.

## Build and test

Requirements are Efinity 2025.2, Pico SDK 2.2.0 with the ARM GCC toolchain,
CMake/Ninja, Python 3.10+, and Questa/ModelSim for RTL simulation. From the
repository root:

```powershell
# Build both FPGA variants and both RP2354 UF2 files
.\scripts\build_all.ps1

# Seven RTL runs, including both LCD controllers and consecutive frames
.\fpga\scripts\run_sim.ps1

# Four host protocol tests
python -m unittest discover -s .\tests -v
```

The checked build produces:

- `fpga/outflow/forgix_lepton.bin` (173,380 bytes);
- `fpga/outflow/forgix_lepton_round.bin` (173,380 bytes);
- `dist/forgix_lepton_waveshare_1in8.uf2`;
- `dist/forgix_lepton_adafruit_round_1in28.uf2`.

To rebuild only one package, pass `-Variant waveshare_1in8` or
`-Variant adafruit_round_1in28` to both `fpga/scripts/build_efinity.ps1` and
`scripts/build_firmware.ps1`.

Both routed images meet the 50 MHz constraint with positive setup and hold
slack. The final Waveshare image has +0.271 ns setup / +0.401 ns hold; the
round-display image has +1.292 ns setup / +0.586 ns hold.

## Flash and run

Put Forgix in RP2354 BOOTSEL mode by holding its `PROGRAM` pad low while
connecting USB, then copy the UF2 matching the connected display to the drive:

```text
dist/forgix_lepton_waveshare_1in8.uf2
dist/forgix_lepton_adafruit_round_1in28.uf2
```

If compatible firmware is already running, `picotool` can load and reboot it:

```powershell
picotool load -f -x .\dist\forgix_lepton_waveshare_1in8.uf2
```

The UF2 contains the FPGA bitstream. The RP2354 programs the T8 on every boot;
there is no separate FPGA image to flash.

USB is optional for normal display operation. A USB-C supply or power bank is
enough after the UF2 has been installed.

## Optional PC viewer

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r .\host\requirements.txt
python .\host\viewer.py
```

The viewer auto-detects a single Raspberry Pi USB serial device. With several
connected, select one explicitly, for example:

```powershell
python .\host\viewer.py --port COM11 --rotate 180
```

USB image transfer is disabled by default so a PC connection used only for
power cannot apply CDC backpressure to the standalone display. The viewer sends
the STREAM ON command when it opens the port and STREAM OFF when it exits.

Viewer keys are `F` for FFC, `A` for auto-contrast, and `S` to save both a
temperature `.npy` array and a colorized PNG under `captures/`.

## Status and troubleshooting

The Forgix RGB LED is active-low: green is a heartbeat, blue indicates active
FPGA-to-RP video, and red latches after a capture/FIFO error or LCD UART
framing/overrun error.

- Blank LCD and backlight off: check LCD VCC is 3.3 V, common ground, RST on
  board pin 13, and BL on board pin 14.
- Backlight on but blank image: verify DIN/CLK/CS/DC are on board pins 9/10/11/12
  respectively and that the numbering starts at 0.
- Test pattern only: verify Lepton power, I2C address `0x2a`, 2.8 V pull-ups,
  jumpers, and the level-shifted VoSPI wiring on pins 4-6.
- Red LED: power-cycle once, then scope the applicable UART, Lepton SPI, or LCD
  SPI link. LCD mode is 0 (12.5 MHz Waveshare or 8.33 MHz round); Lepton is
  mode 3 at 12.5 MHz.
- LCD colors swapped, blank, or displaced: confirm that the installed UF2
  matches the ST7735S Waveshare or GC9A01A Adafruit module actually connected.
- Temperatures look wrong in the PC viewer: it expects TLinear 0.01 K/count;
  ensure camera configuration succeeds.
- `fpgaerr=1 code=5 raw=0xfff` immediately after startup is the enabled raw
  discard-header probe, not a capture failure. Its routed implementation is
  retained because it was hardware-verified for stable 12.5 MHz capture.

## Folder layout

- `fpga/rtl`: VoSPI capture, FIFO/formatter, bidirectional UART, and selectable ST7735S/GC9A01A engine.
- `fpga/sim`: self-checking FIFO, UART, capture, formatter, and LCD simulations.
- `fpga/constraints`: Forgix T8F49 clock and package-pin assignments.
- `firmware`: Pico SDK camera setup, frame assembly, palette/test pattern, DMA, and USB.
- `host`: incremental CRC-checked protocol decoder and Matplotlib viewer.
- `tests`: host protocol resynchronization and corruption tests.
- `scripts`: complete and firmware-only PowerShell builds.

References: [Waveshare 1.8inch LCD Module wiki](https://www.waveshare.com/wiki/1.8inch_LCD_Module),
[Waveshare reference ST7735S driver](https://github.com/waveshare/WSLCD1in8/blob/master/LCD_Driver.cpp),
[Adafruit GC9A01A driver](https://github.com/adafruit/Adafruit_GC9A01A),
[FLIR Lepton technical documentation](https://oem.flir.com/developer/lepton-family/lepton-technical-documentation/),
[FLIR Breakout Board v2.0 datasheet](https://www.mouser.com/datasheet/2/813/DS_16912_FLiR_Lepton___Breakout_Board_V2-3247571.pdf),
and the [Forgix hardware repository](https://github.com/controlpaths/forgix).
