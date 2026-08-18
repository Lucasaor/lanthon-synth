# TEST_LOG.md — L4NTH0N-5YNTH Revamp Verification Evidence

Rewrite of the Zero 2W app: SuperCollider rig → single-clock multichannel
WAV + MIDI automation player. Evidence per build step (dev machine,
2026-08-14; engine tests run offline — deterministic, no audio hardware).

## Test suite

`./tests/run_tests.sh` (offline; `PYTHON=.venv/bin/python3`):

| Module | Covers | Result |
|---|---|---|
| `test_smf.py` | SMF parser: tempo map, SMPTE division, running status | 7/7 PASS |
| `test_devices.py` | enumeration, per-track resolution, fallbacks, two-device offline render | 11/11 PASS |
| `test_engine.py` | sync, routing, transport, memory | 5/5 PASS |
| `test_midi_io.py` | decoding, mapping, learn capture, virtual-MIDI-port e2e | 5/5 PASS |
| `test_routing_web.py` | real node server + engine: devices API, routing save/apply, hot-swap simulation | 3/3 PASS |
| `test_oled.py` | OLED daemon rendering (mock I2C) | 11/11 PASS |
| `test_oled_engine.py` | real daemon + engine over UDP: OLED tracks transport without web UI | 2/2 PASS |

**Total: 7/7 modules PASS.**

## Step 1 — SuperCollider removal

- Deleted `src/*.scd`, all SC tests, pad/program configs, `lanthon-synth.service`,
  `arch_update.md`; stripped SC/jackd/JSONlib/JACK-helper from `setup.sh`.
- Verify: `bash -n` clean; no SC references left in code; `web` builds cleanly;
  OLED daemon tests 8/8 (mock I2C).

## Step 2 — Core playback engine (headless, offline)

- **Sync accuracy**: 4 synthetic MIDI events (PC @0.5 s, CC @3.0 s, note-on
  @5.5 s, note-off @5.75 s) dispatched at **exactly** the expected frames —
  0-frame error over a full 10 s song.
- **Channel correctness**: offline render of a 4-ch WAV reproduces all four
  source channels bit-exact on the output (np.allclose atol 1e-6).
- **Memory (RSS)**:
  - 120 s song render: 124.0 → 124.2 MB (**+0.2 MB**, flat).
  - 25 rapid song switches (play → next ×25): 124.5 → 125.2 MB (**+0.6 MB**, flat).
- **Transport**: cued → playing → stopped; stop is a FULL stop — position
  rewinds to frame 0 so the next play() starts from the top (not a pause);
  song auto-stops and rewinds at end.
- CLI smoke: `python3 -m engine.main --offline --setlist smoke` renders to
  completion and writes a correct `state.json`.

## Step 3 — Routing configuration backend

- Mock two-audio-device snapshot: per-track assignments (Playback L/R →
  USB 8ch ch 1/2; Click → USB 2ch ch 1; Cue → USB 8ch ch 4) resolve into
  exactly two DevicePlans with the expected routes; clock-device override
  and unknown-device fallback verified.
- Offline two-device render: every WAV channel lands on its configured
  device/channel; MIDI still dispatches frame-exact.
- Timecode routed only when enabled + present (5-ch WAV).

## Step 4 — Web UI playback-only

- Full HTTP e2e (offline engine @ realtime rate + node server):
  `/api/health` online; setlist load → `cued`; play → `playing` with
  position advancing; stop → `stopped` — all reflected in the same
  `state.json` the engine writes.
- Setlists API carries `wav`/`mid` fields; `/pads`, `/worlde`,
  `/programs` return 404.

## Step 5 — MIDI controller transport mapping

- Virtual MIDI port e2e (CoreMIDI): note 36 → Play, CC 64 → Stop,
  note 38 → Next, note 37 → Prev; `state.json` reflects each trigger
  identically to the web path; web-style and MIDI-style actions used
  interchangeably agree; next/prev during playback auto-plays.
- Learn capture writes `config/midi_learn.json` single-shot.

## Step 6 — OLED integration

- Real `oled_daemon` module (mock I2C) + real engine over UDP:
  load → `CUED / Drop D`, play → `PLAYING`, stop → `STOP`, next →
  `Standard E`, prev → `Drop D`; setlist/artist/song all correct;
  heartbeat sets the online dot. **No web UI in the path.**
- Fix applied along the way: python-osc `send_message` argument packing.

## Step 7 — Routing screen

- Automated (real node server + engine): `/api/devices` reflects the
  engine's live enumeration; saving routing applies to the engine's audio
  plans (2 devices, exact channel map); swapping the mock device list
  (simulated hot-plug) updates the endpoint and the engine falls back to
  the default device **without restart**.
- Browser check: routing screen lists live devices with per-track
  selects; dashboard ▶ drives engine state (`state.json playing=true`).

## Step 8 — Documentation

- README/DEPLOY/CONTROLS/TEST_LOG/AGENTS rewritten to the new architecture;
  signal-routing diagram validated (mermaid).

## Step 9 — Deployment to the Pi (real hardware) — DONE

- Git history pushed to `origin/main` (11 scoped commits: step0 audit,
  SC removal, engine, routing backend, web scope, MIDI mapping, OLED,
  routing UI, docs, deploy fixes, legacy migration).
- Pi (`L4NTH0N-5YNTH`, aarch64, Debian trixie) updated via `git reset
  --hard origin/main`; runtime data preserved (`media/`, `setlists/`,
  `config/midi_map.json` restored from backup; old config backed up to
  `~/lanthon-backup/`).
- SuperCollider/JACK purged from the Pi (`supercollider*`, `jackd*`,
  `a2jmidid`, `libscsynth1t64`, old unit + JACK helper removed).
- `sudo ./deploy/setup.sh` completed: 4 systemd units installed/enabled,
  hostname preserved (`L4NTH0N-5YNTH`). Fixes needed during deploy:
  `build-essential`/`python3-dev`/`libasound2-dev` for the python-rtmidi
  source build (no aarch64 wheel for Python 3.13) and keeping ffmpeg
  (used by the migration).
- **Real setlist migrated**: `deploy/migrate_legacy.py` merged the legacy
  split VS/Click/Dica tracks into single 4-ch 48 kHz WAVs per song and
  rewrote the setlist to `wav`/`mid` (`.json.legacy` backup kept).
- **Hardware verification on the Pi**:
  - services `active` ×4; engine log: audio stream opened on the real
    CS202, MIDI input ports opened (incl. WORLDE controller), 5 transport
    mappings loaded, real setlist auto-loaded and song cued
    (4 ch, 124.1 s).
  - engine RSS: **42.5 MB** (flat — the old rig OOMed this hardware).
  - web API: `/api/health` online; play → `positionSec` advancing →
    stop; `/api/devices` shows live CS202 + MIDI ports.
  - OLED log: `CUED → PLAYING → STOP` with artist/song/tuning — web UI,
    engine, and OLED agree through one state.json.
- **Remaining for the next rehearsal (needs human hands/ears)**: pressing
  the physical controller buttons (the mapped WORLDE CCs are loaded; the
  same actions as the web path were verified via virtual ports in Step 5),
  hearing the merged tracks through the PA, and adding per-song `.mid`
  automation files (none exist yet — they are authored in Reaper and
  uploaded via the Files page).

## Notes / known limitations

- Multiple *independent* USB audio devices share the same transport frame
  counter, but independent device clocks can drift across devices over
  long songs (unavoidable without word clock); using one multichannel
  interface for all audio tracks is the recommended and sample-accurate
  setup.
- Realtime MIDI dispatch is scheduled against PortAudio's DAC time with
  sub-millisecond busy-spin; the dispatcher logs mean/max offset every
  200 events so accuracy is observable on the Pi.

## M4A/AAC support (Aug 17/18)

Bulk WAVs → compressed 4-track M4A (ch1-2 VS, ch3 Click, ch4 Dica).

- `engine/song.py`: `AAC_EXTS = {.m4a,.mp4,.aac,.m4b}`; cue() decodes via
  ffmpeg into `media/.cache/<tmp>.wav` (pcm_s16le), streams/seeks from
  that; cache deleted on close (per-Song) and purged on engine start.
  `engine/paths.py`: `CACHE_DIR`.
- Web: upload whitelist + chunked endpoint + Files page accept + setlists
  auto-fill now include m4a/mp4/aac.
- Also fixed: a failed cue left the previous setlist's song cued (stale
  playback + stale cache) — do_cue now clears the transport song when
  the failing song is a different object.
- Tests: `TestM4aDecode` (3: cue/read/seek/cache-cleanup, offline render,
  decode-failure) + stale-song test + cache-purge test — 9/9 modules PASS.
- Live verification (Pi): synthetic 4-ch AAC files (full VS + click/dica
  only) uploaded → "decoded 'full.m4a' → cached WAV (4504 kB)",
  "Cued song ... 4 ch, 12.0 s", CS202 stream, play/seek(+8s)/next
  (click-only song auto-played)/stop all work; cache emptied after unload.

## OLED timestamp stuck at 0:00 (Aug 18)

- Symptom: OLED status line always showed "0:00/0:00" for both position
  and duration, even while playing; web dashboard times were correct.
- Root cause: `oled_daemon.render_loop()` copied the shared `_state` into
  a fresh `DisplayState` for rendering but omitted `position_sec` and
  `duration_sec` — so the rendered line always used the dataclass
  defaults (0.0). The daemon was *receiving* correct values (its log
  showed `0.5/261.5 s`). Purely a render-side bug.
- Fix: extracted `_copy_state_locked()` (documented "call with
  `_state_lock` held") that copies the full state incl. position/duration
  and `sc_playing`; render loop uses it. Engine code untouched.
- Tests: `test_oled.py` +3 (copy preserves position/duration,
  `fmt_time` incl. ≥1 h, 7-arg OSC `/oled/update` carries times) —
  11/11 PASS locally.
- Live verification (Pi): scp'd `oled_daemon.py` + restart
  `lanthon-oled` → active, heartbeat ONLINE; mock render check prints
  `PLAYING  1:54/4:22` for (114.0, 261.5); state.json dur 261.5 now shows
  on screen while stopped as `STOP 0:00/4:21`.

## Instant next/prev via background pre-cue (Aug 18)

- Symptom: 5-8 s between pressing next/prev and the new song starting.
  Log timestamps: `next → song 3` 13:42:42 → `Cued song` 13:42:49.
- Root cause: NOT a hardware limit — every setlist song is .m4a, and the
  cue (full ffmpeg transcode on the Pi Zero) ran at press time. The
  "pre-cue the adjacent song" design from the spec was never implemented
  (`_goto` only cued the target when next/prev was pressed).
- Fix (engine):
  - `_precue_worker` (1 thread) runs `_precue_task` rounds: prune stale
    open songs (no longer adjacent or from an old setlist), then cue
    prev+next neighbors. Rounds fire after every successful do_cue AND
    on the 5 s heartbeat (self-heal). Cache bounded to current + 2
    neighbors; prune never closes the transport's current song or a
    queued switch target (`_inflight_songs`).
  - `Song.cue()/close()` serialized per song via `_lock`
    (`@dataclass(eq=False)` so songs are identity-hashed for the sets).
  - `Transport.set_song()` deferred close is now cancelable
    (`cancel_pending_close`); `do_cue` cancels it for the just-left song
    when it's still a neighbor — a busy pre-cue worker would otherwise
    miss the 500 ms window and force a wasteful re-decode (seen live:
    "precue: closing 'One Step Closer'" + immediate re-cue).
  - do_cue reuses the open PortAudio streams when the new song's plans
    equal the current ones (`new_plans != self._plans` gate; logs
    "plans unchanged — reusing open streams").
- Tests: `TestPrecue` (2) in test_engine.py: neighbors opened before a
  switch without touching the transport; prev stays open past the 500 ms
  close timer and stale songs are pruned after moving 2 away. Full suite
  9/9 modules PASS.
- Live verification (Pi): pre-cue log flow (pre-cue 'One Step Closer'
  decodes while 'Take a Look Around' cued); OSC-timed switches
  **next 21-42 ms, prev 21-22 ms** (was 5-8 s); quick next→prev leaves
  One Step open (no re-decode), Remedy pruned after its decode; cache
  holds exactly 2 decoded WAVs; ~52 GB free on the SD card.
