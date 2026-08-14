"""Song model: one multichannel WAV + one companion MIDI file.

The WAV is a single pre-rendered interleaved multichannel file. Canonical
channel layout (also the default routing, see config/audio_routing.json):

    ch 1 — Playback L
    ch 2 — Playback R
    ch 3 — Click
    ch 4 — Cue
    ch 5 — Timecode (optional, if present in the render)

Audio is streamed from disk (never loaded into RAM) via soundfile's
sequential block reads. The MIDI file is pre-parsed once into a sorted
list of (frame, message) pairs (see smf.py) — flat memory regardless of
song length.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import List, Optional

import numpy as np
import soundfile as sf

from .smf import Smf, parse_smf_file

log = logging.getLogger("engine.song")

WAV_CHANNELS = {
    "playback_l": 0,
    "playback_r": 1,
    "click": 2,
    "cue": 3,
    "timecode": 4,  # present only when the WAV has ≥5 channels
}


@dataclass
class Song:
    name: str
    artist: str
    tuning: str          # "standard" | "drop"
    key: str             # "C".."B"
    wav_path: str
    mid_path: Optional[str]

    sample_rate: int = 48000

    # runtime state (opened on cue)
    _sf: Optional[sf.SoundFile] = None
    smf: Optional[Smf] = None
    nchannels: int = 0
    frames: int = 0
    duration_sec: float = 0.0

    @property
    def open(self) -> bool:
        return self._sf is not None

    def cue(self) -> None:
        """Open the WAV handle and parse the MIDI file (background-safe)."""
        if self.open:
            return
        self._sf = sf.SoundFile(self.wav_path)
        if self._sf.samplerate != self.sample_rate:
            raise ValueError(
                f"{self.wav_path}: sample rate {self._sf.samplerate} != "
                f"engine rate {self.sample_rate}"
            )
        self.nchannels = self._sf.channels
        self.frames = len(self._sf)
        self.duration_sec = self.frames / self.sample_rate
        if self.mid_path:
            self.smf = parse_smf_file(self.mid_path, self.sample_rate)
            self.duration_sec = max(
                self.duration_sec,
                self.smf.duration_sec,
            )
        log.info("Cued song '%s': %d ch, %.1f s, %d MIDI events",
                 self.name, self.nchannels, self.duration_sec,
                 len(self.smf.events) if self.smf else 0)

    def read_block(self, pos: int, n: int) -> np.ndarray:
        """Read n frames starting at pos. Zero-pads past EOF.

        Returns float32 array of shape (n, nchannels).
        """
        assert self.open, "song not cued"
        if pos >= self.frames or self._sf is None:
            return np.zeros((n, self.nchannels), dtype=np.float32)
        self._sf.seek(pos)
        data = self._sf.read(n, dtype="float32", always_2d=True)
        if data.shape[0] < n:
            pad = np.zeros((n - data.shape[0], self.nchannels), dtype=np.float32)
            data = np.vstack([data, pad])
        return data

    def close(self) -> None:
        if self._sf is not None:
            self._sf.close()
        self._sf = None

    @property
    def has_timecode(self) -> bool:
        return self.open and self.nchannels >= 5

    def tuning_label(self) -> str:
        if self.tuning == "drop":
            return f"Drop {self.key}"
        return f"Standard {self.key}"
