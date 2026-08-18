"""Project path helpers for the engine.

Mirrors web/src/lib/config.js semantics: project root is resolved from
this file's location (engine/), so both dev runs and systemd installs work.
Override with LANTH0N_PROJECT_DIR for tests.
"""

import os
from pathlib import Path

_PROJECT_ROOT = Path(
    os.environ.get("LANTH0N_PROJECT_DIR") or Path(__file__).resolve().parent.parent
)

CONFIG_DIR = _PROJECT_ROOT / "config"
SETLISTS_DIR = _PROJECT_ROOT / "setlists"
MEDIA_DIR = _PROJECT_ROOT / "media"
CACHE_DIR = MEDIA_DIR / ".cache"   # decoded-AAC spool (m4a → WAV, per cue)
STATE_FILE = CONFIG_DIR / "state.json"
MIDI_MAP_FILE = CONFIG_DIR / "midi_map.json"
ROUTING_FILE = CONFIG_DIR / "audio_routing.json"
DEVICES_FILE = CONFIG_DIR / "devices.json"
LAST_SETLIST_FILE = CONFIG_DIR / "last_setlist.txt"
MIDI_LEARN_FILE = CONFIG_DIR / "midi_learn.json"


def ensure_dirs() -> None:
    for d in (CONFIG_DIR, SETLISTS_DIR, MEDIA_DIR, CACHE_DIR):
        d.mkdir(parents=True, exist_ok=True)
