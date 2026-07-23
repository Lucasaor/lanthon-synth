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

from oled_daemon import update_state, _state, _state_lock, init_display, render, start_osc_server, DisplayState


class TestDisplayState(unittest.TestCase):

    def test_update_state_basic(self):
        update_state("Test Setlist", "Artist A", "Song B", "PLAYING", "128")
        with _state_lock:
            self.assertEqual(_state.setlist_name, "Test Setlist")
            self.assertEqual(_state.artist, "Artist A")
            self.assertEqual(_state.song_name, "Song B")
            self.assertEqual(_state.playback_state, "PLAYING")
            self.assertEqual(_state.bpm, "128")
            self.assertTrue(_state.dirty)

    def test_update_state_truncates(self):
        update_state("A" * 30, "B" * 30, "C" * 30, "STOP", "120")
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
        update_state("S", "A", "T", "PLAYING", "100")
        with _state_lock:
            self.assertTrue(_state.dirty)


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
            bpm="128",
        )
        # Should not raise even with device=None
        try:
            render(None, state)
        except ImportError:
            self.skipTest("Pillow not installed — skipping render test")


class TestOSCReceiver(unittest.TestCase):

    def test_osc_server_starts(self):
        """Verify OSC server thread starts without error."""
        try:
            start_osc_server()
            time.sleep(0.2)
        except Exception as exc:
            self.fail(f"OSC server failed to start: {exc}")

    def test_osc_update_via_client(self):
        """Send a real OSC /oled/update message and verify state is updated."""
        try:
            from pythonosc.udp_client import SimpleUDPClient
        except ImportError:
            self.skipTest("python-osc not installed")

        start_osc_server()
        time.sleep(0.1)

        client = SimpleUDPClient("127.0.0.1", 19876)
        client.send_message("/oled/update", ["Setlist X", "Band Y", "Song Z", "PLAYING", "142"])
        time.sleep(0.2)

        with _state_lock:
            self.assertEqual(_state.song_name, "Song Z")
            self.assertEqual(_state.bpm, "142")


if __name__ == "__main__":
    print("=== OLED Daemon Tests (MOCK mode) ===")
    unittest.main(verbosity=2)
