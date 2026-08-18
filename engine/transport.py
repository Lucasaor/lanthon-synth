"""Transport — the single source of truth for playback state.

Exactly one Transport instance exists in the engine. Audio rendering and
MIDI dispatch both derive their frame position from it, so audio channels
and automation can never drift apart.

States:
    stopped — no song cued (or playback halted), position rewound to 0
    cued    — song loaded and ready, position 0
    playing — rendering

stop() is a FULL STOP, not a pause: it halts playback. Without a seek
position the next play() starts from the top; with one (seek_to), play()
resumes from the seek time. A second stop() while already stopped clears
the seek and rewinds to the start.

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
        # pending seek position (frames): survives stop() → play() cycles
        # until a second stop() with the transport already stopped clears it
        self._seek_frame: Optional[int] = None
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
            self._seek_frame = None  # a new song always starts from the top
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
                # seek landed at/after the end — restart from the top and
                # drop the pending seek so stop() won't restore it later
                self.position_frame = 0
                self._seek_frame = None
            self.state = PLAYING
        self._notify()

    def seek_to(self, seconds: float) -> int:
        """Jump to an absolute position (seconds) in the current song.

        Clamps to [0, song duration], stores it as the pending seek and
        returns the resulting frame. The seek survives stop() → play()
        cycles; see stop().
        """
        with self._lock:
            song = self.song
            max_frame = song.frames if song is not None else 0
            frame = int(round(float(seconds) * self.sample_rate))
            frame = max(0, min(frame, max_frame))
            self._seek_frame = frame
            self.position_frame = frame
        self._notify()
        return frame

    def clear_seek(self) -> None:
        with self._lock:
            self._seek_frame = None

    def seek_sec(self) -> Optional[float]:
        if self._seek_frame is None:
            return None
        return self._seek_frame / self.sample_rate

    def stop(self) -> None:
        """Stop playback.

        With a seek position set, the next play() resumes from it;
        without one, playback rewinds to the top. Pressing stop a second
        time while already stopped clears the seek, so the following
        play() starts from the beginning again."""
        with self._lock:
            if self.state == STOPPED:
                # second stop clears any pending seek
                self._seek_frame = None
                self.position_frame = 0
            else:
                self.state = STOPPED
                self.position_frame = (
                    self._seek_frame if self._seek_frame is not None else 0)
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
