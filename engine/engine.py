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
from bisect import bisect_left
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
        backend=None,   # injectable for tests
        exit_fn=None,   # injectable for tests (default os._exit)
    ):
        self.sr = sample_rate
        self.block_size = block_size
        self.offline = offline
        self._exit_fn = exit_fn or os._exit

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
            "engineRestart": self.restart_engine,
            "btSeekFwd": lambda: self.seek_by(5.0),
            "btSeekBack": lambda: self.seek_by(-5.0),
        })
        self.learn = LearnCapture()
        self.midi_in = MidiInputManager(self._on_midi_message, midi_in_enabled)

        self.backend = backend if backend is not None else make_backend(self, offline)

        # setlist state
        self.setlist: Optional[dict] = None
        self.setlist_name: Optional[str] = None
        self.song_index = 0
        self._next_event_idx = 0
        self._setlist_stat: Optional[tuple] = None  # (mtime_ns, size) watch
        self._cue_error: Optional[str] = None       # surfaced to the web UI
        self._cue_worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="cue")
        # pre-cues the songs adjacent to the current one so next/prev
        # switches are instant (M4A transcode happens ahead of time)
        self._precue_worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="precue")
        self._precued: set = set()        # songs held open by the pre-cue
        self._inflight_songs: set = set() # songs a queued do_cue is switching to
        self._inflight_lock = threading.Lock()
        self._stop_offline = False

        # OSC control (web UI + external tools)
        self.osc = OscControl(port=osc_port, oled_port=oled_port)
        self._register_osc()

        # heartbeat: state.json freshness + OLED liveness
        self._heartbeat_stop = threading.Event()
        self._heartbeat_thread = threading.Thread(
            target=self._heartbeat_loop, daemon=True, name="heartbeat")

        # audio health (device hot-unplug detection + recovery)
        self._last_callback = time.monotonic()
        self._audio_error_count = 0
        self._recovering = False
        self._recovery_lock = threading.Lock()
        self._last_recovery_attempt: Optional[float] = None
        self._recovery_failures = 0
        self._streams_healthy = False

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
        # release the current streams BEFORE probing: a stream on ALSA
        # 'default' can hold the configured USB interface open, hiding it
        # from PortAudio's enumeration (device reports 0 output channels)
        self.backend.stop()
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
        if not self._start_streams():
            log.warning("routing applied but audio streams could not open")
        log.info("routing applied: %d plan(s), MIDI out '%s'",
                 len(self._plans), self._midi_out_name or "(none)")

    # ------------------------------------------------------------------
    # Setlist / song management
    # ------------------------------------------------------------------

    def load_setlist(self, name: str, autoplay: bool = False) -> bool:
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
        try:
            st = path.stat()
            self._setlist_stat = (st.st_mtime_ns, st.st_size)
        except OSError:
            self._setlist_stat = None
        self._goto(0, autoplay=autoplay)
        return bool(songs)

    def _watch_setlist(self) -> None:
        """Hot-reload the active setlist when its file changes on disk.

        Edits made through the web UI (or scp/ssh) are picked up within
        one heartbeat tick without a manual 'Load to Rig'. If playback
        was active, the reloaded setlist auto-plays from its first song.
        """
        name = self.setlist_name
        if not name:
            return
        path = paths.SETLISTS_DIR / f"{name}.json"
        try:
            st = path.stat()
            sig = (st.st_mtime_ns, st.st_size)
        except OSError:
            sig = None
        if sig == self._setlist_stat:
            return
        if sig is None:
            # file vanished (e.g. deleted via the web UI) — keep the
            # current in-memory list playing rather than tearing down
            log.warning("setlist '%s' disappeared on disk — keeping current "
                        "song list", name)
            self._setlist_stat = None
            return
        was_playing = self.transport.playing
        log.info("setlist '%s' changed on disk — reloading", name)
        self.load_setlist(name, autoplay=was_playing)

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
            self._cue_error = None
            self._publish_state()
            return
        self.song_index = index
        with self._inflight_lock:
            self._inflight_songs.add(song)

        def do_cue():
            try:
                try:
                    song.cue()
                except Exception as exc:
                    log.error("failed to cue '%s': %s", song.name, exc)
                    self._cue_error = f"could not load '{song.name}': {exc}"
                    if self.transport.song is not song:
                        # the transport still holds a song from a previous
                        # setlist context — don't leave it playable under
                        # the new setlist (stale song + stale cache)
                        self.transport.set_song(None)
                    song.close()
                    self._publish_state()
                    return
                self._cue_error = None
                new_plans = self.build_plans(song)
                self._next_event_idx = 0
                old = self.transport.song
                self.transport.set_song(song)
                # if the song we just left is still an adjacent neighbor
                # (it always is for a 1-step next/prev), cancel its
                # deferred close RIGHT HERE — the pre-cue round may be
                # queued behind a long decode and miss the 500 ms window,
                # which would force a wasteful re-decode of that song
                songs = (self.setlist or {}).get("songs") or []
                idx = self.song_index
                if old is not None and old is not song and (
                        (idx - 1 >= 0 and songs[idx - 1] is old) or
                        (idx + 1 < len(songs) and songs[idx + 1] is old)):
                    self.transport.cancel_pending_close(old)
                if new_plans != self._plans:
                    # reopen the streams for the new plans: the startup
                    # stream was opened for the bare default plan, and this
                    # song's plans may key/route to different devices —
                    # without the reopen the master stream never receives
                    # buffers (silent playback)
                    self.backend.stop()
                    self._plans = new_plans
                    if not self._start_streams():
                        log.warning("song cued but audio streams could not open")
                else:
                    # identical routing plan (same device+channels): keep
                    # the open streams — the switch is then near-instant
                    log.info("plans unchanged — reusing open streams "
                             "(instant switch)")
                if autoplay:
                    self.transport.play()
                self._publish_state()
            finally:
                with self._inflight_lock:
                    self._inflight_songs.discard(song)
                self._precue_neighbors()

        self._cue_worker.submit(do_cue)

    # ------------------------------------------------------------------
    # Background pre-cue (instant next/prev)
    # ------------------------------------------------------------------

    def _precue_neighbors(self) -> None:
        """Queue a pre-cue round on the dedicated worker. Safe to call
        from any thread; rounds coalesce on the single worker thread."""
        self._precue_worker.submit(self._precue_task)

    def _precue_task(self) -> None:
        """One pre-cue round.

        Closes songs that are no longer adjacent (frees SoundFile handles
        and decoded-AAC cache files), then makes sure both the previous
        and the next song are cued and held open. A press on next/prev
        then only needs the (already open) song, so the switch is instant
        instead of waiting out a full ffmpeg decode.
        """
        try:
            songs = (self.setlist or {}).get("songs") or []
            idx = self.song_index
            current = self.transport.song
            neighbors = [songs[i] for i in (idx - 1, idx + 1)
                         if 0 <= i < len(songs)]
            keep = set(neighbors)
            if current is not None:
                keep.add(current)
            with self._inflight_lock:
                protected = set(self._inflight_songs)

            # stale pre-cues (moved away from, or from an old setlist)
            stale = set(self._precued)
            stale |= {s for s in songs if s.open}
            for s in stale:
                if s in keep or s is current or s in protected:
                    continue
                log.info("precue: closing '%s' (no longer adjacent)", s.name)
                try:
                    s.close()
                except Exception:
                    pass
            self._precued = set()

            for n in neighbors:
                if n is current or n in protected:
                    continue
                # the song we just switched away from is now the adjacent
                # neighbor in the other direction — cancel its deferred
                # close so it stays open for an instant switch back
                self.transport.cancel_pending_close(n)
                if n.open:
                    self._precued.add(n)
                    continue
                log.info("pre-cueing '%s' in the background", n.name)
                try:
                    n.cue()
                    self._precued.add(n)
                except Exception as exc:
                    log.warning("pre-cue failed for '%s': %s", n.name, exc)
        except Exception:
            log.exception("precue round failed")

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
    # Seek
    # ------------------------------------------------------------------

    def seek(self, seconds: float) -> None:
        """Jump to an absolute position (seconds) in the current song.

        Recomputes the MIDI dispatch pointer and drops already-scheduled
        events so automation stays locked to the new position."""
        t = self.transport
        song = t.song
        if song is None or not song.open:
            log.info("seek ignored: no song cued")
            return
        frame = t.seek_to(seconds)
        if song.smf is not None:
            # events are sorted by frame — restart dispatch from the new
            # position (binary search; no full scan)
            self._next_event_idx = bisect_left(
                song.smf.events, frame, key=lambda ev: ev.frame)
        if not self.offline:
            self.dispatcher.clear_pending()
        log.info("seek to %.2f s (frame %d)", frame / self.sr, frame)
        self._publish_state()

    def seek_by(self, delta: float) -> None:
        """Relative seek (e.g. +5 s / −5 s MIDI mappings)."""
        t = self.transport
        if t.song is None or not t.song.open:
            log.info("seek ignored: no song cued")
            return
        self.seek(t.position_sec() + delta)

    def restart_engine(self) -> None:
        """Full engine restart: stop cleanly, mark offline, then exit with a
        non-zero code so systemd restarts the service (Restart=on-failure).
        Triggerable from the web UI and from a MIDI mapping."""
        log.warning("engine restart requested — exiting for systemd restart")
        try:
            self.transport.stop()
            self.backend.stop()
        except Exception:
            pass
        try:
            # written LAST so the final persisted state marks the engine
            # offline (transport stop above may publish its own snapshot)
            snap = self._snapshot()
            snap["engineOnline"] = False
            write_state(snap)
        except Exception:
            log.exception("could not write restart state")
        try:
            self.osc.oled_heartbeat(False, False)
        except Exception:
            pass
        time.sleep(0.2)  # let the writes flush before the process dies
        self._exit_fn(42)

    # ------------------------------------------------------------------
    # Audio block processing (called from the master stream callback)
    # ------------------------------------------------------------------

    def tick(self, frames: int, time_info, status) -> None:
        """Render one block. `time_info` is PortAudio's callback time_info
        (or the offline stand-in); `status` is the callback flags int
        (None = OK, used by the offline driver)."""
        if status:
            # PortAudio callback error (underrun / device lost): silence the
            # output and let the recovery logic reopen the streams. Never
            # spin on a dead device.
            for plan in self._plans:
                self.backend.put_buffer(plan.key, self._zeros(frames, plan))
            self.audio_callback_notify(False)
            return
        self.audio_callback_notify(True)

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

        # Only advance the clock if we're still playing. If stop()/seek()
        # ran mid-block they moved position_frame away from this block's
        # start — don't clobber that with the block's end position
        # (realtime race guard).
        if t.playing and t.position_frame == pos:
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
        # a song that ran to its natural end drops any pending seek
        self.transport.clear_seek()
        self.transport.stop()
        log.info("song '%s' finished", song.name if song else "?")
        if self.offline:
            self._stop_offline = True
        self._publish_state()

    def _zeros(self, frames: int, plan: DevicePlan) -> np.ndarray:
        n = max(1, max((r.out_ch + 1 for r in plan.routes), default=2))
        return np.zeros((frames, n), dtype=np.float32)

    # ------------------------------------------------------------------
    # Audio health / device hot-unplug recovery
    # ------------------------------------------------------------------

    def audio_callback_notify(self, ok: bool) -> None:
        """Called from the audio callback every block."""
        self._last_callback = time.monotonic()
        if ok:
            return
        self._audio_error_count += 1
        if self._audio_error_count >= 3:
            self._start_audio_recovery(force=True)

    def _start_streams(self) -> bool:
        """Open the audio streams; tolerate missing/broken devices."""
        try:
            self.backend.start(self._plans, self.sr, self.block_size)
        except Exception as exc:
            # expected while no output device is connected — single line,
            # no traceback spam on every retry
            log.warning("could not open audio streams (%s)", exc)
            self._streams_healthy = False
            return False
        missing = devices.missing_audio_devices(self._routing_cfg,
                                                self._dev_snapshot)
        if missing:
            # streams ARE open, but on the fallback device — keep the
            # recovery cycle running until the configured interface
            # (re)appears (hot-plug persistence)
            log.warning("audio streams opened on fallback; configured "
                        "device(s) missing: %s — will keep re-enumerating",
                        ", ".join(missing))
            self._streams_healthy = False
        else:
            self._streams_healthy = True
        return True

    def _recovery_cooldown(self, force: bool) -> float:
        if force:
            return 5.0
        return min(60.0, 5.0 * (2 ** min(self._recovery_failures, 4)))

    def _start_audio_recovery(self, force: bool = False) -> None:
        """Re-enumerate devices and reopen the audio streams (hot-plug)."""
        if self.offline:
            return
        now = time.monotonic()
        if (self._last_recovery_attempt is not None
                and now - self._last_recovery_attempt < self._recovery_cooldown(force)):
            return  # back off — don't hammer a broken kernel audio state
        if not self._recovery_lock.acquire(blocking=False):
            return
        if self._recovering:
            self._recovery_lock.release()
            return
        self._recovering = True
        self._last_recovery_attempt = now
        self._recovery_lock.release()
        log.warning("audio recovery: re-enumerating devices and reopening streams")

        def do():
            try:
                # Release the current streams BEFORE probing: a fallback
                # stream on ALSA 'default' can itself hold the missing USB
                # interface open, which hides it from PortAudio's
                # enumeration (device reports 0 output channels) — a
                # self-masking lock that would never re-attach.
                self.backend.stop()
                self._dev_snapshot = devices.snapshot()
                missing = devices.missing_audio_devices(self._routing_cfg,
                                                        self._dev_snapshot)
                song = self.transport.song
                if song is not None and song.open:
                    self._plans = self.build_plans(song)
                else:
                    self._plans = [
                        DevicePlan(key="default", name="default output",
                                   device=None, n_out=8, routes=[], is_master=True)
                    ]
                if self._start_streams():
                    if missing:
                        # reopened on the fallback; back off between probes
                        # so the fallback isn't torn down every 5 s forever
                        self._recovery_failures += 1
                        self._streams_healthy = False
                        log.info("audio recovery: configured device(s) still "
                                 "missing (%s) — fallback stream restored, "
                                 "will keep retrying", ", ".join(missing))
                    else:
                        self._recovery_failures = 0
                        log.info("audio recovery complete: %d plan(s)",
                                 len(self._plans))
                else:
                    self._recovery_failures += 1
                    log.warning("audio recovery: no usable output device yet "
                                "— will retry automatically")
            except Exception:
                log.exception("audio recovery failed — will retry")
                self._recovery_failures += 1
                self._streams_healthy = False
            finally:
                self._audio_error_count = 0
                self._recovering = False

        threading.Thread(target=do, daemon=True, name="audio-recovery").start()

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
        seek_sec = t.seek_sec()
        return {
            # display name = the setlist JSON's "name" field (same as the
            # old rig showed on the OLED/dashboard); filename key stays
            # internal for load/persist
            "activeSetlist": (self.setlist or {}).get("name") or self.setlist_name,
            "songName": song.name if song else None,
            "artist": song.artist if song else None,
            "tuning": song.tuning_label() if song else None,
            "key": song.key if song else None,
            "playing": t.playing,
            "state": t.state,
            "positionSec": round(t.position_sec(), 3),
            "durationSec": round(t.duration_sec(), 3),
            "seekSec": round(seek_sec, 3) if seek_sec is not None else None,
            "cueError": self._cue_error,
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
            snap["positionSec"],
            snap["durationSec"],
        )

    def _on_transport_change(self) -> None:
        self._publish_state()

    def _heartbeat_loop(self) -> None:
        tick = 0
        while not self._heartbeat_stop.wait(1.0):
            tick += 1
            # While playing, refresh position once a second so the web
            # trackbar and the OLED time stay live between state changes.
            if self.transport.playing:
                self._publish_state()
            if tick % 5 != 0:
                continue
            # pick up setlist edits made outside the engine
            self._watch_setlist()
            # keep the adjacent songs pre-cued (self-heals any missed
            # round, e.g. when a deferred close raced a pre-cue)
            self._precue_neighbors()
            write_state(self._snapshot())
            self.osc.oled_heartbeat(True, self.transport.playing)
            # keep the device snapshot fresh for the routing UI
            try:
                devices.write_devices_snapshot()
            except Exception:
                log.exception("device snapshot refresh failed")
            # watchdog: no audio callbacks while playing = device vanished
            # without error statuses (e.g. the callback thread wedged)
            if (self.transport.playing and not self.offline
                    and time.monotonic() - self._last_callback > 3.0):
                self._start_audio_recovery()
            # no usable output device yet (or streams never opened): keep
            # retrying so hot-plugging the interface self-heals the rig
            if not self.offline and not self._streams_healthy:
                self._start_audio_recovery()

    # ------------------------------------------------------------------
    # OSC control interface
    # ------------------------------------------------------------------

    def _register_osc(self) -> None:
        self.osc.on("/backtrack/play", lambda *a: self.play())
        self.osc.on("/backtrack/stop", lambda *a: self.stop())
        self.osc.on("/backtrack/next", lambda *a: self.next_song())
        self.osc.on("/backtrack/prev", lambda *a: self.prev_song())
        self.osc.on("/backtrack/seek",
                    lambda addr, *args: self.seek(float(args[0]) if args else 0.0))
        self.osc.on("/backtrack/seek_by",
                    lambda addr, *args: self.seek_by(float(args[0]) if args else 0.0))
        self.osc.on("/backtrack/load",
                    lambda addr, *args: self.load_setlist(str(args[0]) if args else ""))
        self.osc.on("/midi/reload", lambda *a: self.mapper.reload())
        self.osc.on("/midi/learn/start", lambda *a: self.learn.start())
        self.osc.on("/midi/learn/stop", lambda *a: self.learn.stop(cancel=False))
        self.osc.on("/midi/learn/cancel", lambda *a: self.learn.stop(cancel=True))
        self.osc.on("/config/routing_reload", lambda *a: self.apply_routing())
        self.osc.on("/devices/refresh",
                    lambda *a: devices.write_devices_snapshot())
        self.osc.on("/engine/restart", lambda *a: self.restart_engine())
        # compat: /ping (legacy web health probe) — kept for debugging tools
        self.osc.on("/ping", lambda addr, *a: log.debug("OSC /ping from %s", addr))

    # ------------------------------------------------------------------
    # lifecycle
    # ------------------------------------------------------------------

    def _purge_media_cache(self) -> None:
        """Delete stale decoded-AAC spool files left over from previous
        runs (e.g. after an unclean shutdown)."""
        try:
            for name in os.listdir(paths.CACHE_DIR):
                p = paths.CACHE_DIR / name
                if p.is_file():
                    try:
                        p.unlink()
                    except OSError:
                        pass
        except OSError:
            pass

    def start(self) -> None:
        paths.ensure_dirs()
        self._purge_media_cache()
        self._plans: List[DevicePlan] = [
            DevicePlan(key="default", name="default output", n_out=8, routes=[], is_master=True)
        ]
        self.dispatcher.start()
        self.midi_in.start()
        self._heartbeat_thread.start()
        # opening streams must never kill the engine: without an audio
        # device the engine stays up (OSC/state/OLED work) and the
        # recovery cycle reopens streams once hardware appears
        self._start_streams()
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
        try:
            self._precue_worker.shutdown(wait=False, cancel_futures=True)
        except Exception:
            pass
        self.osc.stop()
