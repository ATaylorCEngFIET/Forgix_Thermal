# Stream protocols

## FPGA to RP2354

The post-configuration Forgix data pin is an 8-N-1 UART at 8 Mbaud. Each valid
Lepton segment is sent as a 16-byte header followed by 9,600 bytes of big-endian
TLinear pixels.

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 4 | ASCII `LPTN` |
| 4 | 1 | version, currently 1 |
| 5 | 1 | segment 1 through 4; zero is an error/resync marker |
| 6 | 1 | flags: bit 0 big-endian, bit 1 TLinear/Raw14 |
| 7 | 1 | header size, 16 |
| 8 | 2 | little-endian FPGA frame counter |
| 10 | 2 | little-endian payload length |
| 12 | 2 | little-endian cumulative FPGA error count |
| 14 | 1 | marker `0xb5` |
| 15 | 1 | XOR of bytes 0 through 14 |

## RP2354 to host

USB CDC is a byte stream. Each image contains a 32-byte little-endian header
followed by `width * height * 2` little-endian pixels.

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 4 | ASCII `LPTF` |
| 4 | 1 | protocol version, currently 1 |
| 5 | 1 | type 1, image |
| 6 | 2 | flags; bit 0 means TLinear in 0.01 K/count |
| 8 | 4 | USB image sequence |
| 12 | 4 | milliseconds since RP2354 boot |
| 16 | 2 | width, 160 |
| 18 | 2 | height, 120 |
| 20 | 4 | payload length, 38,400 |
| 24 | 4 | IEEE CRC-32 of payload |
| 28 | 2 | FPGA frame counter |
| 30 | 2 | cumulative FPGA capture error count |

The host must scan for magic, validate all lengths before allocation, verify
CRC-32, and resume scanning after corrupt input. `host/protocol.py` implements
that behavior and tolerates diagnostic text before the first binary frame.
