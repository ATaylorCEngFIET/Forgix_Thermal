from __future__ import annotations

import struct
import unittest

from lepton_thermal.host.protocol import FrameDecoder, encode_frame


class FrameDecoderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.payload = b"".join(struct.pack("<H", 29000 + index) for index in range(12))
        self.encoded = encode_frame(
            self.payload,
            width=4,
            height=3,
            sequence=19,
            timestamp_ms=12345,
            fpga_frame_counter=77,
            fpga_error_count=2,
        )

    def test_decodes_arbitrary_chunks_and_noise(self) -> None:
        decoder = FrameDecoder()
        frames = []
        stream = b"boot text\n" + self.encoded
        for index in range(0, len(stream), 7):
            frames.extend(decoder.feed(stream[index:index + 7]))
        self.assertEqual(len(frames), 1)
        frame = frames[0]
        self.assertEqual(frame.sequence, 19)
        self.assertEqual(frame.timestamp_ms, 12345)
        self.assertEqual(frame.fpga_frame_counter, 77)
        self.assertEqual(frame.fpga_error_count, 2)
        self.assertEqual(frame.pixels_le16, self.payload)
        self.assertEqual(decoder.discarded_bytes, len(b"boot text\n"))

    def test_bad_crc_is_dropped_and_next_frame_recovers(self) -> None:
        corrupt = bytearray(self.encoded)
        corrupt[-1] ^= 0x80
        decoder = FrameDecoder()
        frames = decoder.feed(corrupt + self.encoded)
        self.assertEqual(len(frames), 1)
        self.assertEqual(frames[0].sequence, 19)
        self.assertEqual(decoder.crc_errors, 1)

    def test_bad_header_resynchronizes(self) -> None:
        corrupt = bytearray(self.encoded)
        corrupt[4] = 99
        decoder = FrameDecoder()
        frames = decoder.feed(corrupt + self.encoded)
        self.assertEqual(len(frames), 1)
        self.assertGreaterEqual(decoder.header_errors, 1)

    def test_encoder_rejects_wrong_size(self) -> None:
        with self.assertRaises(ValueError):
            encode_frame(b"short", width=4, height=3)


if __name__ == "__main__":
    unittest.main()
