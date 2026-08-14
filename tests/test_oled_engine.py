"""OLED integration test (Step 6).

Runs the real oled_daemon module (mock I2C) and a real offline engine in
the same process, wired over real UDP OSC — no web UI anywhere in the
path. Verifies the OLED daemon's display state tracks the engine across
load / play / stop / next / prev, and that the heartbeat marks the engine
online.

Run: LANTH0N_OLED_MOCK=1 python3 tests/test_oled_engine.py
"""

import json
import math
import os
import socket
import struct
import sys
import tempfile
import time
import unittest
import wave

TMP = tempfile.mkdtemp(prefix="lanth0n-oled-e2e-")
os.environ["LANTH0N_PROJECT_DIR"] = TMP
os.environ["LANTH0N_OLED_MOCK"] = "1"

# pick a free UDP port for the daemon
_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
_sock.bind(("127.0.0.1", 0))
OLED_PORT = _sock.getsockname()[1]
_sock.close()
os.environ["LANTH0N_OLED_PORT"] = str(OLED_PORT)

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import oled_daemon  # noqa: E402
from engine.engine import Engine  # noqa: E402
from engine.smf import write_smf  # noqa: E402

SR = 48000
BLOCK = 512


def make_song(dirp, name, tuning, key):
    wav = os.path.join(dirp, f"{name}.wav")
    mid = os.path.join(dirp, f"{name}.mid")
    n = int(2.0 * SR)
    with wave.open(wav, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = bytearray()
        for i in range(n):
            frames += struct.pack("<hh",
                                  int(0.3 * math.sin(2 * math.pi * 220 * i / SR) * 32767),
                                  int(0.3 * math.sin(2 * math.pi * 440 * i / SR) * 32767))
        w.writeframes(bytes(frames))
    write_smf(mid, [(480, bytes([0xC0, 1]))])
    return os.path.basename(wav), os.path.basename(mid)


def daemon_state():
    with oled_daemon._state_lock:
        return (
            oled_daemon._state.setlist_name,
            oled_daemon._state.artist,
            oled_daemon._state.song_name,
            oled_daemon._state.playback_state,
            oled_daemon._state.tuning,
            oled_daemon._state.sc_online,
        )


def wait_for(pred, timeout=8.0, what="condition"):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        if pred():
            return
        time.sleep(0.05)
    raise AssertionError(f"timeout waiting for {what}; state={daemon_state()}")


class TestOledEngine(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # configure daemon for the chosen port, start its OSC listener
        oled_daemon.OSC_PORT = OLED_PORT
        oled_daemon.MOCK_MODE = True
        oled_daemon.start_osc_server()

        cls.dir = tempfile.mkdtemp(prefix="lanth0n-oled-fix-")
        media = os.path.join(TMP, "media")
        os.makedirs(media, exist_ok=True)
        for name, tuning, key in (("Sober", "drop", "D"), ("46 and 2", "standard", "E")):
            wav, mid = make_song(cls.dir, name, tuning, key)
            import shutil
            shutil.copy(os.path.join(cls.dir, wav), os.path.join(media, wav))
            shutil.copy(os.path.join(cls.dir, mid), os.path.join(media, mid))
        setlists_dir = os.path.join(TMP, "setlists")
        os.makedirs(setlists_dir, exist_ok=True)
        with open(os.path.join(setlists_dir, "oled.json"), "w") as f:
            json.dump({"name": "Night 1", "songs": [
                {"name": "Sober", "artist": "Tool", "tuning": "drop", "key": "D",
                 "wav": "Sober.wav", "mid": "Sober.mid"},
                {"name": "46 and 2", "artist": "Tool", "tuning": "standard", "key": "E",
                 "wav": "46 and 2.wav", "mid": "46 and 2.mid"},
            ]}, f)

        cls.engine = Engine(offline=True, sample_rate=SR, block_size=BLOCK,
                            midi_in_enabled=False, oled_port=OLED_PORT)
        cls.engine.start()

    @classmethod
    def tearDownClass(cls):
        cls.engine.shutdown()

    def _wait_cued(self, idx):
        expected = self.engine.setlist["songs"][idx].name
        wait_for(
            lambda: (self.engine.transport.song is not None
                     and self.engine.transport.song.open
                     and self.engine.song_index == idx
                     and self.engine.transport.song.name == expected),
            what=f"song {expected} cued")

    def test_oled_tracks_engine_across_transport(self):
        engine = self.engine
        engine.load_setlist("oled")
        self._wait_cued(0)

        # cued song visible on the OLED (no web UI involved)
        wait_for(lambda: daemon_state()[2] == "Sober", what="song Sober on OLED")
        self.assertEqual(daemon_state()[0], "Night 1")
        self.assertEqual(daemon_state()[1], "Tool")
        self.assertEqual(daemon_state()[3], "CUED")
        self.assertEqual(daemon_state()[4], "Drop D")

        # play
        engine.play()
        wait_for(lambda: daemon_state()[3] == "PLAYING", what="PLAYING on OLED")
        self.assertEqual(daemon_state()[4], "Drop D")

        # stop
        engine.stop()
        wait_for(lambda: daemon_state()[3] == "STOP", what="STOP on OLED")

        # next → song 2, standard tuning
        engine.next_song()
        self._wait_cued(1)
        wait_for(lambda: daemon_state()[2] == "46 and 2", what="next song on OLED")
        self.assertEqual(daemon_state()[4], "Standard E")
        self.assertEqual(daemon_state()[3], "CUED")

        # prev back to song 1
        engine.prev_song()
        self._wait_cued(0)
        wait_for(lambda: daemon_state()[2] == "Sober", what="prev song on OLED")
        self.assertEqual(daemon_state()[4], "Drop D")

    def test_oled_heartbeat_marks_engine_online(self):
        self.engine.osc.oled_heartbeat(True, False)
        wait_for(lambda: daemon_state()[5] is True, what="engine online on OLED")


if __name__ == "__main__":
    unittest.main(verbosity=2)
