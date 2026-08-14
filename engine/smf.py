"""Standard MIDI File parser (and minimal writer for test fixtures).

Parses format 0/1/2 SMFs into a sorted list of ``(frame, message_bytes)``
pairs, converting tick timestamps to audio frames using the file's own
tempo map — the exact same timebase Reaper exports for the companion audio.
Frame = round(seconds * sample_rate).

MIDI events passed through: channel voice messages and SysEx.
Meta events (tempo, time signature, EOT) are consumed internally and not
dispatched. Running status is supported.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional, Tuple

DEFAULT_TEMPO_US = 500_000  # 120 BPM, matches Reaper's default


class SmfError(Exception):
    pass


@dataclass
class Event:
    frame: int          # audio frame (sample) position of the event
    data: bytes         # complete MIDI message (status + data)


@dataclass
class Smf:
    events: List[Event] = field(default_factory=list)   # sorted by frame
    end_frame: int = 0                                  # last event frame
    duration_sec: float = 0.0
    ppq: int = 480
    tempos: List[Tuple[int, int]] = field(default_factory=list)  # (frame, us/beat)


def _read_u16(b: bytes, off: int) -> int:
    return int.from_bytes(b[off:off + 2], "big")


def _read_u32(b: bytes, off: int) -> int:
    return int.from_bytes(b[off:off + 4], "big")


def _read_varint(b: bytes, off: int) -> Tuple[int, int]:
    value = 0
    while True:
        if off >= len(b):
            raise SmfError("truncated varint")
        byte = b[off]
        off += 1
        value = (value << 7) | (byte & 0x7F)
        if not byte & 0x80:
            return value, off


# channel messages that carry a single data byte
_SINGLE_DATA_STATUS = {0xC0, 0xD0}


def _parse_track(b: bytes, off: int) -> Tuple[List[Tuple[int, bytes]], int, int]:
    """Return ([(abs_tick, raw_message)], next_offset, last_tick)."""
    if b[off:off + 4] != b"MTrk":
        raise SmfError("missing MTrk chunk")
    length = _read_u32(b, off + 4)
    end = off + 8 + length
    off += 8
    tick = 0
    last_tick = 0
    running = None
    events: List[Tuple[int, bytes]] = []
    while off < end:
        delta, off = _read_varint(b, off)
        tick += delta
        status = b[off]
        off += 1
        if status == 0xFF:  # meta
            mtype = b[off]
            off += 1
            mlen, off = _read_varint(b, off)
            mdata = b[off:off + mlen]
            off += mlen
            if mtype == 0x51 and mlen == 3:  # tempo, µs per quarter note
                events.append((tick, b"\xFF\x51\x03" + mdata))
            elif mtype == 0x2F:  # end of track
                last_tick = max(last_tick, tick)
            continue
        if status in (0xF0, 0xF7):  # sysEx (raw)
            mlen, off = _read_varint(b, off)
            data = b[off:off + mlen]
            off += mlen
            events.append((tick, bytes([status]) + data))
            last_tick = max(last_tick, tick)
            running = None
            continue
        if status & 0x80 == 0:
            # running status — status omitted
            if running is None:
                raise SmfError("running status without previous status")
            status, running = running, running
            off -= 1  # data byte re-read below
        else:
            running = status
        n_data = 1 if (status & 0xF0) in _SINGLE_DATA_STATUS else 2
        if off + n_data > end:
            raise SmfError("truncated channel message")
        data = b[off:off + n_data]
        off += n_data
        events.append((tick, bytes([status]) + data))
        last_tick = max(last_tick, tick)
    return events, off, last_tick


def parse_smf_bytes(data: bytes, sample_rate: int) -> Smf:
    if data[:4] != b"MThd":
        raise SmfError("not a Standard MIDI File (missing MThd)")
    fmt = _read_u16(data, 8)
    ntracks = _read_u16(data, 10)
    division = _read_u16(data, 12)

    if division & 0x8000:
        # SMPTE time division: high byte = negative fps (two's complement),
        # e.g. 24 fps → 0xE8, 25 → 0xE7, 29.97 → 0xE3, 30 → 0xE2.
        high = (division >> 8) & 0xFF
        signed = high if high < 128 else high - 256
        fps = -signed if signed < 0 else signed
        if fps == 0:
            fps = 24
        ticks_per_frame = division & 0xFF or 1
        seconds_per_tick = (1.0 / fps) / ticks_per_frame
        ppq = None
    else:
        ppq = division or 480
        seconds_per_tick = None  # derived from tempo map

    # merge all tracks (formats 0/1/2 all merge the same way: by time)
    merged: List[Tuple[int, bytes]] = []
    off = 14
    last_tick = 0
    for _ in range(ntracks):
        events, off, track_last = _parse_track(data, off)
        merged.extend(events)
        last_tick = max(last_tick, track_last)
    if not merged:
        return Smf(end_frame=0, duration_sec=0.0, ppq=ppq or 0)

    merged.sort(key=lambda e: e[0])

    # convert ticks → frames using the tempo map
    out_events: List[Event] = []
    tempos: List[Tuple[int, int]] = []
    tempo_us = DEFAULT_TEMPO_US
    prev_tick = 0
    seconds = 0.0
    for tick, msg in merged:
        if seconds_per_tick is not None:
            seconds += (tick - prev_tick) * seconds_per_tick
        else:
            seconds += (tick - prev_tick) * (tempo_us / 1e6) / ppq
        prev_tick = tick
        if msg.startswith(b"\xFF\x51\x03"):
            tempo_us = int.from_bytes(msg[3:6], "big")
            tempos.append((round(seconds * sample_rate), tempo_us))
        else:
            frame = round(seconds * sample_rate)
            out_events.append(Event(frame=frame, data=msg))

    if seconds_per_tick is not None:
        end_sec = last_tick * seconds_per_tick
    else:
        end_sec = last_tick * (tempo_us / 1e6) / ppq

    return Smf(
        events=out_events,
        end_frame=max(round(end_sec * sample_rate), out_events[-1].frame if out_events else 0),
        duration_sec=end_sec,
        ppq=ppq or 0,
        tempos=tempos,
    )


def parse_smf_file(path: str, sample_rate: int) -> Smf:
    with open(path, "rb") as f:
        return parse_smf_bytes(f.read(), sample_rate)


# ---------------------------------------------------------------------------
# Minimal SMF writer (test fixtures only)
# ---------------------------------------------------------------------------

def _varint(value: int) -> bytes:
    out = bytearray([value & 0x7F])
    value >>= 7
    while value:
        out.append(0x80 | (value & 0x7F))
        value >>= 7
    return bytes(reversed(out))


def write_smf(
    path: str,
    track_events: List[Tuple[int, bytes]],      # (tick, message) pairs, sorted
    ppq: int = 480,
    tempo_us: Optional[int] = DEFAULT_TEMPO_US,
) -> None:
    """Write a format-0 SMF with an optional tempo event at tick 0."""
    track = bytearray()
    if tempo_us is not None:
        track += _varint(0) + b"\xFF\x51\x03" + tempo_us.to_bytes(3, "big")
    prev = 0
    for tick, msg in sorted(track_events):
        track += _varint(tick - prev) + msg
        prev = tick
    track += _varint(0) + b"\xFF\x2F\x00"

    header = b"MThd" + (6).to_bytes(4, "big") + (0).to_bytes(2, "big")
    header += (1).to_bytes(2, "big") + ppq.to_bytes(2, "big")
    chunk = b"MTrk" + len(track).to_bytes(4, "big") + bytes(track)

    with open(path, "wb") as f:
        f.write(header + chunk)
