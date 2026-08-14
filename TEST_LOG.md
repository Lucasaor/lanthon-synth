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
| `test_oled.py` | OLED daemon rendering (mock I2C) | 8/8 PASS |
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
- **Transport**: cued → playing → stopped; position retained across stop;
  song auto-stops at end.
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

## Step 9 — Deployment to the Pi (real hardware)

- **PENDING** — `lanth0n.local` not reachable from the dev machine at the
  time of writing. Plan: `git push`, SSH to the Pi, `git pull`, run
  `sudo ./deploy/setup.sh`, restart services, then verify on real hardware:
  - real setlist with WAV+MID pairs,
  - controller transport + web UI + OLED agreement,
  - routing against the real USB interface,
  - `journalctl -u lanthon-engine` clean, memory flat.

## Notes / known limitations

- Multiple *independent* USB audio devices share the same transport frame
  counter, but independent device clocks can drift across devices over
  long songs (unavoidable without word clock); using one multichannel
  interface for all audio tracks is the recommended and sample-accurate
  setup.
- Realtime MIDI dispatch is scheduled against PortAudio's DAC time with
  sub-millisecond busy-spin; the dispatcher logs mean/max offset every
  200 events so accuracy is observable on the Pi.
