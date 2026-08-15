"""Transport — the single source of truth for playback state.

Exactly one Transport instance exists in the engine. Audio rendering and
MIDI dispatch both derive their frame position from it, so audio channels
and automation can never drift apart.

States:
    stopped — no song cued (or playback halted), position rewound to 0
    cued    — song loaded and ready, position 0
    playing — rendering

stop() is a FULL STOP, not a pause: it halts playback and rewinds to the
start of the song, so the next play() starts from the top.

The audio backend advances position_frame block by block; everything else
(web UI state, OLED, MIDI) reads it back.
"""

from __future__ import annotations

import logging
import threading
from typing import Callable, List, Optional

from .song import Song

log = logging.getLogger("engine.transport")

STOPPED = "stopped"
CUED = "cued"
PLAYING = "playing"


class Transport:
    def __init__(self, sample_rate: int = 48000):
        self.sample_rate = sample_rate
        self.state = STOPPED
        self.song: Optional[Song] = None
        self.position_frame = 0
        self._pending_play = False
        self._lock = threading.Lock()
        # listeners: (fn, kwargs) invoked on every state change
        self._listeners: List[Callable] = []

    def add_listener(self, fn: Callable) -> None:
        self._listeners.append(fn)

    def _notify(self) -> None:
        for fn in self._listeners:
            try:
                fn()
            except Exception:
                log.exception("transport listener failed")

    def set_song(self, song: Optional[Song]) -> None:
        with self._lock:
            # NOTE: do not call self.stop() here — it re-acquires _lock
            # (plain Lock, not RLock) and would deadlock.
            old = self.song
            self.song = song
            self.position_frame = 0
            if song is None:
                self.state = STOPPED
                self._pending_play = False
            elif self._pending_play:
                # play() was pressed while the song was still being cued
                self._pending_play = False
                self.state = PLAYING
            else:
                self.state = CUED
        if old is not None and old is not self.song:
            # Deferred close: an audio callback may still be inside a C-level
            # read on the old handle; closing 500 ms later avoids the race.
            def _close_later(s=old):
                try:
                    s.close()
                except Exception:
                    pass
            threading.Timer(0.5, _close_later).start()
        self._notify()

    def play(self) -> None:
        with self._lock:
            if self.song is None:
                # cue in progress — latch the intent
                self._pending_play = True
                return
            if self.position_frame >= self.song.frames:
                self.position_frame = 0
            self.state = PLAYING
        self._notify()

    def stop(self) -> None:
        """Full stop (not pause): halt playback and rewind to frame 0 so
        the next play() starts from the top of the song."""
        with self._lock:
            if self.state == PLAYING:
                self.state = STOPPED
            self.position_frame = 0
        self._notify()

    @property
    def playing(self) -> bool:
        return self.state == PLAYING

    @property
    def pending_play(self) -> bool:
        return self._pending_play

    def position_sec(self) -> float:
        return self.position_frame / self.sample_rate

    def duration_sec(self) -> float:
        return self.song.duration_sec if self.song else 0.0
