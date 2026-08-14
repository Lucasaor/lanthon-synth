"""Engine — the single-clock multichannel-WAV + MIDI automation player.

Owns the Transport (single source of truth), the audio backend, the MIDI
dispatcher, MIDI input mapping, the OSC control interface, and state/OLED
publishing. See AUDIT.md §6 for the architecture.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from typing import List, Optional

import numpy as np

from . import devices, paths
from .audio import ChannelRoute, DevicePlan, make_backend
from .midi_io import (
    LearnCapture,
    MidiDispatcher,
    MidiInputManager,
    NullMidiOut,
    RtMidiOut,
    TransportMapper,
)
from .osc import OscControl
from .smf import SmfError
from .song import Song, WAV_CHANNELS
from .statefile import read_last_setlist, write_last_setlist, write_state
from .transport import CUED, PLAYING, STOPPED, Transport

log = logging.getLogger("engine")

DEFAULT_SR = 48000
DEFAULT_BLOCK = 512


class Engine:
    def __init__(
        self,
        offline: bool = False,
        sample_rate: int = DEFAULT_SR,
        block_size: int = DEFAULT_BLOCK,
        osc_port: int = 57120,
        oled_port: int = 9000,
        midi_out_port: Optional[str] = None,
        midi_in_enabled: bool = True,
    ):
        self.sr = sample_rate
        self.block_size = block_size
        self.offline = offline

        self.transport = Transport(sample_rate)
        self.transport.add_listener(self._on_transport_change)

        # routing (config/audio_routing.json + live device snapshot)
        self._routing_cfg = devices.load_routing()
        self._dev_snapshot = devices.snapshot()
        midi_out_name = midi_out_port or devices._resolve_midi_out(
            (self._routing_cfg.get("tracks") or {}).get("midi_automation") or {},
            self._dev_snapshot,
        )
        self._midi_out_name = midi_out_name

        self.midi_out = NullMidiOut() if offline else self._make_midi_out(midi_out_name)
        self.dispatcher = MidiDispatcher(self.midi_out, sample_rate, offline)
        self.mapper = TransportMapper({
            "btPlay": self.play,
            "btStop": self.stop,
            "btNext": self.next_song,
            "btPrev": self.prev_song,
        })
        self.learn = LearnCapture()
        self.midi_in = MidiInputManager(self._on_midi_message, midi_in_enabled)

        self.backend = make_backend(self, offline)

        # setlist state
        self.setlist: Optional[dict] = None
        self.setlist_name: Optional[str] = None
        self.song_index = 0
        self._next_event_idx = 0
        self._cue_worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="cue")
        self._stop_offline = False

        # OSC control (web UI + external tools)
        self.osc = OscControl(port=osc_port, oled_port=oled_port)
        self._register_osc()

        # heartbeat: state.json freshness + OLED liveness
        self._heartbeat_stop = threading.Event()
        self._heartbeat_thread = threading.Thread(
            target=self._heartbeat_loop, daemon=True, name="heartbeat")

    # ------------------------------------------------------------------
    # MIDI output
    # ------------------------------------------------------------------

    @staticmethod
    def _make_midi_out(port: Optional[str]):
        try:
            out = RtMidiOut(port)
            log.info("MIDI automation output: %s", out.name)
            return out
        except Exception as exc:
            log.warning("MIDI output unavailable (%s) — automation disabled", exc)
            return NullMidiOut()

    # ------------------------------------------------------------------
    # Routing (Step 2: identity mapping; Step 3 makes it configurable)
    # ------------------------------------------------------------------

    def build_plans(self, song: Song) -> List[DevicePlan]:
        """Map WAV channels to device channels per config/audio_routing.json."""
        plans, _midi_name = devices.resolve_routing(
            self._routing_cfg, song, self._dev_snapshot)
        return plans

    def apply_routing(self) -> None:
        """Reload routing config + device snapshot; swap MIDI output and
        restart audio streams with the new channel mapping."""
        self._routing_cfg = devices.load_routing()
        self._dev_snapshot = devices.snapshot()
        midi_name = devices._resolve_midi_out(
            (self._routing_cfg.get("tracks") or {}).get("midi_automation") or {},
            self._dev_snapshot,
        )
        if not self.offline and midi_name != self._midi_out_name:
            self._midi_out_name = midi_name
            self.midi_out.close()
            self.midi_out = self._make_midi_out(midi_name)
            self.dispatcher.out = self.midi_out
        song = self.transport.song
        if song is not None and song.open:
            self._plans = self.build_plans(song)
        else:
            self._plans = [
                DevicePlan(key="default", name="default output",
                           device=None, n_out=8, routes=[], is_master=True)
            ]
        self.backend.stop()
        self.backend.start(self._plans, self.sr, self.block_size)
        log.info("routing applied: %d plan(s), MIDI out '%s'",
                 len(self._plans), self._midi_out_name or "(none)")

    # ------------------------------------------------------------------
    # Setlist / song management
    # ------------------------------------------------------------------

    def load_setlist(self, name: str) -> bool:
        name = name.removesuffix(".json").strip()
        path = paths.SETLISTS_DIR / f"{name}.json"
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except FileNotFoundError:
            log.error("setlist not found: %s", name)
            return False
        except Exception:
            log.exception("failed to parse setlist %s", name)
            return False

        songs = []
        for entry in data.get("songs", []) or []:
            wav = (entry.get("wav") or "").strip()
            if not wav:
                log.warning("song '%s' has no WAV file — skipped", entry.get("name"))
                continue
            wav_path = wav if os.path.isabs(wav) else str(paths.MEDIA_DIR / wav)
            mid = (entry.get("mid") or "").strip()
            mid_path = mid if mid and os.path.isabs(mid) else (
                str(paths.MEDIA_DIR / mid) if mid else None)
            songs.append(Song(
                name=entry.get("name") or wav,
                artist=entry.get("artist") or "",
                tuning=entry.get("tuning") or "standard",
                key=entry.get("key") or "E",
                wav_path=wav_path,
                mid_path=mid_path,
                sample_rate=self.sr,
            ))

        self.setlist = {"name": data.get("name") or name, "songs": songs}
        self.setlist_name = name
        self.song_index = 0
        write_last_setlist(name)
        log.info("setlist '%s' loaded: %d song(s)", name, len(songs))
        self._goto(0, autoplay=False)
        return bool(songs)

    def _song_at(self, index: int) -> Optional[Song]:
        if self.setlist is None:
            return None
        songs = self.setlist["songs"]
        if not songs or not (0 <= index < len(songs)):
            return None
        return songs[index]

    def _goto(self, index: int, autoplay: bool) -> None:
        song = self._song_at(index)
        self.transport.stop()
        if song is None:
            self.transport.set_song(None)
            self.song_index = index
            self._publish_state()
            return
        self.song_index = index

        def do_cue():
            try:
                song.cue()
            except Exception as exc:
                log.error("failed to cue '%s': %s", song.name, exc)
                song.close()
                return
            self._plans = self.build_plans(song)
            self._next_event_idx = 0
            self.transport.set_song(song)
            if autoplay:
                self.transport.play()
            self._publish_state()

        self._cue_worker.submit(do_cue)

    def next_song(self) -> None:
        if self.setlist is None:
            return
        nxt = min(self.song_index + 1, len(self.setlist["songs"]) - 1)
        if nxt == self.song_index:
            log.info("next: already at last song")
            return
        autoplay = self.transport.playing
        log.info("next → song %d%s", nxt, " (auto-play)" if autoplay else "")
        self._goto(nxt, autoplay)

    def prev_song(self) -> None:
        if self.setlist is None:
            return
        prv = max(self.song_index - 1, 0)
        if prv == self.song_index:
            log.info("prev: already at first song")
            return
        autoplay = self.transport.playing
        log.info("prev → song %d%s", prv, " (auto-play)" if autoplay else "")
        self._goto(prv, autoplay)

    def play(self) -> None:
        self.transport.play()

    def stop(self) -> None:
        self.transport.stop()

    # ------------------------------------------------------------------
    # Audio block processing (called from the master stream callback)
    # ------------------------------------------------------------------

    def tick(self, frames: int, time_info, status) -> None:
        """Render one block. `time_info` is PortAudio's callback time_info
        (or the offline stand-in); `status` is ignored."""
        t = self.transport
        song = t.song
        if not t.playing or song is None or not song.open:
            for plan in self._plans:
                self.backend.put_buffer(plan.key, self._zeros(frames, plan))
            return

        pos = t.position_frame
        end = pos + frames
        data = song.read_block(pos, frames)

        # channel routing
        for plan in self._plans:
            buf = np.zeros((frames, max(1, max((r.out_ch + 1 for r in plan.routes), default=2))), dtype=np.float32)
            for route in plan.routes:
                if route.wav_ch < data.shape[1]:
                    buf[:, route.out_ch] += data[:, route.wav_ch] * route.gain
            self.backend.put_buffer(plan.key, buf)

        # MIDI automation dispatch from the same clock
        dac_time = self._dac_time(time_info)
        self._dispatch_range(pos, end, dac_time)

        # let the dispatcher convert stream time → wall time precisely
        if not self.offline:
            self.dispatcher.update_anchor(time.monotonic(), dac_time)

        t.position_frame = end
        if end >= song.frames:
            self._on_song_end(pos, end, dac_time)

    @staticmethod
    def _dac_time(time_info) -> float:
        try:
            return float(getattr(time_info, "outputBufferDacTime", 0.0))
        except Exception:
            return 0.0

    def _dispatch_range(self, start: int, end: int, dac_time: float) -> None:
        song = self.transport.song
        if song is None or song.smf is None:
            return
        events = song.smf.events
        i = self._next_event_idx
        while i < len(events) and events[i].frame < end:
            ev = events[i]
            if ev.frame >= start:
                if self.offline:
                    self.dispatcher.record(ev.frame, ev.data)
                else:
                    due = dac_time + (ev.frame - start) / self.sr
                    self.dispatcher.schedule(due, ev.data)
            i += 1
        self._next_event_idx = i

    def _on_song_end(self, pos: int, end: int, dac_time: float) -> None:
        song = self.transport.song
        # flush any events exactly at the end boundary
        self._dispatch_range(pos, song.frames + 1, dac_time)
        self.transport.position_frame = song.frames
        self.transport.stop()
        log.info("song '%s' finished", song.name if song else "?")
        if self.offline:
            self._stop_offline = True
        self._publish_state()

    def _zeros(self, frames: int, plan: DevicePlan) -> np.ndarray:
        n = max(1, max((r.out_ch + 1 for r in plan.routes), default=2))
        return np.zeros((frames, n), dtype=np.float32)

    # ------------------------------------------------------------------
    # MIDI input
    # ------------------------------------------------------------------

    def _on_midi_message(self, msg: bytes) -> None:
        if self.learn.capture(msg):
            return
        self.mapper.handle(msg)

    # ------------------------------------------------------------------
    # State + OLED publishing
    # ------------------------------------------------------------------

    def _snapshot(self) -> dict:
        t = self.transport
        song = t.song
        return {
            "activeSetlist": self.setlist_name or None,
            "songName": song.name if song else None,
            "artist": song.artist if song else None,
            "tuning": song.tuning_label() if song else None,
            "key": song.key if song else None,
            "playing": t.playing,
            "state": t.state,
            "positionSec": round(t.position_sec(), 3),
            "durationSec": round(t.duration_sec(), 3),
            "songIndex": self.song_index,
            "songCount": len(self.setlist["songs"]) if self.setlist else 0,
            "engineOnline": True,
        }

    def _publish_state(self) -> None:
        snap = self._snapshot()
        write_state(snap)
        self.osc.oled_update(
            snap["activeSetlist"] or "—",
            snap["artist"] or "—",
            snap["songName"] or "—",
            "PLAYING" if snap["playing"] else ("STOP" if snap["state"] == STOPPED else "CUED"),
            snap["tuning"] or "—",
        )

    def _on_transport_change(self) -> None:
        self._publish_state()

    def _heartbeat_loop(self) -> None:
        while not self._heartbeat_stop.wait(5.0):
            write_state(self._snapshot())
            self.osc.oled_heartbeat(True, self.transport.playing)
            # keep the device snapshot fresh for the routing UI
            try:
                devices.write_devices_snapshot()
            except Exception:
                log.exception("device snapshot refresh failed")

    # ------------------------------------------------------------------
    # OSC control interface
    # ------------------------------------------------------------------

    def _register_osc(self) -> None:
        self.osc.on("/backtrack/play", lambda *a: self.play())
        self.osc.on("/backtrack/stop", lambda *a: self.stop())
        self.osc.on("/backtrack/next", lambda *a: self.next_song())
        self.osc.on("/backtrack/prev", lambda *a: self.prev_song())
        self.osc.on("/backtrack/load",
                    lambda addr, *args: self.load_setlist(str(args[0]) if args else ""))
        self.osc.on("/midi/reload", lambda *a: self.mapper.reload())
        self.osc.on("/midi/learn/start", lambda *a: self.learn.start())
        self.osc.on("/midi/learn/stop", lambda *a: self.learn.stop(cancel=False))
        self.osc.on("/midi/learn/cancel", lambda *a: self.learn.stop(cancel=True))
        self.osc.on("/config/routing_reload", lambda *a: self.apply_routing())
        self.osc.on("/devices/refresh",
                    lambda *a: devices.write_devices_snapshot())
        # compat: /ping (legacy web health probe) — kept for debugging tools
        self.osc.on("/ping", lambda addr, *a: log.debug("OSC /ping from %s", addr))

    # ------------------------------------------------------------------
    # lifecycle
    # ------------------------------------------------------------------

    def start(self) -> None:
        paths.ensure_dirs()
        self._plans: List[DevicePlan] = [
            DevicePlan(key="default", name="default output", n_out=8, routes=[], is_master=True)
        ]
        self.dispatcher.start()
        self.midi_in.start()
        self._heartbeat_thread.start()
        self.backend.start(self._plans, self.sr, self.block_size)
        self._publish_state()
        log.info("Engine started (offline=%s, sr=%d, block=%d)",
                 self.offline, self.sr, self.block_size)

    def start_offline_pump(self, rate: float = 1.0) -> None:
        """Offline: render blocks in a background thread whenever the
        transport is playing, throttled to realtime speed. Lets the OSC
        control interface run alongside (hardware-free integration rig)."""
        period = (self.block_size / self.sr) / rate if rate > 0 else 0.0
        stop = threading.Event()
        self._offline_pump_stop = stop

        def pump():
            block = 0
            while not stop.is_set():
                t0 = time.monotonic()
                if self.transport.playing:
                    class _Ti:
                        def __init__(self, dac):
                            self.outputBufferDacTime = dac
                    self.tick(self.block_size,
                              _Ti(block * self.block_size / self.sr), None)
                    block += 1
                if period:
                    elapsed = time.monotonic() - t0
                    if elapsed < period:
                        time.sleep(period - elapsed)
                else:
                    time.sleep(0.002)

        threading.Thread(target=pump, daemon=True, name="offline-pump").start()

    def run_offline_until_stop(self, rate: float = 0.0) -> None:
        """Offline: render blocks until the transport stops (song end).

        rate > 0 throttles rendering to realtime speed (LANTH0N_OFFLINE_RATE),
        which makes the offline driver useful as a hardware-free demo /
        integration-test rig.
        """
        self._stop_offline = False
        block = 0
        period = (self.block_size / self.sr) / rate if rate > 0 else 0.0
        while True:
            t0 = time.monotonic()
            class _Ti:  # minimal stand-in for PortAudio's time_info
                def __init__(self, dac):
                    self.outputBufferDacTime = dac
            self.tick(self.block_size, _Ti(block * self.block_size / self.sr), None)
            block += 1
            if self._stop_offline:
                break
            if self.transport.song is None and not self.transport.pending_play:
                break
            if period:
                elapsed = time.monotonic() - t0
                if elapsed < period:
                    time.sleep(period - elapsed)

    def wait_cued(self, timeout: float = 10.0) -> bool:
        """Block until the current song has finished cueing."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.transport.song is not None and self.transport.song.open:
                return True
            time.sleep(0.01)
        return False

    def auto_load_last_setlist(self) -> None:
        name = read_last_setlist()
        if name:
            log.info("auto-loading last setlist: %s", name)
            self.load_setlist(name)

    def serve_forever(self) -> None:
        self.osc.serve_forever()

    def shutdown(self) -> None:
        self._heartbeat_stop.set()
        self.transport.stop()
        self.dispatcher.stop()
        self.midi_in.stop()
        self.backend.stop()
        self.midi_out.close()
        try:
            self._offline_pump_stop.set()
        except AttributeError:
            pass
        self.osc.stop()
