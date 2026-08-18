#!/usr/bin/env python3
"""
oled_daemon.py — LANTH0N 5YNTH: SSD1306 OLED display daemon

Listens for OSC messages from the playback engine (engine/osc.py) and
renders the current playback state to a 0.96" SSD1306 I2C OLED display
(128×64 px). Runs standalone — the web UI does not need to be open.

Display layout (128×64, blue region top row, yellow region bottom rows):
  Line 1 (top, blue):   Setlist name
  Line 2:               Artist · tuning
  Line 3:               Song name
  Line 4 (bottom):      [PLAYING / STOP]  pos/duration   (e.g. "PLAYING 1:54/4:12")

OSC interface (UDP, default port 9000):
  /oled/update  <setlistName> <artist> <songName> <state> <tuning>
                <positionSec> <durationSec>
    Example: /oled/update "Night 1" "Tool" "Sober" "PLAYING" "Drop D" 114.0 252.0

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
    playback_state: str = "STOP"   # "PLAYING", "STOP" or "CUED"
    tuning: str = "—"              # e.g. "Drop D", "Standard E"
    position_sec: float = 0.0      # current playback position
    duration_sec: float = 0.0      # total song duration
    sc_online: bool = False        # True when engine heartbeat is recent
    sc_playing: bool = False       # True when engine reports playback active
    dirty: bool = True             # True = needs re-render

_state = DisplayState()
_state_lock = threading.Lock()

# Track last engine heartbeat timestamp
_last_heartbeat = 0.0
HEARTBEAT_TIMEOUT = 45.0   # seconds before the engine is considered offline

def update_state(setlist_name: str, artist: str, song_name: str,
                 playback_state: str, tuning: str,
                 position_sec: float = 0.0, duration_sec: float = 0.0) -> None:
    global _state
    with _state_lock:
        _state.setlist_name   = setlist_name[:20] or "—"
        _state.artist         = artist[:20] or "—"
        _state.song_name      = song_name[:20] or "—"
        _state.playback_state = playback_state or "STOP"
        _state.tuning         = str(tuning) or "—"
        try:
            _state.position_sec = max(0.0, float(position_sec))
        except (TypeError, ValueError):
            _state.position_sec = 0.0
        try:
            _state.duration_sec = max(0.0, float(duration_sec))
        except (TypeError, ValueError):
            _state.duration_sec = 0.0
        _state.dirty = True
    log.info("State: %s | %s — %s | Tuning: %s | %.1f/%.1f s",
             playback_state, artist, song_name, tuning,
             _state.position_sec, _state.duration_sec)

def _copy_state_locked() -> DisplayState:
    """Return a snapshot copy of the shared display state.

    Caller must hold `_state_lock`. Used by the render loop so rendering
    sees a consistent state (and so the full state — including
    position/duration — reaches the display).
    """
    global _state
    return DisplayState(
        setlist_name   = _state.setlist_name,
        artist         = _state.artist,
        song_name      = _state.song_name,
        playback_state = _state.playback_state,
        tuning         = _state.tuning,
        position_sec   = _state.position_sec,
        duration_sec   = _state.duration_sec,
        sc_online      = _state.sc_online,
        sc_playing     = _state.sc_playing,
    )


def handle_heartbeat(online: int, playing: int) -> None:
    """Receive periodic heartbeat from the playback engine to confirm it's alive."""
    global _state, _last_heartbeat
    import time
    with _state_lock:
        was_online = _state.sc_online
        _state.sc_online = (online == 1)
        _state.sc_playing = (playing == 1)
        _last_heartbeat = time.monotonic()
        if _state.sc_online != was_online:
            _state.dirty = True
            log.info("Engine heartbeat: %s", "ONLINE" if _state.sc_online else "OFFLINE")

# =============================================================================
# OSC SERVER
# =============================================================================

def start_osc_server() -> None:
    """Start the OSC UDP listener in a background thread."""
    try:
        from pythonosc.dispatcher import Dispatcher
        from pythonosc.osc_server import BlockingOSCUDPServer
    except ImportError:
        log.error("python-osc not installed. Run: pip3 install python-osc")
        sys.exit(1)

    dispatcher = Dispatcher()

    def oled_update_handler(address, *args):
        # Expected: /oled/update setlist artist song state tuning
        #                                  position_sec duration_sec
        try:
            setlist = str(args[0]) if len(args) > 0 else "—"
            artist  = str(args[1]) if len(args) > 1 else "—"
            song    = str(args[2]) if len(args) > 2 else "—"
            state   = str(args[3]) if len(args) > 3 else "STOP"
            tuning  = str(args[4]) if len(args) > 4 else "—"
            pos     = float(args[5]) if len(args) > 5 else 0.0
            dur     = float(args[6]) if len(args) > 6 else 0.0
            update_state(setlist, artist, song, state, tuning, pos, dur)
        except Exception as exc:
            log.warning("Bad OSC message: %s", exc)

    dispatcher.map("/oled/update", oled_update_handler)

    def heartbeat_handler(address, *args):
        # /oled/heartbeat <online:int> <playing:int>
        try:
            online  = int(args[0]) if len(args) > 0 else 0
            playing = int(args[1]) if len(args) > 1 else 0
            handle_heartbeat(online, playing)
        except Exception:
            pass

    dispatcher.map("/oled/heartbeat", heartbeat_handler)

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


def fmt_time(sec: float) -> str:
    """Format seconds as m:ss (or h:mm:ss when ≥ 1 h)."""
    try:
        sec = max(0, int(round(float(sec))))
    except (TypeError, ValueError):
        sec = 0
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def fit_text(draw, text: str, font, max_px: int) -> str:
    """Truncate text until it fits within max_px pixels."""
    while text and draw.textlength(text, font=font) > max_px:
        text = text[:-1]
    return text


def render(device, state: DisplayState) -> None:
    """
    Render the current state to the OLED display.
    Layout:
      Row 0 (y=0):  Setlist name  (small, top blue region)
      Row 1 (y=14): Artist · tuning (small)
      Row 2 (y=28): Song name      (small, may truncate)
      Row 3 (y=44): [STATE]  pos/duration  (large, bottom yellow region)
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

    # Line 1: setlist name + engine status indicator (top-right)
    status_dot = "●" if state.sc_online else "○"
    setlist_display = state.setlist_name[:15]
    draw.text((0, 0),  setlist_display, font=font_sm, fill=255)
    # engine status indicator in top-right corner
    draw.text((DISPLAY_W - 18, 0), f"E{status_dot}", font=font_sm,
              fill=255 if state.sc_online else 128)
    # Line 2: artist + tuning (e.g. "Tool · Drop D"), pixel-fitted
    tuning = state.tuning if state.tuning and state.tuning != "—" else ""
    line2 = state.artist[:18] if state.artist and state.artist != "—" else "—"
    if tuning:
        line2 = f"{line2} · {tuning}"
    draw.text((0, 14), fit_text(draw, line2, font_sm, DISPLAY_W - 4),
              font=font_sm, fill=255)
    # Line 3: song name
    draw.text((0, 28), state.song_name[:18],     font=font_sm, fill=255)
    # Line 4: state + position/duration (larger, in the bottom yellow region)
    state_str = (f"{state.playback_state}  "
                 f"{fmt_time(state.position_sec)}/{fmt_time(state.duration_sec)}")
    # Auto-shrink if the status line would overflow the 128px width
    font = font_lg
    if draw.textlength(state_str, font=font_lg) > DISPLAY_W - 4:
        font = font_sm
    draw.text((0, 44), state_str, font=font, fill=255)

    if device is not None:
        device.display(img)
    else:
        # Mock: log what would be displayed
        log.debug("MOCK render: [%s] [%s] [%s] [%s]",
                  state.setlist_name, line2, state.song_name, state_str)


def render_loop(device) -> None:
    """
    Main render loop: re-render whenever state is dirty.
    Also monitors heartbeat timeout to detect the engine going offline.
    Runs in the main thread after OSC server is started.
    """
    import time
    global _state, _last_heartbeat
    frame_time = 1.0 / REFRESH_HZ

    log.info("Render loop started (%.0f fps max)", REFRESH_HZ)
    while True:
        # Check heartbeat timeout
        now = time.monotonic()
        with _state_lock:
            if _state.sc_online and (now - _last_heartbeat) > HEARTBEAT_TIMEOUT:
                _state.sc_online = False
                _state.dirty = True
                log.warning("Engine heartbeat lost — marking offline")

            if _state.dirty:
                # Copy EVERYTHING (position/duration included) — a partial
                # copy here made the status line always render "0:00".
                local_state = _copy_state_locked()
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
