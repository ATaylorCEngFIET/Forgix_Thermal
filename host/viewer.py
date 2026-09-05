#!/usr/bin/env python3
"""Live 160x120 temperature display for the Forgix Lepton bridge."""

from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path
import sys
import time

import matplotlib.pyplot as plt
import numpy as np
import serial
from serial.tools import list_ports

try:
    from .protocol import FLAG_TLINEAR_0_01K, FrameDecoder, ThermalFrame
except ImportError:
    from protocol import FLAG_TLINEAR_0_01K, FrameDecoder, ThermalFrame


PICO_USB_VID = 0x2E8A


def find_port(explicit: str | None) -> str:
    if explicit:
        return explicit
    candidates = [port.device for port in list_ports.comports() if port.vid == PICO_USB_VID]
    if len(candidates) == 1:
        return candidates[0]
    if not candidates:
        raise RuntimeError("no Raspberry Pi USB serial device found; pass --port COMx")
    raise RuntimeError(f"multiple Raspberry Pi serial devices found: {', '.join(candidates)}; pass --port")


def rotate_image(image: np.ndarray, degrees: int) -> np.ndarray:
    return np.rot90(image, degrees // 90)


class Viewer:
    def __init__(self, port: serial.Serial, rotation: int, save_dir: Path) -> None:
        self.port = port
        self.rotation = rotation
        self.save_dir = save_dir
        self.decoder = FrameDecoder()
        self.auto_scale = True
        self.latest: np.ndarray | None = None
        self.latest_frame: ThermalFrame | None = None
        self.last_sequence: int | None = None
        self.sequence_gaps = 0
        self.frame_times: list[float] = []

        height, width = ((160, 120) if rotation in (90, 270) else (120, 160))
        self.figure, self.axes = plt.subplots(figsize=(9, 6))
        self.image = self.axes.imshow(
            np.zeros((height, width), dtype=np.float32),
            cmap="inferno",
            origin="upper",
            interpolation="nearest",
            vmin=15.0,
            vmax=35.0,
        )
        self.axes.set_xlabel("pixel")
        self.axes.set_ylabel("pixel")
        self.figure.colorbar(self.image, ax=self.axes, label="Temperature (°C)")
        self.figure.canvas.mpl_connect("key_press_event", self.on_key)
        self.figure.tight_layout()

    def on_key(self, event) -> None:
        key = (event.key or "").lower()
        if key == "f":
            self.port.write(b"FFC\n")
            print("Requested flat-field correction")
        elif key == "a":
            self.auto_scale = not self.auto_scale
            print(f"Auto contrast {'on' if self.auto_scale else 'off'}")
        elif key == "s" and self.latest is not None:
            self.save_dir.mkdir(parents=True, exist_ok=True)
            stem = datetime.now().strftime("lepton_%Y%m%d_%H%M%S_%f")
            np.save(self.save_dir / f"{stem}.npy", self.latest)
            plt.imsave(self.save_dir / f"{stem}.png", self.latest, cmap="inferno")
            print(f"Saved {self.save_dir / stem}.[npy|png]")

    def update(self, frame: ThermalFrame) -> None:
        raw = np.frombuffer(frame.pixels_le16, dtype="<u2").reshape(frame.height, frame.width)
        if frame.flags & FLAG_TLINEAR_0_01K:
            values = raw.astype(np.float32) * 0.01 - 273.15
            units = "°C"
        else:
            values = raw.astype(np.float32)
            units = "counts"
        values = rotate_image(values, self.rotation)
        self.latest = values
        self.latest_frame = frame

        if self.last_sequence is not None:
            expected = (self.last_sequence + 1) & 0xFFFFFFFF
            if frame.sequence != expected:
                self.sequence_gaps += (frame.sequence - expected) & 0xFFFFFFFF
        self.last_sequence = frame.sequence

        now = time.monotonic()
        self.frame_times.append(now)
        self.frame_times = [stamp for stamp in self.frame_times if now - stamp <= 2.0]
        fps = max(0.0, (len(self.frame_times) - 1) / max(now - self.frame_times[0], 1e-6))

        self.image.set_data(values)
        if self.auto_scale:
            low, high = np.percentile(values, (2.0, 98.0))
            if high <= low:
                high = low + 1.0
            self.image.set_clim(float(low), float(high))
        self.axes.set_title(
            f"Forgix + Lepton 3.5 | {values.min():.2f} to {values.max():.2f} {units} | "
            f"{fps:.1f} fps | USB gaps {self.sequence_gaps} | FPGA errors {frame.fpga_error_count}\n"
            "F: FFC    A: auto contrast    S: save"
        )
        self.figure.canvas.draw_idle()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="USB CDC port (auto-detected when unique)")
    parser.add_argument("--baud", type=int, default=115200, help="CDC compatibility setting")
    parser.add_argument("--rotate", type=int, choices=(0, 90, 180, 270), default=0)
    parser.add_argument("--save-dir", type=Path, default=Path("captures"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        device = find_port(args.port)
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 2

    print(f"Opening {device}; close the plot window to stop")
    with serial.Serial(device, args.baud, timeout=0.05, write_timeout=1.0) as port:
        port.reset_input_buffer()
        viewer = Viewer(port, args.rotate, args.save_dir)
        plt.show(block=False)
        while plt.fignum_exists(viewer.figure.number):
            data = port.read(port.in_waiting or 1)
            for frame in viewer.decoder.feed(data):
                viewer.update(frame)
            plt.pause(0.001)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
