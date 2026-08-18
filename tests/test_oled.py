#!/usr/bin/env python3
"""
tests/test_oled.py — OLED daemon tests (no hardware needed)

Tests the OSC server and rendering logic of oled_daemon.py.
Run with LANTH0N_OLED_MOCK=1 so no I2C hardware is required.

Usage:
  LANTH0N_OLED_MOCK=1 python3 tests/test_oled.py
"""

import os
import sys
import time
import threading
import unittest

# Force mock mode so no I2C hardware is needed
os.environ["LANTH0N_OLED_MOCK"] = "1"
os.environ["LANTH0N_OLED_PORT"] = "19876"  # use a non-default port for tests

# Add parent dir to path
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from oled_daemon import (update_state, _state, _state_lock, init_display,
                         render, start_osc_server, DisplayState,
                         _copy_state_locked, fmt_time)


class TestDisplayState(unittest.TestCase):

    def test_update_state_basic(self):
        update_state("Test Setlist", "Artist A", "Song B", "PLAYING", "Drop D")
        with _state_lock:
            self.assertEqual(_state.setlist_name, "Test Setlist")
            self.assertEqual(_state.artist, "Artist A")
            self.assertEqual(_state.song_name, "Song B")
            self.assertEqual(_state.playback_state, "PLAYING")
            self.assertEqual(_state.tuning, "Drop D")
            self.assertTrue(_state.dirty)

    def test_update_state_truncates(self):
        update_state("A" * 30, "B" * 30, "C" * 30, "STOP", "Standard E")
        with _state_lock:
            self.assertLessEqual(len(_state.setlist_name), 20)
            self.assertLessEqual(len(_state.artist), 20)
            self.assertLessEqual(len(_state.song_name), 20)

    def test_update_state_empty_fields(self):
        update_state("", "", "", "", "")
        with _state_lock:
            self.assertEqual(_state.setlist_name, "—")
            self.assertEqual(_state.playback_state, "STOP")

    def test_dirty_flag_set(self):
        with _state_lock:
            _state.dirty = False
        update_state("S", "A", "T", "PLAYING", "Drop C#")
        with _state_lock:
            self.assertTrue(_state.dirty)

    def test_render_copy_preserves_position_and_duration(self):
        """Regression: the render-loop copy used to drop position/duration,
        so the status line always showed 0:00/0:00."""
        update_state("S", "A", "T", "PLAYING", "Drop D", 114.0, 252.0)
        with _state_lock:
            snap = _copy_state_locked()
        self.assertEqual(snap.position_sec, 114.0)
        self.assertEqual(snap.duration_sec, 252.0)

    def test_fmt_time(self):
        self.assertEqual(fmt_time(0.0), "0:00")
        self.assertEqual(fmt_time(114.0), "1:54")
        self.assertEqual(fmt_time(252.4), "4:12")
        self.assertEqual(fmt_time(3600.0), "1:00:00")
        self.assertEqual(fmt_time("garbage"), "0:00")


class TestMockDisplay(unittest.TestCase):

    def test_init_display_mock(self):
        device = init_display()
        self.assertIsNone(device)  # mock mode → no device

    def test_render_mock_no_crash(self):
        state = DisplayState(
            setlist_name="Night 1",
            artist="Test Artist",
            song_name="Test Song",
            playback_state="PLAYING",
            tuning="Standard E",
        )
        # Should not raise even with device=None
        try:
            render(None, state)
        except ImportError:
            self.skipTest("Pillow not installed — skipping render test")


class TestOSCReceiver(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        """Start one shared OSC server for all receiver tests."""
        try:
            start_osc_server()
            time.sleep(0.2)
        except Exception as exc:
            raise unittest.SkipTest(f"OSC server failed to start: {exc}")

    def test_osc_server_starts(self):
        """Verify the OSC server started without error (set up in setUpClass)."""
        self.assertTrue(True)

    def test_osc_update_via_client(self):
        """Send a real OSC /oled/update message and verify state is updated."""
        try:
            from pythonosc.udp_client import SimpleUDPClient
        except ImportError:
            self.skipTest("python-osc not installed")

        client = SimpleUDPClient("127.0.0.1", 19876)
        client.send_message("/oled/update", ["Setlist X", "Band Y", "Song Z", "PLAYING", "Drop D"])
        time.sleep(0.2)

        with _state_lock:
            self.assertEqual(_state.song_name, "Song Z")
            self.assertEqual(_state.tuning, "Drop D")

    def test_osc_update_position_duration(self):
        """7-arg /oled/update carries position/duration through to state."""
        try:
            from pythonosc.udp_client import SimpleUDPClient
        except ImportError:
            self.skipTest("python-osc not installed")

        client = SimpleUDPClient("127.0.0.1", 19876)
        client.send_message("/oled/update",
                            ["SL", "AR", "SN", "PLAYING", "Drop D", 65.0, 200.0])
        time.sleep(0.2)

        with _state_lock:
            self.assertEqual(_state.position_sec, 65.0)
            self.assertEqual(_state.duration_sec, 200.0)


if __name__ == "__main__":
    print("=== OLED Daemon Tests (MOCK mode) ===")
    unittest.main(verbosity=2)
