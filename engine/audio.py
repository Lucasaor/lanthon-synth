"""Audio backends: realtime (sounddevice/PortAudio) and offline (tests).

Both backends drive the same Engine.tick() entry point, so the transport
clock, channel routing, and MIDI dispatch logic are identical in test and
production. In realtime, one PortAudio stream per output device is opened;
the master stream (the one carrying Playback L/R) advances the transport,
all other streams render from the same frame position.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Dict, List, Optional

log = logging.getLogger("engine.audio")


@dataclass
class ChannelRoute:
    wav_ch: int           # 0-based source channel in the multichannel WAV
    out_ch: int           # 0-based destination channel on the device
    gain: float = 1.0


@dataclass
class DevicePlan:
    key: str              # stable key for this output device
    name: str             # human-readable device name
    device: Optional[int] = None     # sounddevice device index (None=auto)
    n_out: int = 8                  # output channel count of the device
    routes: List[ChannelRoute] = field(default_factory=list)
    is_master: bool = False


def default_output_device() -> Optional[int]:
    """Resolve the default output device index (or LANTH0N_DEVICE override)."""
    try:
        import sounddevice as sd

        override = os.environ.get("LANTH0N_DEVICE")
        if override:
            if override.isdigit():
                return int(override)
            for idx, name in enumerate(sd.query_devices()):
                if override.lower() in str(name).lower():
                    return idx
        return sd.default.device[1]
    except Exception:
        return None


def device_output_channels(device_index: Optional[int]) -> int:
    try:
        import sounddevice as sd

        info = sd.query_devices(device_index)
        return int(info["max_output_channels"])
    except Exception:
        return 8


class AudioBackend(ABC):
    @abstractmethod
    def start(self, plans: List[DevicePlan], sample_rate: int, block_size: int) -> None: ...

    @abstractmethod
    def stop(self) -> None: ...


# ---------------------------------------------------------------------------
# Realtime backend
# ---------------------------------------------------------------------------


class PortAudioBackend(AudioBackend):
    """One sounddevice.OutputStream per DevicePlan.

    The master plan's callback runs engine.tick(); slaves copy the latest
    rendered buffer for their plan. Callbacks must never block, so all
    work in tick() is buffered reads and atomic state flips.
    """

    def __init__(self, engine):
        self.engine = engine
        self._streams = []
        self._buffers: Dict[str, object] = {}   # key → ndarray
        self._buffers_lock = threading.Lock()

    def start(self, plans, sample_rate, block_size) -> None:
        import sounddevice as sd

        for plan in plans:
            plan.device = default_output_device()
            plan.n_out = max(device_output_channels(plan.device), 2)
            channels = max(1, max((r.out_ch + 1 for r in plan.routes), default=2))
            channels = min(channels, plan.n_out)
            if channels > plan.n_out:
                log.warning("%s: plan needs %d channels but device has %d",
                            plan.key, channels, plan.n_out)

            self._buffers[plan.key] = None

            def make_cb(plan):
                def cb(outdata, frames, time_info, status):
                    if plan.is_master:
                        self.engine.tick(frames, time_info, status)
                    try:
                        with self._buffers_lock:
                            buf = self._buffers.get(plan.key)
                            if buf is None or buf.shape != outdata.shape:
                                outdata.fill(0)
                                return
                            outdata[:] = buf
                    except Exception:
                        outdata.fill(0)
                return cb

            stream = sd.OutputStream(
                device=plan.device,
                channels=channels,
                samplerate=sample_rate,
                blocksize=block_size,
                dtype="float32",
                callback=make_cb(plan),
            )
            stream.start()
            self._streams.append((plan, stream))
            log.info("Audio stream opened on '%s' (%d ch, device=%s)",
                     plan.name, channels, plan.device)

    def put_buffer(self, key: str, buf) -> None:
        with self._buffers_lock:
            self._buffers[key] = buf

    def stop(self) -> None:
        for _plan, stream in self._streams:
            try:
                stream.stop()
                stream.close()
            except Exception:
                pass
        self._streams = []


# ---------------------------------------------------------------------------
# Offline backend (tests + verification)
# ---------------------------------------------------------------------------


class OfflineBackend(AudioBackend):
    """Deterministic block renderer — no audio hardware, no wall clock.

    Block rendering is driven explicitly by Engine.run_offline_until_stop(),
    which calls engine.tick() with a virtual DAC time, so the identical code
    path (including MIDI scheduling) is exercised. Set LANTH0N_OFFLINE=1.
    """

    def __init__(self, engine):
        self.engine = engine
        self.record = False
        # rendered blocks per plan key (list of ndarrays, in order)
        self.buffers: Dict[str, list] = {}

    def start(self, plans, sample_rate, block_size) -> None:
        pass  # driven by Engine.run_offline_until_stop()

    def put_buffer(self, key: str, buf) -> None:
        if self.record:
            self.buffers.setdefault(key, []).append(buf.copy())

    def stop(self) -> None:
        pass


def make_backend(engine, offline: bool):
    return OfflineBackend(engine) if offline else PortAudioBackend(engine)
