"""Incremental decoder for the Forgix Lepton USB CDC byte stream."""

from __future__ import annotations

from dataclasses import dataclass
import struct
from typing import Iterable
import zlib


MAGIC = b"LPTF"
PROTOCOL_VERSION = 1
FRAME_TYPE_IMAGE = 1
FLAG_TLINEAR_0_01K = 1 << 0
HEADER = struct.Struct("<4sBBHIIHHIIHH")
HEADER_SIZE = HEADER.size
MAX_PAYLOAD_BYTES = 1024 * 1024


@dataclass(frozen=True)
class ThermalFrame:
    sequence: int
    timestamp_ms: int
    width: int
    height: int
    flags: int
    fpga_frame_counter: int
    fpga_error_count: int
    pixels_le16: bytes


class FrameDecoder:
    """Turn arbitrarily chunked serial data into CRC-checked image frames."""

    def __init__(self) -> None:
        self._buffer = bytearray()
        self.discarded_bytes = 0
        self.header_errors = 0
        self.crc_errors = 0

    def feed(self, data: bytes | bytearray | memoryview) -> list[ThermalFrame]:
        self._buffer.extend(data)
        frames: list[ThermalFrame] = []

        while True:
            magic_index = self._buffer.find(MAGIC)
            if magic_index < 0:
                keep = min(len(self._buffer), len(MAGIC) - 1)
                self.discarded_bytes += len(self._buffer) - keep
                if keep:
                    del self._buffer[:-keep]
                else:
                    self._buffer.clear()
                break
            if magic_index:
                self.discarded_bytes += magic_index
                del self._buffer[:magic_index]
            if len(self._buffer) < HEADER_SIZE:
                break

            fields = HEADER.unpack_from(self._buffer)
            (
                _magic,
                version,
                frame_type,
                flags,
                sequence,
                timestamp_ms,
                width,
                height,
                payload_length,
                expected_crc,
                fpga_frame_counter,
                fpga_error_count,
            ) = fields

            valid_header = (
                version == PROTOCOL_VERSION
                and frame_type == FRAME_TYPE_IMAGE
                and width > 0
                and height > 0
                and payload_length == width * height * 2
                and payload_length <= MAX_PAYLOAD_BYTES
            )
            if not valid_header:
                self.header_errors += 1
                self.discarded_bytes += 1
                del self._buffer[0]
                continue

            total_length = HEADER_SIZE + payload_length
            if len(self._buffer) < total_length:
                break
            payload = bytes(self._buffer[HEADER_SIZE:total_length])
            if (zlib.crc32(payload) & 0xFFFFFFFF) != expected_crc:
                self.crc_errors += 1
                self.discarded_bytes += total_length
                del self._buffer[:total_length]
                continue

            frames.append(
                ThermalFrame(
                    sequence=sequence,
                    timestamp_ms=timestamp_ms,
                    width=width,
                    height=height,
                    flags=flags,
                    fpga_frame_counter=fpga_frame_counter,
                    fpga_error_count=fpga_error_count,
                    pixels_le16=payload,
                )
            )
            del self._buffer[:total_length]

        return frames


def encode_frame(
    pixels_le16: bytes,
    *,
    width: int,
    height: int,
    sequence: int = 0,
    timestamp_ms: int = 0,
    flags: int = FLAG_TLINEAR_0_01K,
    fpga_frame_counter: int = 0,
    fpga_error_count: int = 0,
) -> bytes:
    """Create a protocol frame for tests and offline producers."""
    if len(pixels_le16) != width * height * 2:
        raise ValueError("payload length does not match width and height")
    header = HEADER.pack(
        MAGIC,
        PROTOCOL_VERSION,
        FRAME_TYPE_IMAGE,
        flags,
        sequence,
        timestamp_ms,
        width,
        height,
        len(pixels_le16),
        zlib.crc32(pixels_le16) & 0xFFFFFFFF,
        fpga_frame_counter,
        fpga_error_count,
    )
    return header + pixels_le16


def decode_chunks(chunks: Iterable[bytes]) -> list[ThermalFrame]:
    """Convenience helper used by tests and recorded byte streams."""
    decoder = FrameDecoder()
    frames: list[ThermalFrame] = []
    for chunk in chunks:
        frames.extend(decoder.feed(chunk))
    return frames
