"""Unit tests for the Standard MIDI File parser (engine/smf.py)."""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from engine.smf import (  # noqa: E402
    DEFAULT_TEMPO_US,
    SmfError,
    parse_smf_bytes,
    parse_smf_file,
    write_smf,
)

SR = 48000


def frames_at(tick, ppq=480, tempo_us=DEFAULT_TEMPO_US):
    return round(tick * (tempo_us / 1e6) / ppq * SR)


class TestSmf(unittest.TestCase):
    def _roundtrip(self, events, ppq=480, tempo_us=DEFAULT_TEMPO_US):
        with tempfile.NamedTemporaryFile(suffix=".mid", delete=False) as f:
            path = f.name
        write_smf(path, events, ppq=ppq, tempo_us=tempo_us)
        try:
            return parse_smf_file(path, SR)
        finally:
            os.unlink(path)

    def test_basic_events_and_frames(self):
        events = [
            (480, bytes([0xC0, 5])),                # PC @ 0.5 s
            (2880, bytes([0xB0, 7, 127])),          # CC @ 3.0 s
            (5280, bytes([0x90, 60, 100])),         # note-on @ 5.5 s
        ]
        smf = self._roundtrip(events)
        self.assertEqual(len(smf.events), 3)
        self.assertEqual(smf.events[0].frame, frames_at(480))
        self.assertEqual(smf.events[0].data, bytes([0xC0, 5]))
        self.assertEqual(smf.events[1].frame, frames_at(2880))
        self.assertEqual(smf.events[2].frame, frames_at(5280))

    def test_tempo_map_changes(self):
        # tempo 120 BPM → 60 BPM at tick 480 (0.5 s)
        events = [
            (480, b"\xFF\x51\x03" + (1_000_000).to_bytes(3, "big")),  # 60 BPM
            (960, bytes([0xC0, 1])),   # 0.5 s + 1.0 s = 1.5 s
        ]
        smf = self._roundtrip(events, tempo_us=500_000)
        self.assertEqual(smf.events[-1].frame, round(1.5 * SR))

    def test_default_tempo_120(self):
        smf = self._roundtrip([(960, bytes([0xC0, 1]))])
        # 960 ticks @ 120 BPM, ppq 480 → 2 beats = 1 s
        self.assertEqual(smf.events[0].frame, frames_at(960))

    def test_smpte_division(self):
        # 24 fps, 24 ticks/frame: 72 ticks = 3 frames = 0.125 s
        events = [(72, bytes([0xC0, 1]))]
        with tempfile.NamedTemporaryFile(suffix=".mid", delete=False) as f:
            path = f.name
        write_smf(path, events)
        with open(path, "rb") as f:
            data = bytearray(f.read())
        data[12:14] = (0xE8 << 8 | 24).to_bytes(2, "big")  # SMPTE 24 fps
        try:
            smf = parse_smf_bytes(bytes(data), SR)
        finally:
            os.unlink(path)
        self.assertEqual(smf.events[0].frame, round(0.125 * SR))

    def test_running_status(self):
        # note-on ch1 note 60, then running-status note-on 64
        track = bytearray()
        track += b"\x00\x90\x3C\x64"      # note 60
        track += b"\x7F\x40\x64"          # running status: note 64 @127 ticks
        track += b"\x00\xFF\x2F\x00"
        header = b"MThd" + (6).to_bytes(4, "big") + (0).to_bytes(2, "big")
        header += (1).to_bytes(2, "big") + (480).to_bytes(2, "big")
        mid = bytes(header) + b"MTrk" + len(track).to_bytes(4, "big") + bytes(track)
        smf = parse_smf_bytes(mid, SR)
        self.assertEqual(len(smf.events), 2)
        self.assertEqual(smf.events[0].data, bytes([0x90, 60, 100]))
        self.assertEqual(smf.events[1].data, bytes([0x90, 64, 100]))

    def test_bad_file(self):
        with self.assertRaises(SmfError):
            parse_smf_bytes(b"not midi", SR)

    def test_end_frame(self):
        events = [(5280, bytes([0xC0, 1]))]
        smf = self._roundtrip(events)
        self.assertGreaterEqual(smf.end_frame, frames_at(5280))


if __name__ == "__main__":
    unittest.main(verbosity=1)
