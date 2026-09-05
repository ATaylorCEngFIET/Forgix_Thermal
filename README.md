# Forgix + FLIR Lepton 3.5 USB thermal camera

This folder is a self-contained implementation for the official FLIR Lepton
Breakout Board v2.0 and a Forgix RP2354 + Efinix Trion T8 board. The FPGA
captures 160 x 120 TLinear video over VoSPI, the RP2354 configures the camera
over CCI/I2C and assembles frames, and USB CDC carries CRC-checked images to a
Python live viewer.

The project builds, its protocol simulations/tests pass, and it has been
verified on the connected Lepton 3.5 at 9 complete frames per second with
matched segment counts and no FPGA or transport errors.

## Architecture

```text
Lepton 3.5 on BOB v2.0
  |  CCI/I2C, 100 kHz                  |  VoSPI mode 3, 12.5 MHz
  v                                    v
Forgix RP2354                    Forgix Efinix T8 FPGA
  camera setup                    packet/segment validation
  FPGA configuration             11.25 KiB segment FIFO
  DMA UART receive      <------   8.333 Mbaud framed UART
  160x120 frame assembly
  |  USB full-speed CDC, 38432 bytes/frame + CRC32
  v
Python viewer (temperature, contrast, FFC, capture)
```

The FPGA handles the timing-sensitive VoSPI link and recognizes Lepton 3.x
four-segment frames. It speculatively buffers packets 0 through 19 because the
segment number first appears in packet 20, rejects discard packets, segment
zero, and repeated segment 4, and validates packet order. Because the breakout
has no VSYNC connection, CS remains asserted while the FPGA finds segment
boundaries over SPI. A one-second no-descriptor watchdog performs the required
250 ms CS-high resynchronization after FFC or a stalled stream. The FPGA packs
each Raw14 pixel pair into three bytes, so the RP2354 receives 7,200-byte
segments by DMA and double-buffers the final 38,400-byte images.

## Breakout-board wiring

The table uses the 20-pin, 0.1-inch breakout header numbering from the FLIR
Breakout Board v2.0 datasheet. The Forgix board-edge numbers are the Teensy-form
factor labels used by this project.

| Forgix connection | FLIR breakout v2.0 | Direction | Notes |
|---|---|---|---|
| GND | pin 1 or 19, GND | - | A common ground is mandatory. |
| 3.3 V or a suitable 5 V rail | pin 2, Power in | to camera | Input is 3 to 5.5 V. Check the R120 erratum below. |
| board pin 2 / RP2354 GPIO22 | pin 5, SDA | bidirectional | Diagnostic firmware enables a weak internal pull-up to 3.3 V; external 4.7 kOhm to `VCC28_IO` is preferred. |
| board pin 3 / RP2354 GPIO23 | pin 8, SCL | bidirectional | Diagnostic firmware enables a weak internal pull-up to 3.3 V; external 4.7 kOhm to `VCC28_IO` is preferred. |
| board pin 4 / FPGA A5 | pin 10, `SPI_CS` | to camera | Pass through a 3.3 V to 2.8 V level translator. |
| board pin 5 / FPGA D7 | pin 7, `SPI_CLK` | to camera | Pass through a fast 3.3 V to 2.8 V level translator. |
| board pin 6 / FPGA C7 | pin 12, `SPI_MISO` | from camera | 2.8 V is normally a valid T8 3.3 V-bank high; a translator is the conservative choice. |
| GND | pin 9, `SPI_MOSI` | - | VoSPI does not use MOSI; hold the unused input low. |

The current diagnostic build enables the RP2354's weak internal 3.3 V pull-ups on
SDA/SCL at the user's direction. Both lines now idle high, but external 4.7 kOhm
pull-ups to breakout pin 6 (VCC28_IO) remain the robust choice. Do not drive the
Lepton's SPI inputs with raw 3.3 V; use a fast level translator for 12.5 MHz.

Leave the breakout's J5-J9 jumpers in their factory-installed positions so it
provides the 1.2 V and 2.8 V rails, 25 MHz master clock, and normal power-up
sequence. `RESET_L`, `PW_DWN_L`, `MASTER_CLK`, `VCC12`, and `VCC28` therefore do
not need Forgix connections. FLIR notes that breakout assembly R120 has D1
reversed and cannot be powered through its usual J2 pin 2; use the documented
J3 pin 2 power point on that revision.

If your Forgix header revision uses different labels, change the three package
pins in `fpga/constraints/forgix_lepton_io.isf` and the two RP GPIO definitions
in `firmware/include/board_config.h` before building.

## Camera configuration

After the five-second Lepton startup/automatic-FFC interval, the firmware uses
CCI address `0x2a` to:

- wait for `BOOTED=1`, `BUSY=0`, and FFC completion;
- disable VoSPI telemetry so every segment remains 60 packets;
- enable radiometry and TLinear output at 0.01 kelvin/count;
- select 16-bit RAW14 VoSPI output.

Type `FFC` followed by Enter on the USB serial port, or press `F` in the viewer,
to request a manual flat-field correction.

## Build

Requirements are Efinity 2025.2, Pico SDK 2.2.0 with the ARM GCC toolchain,
CMake/Ninja, Python 3.10+, and Questa/ModelSim for FPGA simulation. From the
repository root:

```powershell
# FPGA implementation followed by RP2354 firmware embedding that image
.\lepton_thermal\scripts\build_all.ps1

# Packet-capture and UART RTL simulations
.\lepton_thermal\fpga\scripts\run_sim.ps1

# Host protocol tests (no third-party packages needed)
python -m unittest discover -s .\lepton_thermal\tests -v
```

The checked build produces:

- `lepton_thermal/fpga/outflow/forgix_lepton.bin` (173,380 bytes);
- `lepton_thermal/firmware/build/forgix_lepton_bridge.uf2` (423,936 bytes).

Post-route usage is 798/7,384 logic elements and 21/24 memory blocks. The 32 MHz
clock closes with +1.243 ns setup and +0.375 ns hold slack.

## Flash and run

Put Forgix in RP2354 BOOTSEL mode by holding its `PROGRAM` pad low while
connecting USB, then copy the UF2 to the mounted drive. If compatible firmware
is already running, `picotool` can be used instead:

```powershell
picotool load -f -x .\lepton_thermal\firmware\build\forgix_lepton_bridge.uf2
```

The UF2 contains the FPGA bitstream, so the RP2354 programs the T8 at every
boot; no separate FPGA programmer is required.

Install and launch the host viewer:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r .\lepton_thermal\host\requirements.txt
python .\lepton_thermal\host\viewer.py
```

The viewer auto-detects a single Raspberry Pi USB serial device. With several
connected, select one explicitly, for example:

```powershell
python .\lepton_thermal\host\viewer.py --port COM11 --rotate 180
```

Viewer keys are `F` for FFC, `A` for auto-contrast, and `S` to save both a
temperature `.npy` array and a colorized PNG under `captures/`.

## Status and troubleshooting

The Forgix RGB LED is active-low: green is a heartbeat, blue indicates active
FPGA-to-RP streaming, and red latches after a capture/FIFO error.

- No USB device: confirm the UF2 is loaded and use Device Manager or
  `python -m serial.tools.list_ports` to find the port.
- `LEPTON_ERROR cci=...`: verify 2.8 V I2C pull-ups, address `0x2a`, breakout
  power, installed jumpers, and the full five-second startup delay. If the
  diagnostic shows `sda=0 scl=0`, both lines lack pull-ups or are held low;
  the diagnostic firmware enables RP2354 internal pull-ups and retries setup.
- Red LED or no frames: scope `SPI_CS`, `SPI_CLK`, and `SPI_MISO`; clock should
  be mode 3 at 12.5 MHz. Check level-shifter direction and bandwidth.
- Repeated FPGA errors: keep SPI wiring short, verify a clean 2.8 V reference,
  and confirm the module is a Lepton 3.x 160 x 120 device.
- The FPGA currently validates VoSPI packet IDs and ordering but does not check
  the Lepton packet CRC field; the RP-to-host image payload has IEEE CRC-32.
- Temperatures look wrong: the viewer expects TLinear 0.01 K/count. Verify that
  camera configuration succeeds rather than treating generic Raw14 counts as
  absolute temperature.

## Folder layout

- `fpga/rtl`: synthesizable VoSPI master, segment FIFO, formatter, and UART.
- `fpga/sim`: self-checking capture and UART simulations.
- `fpga/constraints`: Forgix T8F49 clock and package-pin assignments.
- `firmware`: Pico SDK C application, camera CCI driver, DMA receiver, USB link.
- `host`: incremental CRC-checked protocol decoder and Matplotlib viewer.
- `tests`: host protocol resynchronization and corruption tests.
- `scripts`: complete and firmware-only PowerShell builds.

Reference documents: [FLIR Lepton technical documentation](https://oem.flir.com/developer/lepton-family/lepton-technical-documentation/),
[official Breakout Board v2.0 datasheet](https://www.mouser.com/datasheet/2/813/DS_16912_FLiR_Lepton___Breakout_Board_V2-3247571.pdf),
and [Forgix getting-started guide](https://www.hackster.io/adam-taylor/getting-started-with-forgix-4c72eb).
