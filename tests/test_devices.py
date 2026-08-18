"""Tests for device enumeration + routing resolution (Step 3)."""

import json
import math
import os
import struct
import sys
import tempfile
import unittest
import wave

import numpy as np

TMP = tempfile.mkdtemp(prefix="lanth0n-routing-test-")
os.environ["LANTH0N_PROJECT_DIR"] = TMP

# Mock device snapshot (no audio hardware on dev machine)
MOCK_SNAPSHOT = json.dumps({
    "audio": [
        {"key": "audio:0", "name": "Mock USB 8ch", "index": 0, "max_out_channels": 8},
        {"key": "audio:1", "name": "Mock USB 2ch", "index": 1, "max_out_channels": 2},
    ],
    "midi_out": [
        {"key": "midi_out:0", "name": "Mock Pedalboard", "index": 0},
        {"key": "midi_out:1", "name": "Mock Synth Board", "index": 1},
    ],
    "midi_in": [
        {"key": "midi_in:0", "name": "Mock Controller", "index": 0},
    ],
})

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from engine import devices  # noqa: E402
from engine import paths  # noqa: E402
from engine.engine import Engine  # noqa: E402
from engine.smf import write_smf  # noqa: E402
from engine.song import Song  # noqa: E402

SR = 48000
BLOCK = 512


def _push_mock_env():
    prev = os.environ.get("LANTH0N_DEVICES_JSON")
    os.environ["LANTH0N_DEVICES_JSON"] = MOCK_SNAPSHOT
    return prev


def _pop_mock_env(prev):
    if prev is None:
        os.environ.pop("LANTH0N_DEVICES_JSON", None)
    else:
        os.environ["LANTH0N_DEVICES_JSON"] = prev


def make_wav(path, seconds, nch=4):
    n = int(seconds * SR)
    with wave.open(path, "wb") as w:
        w.setnchannels(nch)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = bytearray()
        for i in range(n):
            for ch in range(nch):
                v = (ch + 1) * 0.2 * math.sin(2 * math.pi * (220 * (ch + 1)) * i / SR)
                frames += struct.pack("<h", int(v * 32767))
        w.writeframes(bytes(frames))
    return n


class TestEnumeration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._prev = _push_mock_env()

    @classmethod
    def tearDownClass(cls):
        _pop_mock_env(cls._prev)

    def test_mock_snapshot_reflected(self):
        snap = devices.snapshot()
        self.assertEqual(len(snap.audio), 2)
        self.assertEqual(snap.audio[0].name, "Mock USB 8ch")
        self.assertEqual(snap.audio[0].key, "audio:0")
        self.assertEqual(len(snap.midi_out), 2)
        self.assertEqual(snap.midi_out[1].name, "Mock Synth Board")
        self.assertEqual(len(snap.midi_in), 1)

    def test_snapshot_json_roundtrip(self):
        snap = devices.snapshot()
        data = json.loads(json.dumps(devices.snapshot_to_json(snap)))
        self.assertEqual(data["default_audio"], "audio:0")
        self.assertEqual(data["default_midi_out"], "midi_out:0")
        self.assertEqual(data["audio"][1]["max_out_channels"], 2)


class TestResolution(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._prev = _push_mock_env()
        cls.dir = tempfile.mkdtemp(prefix="lanth0n-resolve-")
        cls.wav = os.path.join(cls.dir, "song.wav")
        cls.mid = os.path.join(cls.dir, "song.mid")
        make_wav(cls.wav, 2.0, nch=4)
        write_smf(cls.mid, [(480, bytes([0xC0, 1]))])
        cls.song = Song(name="S", artist="", tuning="standard", key="E",
                        wav_path=cls.wav, mid_path=cls.mid, sample_rate=SR)
        cls.song.cue()
        cls.snap = devices.snapshot()

    @classmethod
    def tearDownClass(cls):
        _pop_mock_env(cls._prev)
        cls.song.close()

    def _plans(self, cfg):
        return devices.resolve_routing(cfg, self.song, self.snap)[0]

    def test_auto_targets_first_device_with_identity_channels(self):
        # empty config + known devices → tracks land on the default device
        plans = self._plans({})
        self.assertEqual(len(plans), 1)
        self.assertEqual(plans[0].key, "audio:0")
        routes = {(r.wav_ch, r.out_ch) for r in plans[0].routes}
        self.assertEqual(routes, {(0, 0), (1, 1), (2, 2), (3, 3)})
        self.assertTrue(plans[0].is_master)

    def test_identity_fallback_when_no_devices_at_all(self):
        snap_empty = devices.Snapshot()
        plans = devices.resolve_routing({}, self.song, snap_empty)[0]
        self.assertEqual(len(plans), 1)
        self.assertEqual(plans[0].key, "default")
        self.assertEqual([r.wav_ch for r in plans[0].routes], [0, 1, 2, 3])

    def test_per_track_device_and_channel(self):
        cfg = {
            "tracks": {
                "playback_l": {"device": "Mock USB 8ch", "channel": 1},
                "playback_r": {"device": "Mock USB 8ch", "channel": 2},
                "click": {"device": "Mock USB 2ch", "channel": 1},
                "cue": {"device": "Mock USB 8ch", "channel": 4},
            }
        }
        plans = {p.key: p for p in self._plans(cfg)}
        self.assertEqual(set(plans), {"audio:0", "audio:1"})
        main = plans["audio:0"]
        routes = {(r.wav_ch, r.out_ch) for r in main.routes}
        self.assertEqual(routes, {(0, 0), (1, 1), (3, 3)})  # L, R, Cue
        self.assertTrue(main.is_master)
        second = plans["audio:1"]
        self.assertEqual([(r.wav_ch, r.out_ch) for r in second.routes], [(2, 0)])
        self.assertFalse(second.is_master)

    def test_unknown_device_falls_back_to_default_plan(self):
        cfg = {"tracks": {"click": {"device": "Not Plugged In", "channel": 1}}}
        plans = self._plans(cfg)
        # a missing named device must NOT be silently substituted by
        # another enumerated device — the track lands on the default
        # fallback plan (device=None → system default) instead
        self.assertIsNone(devices._resolve_audio(cfg["tracks"]["click"], self.snap))
        default = next(p for p in plans if p.key == "default")
        self.assertIsNone(default.device)
        self.assertTrue(any(r.wav_ch == 2 for r in default.routes))

    def test_missing_audio_devices_reported(self):
        cfg = {"tracks": {
            "playback_l": {"device": "Mock USB 8ch", "channel": 1},
            "playback_r": {"device": "Mock USB 8ch", "channel": 2},
            "click": {"device": "Gone Away Interface", "channel": 1},
            "cue": {"device": "Mock USB 2ch", "channel": 2},
        }}
        missing = devices.missing_audio_devices(cfg, self.snap)
        self.assertEqual(missing, ["Gone Away Interface"])
        # auto tracks never count as missing
        cfg["tracks"]["click"]["device"] = "auto"
        self.assertEqual(devices.missing_audio_devices(cfg, self.snap), [])

    def test_timecode_disabled_by_default(self):
        cfg = {"tracks": {}}
        plans = self._plans(cfg)
        all_wav = {r.wav_ch for p in plans for r in p.routes}
        self.assertNotIn(4, all_wav)

    def test_timecode_routed_when_enabled_and_present(self):
        wav5 = os.path.join(self.dir, "song5.wav")
        make_wav(wav5, 1.0, nch=5)
        song5 = Song(name="S5", artist="", tuning="standard", key="E",
                     wav_path=wav5, mid_path=self.mid, sample_rate=SR)
        song5.cue()
        cfg = {"tracks": {"timecode": {"device": "Mock USB 8ch", "channel": 8, "enabled": True}}}
        plans = devices.resolve_routing(cfg, song5, self.snap)[0]
        main = next(p for p in plans if p.key == "audio:0")
        self.assertTrue(any(r.wav_ch == 4 and r.out_ch == 7 for r in main.routes))
        song5.close()

    def test_clock_device_override(self):
        cfg = {
            "clock_device": "Mock USB 2ch",
            "tracks": {
                "playback_l": {"device": "Mock USB 8ch", "channel": 1},
                "playback_r": {"device": "Mock USB 8ch", "channel": 2},
                "click": {"device": "Mock USB 2ch", "channel": 1},
            }
        }
        plans = self._plans(cfg)
        master = [p for p in plans if p.is_master]
        self.assertEqual(len(master), 1)
        self.assertEqual(master[0].key, "audio:1")

    def test_midi_automation_resolution(self):
        cfg = {"tracks": {"midi_automation": {"device": "Mock Synth Board"}}}
        name = devices.resolve_routing(cfg, self.song, self.snap)[1]
        self.assertEqual(name, "Mock Synth Board")


class TestOfflineMultiDevice(unittest.TestCase):
    """End-to-end offline render across two mocked devices."""

    @classmethod
    def setUpClass(cls):
        cls._prev = _push_mock_env()

    @classmethod
    def tearDownClass(cls):
        _pop_mock_env(cls._prev)

    def test_channels_land_on_configured_devices(self):
        dirp = tempfile.mkdtemp(prefix="lanth0n-multi-")
        wav = os.path.join(dirp, "s.wav")
        mid = os.path.join(dirp, "s.mid")
        make_wav(wav, 1.0, nch=4)
        write_smf(mid, [(480, bytes([0xC0, 1]))])

        routing = {
            "clock_device": "Mock USB 8ch",
            "tracks": {
                "playback_l": {"device": "Mock USB 8ch", "channel": 1},
                "playback_r": {"device": "Mock USB 8ch", "channel": 2},
                "click": {"device": "Mock USB 2ch", "channel": 1},
                "cue": {"device": "Mock USB 2ch", "channel": 2},
                "midi_automation": {"device": "Mock Pedalboard"},
            }
        }
        cfg_dir = str(paths.CONFIG_DIR)
        os.makedirs(cfg_dir, exist_ok=True)
        with open(os.path.join(cfg_dir, "audio_routing.json"), "w") as f:
            json.dump(routing, f)

        engine = Engine(offline=True, sample_rate=SR, block_size=BLOCK,
                        midi_in_enabled=False)
        engine.start()
        song = Song(name="S", artist="", tuning="standard", key="E",
                    wav_path=wav, mid_path=mid, sample_rate=SR)
        song.cue()
        engine._plans = engine.build_plans(song)
        engine.transport.set_song(song)
        engine.backend.record = True
        engine.play()
        engine.run_offline_until_stop()

        n = song.frames
        out0 = np.vstack(engine.backend.buffers["audio:0"])[:n]   # 8ch device
        out1 = np.vstack(engine.backend.buffers["audio:1"])[:n]   # 2ch device
        src = song.read_block(0, n)

        self.assertTrue(np.allclose(out0[:, 0], src[:, 0], atol=1e-6))  # L
        self.assertTrue(np.allclose(out0[:, 1], src[:, 1], atol=1e-6))  # R
        self.assertTrue(np.allclose(out1[:, 0], src[:, 2], atol=1e-6))  # Click
        self.assertTrue(np.allclose(out1[:, 1], src[:, 3], atol=1e-6))  # Cue

        # MIDI events dispatched frame-exact as before
        self.assertEqual(len(engine.dispatcher.recorded), 1)
        self.assertEqual(engine.dispatcher.recorded[0][0],
                         round(480 * 500000 / 1e6 / 480 * SR))
        engine.shutdown()


if __name__ == "__main__":
    unittest.main(verbosity=2)
