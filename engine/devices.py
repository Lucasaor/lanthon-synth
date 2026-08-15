"""Device enumeration + routing resolution (Task 4 backend, Step 3).

Enumeration is live: every refresh re-queries PortAudio (sounddevice) and
python-rtmidi, so hot-plugged interfaces show up without a restart. The
routing config stores device *names* (chosen from the enumeration), never
hardcoded indexes — names survive re-plugging, indexes don't.

For tests and dev machines without audio hardware, LANTH0N_DEVICES_JSON
injects a mock device snapshot (same format as the runtime snapshot).

Routing config (config/audio_routing.json):

    {
      "clock_device": "auto",
      "tracks": {
        "playback_l": {"device": "auto", "channel": 1},
        "playback_r": {"device": "auto", "channel": 2},
        "click":      {"device": "auto", "channel": 3},
        "cue":        {"device": "auto", "channel": 4},
        "timecode":   {"device": "auto", "channel": 5, "enabled": false},
        "midi_automation": {"device": "auto"}
      }
    }

Channels are 1-based on the destination device. "auto" = system default
audio output / first available MIDI output.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from .audio import ChannelRoute, DevicePlan
from .paths import DEVICES_FILE, ROUTING_FILE
from .song import WAV_CHANNELS

log = logging.getLogger("engine.devices")

AUTO = "auto"

# audio tracks in canonical WAV channel order
AUDIO_TRACKS = ("playback_l", "playback_r", "click", "cue", "timecode")


@dataclass
class AudioDevice:
    key: str                 # "audio:<index>" — stable within a snapshot
    name: str
    index: int
    max_out_channels: int = 8


@dataclass
class MidiDevice:
    key: str                 # "midi_out:<index>" / "midi_in:<index>"
    name: str
    index: int


@dataclass
class Snapshot:
    audio: List[AudioDevice] = field(default_factory=list)
    midi_out: List[MidiDevice] = field(default_factory=list)
    midi_in: List[MidiDevice] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Live enumeration
# ---------------------------------------------------------------------------


def enumerate_audio() -> List[AudioDevice]:
    try:
        import sounddevice as sd

        out = []
        for idx, info in enumerate(sd.query_devices()):
            if int(info.get("max_output_channels", 0)) > 0:
                out.append(AudioDevice(
                    key=f"audio:{idx}",
                    name=str(info.get("name", f"device {idx}")),
                    index=idx,
                    max_out_channels=int(info["max_output_channels"]),
                ))
        return out
    except Exception as exc:
        log.debug("audio enumeration unavailable: %s", exc)
        return []


_probe_out = None
_probe_in = None


def enumerate_midi() -> tuple:
    """List MIDI out/in ports.

    Probe rtmidi objects are created ONCE and cached — creating a fresh
    rtmidi object per call leaks an ALSA sequencer client on Linux and
    eventually exhausts the kernel seq client table.
    """
    global _probe_out, _probe_in
    try:
        import rtmidi
    except Exception as exc:
        log.debug("MIDI enumeration unavailable: %s", exc)
        return [], []
    try:
        if _probe_out is None:
            _probe_out = rtmidi.MidiOut()
        if _probe_in is None:
            _probe_in = rtmidi.MidiIn()
        outs = [MidiDevice(key=f"midi_out:{i}", name=n, index=i)
                for i, n in enumerate(_probe_out.get_ports())]
        ins = [MidiDevice(key=f"midi_in:{i}", name=n, index=i)
               for i, n in enumerate(_probe_in.get_ports())]
        return outs, ins
    except Exception as exc:
        # broken ALSA seq state (e.g. after a USB disconnect) — recreate
        # the probes next time instead of reusing stale handles
        log.debug("MIDI enumeration failed: %s", exc)
        _probe_out = None
        _probe_in = None
        return [], []


def snapshot() -> Snapshot:
    """Full live snapshot, or the mock from LANTH0N_DEVICES_JSON."""
    override = os.environ.get("LANTH0N_DEVICES_JSON")
    if override:
        try:
            data = json.loads(override)
            return Snapshot(
                audio=[AudioDevice(**d) for d in data.get("audio", [])],
                midi_out=[MidiDevice(**d) for d in data.get("midi_out", [])],
                midi_in=[MidiDevice(**d) for d in data.get("midi_in", [])],
            )
        except Exception:
            log.exception("bad LANTH0N_DEVICES_JSON — falling back to live")
    outs, ins = enumerate_midi()
    return Snapshot(audio=enumerate_audio(), midi_out=outs, midi_in=ins)


def snapshot_to_json(snap: Snapshot) -> dict:
    return {
        "audio": [vars(d) for d in snap.audio],
        "midi_out": [vars(d) for d in snap.midi_out],
        "midi_in": [vars(d) for d in snap.midi_in],
        "default_audio": snap.audio[0].key if snap.audio else None,
        "default_midi_out": snap.midi_out[0].key if snap.midi_out else None,
    }


def write_devices_snapshot() -> Optional[Snapshot]:
    """Persist the live snapshot to config/devices.json for the web UI."""
    snap = snapshot()
    try:
        tmp = f"{DEVICES_FILE}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(snapshot_to_json(snap), f, indent=2)
        os.replace(tmp, DEVICES_FILE)
    except Exception:
        log.exception("failed to write devices.json")
    return snap


# ---------------------------------------------------------------------------
# Routing resolution
# ---------------------------------------------------------------------------


def load_routing() -> dict:
    try:
        with open(ROUTING_FILE, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except Exception:
        log.exception("failed to read audio_routing.json")
        return {}


def _resolve_audio(track_cfg: dict, snap: Snapshot) -> Optional[AudioDevice]:
    if not snap.audio:
        return None
    want = str(track_cfg.get("device") or AUTO)
    if want != AUTO:
        for dev in snap.audio:
            if want.lower() in dev.name.lower():
                return dev
    return snap.audio[0]


def _resolve_midi_out(track_cfg: dict, snap: Snapshot) -> Optional[str]:
    want = str(track_cfg.get("device") or AUTO)
    if want != AUTO and snap.midi_out:
        for dev in snap.midi_out:
            if want.lower() in dev.name.lower():
                return dev.name
    if snap.midi_out:
        return snap.midi_out[0].name
    return None


def resolve_routing(cfg: dict, song, snap: Snapshot, block_default_identity: bool = True):
    """Return (plans: list[DevicePlan], midi_out_name).

    Groups tracks by destination audio device; each group becomes one
    DevicePlan. The clock device (master stream) is the plan carrying
    Playback L/R unless overridden by cfg['clock_device'].
    """
    tracks = cfg.get("tracks") or {}
    plans_by_key: Dict[str, DevicePlan] = {}

    for track in AUDIO_TRACKS:
        wav_ch = WAV_CHANNELS.get(track)
        if wav_ch is None:
            continue
        if track == "timecode":
            if not song.has_timecode:
                continue
            if tracks.get("timecode", {}).get("enabled", False) is not True:
                continue
        if wav_ch >= song.nchannels:
            continue
        tcfg = tracks.get(track) or {}
        dev = _resolve_audio(tcfg, snap)
        if dev is None:
            plan = plans_by_key.setdefault(
                "default",
                DevicePlan(key="default", name="default output", device=None,
                           n_out=max(8, song.nchannels)),
            )
        else:
            plan = plans_by_key.setdefault(
                dev.key,
                DevicePlan(key=dev.key, name=dev.name, device=dev.index,
                           n_out=dev.max_out_channels),
            )
        plan.routes.append(ChannelRoute(
            wav_ch=wav_ch,
            out_ch=max(0, int(tcfg.get("channel", wav_ch + 1)) - 1),  # 1-based → 0-based
        ))

    # identity fallback when config is absent entirely
    if not plans_by_key and block_default_identity and song.nchannels:
        plans_by_key["default"] = DevicePlan(
            key="default", name="default output", device=None,
            n_out=max(8, song.nchannels),
            routes=[ChannelRoute(i, i) for i in range(song.nchannels)],
        )

    plans = list(plans_by_key.values())

    # master = clock device: the plan carrying playback_l (or first)
    clock_want = str(cfg.get("clock_device") or AUTO)
    master = None
    if clock_want != AUTO:
        for p in plans:
            if clock_want.lower() in p.name.lower():
                master = p
                break
    if master is None:
        for p in plans:
            if any(r.wav_ch == WAV_CHANNELS["playback_l"] for r in p.routes):
                master = p
                break
    if master is None and plans:
        master = plans[0]
    if master is not None:
        master.is_master = True

    midi_out = _resolve_midi_out(tracks.get("midi_automation") or {}, snap)
    return plans, midi_out
