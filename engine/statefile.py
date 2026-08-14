"""Playback state persistence.

Writes config/state.json — the single source of truth the web UI and
health checks read. Mirrors the legacy SuperCollider schema (so the web
UI keeps working) and extends it:

    {
      "activeSetlist": "Night 1",
      "songName": "Sober", "artist": "Tool",
      "tuning": "Drop D", "key": "D",
      "playing": false, "state": "cued",
      "positionSec": 0.0, "durationSec": 360.0,
      "songIndex": 2, "songCount": 12,
      "engineOnline": true,
      "engineHeartbeat": <epoch seconds>
    }

Also persists config/last_setlist.txt for auto-load on boot.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any, Dict, Optional

from .paths import LAST_SETLIST_FILE, STATE_FILE

log = logging.getLogger("engine.statefile")


def _atomic_write(path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, path)


def write_state(state: Dict[str, Any]) -> None:
    try:
        state = dict(state)
        state["engineHeartbeat"] = time.time()
        _atomic_write(STATE_FILE, json.dumps(state))
    except Exception:
        log.exception("failed to write state.json")


def write_last_setlist(name: str) -> None:
    try:
        _atomic_write(LAST_SETLIST_FILE, name)
    except Exception:
        log.exception("failed to write last_setlist.txt")


def read_last_setlist() -> Optional[str]:
    try:
        with open(LAST_SETLIST_FILE, encoding="utf-8") as f:
            name = f.read().strip()
        return name or None
    except FileNotFoundError:
        return None
