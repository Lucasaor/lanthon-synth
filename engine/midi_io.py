"""MIDI input/output: transport control input, MIDI-learn capture,
and sample-accurate automation dispatch.

Realtime dispatch model
-----------------------
The audio callback computes, for every MIDI event whose frame falls inside
the block being rendered, its exact due *stream time*:

    due_stream = dac_time(block) + (event_frame - block_start_frame) / sr

The Dispatcher thread converts stream time to monotonic time using anchors
updated by every callback, sleeps until the deadline (busy-spin for the
final ~1 ms), and sends the message. Scheduling error is measured and
logged so sync quality is observable.

Offline mode (`LANTH0N_OFFLINE=1`) skips wall-clock scheduling entirely:
events are recorded with their exact frames during block processing, which
lets tests assert 0-frame sync error.
"""

from __future__ import annotations

import heapq
import json
import logging
import os
import threading
import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

from .paths import MIDI_LEARN_FILE, MIDI_MAP_FILE

log = logging.getLogger("engine.midi")

# ---------------------------------------------------------------------------
# MIDI output abstraction
# ---------------------------------------------------------------------------


class MidiOut:
    """Interface implemented by RtMidiOut and the offline recorder."""

    def send(self, data: bytes) -> None:
        raise NotImplementedError

    def close(self) -> None:
        pass


class NullMidiOut(MidiOut):
    """Offline / no-port fallback."""

    def send(self, data: bytes) -> None:
        pass


class RtMidiOut(MidiOut):
    """python-rtmidi output port (ALSA sequencer on the Pi)."""

    def __init__(self, port: Optional[str] = None):
        import rtmidi

        self._rt = rtmidi.MidiOut()
        ports = self._rt.get_ports()
        target = None
        if port is not None:
            if port.isdigit():
                target = int(port)
            else:
                target = next(
                    (i for i, p in enumerate(ports) if port.lower() in p.lower()),
                    None,
                )
        if target is None and ports:
            target = 0
        if target is not None:
            self._rt.open_port(target)
            self.name = ports[target]
        else:
            self.name = "(none)"

    def send(self, data: bytes) -> None:
        if self._rt.is_port_open():
            self._rt.send_message(bytes(data))

    def close(self) -> None:
        if self._rt.is_port_open():
            self._rt.close_port()


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------


class MidiDispatcher(threading.Thread):
    """Sends pre-parsed (frame, message) events against the audio clock."""

    STATS_EVERY = 200  # events between scheduler-stat log lines

    def __init__(self, midi_out: MidiOut, sample_rate: int, offline: bool = False):
        super().__init__(daemon=True, name="midi-dispatcher")
        self.out = midi_out
        self.sr = sample_rate
        self.offline = offline
        self._cond = threading.Condition()
        self._queue: List[Tuple[float, bytes]] = []  # (due_stream_sec, msg)
        self._anchor: Tuple[float, float] = (0.0, 0.0)  # (mono_sec, stream_sec)
        self._alive = True
        self._sent = 0
        self._err_sum = 0.0
        self._err_max = 0.0
        self._err_n = 0
        self.recorded: List[Tuple[int, bytes]] = []  # offline: (frame, msg)

    # -- called from audio callback threads --------------------------------

    def update_anchor(self, mono_sec: float, stream_sec: float) -> None:
        with self._cond:
            self._anchor = (mono_sec, stream_sec)
            self._cond.notify_all()

    def schedule(self, due_stream: float, msg: bytes) -> None:
        with self._cond:
            heapq.heappush(self._queue, (due_stream, msg))
            self._cond.notify_all()

    def record(self, frame: int, msg: bytes) -> None:
        """Offline: record exact-frame dispatch."""
        self.recorded.append((frame, msg))
        self._sent += 1

    # -- dispatcher thread -------------------------------------------------

    def _now_stream(self) -> float:
        mono, stream = self._anchor
        return stream + (time.monotonic() - mono)

    def run(self) -> None:
        if self.offline:
            return  # nothing to do; record() is called inline
        spin_until = time.monotonic
        while self._alive:
            with self._cond:
                while self._alive and not self._queue:
                    self._cond.wait()
                if not self._alive:
                    break
                due, _ = self._queue[0]
                now = self._now_stream()
                delay = due - now
                if delay > 0:
                    # release the lock and sleep until ~2 ms before due
                    self._cond.wait(timeout=max(0.0, delay - 0.002))
                    continue
                due, msg = heapq.heappop(self._queue)

            # final precision wait: busy-spin until the deadline passes
            while True:
                now = self._now_stream()
                if now >= due:
                    break
                remaining = due - now
                if remaining > 0.002:
                    time.sleep(remaining - 0.001)
                # else: tight spin

            self.out.send(msg)
            err = abs(self._now_stream() - due)
            self._err_sum += err
            self._err_n += 1
            self._err_max = max(self._err_max, err)
            self._sent += 1
            if self._err_n >= self.STATS_EVERY:
                mean_ms = 1000 * self._err_sum / self._err_n
                max_ms = 1000 * self._err_max
                log.info("MIDI dispatch: %d sent, mean offset %.3f ms, "
                         "max %.3f ms", self._sent, mean_ms, max_ms)
                self._err_sum = 0.0
                self._err_n = 0

    def stop(self) -> None:
        with self._cond:
            self._alive = False
            self._cond.notify_all()


# ---------------------------------------------------------------------------
# Transport mapping (MIDI in → actions)
# ---------------------------------------------------------------------------

ACTIONS = ("btPlay", "btStop", "btNext", "btPrev")

# status → (event type, data bytes used for "value", min/max range)
_NOTE_ON = 0x90
_NOTE_OFF = 0x80
_CC = 0xB0
_PC = 0xC0


def decode_message(msg: bytes) -> Optional[Dict]:
    """Decode a MIDI message into a mappable event dict (or None)."""
    if len(msg) < 2:
        return None
    status = msg[0] & 0xF0
    chan = msg[0] & 0x0F
    if status == _NOTE_ON:
        if len(msg) < 3:
            return None
        return {
            "chan": chan, "type": "note", "value": msg[1], "vel": msg[2],
            "trigger": msg[2] > 0,
        }
    if status == _NOTE_OFF:
        return None  # note-off never triggers transport
    if status == _CC:
        if len(msg) < 3:
            return None
        return {
            "chan": chan, "type": "cc", "value": msg[1], "ccVal": msg[2],
            "trigger": msg[2] >= 64,
        }
    if status == _PC:
        return {
            "chan": chan, "type": "pgm", "value": msg[1],
            "trigger": True,
        }
    return None


class TransportMapper:
    """Matches incoming MIDI against config/midi_map.json mappings."""

    def __init__(self, action_callbacks: Dict[str, Callable]):
        self.actions = action_callbacks
        self.mappings: List[Dict] = []
        # CC edge detection: (chan, cc) → last triggered bool
        self._cc_state: Dict[Tuple[int, int], bool] = {}
        self.reload()

    def reload(self) -> None:
        try:
            with open(MIDI_MAP_FILE, encoding="utf-8") as f:
                data = json.load(f)
            self.mappings = data.get("mappings", []) or []
        except FileNotFoundError:
            self.mappings = []
        except Exception:
            log.exception("failed to read midi_map.json")
            self.mappings = []
        self._cc_state.clear()
        log.info("MIDI transport map reloaded: %d mapping(s)", len(self.mappings))

    def handle(self, msg: bytes) -> bool:
        ev = decode_message(msg)
        if ev is None:
            return False
        for m in self.mappings:
            if m.get("chan") != ev["chan"]:
                continue
            if m.get("type") != ev["type"]:
                continue
            if m.get("value") != ev["value"]:
                continue
            if not self._should_trigger(ev):
                return True
            action = self.actions.get(m.get("action"))
            if action:
                log.info("MIDI trigger: ch%d %s %d → %s",
                         ev["chan"], ev["type"], ev["value"], m.get("action"))
                try:
                    action()
                except Exception:
                    log.exception("transport action failed")
            return True
        return False

    def _should_trigger(self, ev: Dict) -> bool:
        if not ev.get("trigger"):
            # keep CC state updated so release edge doesn't retrigger
            if ev["type"] == "cc":
                self._cc_state[(ev["chan"], ev["value"])] = False
            return False
        if ev["type"] == "cc":
            key = (ev["chan"], ev["value"])
            if self._cc_state.get(key):
                return False
            self._cc_state[key] = True
        return True


# ---------------------------------------------------------------------------
# MIDI-learn capture
# ---------------------------------------------------------------------------


class LearnCapture:
    """Captures the next incoming MIDI event for the web MIDI-learn flow."""

    def __init__(self):
        self.active = False
        self._lock = threading.Lock()

    def start(self) -> None:
        with self._lock:
            self.active = True
        try:
            os.remove(MIDI_LEARN_FILE)
        except FileNotFoundError:
            pass
        log.info("MIDI learn: listening")

    def stop(self, cancel: bool = False) -> None:
        with self._lock:
            self.active = False
        if cancel:
            try:
                os.remove(MIDI_LEARN_FILE)
            except FileNotFoundError:
                pass
        log.info("MIDI learn: %s", "cancelled" if cancel else "stopped")

    def capture(self, msg: bytes) -> bool:
        ev = decode_message(msg)
        if ev is None or ev.get("trigger") is False:
            return False
        with self._lock:
            if not self.active:
                return False
            self.active = False
        try:
            MIDI_LEARN_FILE.parent.mkdir(parents=True, exist_ok=True)
            with open(MIDI_LEARN_FILE, "w", encoding="utf-8") as f:
                json.dump(ev, f)
            log.info("MIDI learn: captured ch%d %s %d",
                     ev["chan"], ev["type"], ev["value"])
        except Exception:
            log.exception("failed to write midi_learn.json")
        return True


# ---------------------------------------------------------------------------
# Input port manager (hot-plug aware)
# ---------------------------------------------------------------------------


class MidiInputManager(threading.Thread):
    """Opens all available MIDI input ports; refreshes every 2 s so
    hot-plugged controllers are picked up without a restart."""

    REFRESH_SEC = 2.0

    def __init__(self, handler: Callable[[bytes], None], enabled: bool = True):
        super().__init__(daemon=True, name="midi-input")
        self.handler = handler
        self.enabled = enabled
        self._alive = True
        self._ports: Dict[str, object] = {}
        self._lock = threading.Lock()

    @staticmethod
    def list_ports() -> List[str]:
        try:
            import rtmidi

            return rtmidi.MidiIn().get_ports()
        except Exception:
            return []

    def _refresh(self) -> None:
        try:
            import rtmidi
        except Exception as exc:
            log.warning("python-rtmidi unavailable (%s) — no MIDI input", exc)
            return
        wanted = rtmidi.MidiIn().get_ports()
        with self._lock:
            for name in list(self._ports):
                if name not in wanted:
                    self._ports.pop(name)
                    log.info("MIDI input closed: %s", name)
            for name in wanted:
                if name in self._ports:
                    continue
                try:
                    mi = rtmidi.MidiIn()
                    mi.open_port(wanted.index(name))
                    mi.ignore_types(sysex=False, timing=False, active_sense=False)
                    self._ports[name] = mi
                    log.info("MIDI input opened: %s", name)
                except Exception as exc:
                    log.warning("could not open MIDI input '%s': %s", name, exc)

    def run(self) -> None:
        if not self.enabled:
            return
        next_refresh = 0.0
        while self._alive:
            now = time.monotonic()
            if now >= next_refresh:
                self._refresh()
                next_refresh = now + self.REFRESH_SEC
            with self._lock:
                ports = list(self._ports.items())
            for _name, mi in ports:
                msg = None
                try:
                    msg = mi.get_message()
                except Exception:
                    msg = None
                if msg is None:
                    continue
                data, _delta = msg
                if isinstance(data, (list, tuple)):
                    data = bytes(data)
                try:
                    self.handler(bytes(data))
                except Exception:
                    log.exception("MIDI input handler failed")
            time.sleep(0.005)

    def stop(self) -> None:
        self._alive = False
        with self._lock:
            for mi in self._ports.values():
                try:
                    mi.close_port()
                except Exception:
                    pass
            self._ports.clear()
