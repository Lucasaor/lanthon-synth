"""Tests for audio-device loss handling, recovery, and MIDI probe reuse.

Regressions from the Pi incident (2026-08-14): the CS202 USB interface
dropped off the bus and the engine spun at ~90% CPU with ALSA errors
instead of recovering; rtmidi probe objects were leaked on every refresh,
exhausting the kernel sequencer client table.
"""

import json
import os
import sys
import tempfile
import time
import unittest
from unittest import mock

TMP = tempfile.mkdtemp(prefix="lanth0n-recovery-")
os.environ["LANTH0N_PROJECT_DIR"] = TMP
MOCK_DEVICES = json.dumps({
    "audio": [{"key": "audio:0", "name": "Mock USB", "index": 0, "max_out_channels": 8}],
    "midi_out": [{"key": "midi_out:0", "name": "Mock Out", "index": 0}],
    "midi_in": [{"key": "midi_in:0", "name": "Mock In", "index": 0}],
})

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from engine.engine import Engine  # noqa: E402
from engine.midi_io import MidiInputManager  # noqa: E402
from engine import devices  # noqa: E402

SR = 48000
BLOCK = 512


def _push_mock_env():
    """Set the mock device snapshot, remembering any previous value."""
    prev = os.environ.get("LANTH0N_DEVICES_JSON")
    os.environ["LANTH0N_DEVICES_JSON"] = MOCK_DEVICES
    return prev


def _pop_mock_env(prev):
    if prev is None:
        os.environ.pop("LANTH0N_DEVICES_JSON", None)
    else:
        os.environ["LANTH0N_DEVICES_JSON"] = prev


class _Ti:
    def __init__(self, dac):
        self.outputBufferDacTime = dac


class FakeBackend:
    """Stand-in for the audio backend — counts stop/start cycles."""

    def __init__(self):
        self.starts = 0
        self.stops = 0
        self.buffers = {}

    def start(self, plans, sample_rate, block_size):
        self.starts += 1

    def stop(self):
        self.stops += 1

    def put_buffer(self, key, buf):
        self.buffers[key] = buf


class TestAudioRecovery(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._prev_devices = _push_mock_env()

    @classmethod
    def tearDownClass(cls):
        _pop_mock_env(cls._prev_devices)

    def make_engine(self):
        return Engine(
            offline=False, sample_rate=SR, block_size=BLOCK,
            midi_in_enabled=False, backend=FakeBackend(),
        )

    def test_error_status_silences_and_triggers_recovery(self):
        engine = self.make_engine()
        engine.start()
        self.assertEqual(engine.backend.starts, 1)

        # three consecutive callback errors (device lost)
        for _ in range(3):
            engine.tick(BLOCK, _Ti(0.0), status=1)
        # buffers must be silence during the failure
        for key, buf in engine.backend.buffers.items():
            self.assertFalse(buf.any(), f"buffer {key} not silenced on error")

        # recovery thread restarts the backend with fresh device plans
        deadline = time.monotonic() + 5.0
        while engine.backend.starts < 2 and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertGreaterEqual(engine.backend.starts, 2)
        self.assertGreaterEqual(engine.backend.stops, 1)
        # transport untouched by the outage
        self.assertEqual(engine.transport.position_frame, 0)
        engine.shutdown()

    def test_healthy_callbacks_do_not_recover(self):
        engine = self.make_engine()
        engine.start()
        for _ in range(10):
            engine.tick(BLOCK, _Ti(0.0), status=0)
        time.sleep(0.3)
        self.assertEqual(engine.backend.starts, 1)
        self.assertEqual(engine.backend.stops, 0)
        engine.shutdown()

    def test_start_survives_missing_audio_device(self):
        class FlakyBackend(FakeBackend):
            def start(self, plans, sample_rate, block_size):
                self.starts += 1
                if self.starts == 1:
                    raise RuntimeError("no audio output device")

        engine = Engine(
            offline=False, sample_rate=SR, block_size=BLOCK,
            midi_in_enabled=False, backend=FlakyBackend(),
        )
        # must NOT raise — engine stays up with OSC/state/OLED functional
        engine.start()
        self.assertFalse(engine._streams_healthy)

        # recovery cycle reopens the streams once a device appears
        engine._start_audio_recovery()
        deadline = time.monotonic() + 5.0
        while not engine._streams_healthy and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(engine._streams_healthy)
        self.assertEqual(engine.backend.starts, 2)
        engine.shutdown()


# ---------------------------------------------------------------------------
# Fake rtmidi for probe-reuse checks
# ---------------------------------------------------------------------------

class _FakePort:
    def __init__(self):
        self.opened = False

    def get_ports(self):
        return ["Mock In"]

    def open_port(self, index):
        self.opened = True

    def ignore_types(self, **kwargs):
        pass

    def get_message(self):
        return None

    def close_port(self):
        pass


class _FakeRtmidi:
    created = 0

    @classmethod
    def reset(cls):
        cls.created = 0

    @classmethod
    def MidiIn(cls):
        cls.created += 1
        return _FakePort()

    @classmethod
    def MidiOut(cls):
        cls.created += 1
        return _FakePort()


class TestProbeReuse(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._prev_devices = _push_mock_env()

    @classmethod
    def tearDownClass(cls):
        _pop_mock_env(cls._prev_devices)

    def test_devices_enumerate_reuses_probe(self):
        with mock.patch.dict(sys.modules, {"rtmidi": _FakeRtmidi}):
            _FakeRtmidi.reset()
            devices._probe_out = None
            devices._probe_in = None
            outs, ins = devices.enumerate_midi()
            self.assertEqual([d.name for d in outs], ["Mock In"])
            self.assertEqual([d.name for d in ins], ["Mock In"])
            created_after_first = _FakeRtmidi.created
            devices.enumerate_midi()
            devices.enumerate_midi()
            # no NEW rtmidi objects per call — the probes are reused
            self.assertEqual(_FakeRtmidi.created, created_after_first)
            devices._probe_out = None
            devices._probe_in = None

    def test_midi_input_manager_probe_reused_and_survives_errors(self):
        with mock.patch.dict(sys.modules, {"rtmidi": _FakeRtmidi}):
            _FakeRtmidi.reset()
            mgr = MidiInputManager(lambda msg: None, enabled=True)
            mgr._next_refresh = 0.0
            mgr._loop_once()
            self.assertIn("Mock In", mgr._ports)
            first_probe_creations = _FakeRtmidi.created
            # force several refreshes — probe is reused, no new clients
            for _ in range(3):
                mgr._next_refresh = 0.0
                mgr._loop_once()
            self.assertEqual(_FakeRtmidi.created, first_probe_creations)
            mgr.stop()

    def test_midi_input_manager_survives_broken_sequencer(self):
        # get_ports raising must not kill the manager thread logic
        class BrokenPort(_FakePort):
            def get_ports(self):
                raise RuntimeError("ALSA seq broken")

        class BrokenRtmidi(_FakeRtmidi):
            @classmethod
            def MidiIn(cls):
                return BrokenPort()

        with mock.patch.dict(sys.modules, {"rtmidi": BrokenRtmidi}):
            mgr = MidiInputManager(lambda msg: None, enabled=True)
            mgr._next_refresh = 0.0
            mgr._loop_once()   # must not raise
            self.assertIsNone(mgr._probe)  # stale probe dropped
            mgr.stop()


if __name__ == "__main__":
    unittest.main(verbosity=2)
