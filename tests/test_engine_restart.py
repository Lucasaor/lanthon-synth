"""Tests for the engine-restart feature (web button + MIDI CC).

The engine exits non-zero on restart so systemd's Restart=on-failure
brings it back; tests inject a recorder instead of actually exiting.
"""

import json
import os
import sys
import tempfile
import unittest
from unittest import mock

TMP = tempfile.mkdtemp(prefix="lanth0n-restart-test-")
os.environ.setdefault("LANTH0N_PROJECT_DIR", TMP)

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from engine import paths  # noqa: E402
from engine.engine import Engine  # noqa: E402

SR = 48000
BLOCK = 512


class TestEngineRestart(unittest.TestCase):
    def setUp(self):
        self.exit_calls = []
        self.engine = Engine(
            offline=True, sample_rate=SR, block_size=BLOCK,
            midi_in_enabled=False,
            exit_fn=lambda code: self.exit_calls.append(code),
        )
        self.engine.start()

    def tearDown(self):
        self.engine.shutdown()

    def test_restart_marks_offline_and_exits_42(self):
        with mock.patch.object(self.engine.osc, "oled_heartbeat") as hb, \
                mock.patch("engine.engine.write_state") as ws:
            self.engine.restart_engine()
            self.assertEqual(self.exit_calls, [42])
            hb.assert_called_with(False, False)
            snap = ws.call_args[0][0]
            self.assertFalse(snap["engineOnline"], "state must mark the engine offline")

    def test_osc_command_triggers_restart(self):
        handler = self.engine.osc._handlers.get("/engine/restart")
        self.assertIsNotNone(handler, "/engine/restart must be registered")
        handler()
        self.assertEqual(self.exit_calls, [42])

    def test_midi_mapping_triggers_restart(self):
        with open(paths.MIDI_MAP_FILE, "w") as f:
            json.dump({"mappings": [
                {"chan": 0, "type": "cc", "value": 70, "action": "engineRestart"},
            ]}, f)
        self.engine.mapper.reload()
        handled = self.engine.mapper.handle(bytes([0xB0, 70, 127]))
        self.assertTrue(handled)
        self.assertEqual(self.exit_calls, [42])
        # CC below threshold must not trigger
        self.engine.mapper.reload()
        handled = self.engine.mapper.handle(bytes([0xB0, 70, 10]))
        self.assertTrue(handled)
        self.assertEqual(self.exit_calls, [42])


if __name__ == "__main__":
    unittest.main(verbosity=2)
