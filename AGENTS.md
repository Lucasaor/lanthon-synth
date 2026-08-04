# LANTH0N 5YNTH — Agent Instructions

Headless real-time live-performance instrument: SuperCollider audio engine + SvelteKit web UI + Python OLED daemon, all running on a **Raspberry Pi Zero 2W** (512 MB RAM, headless, no screen).

See [README.md](README.md) for hardware overview and [prompt.md](prompt.md) for the full specification, step-by-step build plan, and deliverables list.

---

## Architecture

| Component | Entry point | Service |
|-----------|-------------|---------|
| SC audio engine | `src/main.scd` → loads all `src/*.scd` | `lanthon-synth.service` |
| OLED display daemon | `oled_daemon.py` (Python, luma.oled) | `lanthon-oled.service` |
| Web config UI | `web/` (SvelteKit, port 5000) | `lanthon-web.service` |
| CPU governor | — | `lanth0n-cpugov.service` |

SC `src/` file responsibilities:

| File | Responsibility |
|------|----------------|
| `main.scd` | Boot, SC server config, `executeFile` all others, OSC server |
| `synths.scd` | SynthDefs: 6 oscillators + effect chain + sample voice |
| `midi_routing.scd` | MIDI handlers for all 3 controllers, device watcher |
| `apc_pads.scd` | FX pad + Program Change pad state machines |
| `apc_leds.scd` | APC Mini v2 LED colour feedback |
| `loops.scd` | Metronome row + 8-track loop recording engine |
| `backtrack.scd` | Disk-streaming backtrack player + setlist engine |
| `clock.scd` | Shared `TempoClock` + click voice |
| `calibration.scd` | Step 0: MIDI discovery & calibration tool |

Config files: [config/](config/) — `midi_map.json`, `pads_worlde.json`, `pads_smk.json`, `pc_snapshots.json`, `audio_routing.json`.  
Setlists: [setlists/](setlists/) — JSON files edited via web UI.

---

## Critical SuperCollider Pitfalls

**These will silently break or hang the system — read before touching any `.scd` file.**

1. **`^` (return) HANGS** SC 3.13.0 when run via `executeFile`/`sclang -e`. Avoid `^` everywhere; use `if/else` nesting instead.
2. **`var` after a statement** is a parse error in `executeFile`. All `var`/`arg` declarations must be at the top of their block.
3. **`try { Json.parse }` does NOT catch "Class not defined"** (JSONlib missing). Guard with `\Json.asClass` (returns nil safely). JSONlib is NOT installed on the Pi — all JSON paths use fallback regex parsers.
4. **`synths.scd` must NOT reassign `~synthSendBus`** — `main.scd` allocates the bus; assigning `nil` clobbers it.
5. **`executeFile` reports only the FIRST syntax error.** Fix iteratively.
6. **`pads.do { |pad| ... }` sugar**: closing is `}` only — do not add `});`.
7. Boot is healthy when the log contains `[MIDI] Initialization complete.` + `RIG READY`.

---

## Key Global State (SC)

| Global | Description |
|--------|-------------|
| `~synthSendBus` | Private bus: voices → masterFX Ndef |
| `~mainOutBus` (0) | FOH stereo output |
| `~iemOutBus` (0) | IEM/monitor (shares main on CS202 2-ch interface) |
| `~fxPadState[row][col]` | `\off \| \idle \| \active` (rows 0–5, cols 0–5) |
| `~pcPadState[0-11]` | `\empty \| \saved \| \active` |
| `~loopState[0-7]` | `\empty \| \waiting \| \recording \| \playing \| \paused` |
| `~loopLength` | 1–8 bars |
| `~lanth0nVoices` | SMK25 8-voice polyphonic pool |
| `~apcNotesVoices` | APC Notes Mode 8-voice pool (separate) |
| `~voiceParams` | IdentityDictionary of live voice params |
| `~smkKnobMap` | IdentityDictionary[CC → paramSym] (MIDI-learn configurable) |

---

## Non-Negotiable Constraints

1. **No Sonic Pi.** Use `sclang`/`scsynth` directly.
2. **Backtracks stream from disk** (`VDiskIn`) — never load full audio files into RAM.
3. **Every `MIDIdef`/`MIDIFunc` must be filtered by `srcID`** — never assume note/CC numbers are globally unique across devices.
4. **All timing derives from one shared `TempoClock`** — tempo set from setlist song BPM, never from audio analysis.
5. **No controller crash on absence.** Guard all MIDI handlers; log warnings, never throw. Hot-plug re-registers handlers.
6. **Effects on shared buses, not per-voice** — keep SynthDefs cheap to protect 8-voice headroom.
7. **Web UI must not hold audio buffers in memory.**
8. **All APC Mini LED state must be saved/restored on Notes Mode entry/exit.**
9. **CPU governor = `performance`** — handled by `lanth0n-cpugov.service`, not manual.

See [prompt.md § Non-negotiable technical constraints](prompt.md) for full rationale.

---

## Testing

```bash
# Run all automated tests (uses sclang + Python)
./tests/run_tests.sh

# Individual SC tests
sclang tests/test_synths.scd
sclang tests/test_apc_pads.scd
sclang tests/test_midi.scd
sclang tests/test_backtrack.scd

# OLED daemon (mocked I2C)
LANTH0N_OLED_MOCK=1 python3 tests/test_oled.py
```

Test on the **host machine first** — only Steps 13 (boot packaging) and 14 (integration rehearsal) require physical Pi hardware. See [prompt.md § Testing strategy](prompt.md).

---

## Deploy to Pi

```bash
# Copy a file and hot-reload SC
scp src/<file>.scd lanthon@lanth0n.local:/tmp/
ssh lanthon@lanth0n.local "sudo systemctl stop lanthon-synth.service && sudo pkill -9 jackd; sleep 2; sudo cp /tmp/<file>.scd /home/lanthon/lanthon-synth/src/ && sudo chown lanthon:lanthon /home/lanthon/lanthon-synth/src/<file>.scd && sudo systemctl start lanthon-synth.service"

# Check health after 35s
ssh lanthon@lanth0n.local "sudo systemctl status lanthon-synth.service --no-pager | grep Active: && sudo grep -a 'RIG READY' /var/log/lanth0n/synth.log | tail -1"

# Full setup on fresh Pi OS
sudo ./deploy/setup.sh && sudo reboot
```

Full deployment instructions: [DEPLOY.md](DEPLOY.md).  
Controller note/CC/srcID map: [CONTROLS.md](CONTROLS.md).  
Test log: [TEST_LOG.md](TEST_LOG.md).

---

## Web UI (SvelteKit)

- Source: `web/src/` — routes map to config pages (files, setlists, midi, routing, pads, programs, worlde, worlde).
- OSC bridge: `web/src/lib/osc.js` — sends commands to SC on port 57120.
- CSRF disabled (`svelte.config.js`) — safe for local-device-only use.
- Upload body limit: set via `Environment="BODY_SIZE_LIMIT=104857600"` in `lanthon-web.service` (not `kit.bodySizeLimit`).
- `config.js` uses `process.cwd()` for `PROJECT_ROOT` (not `import.meta.dirname` — build depth shifts).
- Build: `cd web && npm run build`. Runs from `web/build/`.
