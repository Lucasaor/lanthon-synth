# Step 0 — Codebase Audit (pre-rewrite)

Date: 2026-08-14 · Commit baseline: `9f0af4f`
Purpose: map the existing repo before the L4NTH0N-5YNTH revamp (see `prompt.md`).

## 1. Web UI framework/stack

- **SvelteKit 2 + Svelte 5**, `@sveltejs/adapter-node`; build output served by plain
  `node build/index.js` on **port 5000** via systemd `lanthon-web.service`.
- Dev deps: `vite ^5`, `@sveltejs/vite-plugin-svelte ^4`. Runtime deps: `node-osc`
  (OSC client → SC on `127.0.0.1:57120`), `multer` (declared but NOT actually used —
  upload route uses `request.formData()`).
- CSRF disabled (`svelte.config.js`) — local-device-only design.
- Upload body limit via `Environment=BODY_SIZE_LIMIT=104857600` in the service unit.
- `web/src/lib/config.js`: JSON config read/write helpers; `PROJECT_ROOT` resolved
  via `process.cwd()` + `..` (service WorkingDirectory = `web/`).

### Routes inventory

| Route | Purpose | Fate |
|---|---|---|
| `/` dashboard | transport (play/stop/prev/next via OSC), setlist load | keep (rewire) |
| `/files` | media upload (WAV/MP3→ffmpeg→WAV 48k stereo) + sample upload | keep media only; drop sample + conversion |
| `/setlists` | song list: name/artist/tuning/key + VS/Click/Dica file selects | keep; fields become `wav` + `mid` |
| `/midi` | MIDI-learn: capture → map to actions (btPlay/Stop/Next/Prev/btPanic + synth actions) | keep; actions reduced to transport only |
| `/routing` | `audio_routing.json` — vs/click/dica/synth → foh/iem/both (bus channels, NOT devices) | **rewrite** (Task 4) |
| `/pads`, `/worlde`, `/programs` | synth/sample pad config | **delete** |
| `api/config/[name]`, `api/setlists*`, `api/state`, `api/health`, `api/osc`, `api/upload`, `api/midi/learn` | JSON config CRUD, OSC proxy, SC health | keep subset (see §4) |

## 2. OLED integration (how it gets data today)

- `oled_daemon.py` (Python: `luma.oled` + `python-osc` + `Pillow`), SSD1306 I2C,
  systemd `lanthon-oled.service`.
- Receives **UDP OSC on port 9000**: `/oled/update <setlist> <artist> <song> <STATE> <tuning>`
  and `/oled/heartbeat <online> <playing>`.
- Sent by SuperCollider `backtrack.scd` (`~oledUpdate`) on every state change +
  30 s heartbeat from `main.scd`.
- Dev mode: `LANTH0N_OLED_MOCK=1` (used by `tests/test_oled.py`).
- **Reusable as-is**: the daemon only cares about the OSC protocol. New engine must
  emit the same messages → OLED works with web UI closed.

## 3. Device routing today

- `config/audio_routing.json` = `{vs, click, dica, synth}` → `foh|iem|both`
  (bus channel numbers in scsynth, 2-channel CS202 interface).
- JACK device chosen **at setup time**: `deploy/setup.sh` greps `aplay -l` for "USB"
  and bakes `hw:N` into `/usr/local/bin/lanthon-jack-start.sh` → NOT hot-pluggable,
  no live enumeration, no per-track device assignment.
- **Rewrite required** (Task 4): per-track (Playback L/R, Click, Cue, MIDI
  automation, Timecode) → device + channel, live enumeration of connected devices.

## 4. MIDI controller mapping today

- `config/midi_map.json`: `{mappings: [{chan, type, value, action}]}` (channel-based,
  survives reboots). Loaded by `midi_routing.scd` (srcID-filtered MIDIdefs).
- Web MIDI-learn flow: web POSTs `/api/midi/learn` (OSC `/midi/learn/start`) → SC
  captures next event → writes `config/midi_learn.json` → web polls → save writes
  `midi_map.json` + OSC `/midi/reload`.
- **Reusable pattern**: keep channel-based map + learn-via-file protocol; new engine
  implements the same endpoints on its OSC port (57120) and the same `midi_learn.json`
  handshake. Actions reduced to: `btPlay`, `btStop`, `btNext`, `btPrev`.

## 5. SuperCollider-related vs reusable

**SC-related — remove entirely:**
- `src/*.scd` (main, synths, midi_routing, apc_pads, apc_leds, loops, backtrack,
  clock, calibration) and all synthesis/sample/loop code paths.
- `tests/*.scd` + SC parts of `tests/run_tests.sh`.
- Config: `pads_worlde.json`, `pads_smk.json`, `pc_snapshots.json`; old fields in
  `midi_map.json` and `audio_routing.json`.
- `deploy/lanthon-synth.service` (SC+JACK) → replaced by new engine unit;
  `/usr/local/bin/lanthon-jack-start.sh`; setup.sh SuperCollider/JSONlib/jackd
  install steps; SC mention in `.gitignore`, AGENTS.md, CONTROLS.md, DEPLOY.md.
- `arch_update.md` (obsolete architecture notes).

**Reusable — keep and adapt:**
- SvelteKit app skeleton, layout, CSS, all API CRUD patterns, `state.json`
  single-source-of-truth pattern, `last_setlist.txt` auto-load pattern.
- `oled_daemon.py` unchanged (OSC protocol preserved).
- `lanth0n-cpugov.service` (performance governor).
- BlueZ Bluetooth-MIDI setup in setup.sh (SMK25 transport control is still MIDI in).
- Upload endpoint skeleton (validation changes: WAV + MID only).
- `node-osc` web→engine OSC bridge (engine listens on 57120 — same address,
  different process).

## 6. New playback engine stack (decision)

**Python 3** (system python on Pi, same as OLED daemon) as one long-running process
(`lanthon-engine.service`) that owns the single source of truth:

| Concern | Library | Why |
|---|---|---|
| Audio output | `sounddevice` (PortAudio/ALSA) | multichannel streams, live device enumeration via `sounddevice.query_devices()`, per-device streams |
| Audio decoding | `soundfile` (libsndfile) | streaming block reads (flat memory), multichannel interleaved WAV |
| MIDI in/out | `python-rtmidi` | ALSA sequencer ports, hot-plug polling, automation output |
| OSC (web + OLED) | `python-osc` | already on the Pi (OLED daemon); same 57120/9000 ports |

- **One transport clock**: master PortAudio stream callback frame counter
  (`block index × framesPerBlock`, 48 kHz) is the authoritative sample position;
  all tracks render from it; pre-parsed MIDI events (`(frame, message)` list from
  the SMF tempo map) dispatched against the same counter → no drift possible.
- **Streaming**: `SoundFile.blocks()` — RAM flat regardless of song length;
  next song's WAV + MIDI pre-parsed/cued in background (Next/Prev = gap-free).
- **Offline driver** for tests (`LANTH0N_OFFLINE=1`): deterministic rendering
  without audio hardware — lets sync accuracy be asserted frame-exactly on any
  machine and lets tests run with no PortAudio installed.
- PortAudio package on Pi: `libportaudio2`; pip wheels: `sounddevice`, `soundfile`
  (bundles libsndfile), `python-rtmidi` (arm wheels), `python-osc`, `luma.oled`,
  `Pillow`.

## 7. Environment findings

- Dev machine: macOS, Python 3.13.1 venv (python-osc only), no PortAudio installed
  (offline driver required for local tests — by design).
- `media/`, `samples/` empty on dev; `setlists/example.json` uses old vs/click/dica
  fields → migrate to `wav` + `mid`.
- `web/build/` is git-ignored (build output).
- Remote: `github.com/Lucasaor/lanthon-synth.git`; HEAD `9f0af4f`.
- Pi `lanth0n.local` **not resolvable from dev machine at audit time** — Step 9
  deployment must re-check; docs will cover offline fallback.

## 8. Non-negotiable constraints mapping

| # | Constraint | Where satisfied |
|---|---|---|
| 1 | No SuperCollider/synthesis anywhere | Step 1 removal + new engine |
| 2 | One WAV + one MIDI per song, one clock | engine transport/song model |
| 3 | Sample-accurate sync | single frame counter + (frame,msg) dispatch; offline test asserts 0-frame error |
| 4 | Memory-safe streaming | `SoundFile.blocks()`, cued file handles; memory test in CI script |
| 5 | Single source of truth | engine → `config/state.json` (web reads it), OLED fed by engine only |
| 6 | Hot-pluggable discovery | `sounddevice.query_devices()` + rtmidi port polling → `config/devices.json` for web |
