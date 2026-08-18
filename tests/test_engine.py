"""Engine verification: sample-accurate sync, channel routing, memory.

All tests run offline (LANTH0N_OFFLINE semantics — the engine's offline
driver), which exercises the exact same tick()/dispatch code path as the
realtime backend, with deterministic results.

Run:  python3 tests/test_engine.py
"""

import json
import math
import os
import resource
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import wave

import numpy as np

# LANTH0N_PROJECT_DIR must be set BEFORE importing engine (paths module
# reads it at import time) so state files land in a temp dir.
TMP = tempfile.mkdtemp(prefix="lanth0n-engine-test-")
os.environ.setdefault("LANTH0N_PROJECT_DIR", TMP)

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from engine import paths  # noqa: E402
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
    """Base: builds one WAV + one MID with known event timestamps.

    Mock device snapshots are popped for this module — the engine's
    identity fallback (no devices) is what these tests assert.
    """

    @classmethod
    def setUpClass(cls):
        cls._prev_devices = os.environ.pop("LANTH0N_DEVICES_JSON", None)
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

    @classmethod
    def tearDownClass(cls):
        if cls._prev_devices is not None:
            os.environ["LANTH0N_DEVICES_JSON"] = cls._prev_devices

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

        # song finished: transport stopped and rewound to the top
        self.assertFalse(engine.transport.playing)
        self.assertEqual(engine.transport.position_frame, 0)
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
        for _ in range(5):
            engine.tick(BLOCK, _Ti(0.0), None)
        self.assertGreater(t.position_frame, 0)
        engine.stop()
        self.assertFalse(t.playing)
        # full stop (not pause): position rewound to the top
        self.assertEqual(t.position_frame, 0)
        engine.play()
        self.assertTrue(t.playing)
        self.assertEqual(t.position_frame, 0)
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
        setlist_file = os.path.join(str(paths.SETLISTS_DIR), "stress.json")
        os.makedirs(os.path.dirname(setlist_file), exist_ok=True)
        with open(setlist_file, "w") as f:
            import json
            json.dump({"name": "stress", "songs": songs}, f)
        # copy fixture files into the engine media dir
        import shutil
        media = str(paths.MEDIA_DIR)
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


class TestSeek(Fixtures):
    def test_seek_and_stop_semantics(self):
        """Seek survives stop() → play(); a second stop clears it."""
        engine = self.make_engine()
        engine.start()
        self.load_song(engine)
        t = engine.transport
        engine.play()
        for _ in range(5):
            engine.tick(BLOCK, _Ti(0.0), None)
        self.assertGreater(t.position_frame, 0)

        engine.seek(1.5)
        self.assertEqual(t.position_frame, int(1.5 * SR))
        self.assertEqual(t.seek_sec(), 1.5)

        # rendering continues from the seek position
        engine.tick(BLOCK, _Ti(0.0), None)
        self.assertEqual(t.position_frame, int(1.5 * SR) + BLOCK)

        # stop with a seek defined → next play resumes from the seek time
        engine.stop()
        self.assertFalse(t.playing)
        self.assertEqual(t.position_frame, int(1.5 * SR))
        engine.play()
        self.assertTrue(t.playing)
        self.assertEqual(t.position_frame, int(1.5 * SR))

        # stopping from playing keeps the seek position...
        engine.stop()
        self.assertFalse(t.playing)
        self.assertEqual(t.position_frame, int(1.5 * SR))
        # ...but a second stop while already stopped clears it
        engine.stop()
        self.assertFalse(t.playing)
        self.assertIsNone(t.seek_sec())
        self.assertEqual(t.position_frame, 0)
        engine.play()
        self.assertTrue(t.playing)
        self.assertEqual(t.position_frame, 0)
        engine.shutdown()

    def test_seek_recomputes_midi_dispatch(self):
        """After a seek, only events at/after the new position fire."""
        engine = self.make_engine()
        engine.start()
        self.load_song(engine)
        engine.play()
        # 4.0 s: past the 0.5 s PC and 3.0 s CC, before the 5.5 s note
        engine.seek(4.0)
        self.assertEqual(engine._next_event_idx, 2)
        engine.run_offline_until_stop()
        recorded = engine.dispatcher.recorded
        self.assertEqual(len(recorded), 2,
                         f"expected only post-seek events, got "
                         f"{[(f, list(m)) for f, m in recorded]}")
        for (frame, msg), exp_f, exp_m in zip(
                recorded, self.expected_frames[2:], self.expected_msgs[2:]):
            self.assertEqual(frame, exp_f, "MIDI event frame mismatch after seek")
            self.assertEqual(msg, exp_m)
        engine.shutdown()

    def test_seek_while_stopped_and_clamping(self):
        engine = self.make_engine()
        engine.start()
        self.load_song(engine)
        t = engine.transport
        # seek before ever playing: position set, transport stays cued
        engine.seek(2.0)
        self.assertEqual(t.position_frame, int(2.0 * SR))
        self.assertEqual(t.seek_sec(), 2.0)
        # clamp to song bounds (fixture is 10 s long)
        engine.seek(999.0)
        self.assertEqual(t.position_frame, self.nframes)
        engine.seek(-5.0)
        self.assertEqual(t.position_frame, 0)
        engine.seek(2.0)
        engine.play()
        self.assertTrue(t.playing)
        self.assertEqual(t.position_frame, int(2.0 * SR))
        # natural song end clears any pending seek
        engine.run_offline_until_stop()
        self.assertIsNone(t.seek_sec())
        self.assertEqual(t.position_frame, 0)
        engine.shutdown()


class TestDevicePersistence(Fixtures):
    """A missing configured interface must NOT be masked by a working
    fallback stream — the engine stays unhealthy, keeps re-enumerating,
    and re-attaches when the interface (re)appears."""

    MOCK_ABSENT = json.dumps({
        "audio": [{"key": "audio:0", "name": "default", "index": 0,
                    "max_out_channels": 2}],
        "midi_out": [{"key": "midi_out:0", "name": "Midi Through", "index": 0}],
        "midi_in": [],
    })
    MOCK_PRESENT = json.dumps({
        "audio": [{"key": "audio:0", "name": "CS202: USB Audio (hw:0,0)",
                    "index": 0, "max_out_channels": 2}],
        "midi_out": [{"key": "midi_out:0", "name": "Midi Through", "index": 0}],
        "midi_in": [],
    })

    @classmethod
    def setUpClass(cls):
        super().setUpClass()  # Fixtures: WAV/MIDI fixtures + env pop
        cfg_dir = str(paths.CONFIG_DIR)
        os.makedirs(cfg_dir, exist_ok=True)
        with open(os.path.join(cfg_dir, "audio_routing.json"), "w") as f:
            json.dump({"tracks": {
                "playback_l": {"device": "CS202: USB Audio (hw:0,0)", "channel": 1},
                "playback_r": {"device": "CS202: USB Audio (hw:0,0)", "channel": 2},
            }}, f)

    @classmethod
    def tearDownClass(cls):
        try:
            os.remove(os.path.join(str(paths.CONFIG_DIR), "audio_routing.json"))
        except FileNotFoundError:
            pass
        super().tearDownClass()

    def setUp(self):
        self._prev = os.environ.get("LANTH0N_DEVICES_JSON")

    def tearDown(self):
        if self._prev is None:
            os.environ.pop("LANTH0N_DEVICES_JSON", None)
        else:
            os.environ["LANTH0N_DEVICES_JSON"] = self._prev

    def test_fallback_stream_stays_unhealthy_until_device_appears(self):
        os.environ["LANTH0N_DEVICES_JSON"] = self.MOCK_ABSENT
        engine = self.make_engine()
        engine.start()
        # streams open (offline backend) but the configured device is
        # absent → the engine must NOT consider itself healthy
        self.assertFalse(engine._streams_healthy,
                         "fallback stream masked the missing interface")
        self.load_song(engine)
        self.assertFalse(engine._streams_healthy)

        # the interface appears → applying routing re-attaches to it
        os.environ["LANTH0N_DEVICES_JSON"] = self.MOCK_PRESENT
        engine.apply_routing()
        self.assertTrue(engine._streams_healthy)
        self.assertTrue(any("CS202" in p.name for p in engine._plans),
                        f"plans: {[p.name for p in engine._plans]}")
        engine.shutdown()

    def test_apply_routing_rebuilds_after_device_swap(self):
        os.environ["LANTH0N_DEVICES_JSON"] = self.MOCK_PRESENT
        engine = self.make_engine()
        engine.start()
        self.load_song(engine)
        self.assertTrue(engine._streams_healthy)
        self.assertTrue(any("CS202" in p.name for p in engine._plans))

        # device drops off the bus
        os.environ["LANTH0N_DEVICES_JSON"] = self.MOCK_ABSENT
        engine.apply_routing()
        self.assertFalse(engine._streams_healthy)
        self.assertTrue(any(p.device is None for p in engine._plans))
        engine.shutdown()


class TestOscRobustness(Fixtures):
    def test_malformed_osc_does_not_kill_server(self):
        import socket

        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()

        engine = Engine(offline=True, sample_rate=SR, block_size=BLOCK,
                        midi_in_enabled=False, osc_port=port)
        engine.start()
        t = threading.Thread(target=engine.serve_forever, daemon=True)
        t.start()
        time.sleep(0.2)
        self.assertTrue(t.is_alive())

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # garbage bytes + an OSC message with a boolean type tag
        # (python-osc cannot decode T/F — must not take the server down)
        sock.sendto(b"\x00\x01\x02\x03not-osc-at-all", ("127.0.0.1", port))
        sock.sendto(b"/x\x00\x00" + b",T\x00\x00" + b"\x01\x00\x00\x00",
                    ("127.0.0.1", port))
        time.sleep(0.3)
        self.assertTrue(t.is_alive(), "OSC server died on malformed datagram")

        # a valid message is still served afterwards
        from pythonosc.udp_client import SimpleUDPClient

        client = SimpleUDPClient("127.0.0.1", port)
        client.send_message("/backtrack/play", [])
        time.sleep(0.3)
        self.assertTrue(engine.transport.pending_play,
                        "play latch not set — server no longer handling messages")
        sock.close()
        engine.shutdown()


class TestSetlistHotReload(Fixtures):
    """Edits to the active setlist file must be picked up automatically
    (the user edits on disk / web UI → engine reloads without a manual
    'Load to Rig')."""

    def setUp(self):
        import shutil

        media = str(paths.MEDIA_DIR)
        os.makedirs(media, exist_ok=True)
        shutil.copy(self.wav_path, os.path.join(media, "hot.wav"))
        shutil.copy(self.mid_path, os.path.join(media, "hot.mid"))
        self.sl = os.path.join(str(paths.SETLISTS_DIR), "hot.json")
        os.makedirs(os.path.dirname(self.sl), exist_ok=True)
        self._write(("A", "B"))

    def _write(self, names):
        with open(self.sl, "w") as f:
            json.dump({"name": "hot", "songs": [
                {"name": n, "artist": "", "tuning": "standard", "key": "E",
                 "wav": "hot.wav", "mid": "hot.mid"}
                for n in names
            ]}, f)

    def _engine(self):
        engine = self.make_engine()
        engine.start()
        engine.load_setlist("hot")
        self.assertTrue(engine.wait_cued())
        return engine

    def test_watch_reloads_edited_setlist(self):
        engine = self._engine()
        self.assertEqual(len(engine.setlist["songs"]), 2)
        self._write(("A",))           # user removes a song
        engine._watch_setlist()
        self.assertEqual(len(engine.setlist["songs"]), 1)
        self.assertEqual(engine.song_index, 0)
        self.assertEqual(engine.transport.song.name, "A")
        engine.shutdown()

    def test_watch_noop_when_unchanged(self):
        engine = self._engine()
        before = [s.name for s in engine.setlist["songs"]]
        engine._watch_setlist()
        self.assertEqual([s.name for s in engine.setlist["songs"]], before)
        engine.shutdown()

    def test_watch_autoplays_when_playing(self):
        engine = self._engine()
        engine.play()
        self.assertTrue(engine.transport.playing)
        self._write(("B",))           # replace song list while playing
        engine._watch_setlist()
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            if (engine.transport.playing
                    and engine.transport.song is not None
                    and engine.transport.song.name == "B"):
                break
            time.sleep(0.02)
        else:
            self.fail("hot-reload did not resume playback of the new song")
        engine.shutdown()

    def test_watch_keeps_list_when_file_deleted(self):
        engine = self._engine()
        os.remove(self.sl)
        engine._watch_setlist()
        self.assertEqual(len(engine.setlist["songs"]), 2,
                         "in-memory setlist must survive file deletion")
        engine.shutdown()


class TestCueError(Fixtures):
    def test_cue_failure_surfaces_in_state(self):
        media = str(paths.MEDIA_DIR)
        os.makedirs(media, exist_ok=True)
        with open(os.path.join(media, "broken.wav"), "w"):
            pass  # 0-byte file
        sl = os.path.join(str(paths.SETLISTS_DIR), "broken.json")
        os.makedirs(os.path.dirname(sl), exist_ok=True)
        with open(sl, "w") as f:
            json.dump({"name": "broken", "songs": [
                {"name": "Broken", "artist": "", "tuning": "standard", "key": "E",
                 "wav": "broken.wav", "mid": ""}]}, f)

        engine = self.make_engine()
        engine.start()
        engine.load_setlist("broken")
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and engine._cue_error is None:
            time.sleep(0.02)
        self.assertIsNotNone(engine._cue_error, "cue failure not recorded")
        self.assertIn("broken.wav", engine._cue_error)
        with open(paths.STATE_FILE) as f:
            st = json.load(f)
        self.assertTrue(st.get("cueError"), "cueError missing from state.json")
        engine.shutdown()

    def test_failed_cue_clears_stale_song(self):
        media = str(paths.MEDIA_DIR)
        os.makedirs(media, exist_ok=True)
        shutil.copy(self.wav_path, os.path.join(media, "good.wav"))
        good = os.path.join(str(paths.SETLISTS_DIR), "good.json")
        os.makedirs(os.path.dirname(good), exist_ok=True)
        with open(good, "w") as f:
            json.dump({"name": "good", "songs": [
                {"name": "Good", "artist": "", "tuning": "standard", "key": "E",
                 "wav": "good.wav", "mid": ""}]}, f)

        engine = self.make_engine()
        engine.start()
        engine.load_setlist("good")
        self.assertTrue(engine.wait_cued())
        self.assertIsNotNone(engine.transport.song)

        # a new setlist whose only song cannot be cued
        with open(os.path.join(media, "broken.wav"), "w"):
            pass
        bad = os.path.join(str(paths.SETLISTS_DIR), "bad.json")
        with open(bad, "w") as f:
            json.dump({"name": "bad", "songs": [
                {"name": "Broken", "artist": "", "tuning": "standard", "key": "E",
                 "wav": "broken.wav", "mid": ""}]}, f)
        engine.load_setlist("bad")
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and engine._cue_error is None:
            time.sleep(0.02)
        self.assertIsNotNone(engine._cue_error)
        self.assertIsNone(engine.transport.song,
                          "stale song from the previous setlist still cued")
        engine.shutdown()


class TestMediaCache(Fixtures):
    def test_startup_purges_decoded_cache(self):
        os.makedirs(paths.CACHE_DIR, exist_ok=True)
        junk = paths.CACHE_DIR / "stale.wav"
        junk.write_bytes(b"junk")
        engine = self.make_engine()
        engine.start()
        self.assertFalse(junk.exists(), "stale decoded cache not purged")
        engine.shutdown()


class TestM4aDecode(Fixtures):
    """Compressed M4A/AAC sources: decoded to a cached WAV at cue time,
    streamed + seekable, cache removed when the song closes."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.ffmpeg = shutil.which("ffmpeg")

    def _make_m4a(self, out):
        subprocess.run(
            [self.ffmpeg, "-y", "-v", "error", "-i", self.wav_path,
             "-c:a", "aac", "-b:a", "192k", out],
            check=True)

    def test_m4a_cue_read_seek_and_cache_cleanup(self):
        if not self.ffmpeg:
            raise unittest.SkipTest("ffmpeg not available")
        m4a = os.path.join(self.dir, "test-song.m4a")
        self._make_m4a(m4a)

        song = Song(name="M4A Song", artist="", tuning="standard", key="E",
                    wav_path=m4a, mid_path=None, sample_rate=SR)
        song.cue()
        try:
            self.assertTrue(song.open)
            self.assertEqual(song.nchannels, 4)
            # AAC priming adds a little padding — allow < 1 s of slack
            self.assertLess(abs(song.frames - self.nframes), SR)
            cache = song._cache_wav
            self.assertTrue(cache and os.path.exists(cache),
                            "decoded cache WAV missing")

            blk = song.read_block(0, SR)
            self.assertEqual(blk.shape, (SR, 4))
            # channels 1-2 (VS tones) and 3 (click) must carry signal
            self.assertGreater(np.abs(blk[:, 0]).mean(), 1e-3, "VS L silent")
            self.assertGreater(np.abs(blk[:, 1]).mean(), 1e-3, "VS R silent")
            self.assertGreater(np.abs(blk[:, 2]).mean(), 1e-3, "click silent")

            # seek: the middle of the song differs from the start
            mid = song.read_block(5 * SR, 1000)
            self.assertFalse(np.allclose(blk[:1000], mid, atol=1e-3))
        finally:
            song.close()
        self.assertFalse(os.path.exists(cache), "cache WAV not cleaned up")

    def test_engine_plays_m4a_offline(self):
        if not self.ffmpeg:
            raise unittest.SkipTest("ffmpeg not available")
        m4a = os.path.join(self.dir, "test-song.m4a")
        self._make_m4a(m4a)

        engine = self.make_engine()
        engine.start()
        self.load_song(engine, wav_path=m4a)
        engine.backend.record = True
        engine.play()
        engine.run_offline_until_stop()
        out = np.vstack(engine.backend.buffers["default"])
        self.assertGreater(np.abs(out[:, 0]).mean(), 1e-3,
                           "rendered VS channel is silent")
        # companion MIDI automation still dispatches frame-exact
        self.assertEqual(len(engine.dispatcher.recorded),
                         len(self.expected_frames))
        engine.shutdown()

    def test_m4a_decode_failure_surfaces(self):
        if not self.ffmpeg:
            raise unittest.SkipTest("ffmpeg not available")
        bad = os.path.join(self.dir, "garbage.m4a")
        with open(bad, "w") as f:
            f.write("this is not audio at all")
        song = Song(name="Bad", artist="", tuning="standard", key="E",
                    wav_path=bad, mid_path=None, sample_rate=SR)
        with self.assertRaises(Exception):
            song.cue()
        self.assertFalse(song.open)
        song.close()


class _Ti:
    """Minimal PortAudio time_info stand-in for direct tick() calls."""

    def __init__(self, dac):
        self.outputBufferDacTime = dac


if __name__ == "__main__":
    unittest.main(verbosity=2)
