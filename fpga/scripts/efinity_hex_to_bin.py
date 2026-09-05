#!/usr/bin/env python3
"""Convert an Efinity passive-SPI hex image to raw bytes."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    digits = "".join(args.input.read_text(encoding="ascii").split())
    if len(digits) % 2:
        raise ValueError("hex file has an odd number of digits")
    image = bytes.fromhex(digits)
    args.output.write_bytes(image)
    print(f"Wrote {len(image)} bytes to {args.output}")


if __name__ == "__main__":
    main()
