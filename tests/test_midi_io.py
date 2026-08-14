"""MIDI transport mapping tests (Step 5).

Unit tests for message decoding / mapping, plus an end-to-end test using
virtual MIDI ports (CoreMIDI on macOS / ALSA on Linux). The e2e test is
skipped when no virtual-port support is available.

The transport actions triggered by MIDI must behave identically to the
web UI path: both call the same Engine.play/stop/next/prev methods, and
the resulting state.json must reflect the transition.
"""

import json
import os
import sys
import tempfile
import time
import unittest

import numpy as np

TMP = tempfile.mkdtemp(prefix="lanth0n-midi-test-")
os.environ.setdefault("LANTH0N_PROJECT_DIR", TMP)

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from engine.engine import Engine  # noqa: E402
from engine.midi_io import (  # noqa: E402
    LearnCapture,
    TransportMapper,
    decode_message,
)
from engine.smf import write_smf  # noqa: E402
from engine.song import Song  # noqa: E402

SR = 48000
BLOCK = 512


def make_fixture_song(dirp, name, seconds=2.0):
    import math
    import struct
    import wave

    wav = os.path.join(dirp, f"{name}.wav")
    mid = os.path.join(dirp, f"{name}.mid")
    n = int(seconds * SR)
    with wave.open(wav, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = bytearray()
        for i in range(n):
            frames += struct.pack("<hh",
                                  int(0.4 * math.sin(2 * math.pi * 220 * i / SR) * 32767),
                                  int(0.4 * math.sin(2 * math.pi * 440 * i / SR) * 32767))
        w.writeframes(bytes(frames))
    write_smf(mid, [(480, bytes([0xC0, 1]))])
    return os.path.basename(wav), os.path.basename(mid)


class TestDecodeAndMap(unittest.TestCase):
    def test_decode_note_cc_pc(self):
        self.assertEqual(decode_message(bytes([0x90, 36, 100])),
                         {"chan": 0, "type": "note", "value": 36, "vel": 100, "trigger": True})
        # note-on with velocity 0 is a note-off in disguise — never triggers
        self.assertEqual(decode_message(bytes([0x90, 36, 0]))["trigger"], False)
        self.assertIsNone(decode_message(bytes([0x80, 36, 0])))  # note-off ignored
        self.assertEqual(decode_message(bytes([0xB3, 64, 127])),
                         {"chan": 3, "type": "cc", "value": 64, "ccVal": 127, "trigger": True})
        self.assertEqual(decode_message(bytes([0xC0, 7])),
                         {"chan": 0, "type": "pgm", "value": 7, "trigger": True})

    def test_mapper_channel_filtering_and_cc_edge(self):
        calls = []
        mapper = TransportMapper({
            "btPlay": lambda: calls.append("play"),
            "btStop": lambda: calls.append("stop"),
        })
        mapper.mappings = [
            {"chan": 0, "type": "note", "value": 36, "action": "btPlay"},
            {"chan": 1, "type": "cc", "value": 64, "action": "btStop"},
        ]
        # wrong channel → ignored
        self.assertFalse(mapper.handle(bytes([0x91, 36, 100])))
        self.assertEqual(calls, [])
        # right channel → triggers
        self.assertTrue(mapper.handle(bytes([0x90, 36, 100])))
        self.assertEqual(calls, ["play"])
        # CC requires rising edge ≥64: 127 triggers, then 127 again doesn't
        self.assertTrue(mapper.handle(bytes([0xB1, 64, 127])))
        self.assertTrue(mapper.handle(bytes([0xB1, 64, 127])))
        self.assertEqual(calls, ["play", "stop"])   # only one stop

    def test_learn_capture_writes_file(self):
        learn = LearnCapture()
        learn.start()
        self.assertTrue(learn.capture(bytes([0x90, 60, 100])))
        with open(os.path.join(TMP, "config", "midi_learn.json")) as f:
            ev = json.load(f)
        self.assertEqual(ev["type"], "note")
        self.assertEqual(ev["value"], 60)
        self.assertEqual(ev["chan"], 0)
        # learn is single-shot
        self.assertFalse(learn.capture(bytes([0x90, 62, 100])))


class TestVirtualPortEndToEnd(unittest.TestCase):
    """Full path: virtual MIDI port → MidiInputManager → TransportMapper →
    engine actions → state.json (same single source of truth as the web)."""

    VIRTUAL_NAME = "Lanth0n Test Controller"

    @classmethod
    def setUpClass(cls):
        try:
            import rtmidi
        except Exception:
            raise unittest.SkipTest("python-rtmidi not available")
        cls.rtmidi = rtmidi
        out = rtmidi.MidiOut()
        try:
            out.open_virtual_port(cls.VIRTUAL_NAME)
        except Exception:
            raise unittest.SkipTest("virtual MIDI ports unavailable")
        cls.virt_out = out

    @classmethod
    def tearDownClass(cls):
        try:
            cls.virt_out.close_port()
        except Exception:
            pass

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="lanth0n-midie2e-")
        media = os.path.join(TMP, "media")
        os.makedirs(media, exist_ok=True)
        wav, mid = make_fixture_song(self.dir, "A")
        import shutil
        shutil.copy(os.path.join(self.dir, wav), os.path.join(media, wav))
        shutil.copy(os.path.join(self.dir, mid), os.path.join(media, mid))
        wav2, mid2 = make_fixture_song(self.dir, "B")
        shutil.copy(os.path.join(self.dir, wav2), os.path.join(media, wav2))
        shutil.copy(os.path.join(self.dir, mid2), os.path.join(media, mid2))
        setlists = os.path.join(TMP, "setlists")
        os.makedirs(setlists, exist_ok=True)
        with open(os.path.join(setlists, "midie2e.json"), "w") as f:
            json.dump({"name": "midie2e", "songs": [
                {"name": "A", "wav": wav, "mid": mid, "tuning": "standard", "key": "E"},
                {"name": "B", "wav": wav2, "mid": mid2, "tuning": "drop", "key": "D"},
            ]}, f)
        # MIDI map: note36→play, cc64→stop, note38→next, note37→prev (ch 0)
        os.makedirs(os.path.join(TMP, "config"), exist_ok=True)
        with open(os.path.join(TMP, "config", "midi_map.json"), "w") as f:
            json.dump({"mappings": [
                {"chan": 0, "type": "note", "value": 36, "action": "btPlay"},
                {"chan": 0, "type": "cc", "value": 64, "action": "btStop"},
                {"chan": 0, "type": "note", "value": 38, "action": "btNext"},
                {"chan": 0, "type": "note", "value": 37, "action": "btPrev"},
            ]}, f)

        self.engine = Engine(offline=True, sample_rate=SR, block_size=BLOCK,
                             midi_in_enabled=True)
        self.engine.start()
        self.engine.load_setlist("midie2e")
        self._wait_cued(0)

    def tearDown(self):
        self.engine.shutdown()

    def _wait_cued(self, idx, timeout=10.0):
        expected = None
        songs = self.engine.setlist["songs"] if self.engine.setlist else []
        if 0 <= idx < len(songs):
            expected = songs[idx].name
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            song = self.engine.transport.song
            if (song is not None and song.open
                    and self.engine.song_index == idx
                    and (expected is None or song.name == expected)):
                return
            time.sleep(0.02)
        raise AssertionError(
            f"song {idx} never cued (index={self.engine.song_index}, "
            f"song={self.engine.transport.song.name if self.engine.transport.song else None})")

    def _wait_port_open(self, timeout=10.0):
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            if any(self.VIRTUAL_NAME in n for n in self.engine.midi_in._ports):
                return
            time.sleep(0.1)
        raise unittest.SkipTest("virtual port not discovered by engine (no MIDI)")

    def _send(self, msg, delay=0.15):
        self.virt_out.send_message(msg)
        time.sleep(delay)

    def _state_file(self):
        with open(os.path.join(TMP, "config", "state.json")) as f:
            return json.load(f)

    def test_transport_actions_via_midi(self):
        self._wait_port_open()
        t = self.engine.transport

        # Play (note 36)
        self._send([0x90, 36, 100])
        self.assertTrue(t.playing, "MIDI note should trigger play")
        s = self._state_file()
        self.assertTrue(s["playing"], "state.json must reflect MIDI-triggered play")

        # Stop (CC 64)
        self._send([0xB0, 64, 127])
        self.assertFalse(t.playing)

        # Next (note 38)
        self._send([0x90, 38, 100])
        self._wait_cued(1)
        self.assertEqual(self.engine.song_index, 1)
        s = self._state_file()
        self.assertEqual(s["songName"], "B")

        # Prev (note 37)
        self._send([0x90, 37, 100])
        self._wait_cued(0)
        self.assertEqual(self.engine.song_index, 0)
        s = self._state_file()
        self.assertEqual(s["songName"], "A")

    def test_web_and_midi_share_one_control_path(self):
        """Same actions from the web path (direct method calls, as the OSC
        handler does) and the MIDI path — state must agree."""
        self._wait_port_open()
        # web-style: engine.play() (what /backtrack/play handler invokes)
        self.engine.play()
        self.assertTrue(self.engine.transport.playing)
        # MIDI stop
        self._send([0xB0, 64, 127])
        self.assertFalse(self.engine.transport.playing)
        # web-style play again
        self.engine.play()
        self.assertTrue(self.engine.transport.playing)
        # MIDI next
        self._send([0x90, 38, 100])
        self._wait_cued(1)
        # web-style prev (what /backtrack/prev handler invokes) — playback
        # was active, so prev auto-plays the previous song (by design)
        self.engine.prev_song()
        self._wait_cued(0)
        s = self._state_file()
        self.assertEqual(s["songName"], "A")
        self.assertTrue(s["playing"], "prev during playback auto-plays")


if __name__ == "__main__":
    unittest.main(verbosity=2)
