#!/usr/bin/env python3
"""Convert a raw Efinity passive-SPI image into a C translation unit."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    image = args.input.read_bytes()
    rows = []
    for offset in range(0, len(image), 16):
        values = ", ".join(f"0x{value:02x}" for value in image[offset : offset + 16])
        rows.append(f"    {values},")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        "#include <stddef.h>\n"
        "#include <stdint.h>\n\n"
        "const uint8_t g_forgix_lepton_fpga_image[] = {\n"
        + "\n".join(rows)
        + "\n};\n"
        "const size_t g_forgix_lepton_fpga_image_size = "
        "sizeof(g_forgix_lepton_fpga_image);\n",
        encoding="utf-8",
    )
    print(f"Embedded {len(image)} FPGA bytes in {args.output}")


if __name__ == "__main__":
    main()
