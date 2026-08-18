"""Song model: one multichannel audio file + one companion MIDI file.

Audio comes as a single pre-rendered interleaved multichannel file.
Canonical channel layout (also the default routing, see
config/audio_routing.json):

    ch 1 — Playback L (VS)
    ch 2 — Playback R (VS)
    ch 3 — Click
    ch 4 — Cue
    ch 5 — Timecode (optional, if present in the render)

Both PCM WAV and compressed AAC/M4A sources are accepted: M4A is decoded
to a temporary cached WAV with ffmpeg at cue time (kept only while the
song is open), so audio stays streamed block-by-block from disk and seek
keeps working without loading the whole song into RAM.

The MIDI file is pre-parsed once into a sorted list of (frame, message)
pairs (see smf.py) — flat memory regardless of song length.
"""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
import tempfile
import threading
from dataclasses import dataclass, field
from typing import List, Optional

import numpy as np
import soundfile as sf

from .paths import CACHE_DIR
from .smf import Smf, parse_smf_file

log = logging.getLogger("engine.song")

# containers libsndfile cannot read — decoded via ffmpeg into the cache
AAC_EXTS = {".m4a", ".mp4", ".aac", ".m4b"}

WAV_CHANNELS = {
    "playback_l": 0,
    "playback_r": 1,
    "click": 2,
    "cue": 3,
    "timecode": 4,  # present only when the WAV has ≥5 channels
}


# eq=False: songs are compared/hashed by identity only — runtime state
# (open handle, decoded cache) must never participate in equality, and the
# engine keeps songs in sets (pre-cue tracking). All comparisons use `is`.
@dataclass(eq=False)
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
    _cache_wav: Optional[str] = None  # decoded-AAC spool, deleted on close
    smf: Optional[Smf] = None
    nchannels: int = 0
    frames: int = 0
    duration_sec: float = 0.0
    # serializes cue()/close(): the engine pre-cues adjacent songs in the
    # background while a user-triggered switch may cue the same song
    _lock: object = field(default_factory=threading.Lock, repr=False,
                          compare=False)

    @property
    def open(self) -> bool:
        return self._sf is not None

    def _decode_to_cache(self, src: str) -> str:
        """Decode a compressed source (m4a/aac/mp4) to a cached PCM WAV.

        The cache lives only while the song is open — close() deletes it —
        so disk usage stays small (just the currently cued song(s)).
        """
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            raise ValueError(
                f"{src}: ffmpeg not found — cannot decode compressed audio")
        os.makedirs(CACHE_DIR, exist_ok=True)
        fd, out_path = tempfile.mkstemp(suffix=".wav", dir=CACHE_DIR)
        os.close(fd)
        cmd = [ffmpeg, "-y", "-v", "error", "-i", src,
               "-c:a", "pcm_s16le", out_path]
        try:
            proc = subprocess.run(cmd, capture_output=True, timeout=900)
        except subprocess.TimeoutExpired:
            try:
                os.unlink(out_path)
            except OSError:
                pass
            raise ValueError(f"{src}: ffmpeg decode timed out")
        if proc.returncode != 0 or not os.path.exists(out_path) \
                or os.path.getsize(out_path) <= 44:
            err = (proc.stderr or b"").decode("utf-8", "replace").strip()
            try:
                os.unlink(out_path)
            except OSError:
                pass
            raise ValueError(
                f"{src}: ffmpeg could not decode"
                + (f": {err[-300:]}" if err else ""))
        log.info("decoded '%s' → cached WAV (%d kB)",
                 os.path.basename(src), os.path.getsize(out_path) // 1024)
        return out_path

    def cue(self) -> None:
        """Open the audio handle and parse the MIDI file (background-safe).

        Thread-safe: if a pre-cue task is already decoding this song,
        concurrent callers wait for that decode instead of starting a
        second one (the open-check happens again under the lock).
        """
        with self._lock:
            if self.open:
                return
            self._cue_unlocked()

    def _cue_unlocked(self) -> None:
        """Open audio + MIDI; caller must hold self._lock."""
        path = self.wav_path
        if os.path.splitext(path)[1].lower() in AAC_EXTS:
            self._cache_wav = self._decode_to_cache(path)
            path = self._cache_wav
        try:
            self._sf = sf.SoundFile(path)
        except Exception:
            self._discard_cache()
            raise
        if self._sf.samplerate != self.sample_rate:
            actual = self._sf.samplerate
            self._sf.close()
            self._sf = None
            self._discard_cache()
            raise ValueError(
                f"{self.wav_path}: sample rate {actual} != "
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

    def _discard_cache(self) -> None:
        if self._cache_wav:
            try:
                os.unlink(self._cache_wav)
            except OSError:
                pass
            self._cache_wav = None

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
        with self._lock:
            if self._sf is not None:
                self._sf.close()
            self._sf = None
            self._discard_cache()

    @property
    def has_timecode(self) -> bool:
        return self.open and self.nchannels >= 5

    def tuning_label(self) -> str:
        if self.tuning == "drop":
            return f"Drop {self.key}"
        return f"Standard {self.key}"
