#!/usr/bin/env python3
"""
oled_daemon.py — LANTH0N 5YNTH: SSD1306 OLED display daemon

Listens for OSC messages from the SuperCollider backtrack engine and renders
the current playback state to a 0.96" SSD1306 I2C OLED display (128×64 px).

Display layout (128×64, blue region top row, yellow region bottom rows):
  Line 1 (top, blue):   Setlist name
  Line 2:               Artist name
  Line 3:               Song name
  Line 4 (bottom):      [PLAYING / STOP]  BPM: xxx

OSC interface (UDP, default port 9000):
  /oled/update  <setlistName> <artist> <songName> <state> <bpm>
    Example: /oled/update "Night 1" "Tool" "Sober" "PLAYING" "120"

Requirements (install on Pi):
  pip3 install luma.oled python-osc Pillow
  For dev (no I2C hardware), set LANTH0N_OLED_MOCK=1 to skip I2C init.

Usage:
  python3 oled_daemon.py              # normal operation
  LANTH0N_OLED_MOCK=1 python3 oled_daemon.py  # dev/test without display

systemd: see deploy/lanthon-oled.service
"""

import os
import sys
import signal
import threading
import logging
from dataclasses import dataclass, field
from typing import Optional

logging.basicConfig(
    level=logging.INFO,
    format="[OLED] %(asctime)s %(levelname)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("oled_daemon")

# =============================================================================
# CONFIGURATION
# =============================================================================

OSC_PORT      = int(os.environ.get("LANTH0N_OLED_PORT", 9000))
I2C_PORT      = int(os.environ.get("LANTH0N_I2C_PORT", 1))   # /dev/i2c-1 on Pi
I2C_ADDR      = int(os.environ.get("LANTH0N_I2C_ADDR", "0x3C"), 16)
MOCK_MODE     = os.environ.get("LANTH0N_OLED_MOCK", "0") == "1"
DISPLAY_W     = 128
DISPLAY_H     = 64
FONT_SIZE_LG  = 11   # large font for status line
FONT_SIZE_SM  = 9    # small font for text lines
REFRESH_HZ    = 10   # max display refresh rate (frames/second)

# =============================================================================
# DISPLAY STATE
# =============================================================================

@dataclass
class DisplayState:
    setlist_name: str = "—"
    artist: str = "—"
    song_name: str = "—"
    playback_state: str = "STOP"   # "PLAYING" or "STOP"
    bpm: str = "—"
    dirty: bool = True             # True = needs re-render

_state = DisplayState()
_state_lock = threading.Lock()

def update_state(setlist_name: str, artist: str, song_name: str,
                 playback_state: str, bpm: str) -> None:
    global _state
    with _state_lock:
        _state.setlist_name   = setlist_name[:20] or "—"
        _state.artist         = artist[:20] or "—"
        _state.song_name      = song_name[:20] or "—"
        _state.playback_state = playback_state or "STOP"
        _state.bpm            = str(bpm) or "—"
        _state.dirty = True
    log.info("State: %s | %s — %s | %s BPM", playback_state, artist, song_name, bpm)

# =============================================================================
# OSC SERVER
# =============================================================================

def start_osc_server() -> None:
    """Start the OSC UDP listener in a background thread."""
    try:
        from pythonosc.dispatcher import Dispatcher
        from pythonosc.server import BlockingOSCUDPServer
    except ImportError:
        log.error("python-osc not installed. Run: pip3 install python-osc")
        sys.exit(1)

    dispatcher = Dispatcher()

    def oled_update_handler(address, *args):
        # Expected: /oled/update setlist artist song state bpm
        try:
            setlist = str(args[0]) if len(args) > 0 else "—"
            artist  = str(args[1]) if len(args) > 1 else "—"
            song    = str(args[2]) if len(args) > 2 else "—"
            state   = str(args[3]) if len(args) > 3 else "STOP"
            bpm     = str(args[4]) if len(args) > 4 else "—"
            update_state(setlist, artist, song, state, bpm)
        except Exception as exc:
            log.warning("Bad OSC message: %s", exc)

    dispatcher.map("/oled/update", oled_update_handler)

    # Catch-all for debug
    def default_handler(address, *args):
        log.debug("Unhandled OSC: %s %s", address, args)
    dispatcher.set_default_handler(default_handler)

    server = BlockingOSCUDPServer(("0.0.0.0", OSC_PORT), dispatcher)
    log.info("OSC server listening on port %d", OSC_PORT)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

# =============================================================================
# DISPLAY DRIVER
# =============================================================================

def init_display():
    """Initialize the SSD1306 display. Returns a device object or None (mock)."""
    if MOCK_MODE:
        log.info("MOCK MODE: I2C display skipped (set LANTH0N_OLED_MOCK=0 for real hardware)")
        return None

    try:
        from luma.core.interface.serial import i2c
        from luma.oled.device import ssd1306
        serial = i2c(port=I2C_PORT, address=I2C_ADDR)
        device = ssd1306(serial, width=DISPLAY_W, height=DISPLAY_H)
        log.info("SSD1306 display initialized at I2C:%d addr=0x%02X", I2C_PORT, I2C_ADDR)
        return device
    except Exception as exc:
        log.error("Could not initialize SSD1306 display: %s", exc)
        log.warning("Running in mock mode (no display output)")
        return None


def render(device, state: DisplayState) -> None:
    """
    Render the current state to the OLED display.
    Layout:
      Row 0 (y=0):  Setlist name  (small, top blue region)
      Row 1 (y=14): Artist         (small)
      Row 2 (y=28): Song name      (small, may truncate)
      Row 3 (y=44): [STATE]  BPM:xxx  (large, bottom yellow region)
    """
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        log.error("Pillow not installed. Run: pip3 install Pillow")
        return

    img  = Image.new("1", (DISPLAY_W, DISPLAY_H), 0)   # 1-bit, black background
    draw = ImageDraw.Draw(img)

    # Default font (bitmap, no external file needed)
    try:
        font_sm = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", FONT_SIZE_SM)
        font_lg = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", FONT_SIZE_LG)
    except OSError:
        # Fallback: use PIL built-in bitmap font
        font_sm = ImageFont.load_default()
        font_lg = font_sm

    # Line 1: setlist name
    draw.text((0, 0),  state.setlist_name[:18], font=font_sm, fill=255)
    # Line 2: artist
    draw.text((0, 14), state.artist[:18],        font=font_sm, fill=255)
    # Line 3: song name
    draw.text((0, 28), state.song_name[:18],     font=font_sm, fill=255)
    # Line 4: state + BPM (larger, in the bottom yellow region)
    state_str = f"{state.playback_state}  BPM:{state.bpm}"
    draw.text((0, 44), state_str,                font=font_lg, fill=255)

    if device is not None:
        device.display(img)
    else:
        # Mock: log what would be displayed
        log.debug("MOCK render: [%s] [%s] [%s] [%s]",
                  state.setlist_name, state.artist, state.song_name, state_str)


def render_loop(device) -> None:
    """
    Main render loop: re-render whenever state is dirty.
    Runs in the main thread after OSC server is started.
    """
    import time
    frame_time = 1.0 / REFRESH_HZ

    log.info("Render loop started (%.0f fps max)", REFRESH_HZ)
    while True:
        with _state_lock:
            if _state.dirty:
                local_state = DisplayState(
                    setlist_name   = _state.setlist_name,
                    artist         = _state.artist,
                    song_name      = _state.song_name,
                    playback_state = _state.playback_state,
                    bpm            = _state.bpm,
                    dirty          = False,
                )
                _state.dirty = False
            else:
                local_state = None

        if local_state is not None:
            try:
                render(device, local_state)
            except Exception as exc:
                log.warning("Render error: %s", exc)

        time.sleep(frame_time)

# =============================================================================
# SIGNAL HANDLING
# =============================================================================

def shutdown_handler(sig, frame):
    log.info("Signal %d received — shutting down.", sig)
    sys.exit(0)

# =============================================================================
# ENTRY POINT
# =============================================================================

def main():
    log.info("LANTH0N 5YNTH — OLED daemon starting")
    log.info("OSC port: %d | I2C port: %d | addr: 0x%02X | mock: %s",
             OSC_PORT, I2C_PORT, I2C_ADDR, MOCK_MODE)

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    # Initialize display (gracefully handles missing hardware)
    device = init_display()

    # Show startup screen
    update_state("LANTH0N 5YNTH", "", "Starting...", "STOP", "—")
    try:
        from PIL import Image, ImageDraw
        render(device, _state)
    except Exception:
        pass

    # Start OSC listener in background thread
    start_osc_server()

    # Main render loop (blocks until process is killed)
    render_loop(device)


if __name__ == "__main__":
    main()
