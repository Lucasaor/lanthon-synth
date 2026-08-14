# LANTH0N 5YNTH — Agent Instructions

Headless live-playback rig: Python playback engine (multichannel WAV +
MIDI automation, one clock) + SvelteKit web UI + Python OLED daemon, all
on a **Raspberry Pi Zero 2W** (512 MB RAM, headless). **No synthesis
anywhere** — synthesis lives on a separate board, out of scope.

See [README.md](README.md) for the architecture, [prompt.md](prompt.md)
for the full rewrite spec, [AUDIT.md](AUDIT.md) for the pre-rewrite audit,
and [TEST_LOG.md](TEST_LOG.md) for verification evidence.

## Architecture

| Component | Entry point | Service |
|-----------|-------------|---------|
| Playback engine | `python3 -m engine.main` | `lanthon-engine.service` |
| OLED display daemon | `oled_daemon.py` (luma.oled) | `lanthon-oled.service` |
| Web config UI | `web/` (SvelteKit, port 5000) | `lanthon-web.service` |
| CPU governor | — | `lanth0n-cpugov.service` |

Engine modules (`engine/`):

| Module | Responsibility |
|--------|----------------|
| `main.py` | entry point — always run as `python3 -m engine.main` |
| `engine.py` | `Engine`: transport wiring, block renderer, MIDI dispatch, OSC handlers |
| `song.py` | `Song`: one WAV + one MID per song, streamed (SoundFile block reads) |
| `smf.py` | SMF parser: ticks → frames via the file's own tempo map |
| `devices.py` | live audio/MIDI enumeration + routing resolver (DevicePlans) |
| `midi_io.py` | transport mapping (midi_map.json), MIDI-learn, dispatcher thread |
| `osc.py` | OSC control server :57120 + OLED sender :9000 |
| `transport.py` | single source of truth: stopped/cued/playing + position frame |
| `statefile.py` | `config/state.json` writer + last-setlist persistence |

Config: `config/audio_routing.json` (per-track device+channel),
`config/midi_map.json` (channel-based transport mappings). Runtime files
written by the engine: `state.json`, `devices.json`, `midi_learn.json`,
`last_setlist.txt`. Setlists: `setlists/*.json` (song = name, artist,
tuning, key, wav, mid).

## Non-negotiable constraints

1. **No SuperCollider, no synthesis, no sample playback.** Nothing may
   reintroduce audio generation — the engine only streams + routes.
2. **One audio file + one MIDI file per song**, both driven by the same
   transport frame counter. Never split a song across files/processes.
3. **Sample-accurate sync** — audio blocks and MIDI dispatch both derive
   from `Transport.position_frame`; offline tests assert 0-frame error.
4. **Memory-safe streaming** — `SoundFile.read` per block, never load
   whole songs; memory tests gate this (`test_engine.py`).
5. **One source of truth** — the engine writes `config/state.json`;
   web UI reads it, never holds its own playback state.
6. **Hot-pluggable devices** — routing stores device *names* from the
   live snapshot (`config/devices.json`), never hardcoded indexes.

## Engine protocol (web UI depends on this)

- OSC in `udp:57120`: `/backtrack/play|stop|next|prev`,
  `/backtrack/load <name>`, `/midi/reload`, `/midi/learn/start|stop|cancel`,
  `/config/routing_reload`, `/devices/refresh`.
- OSC out `udp:9000`: `/oled/update <setlist> <artist> <song> <STATE> <tuning>`,
  `/oled/heartbeat <online:int> <playing:int>`.
- `state.json` heartbeat: refreshed every 5 s; web `/api/health` treats
  > 15 s as offline.

## Key behaviours

- Next/Prev pre-cues the adjacent song in a background worker; switching
  **during playback auto-plays** the new song.
- `play()` before the cue finishes latches (`Transport._pending_play`).
- Transport `set_song` must NOT call `self.stop()` (plain Lock deadlock).
- Old songs close after a 500 ms deferral (in-flight C-level reads).
- CC transport triggers need a rising edge ≥ 64; notes trigger on
  velocity > 0.
- `SimpleUDPClient.send_message` takes ONE value — pack multiple OSC args
  in a list.

## Dev commands

```bash
.venv/bin/python3 -m engine.main --offline --setlist <name>   # hardware-free run
LANTH0N_OFFLINE_RATE=1 ...                                    # realtime-throttled
PYTHON=.venv/bin/python3 ./tests/run_tests.sh                 # full offline suite
cd web && npm run build                                       # web build
LANTH0N_DEVICES_JSON='...' ...                                # mock device snapshot
```

- `LANTH0N_PROJECT_DIR` redirects all runtime dirs (tests use temp dirs;
  set it BEFORE importing `engine.paths`).
- Tests must be import-order safe: env before `engine` imports.
- `web/build/` is git-ignored; rebuild before running the web server or
  `test_routing_web.py` against a fresh clone.

## Deployment

`deploy/setup.sh` installs packages (portaudio, python, node, pip deps:
sounddevice/soundfile/python-rtmidi/python-osc/luma.oled/Pillow), builds
the web UI, installs the four systemd units. See [DEPLOY.md](DEPLOY.md).
The Pi hostname is `L4NTH0N-5YNTH` (ssh alias `lanth0n` on the dev Mac).
