"""Engine verification: sample-accurate sync, channel routing, memory.

All tests run offline (LANTH0N_OFFLINE semantics — the engine's offline
driver), which exercises the exact same tick()/dispatch code path as the
realtime backend, with deterministic results.

Run:  python3 tests/test_engine.py
"""

import math
import os
import resource
import struct
import sys
import tempfile
import unittest
import wave

import numpy as np

# LANTH0N_PROJECT_DIR must be set BEFORE importing engine (paths module
# reads it at import time) so state files land in a temp dir.
TMP = tempfile.mkdtemp(prefix="lanth0n-engine-test-")
os.environ.setdefault("LANTH0N_PROJECT_DIR", TMP)

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from engine.engine import Engine  # noqa: E402
from engine.smf import DEFAULT_TEMPO_US, write_smf  # noqa: E402
from engine.song import Song  # noqa: E402

SR = 48000
BLOCK = 512


def make_wav(path, seconds, sr=SR, nch=4, freqs=(220, 440, 1000, 2000)):
    """Synthetic interleaved multichannel WAV: distinct tone per channel."""
    n = int(seconds * sr)
    with wave.open(path, "wb") as w:
        w.setnchannels(nch)
        w.setsampwidth(2)
        w.setframerate(sr)
        frames = bytearray()
        for i in range(n):
            t = i / sr
            for ch in range(nch):
                amp = 0.5 if ch < 2 else (1.0 if i % 24000 < 480 else 0.0)  # click-ish
                v = amp * math.sin(2 * math.pi * freqs[ch] * t)
                frames += struct.pack("<h", int(v * 32767))
        w.writeframes(bytes(frames))
    return n


def make_midi(path, events, ppq=480, tempo_us=DEFAULT_TEMPO_US):
    write_smf(path, events, ppq=ppq, tempo_us=tempo_us)


def frames_at(tick, ppq=480, tempo_us=DEFAULT_TEMPO_US):
    return round(tick * (tempo_us / 1e6) / ppq * SR)


def rss_mb():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024 / 1024


class Fixtures(unittest.TestCase):
    """Base: builds one WAV + one MID with known event timestamps."""

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp(prefix="lanth0n-fix-")
        cls.wav_path = os.path.join(cls.dir, "test-song.wav")
        cls.mid_path = os.path.join(cls.dir, "test-song.mid")
        cls.nframes = make_wav(cls.wav_path, 10.0)
        # events at 0.5 s / 3.0 s / 5.5 s (+note-off 5.75 s)
        cls.events_spec = [
            (480, bytes([0xC0, 5])),               # PC  → 0.5 s
            (2880, bytes([0xB0, 7, 127])),         # CC  → 3.0 s
            (5280, bytes([0x90, 60, 100])),        # note-on → 5.5 s
            (5520, bytes([0x80, 60, 0])),          # note-off → 5.75 s
        ]
        make_midi(cls.mid_path, cls.events_spec)
        cls.expected_frames = [frames_at(t) for t, _ in cls.events_spec]
        cls.expected_msgs = [m for _, m in cls.events_spec]

    def make_engine(self):
        return Engine(
            offline=True, sample_rate=SR, block_size=BLOCK,
            midi_in_enabled=False,
        )

    def load_song(self, engine, wav_path=None, mid_path=None):
        song = Song(
            name="Test Song", artist="Test Artist", tuning="drop", key="D",
            wav_path=wav_path or self.wav_path,
            mid_path=mid_path or self.mid_path,
            sample_rate=SR,
        )
        song.cue()
        engine._plans = engine.build_plans(song)
        engine.transport.set_song(song)
        return song


class TestSyncAccuracy(Fixtures):
    def test_midi_events_dispatch_frame_exact(self):
        engine = self.make_engine()
        engine.start()
        self.load_song(engine)
        engine.play()
        engine.run_offline_until_stop()

        recorded = engine.dispatcher.recorded
        self.assertEqual(len(recorded), len(self.expected_frames),
                         f"expected {len(self.expected_frames)} events, got "
                         f"{[(f, list(m)) for f, m in recorded]}")
        for (frame, msg), exp_f, exp_m in zip(recorded, self.expected_frames, self.expected_msgs):
            self.assertEqual(frame, exp_f, "MIDI event frame mismatch")
            self.assertEqual(msg, exp_m)

        # song finished: transport stopped at end
        self.assertFalse(engine.transport.playing)
        self.assertEqual(engine.transport.position_frame, self.nframes)
        engine.shutdown()

    def test_audio_channels_routed_correctly(self):
        engine = self.make_engine()
        engine.start()
        song = self.load_song(engine)
        engine.backend.record = True
        engine.play()
        engine.run_offline_until_stop()

        # verify every rendered block equals the source WAV channels 1:1
        out = np.vstack(engine.backend.buffers["default"])[:self.nframes]
        src = song.read_block(0, self.nframes)
        self.assertEqual(out.shape[0], src.shape[0])
        for ch in range(song.nchannels):
            self.assertTrue(
                np.allclose(out[:, ch], src[:, ch], atol=1e-6),
                f"output channel {ch} differs from WAV channel {ch}")
        engine.shutdown()

    def test_transport_state_machine(self):
        engine = self.make_engine()
        engine.start()
        self.load_song(engine)
        t = engine.transport
        self.assertEqual(t.state, "cued")
        engine.play()
        self.assertTrue(t.playing)
        engine.stop()
        self.assertFalse(t.playing)
        # position retained after stop, restart continues from it
        pos = t.position_frame
        engine.play()
        for _ in range(3):
            engine.tick(BLOCK, _Ti(0.0), None)
        engine.stop()
        self.assertGreater(t.position_frame, pos)
        engine.shutdown()


class TestMemory(Fixtures):
    def test_flat_memory_long_song(self):
        """RSS must not climb while rendering a long song."""
        # 120 s song (same fixture content, longer render)
        long_wav = os.path.join(self.dir, "long.wav")
        make_wav(long_wav, 120.0)

        engine = self.make_engine()
        engine.start()
        self.load_song(engine, wav_path=long_wav)
        engine.play()
        rss0 = rss_mb()
        blocks = (120 * SR) // BLOCK
        for _ in range(blocks):
            engine.tick(BLOCK, _Ti(0.0), None)
            if not engine.transport.playing:
                break
        rss1 = rss_mb()
        engine.shutdown()
        growth = rss1 - rss0
        self.assertLess(growth, 20.0,
                        f"RSS grew {growth:.1f} MB during long-song render")
        print(f"  memory: {rss0:.1f} → {rss1:.1f} MB (Δ {growth:+.1f} MB)")

    def test_flat_memory_rapid_switching(self):
        """RSS must stay flat across rapid song switches."""
        n_songs = 25
        songs = []
        for i in range(n_songs):
            songs.append({
                "name": f"Song {i}", "artist": "", "tuning": "standard",
                "key": "E", "wav": os.path.basename(self.wav_path),
                "mid": os.path.basename(self.mid_path),
            })
        setlist_file = os.path.join(TMP, "setlists", "stress.json")
        os.makedirs(os.path.dirname(setlist_file), exist_ok=True)
        with open(setlist_file, "w") as f:
            import json
            json.dump({"name": "stress", "songs": songs}, f)
        # copy fixture files into the engine media dir
        import shutil
        media = os.path.join(TMP, "media")
        os.makedirs(media, exist_ok=True)
        shutil.copy(self.wav_path, media)
        shutil.copy(self.mid_path, media)

        engine = self.make_engine()
        engine.start()
        engine.load_setlist("stress")
        self._wait_cued(engine, 0)
        engine.play()
        rss0 = rss_mb()

        for i in range(1, n_songs):
            engine.next_song()
            self._wait_cued(engine, i)
            # render a few blocks of each song
            for _ in range(10):
                engine.tick(BLOCK, _Ti(0.0), None)
                if not engine.transport.playing:
                    break
        rss1 = rss_mb()
        engine.shutdown()
        growth = rss1 - rss0
        self.assertLess(growth, 25.0,
                        f"RSS grew {growth:.1f} MB across {n_songs} song switches")
        print(f"  memory: {rss0:.1f} → {rss1:.1f} MB over {n_songs} switches "
              f"(Δ {growth:+.1f} MB)")

    @staticmethod
    def _wait_cued(engine, idx, timeout=10.0):
        import time
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            if engine.transport.song is not None and engine.song_index == idx:
                return
            time.sleep(0.01)
        raise AssertionError(f"song {idx} never cued (song_index="
                             f"{engine.song_index})")


class _Ti:
    """Minimal PortAudio time_info stand-in for direct tick() calls."""

    def __init__(self, dac):
        self.outputBufferDacTime = dac


if __name__ == "__main__":
    unittest.main(verbosity=2)
