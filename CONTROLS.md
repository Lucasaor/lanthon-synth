# CONTROLS.md — LANTH0N 5YNTH User Manual

The Zero 2W does one job: play per-song **multichannel WAV + MIDI
automation** with a single clock. No synthesis, no loops, no samples.

## Transport controls

Four actions exist. The **web dashboard buttons and the MIDI controller
buttons call the exact same actions** — there is one control path.

| Action | Web UI | MIDI (after mapping) |
|---|---|---|
| Play | ▶ | your button |
| Stop | ■ | your button |
| Next song | ⏭ | your button |
| Previous song | ⏮ | your button |
| Restart engine | 🔄 dashboard → Engine | your button |

Behaviour:

- **Play** — starts/continues the current song from its current position.
- **Stop** — halts; position is retained (Play resumes from there).
- **Next / Prev** — loads the adjacent song instantly (it was pre-cued in
  the background). If playback was active, the new song **auto-plays**.
- **Song end** — playback stops automatically at the end of a song.
- **Load setlist** — dashboard "Load to Rig" or setlists page; the rig
  remembers the last setlist across reboots.
- **Restart engine** — stops playback and restarts the engine process
  (dashboard → Engine → 🔄, or a mapped MIDI CC). systemd brings it back
  in ~5 s; the web UI and OLED show it offline briefly, then online.
  If the engine is already dead, the button falls back to
  `systemctl restart lanthon-engine` (via the sudoers rule installed by
  the setup script).

Every state change lands in `config/state.json` — the single source of
truth read by the dashboard and displayed on the OLED.

## MIDI transport mapping

Mappings are **channel-based** (`chan + type + value → action`) and live
in `config/midi_map.json`:

```json
{
  "mappings": [
    { "chan": 0, "type": "note", "value": 36, "action": "btPlay"  },
    { "chan": 0, "type": "cc",   "value": 64, "action": "btStop"  },
    { "chan": 0, "type": "note", "value": 38, "action": "btNext"  },
    { "chan": 0, "type": "note", "value": 37, "action": "btPrev"  }
  ]
}
```

Mapping rules:

- `note` — triggers on **note-on with velocity > 0** (note-off is ignored).
- `cc` — triggers on a **rising edge at value ≥ 64** (won't retrigger
  while held).
- `pgm` — triggers on any program change.
- Available actions: `btPlay`, `btStop`, `btNext`, `btPrev`,
  `engineRestart` (same restart as the dashboard button).
- The engine listens on **all connected MIDI input ports** (USB and
  Bluetooth, re-scanned every 2 s) — no device-specific setup needed.

### Mapping with the web UI (recommended)

`/midi` page → **Start Learning** → press the button / turn the knob on
your controller → pick the action → **Save**. Conflicts on the same
channel/type/value are flagged before overwriting.

### Editing midi_map.json by hand

Edit `config/midi_map.json`, then reload: press "Save" from the MIDI page,
or `curl -X POST http://<pi>:5000/api/osc -d '{"address":"/midi/reload"}'`
with the proper content-type, or restart `lanthon-engine`.

## Web UI pages

| Page | What it does |
|---|---|
| Dashboard | transport buttons, setlist load, live engine state |
| Files | upload per-song WAV + MID files |
| Setlists | songs with WAV, MID, **tuning** (standard/drop), **key** (C…B) |
| MIDI Map | MIDI-learn transport mapping |
| Routing | per-track device + channel assignment with live device list |

## Routing screen

For each logical track choose the destination **device** and **channel**:

| Track | Source | Default channel |
|---|---|---|
| Playback L | WAV ch 1 | device ch 1 |
| Playback R | WAV ch 2 | device ch 2 |
| Click | WAV ch 3 | device ch 3 |
| Cue | WAV ch 4 | device ch 4 |
| Timecode | WAV ch 5 (only if present) | device ch 5 |
| MIDI automation | song's `.mid` | first MIDI output |

- `auto` = system default audio output / first MIDI output.
- The device list refreshes live (engine every 5 s, screen every 3 s) —
  a hot-plugged interface appears without a restart.
- A track pointing at a disconnected device falls back to the default
  output (warning shown in the UI).
- **Clock device** selects which audio stream drives the transport; the
  default is the device carrying Playback L/R.

## OLED display (no web UI required)

| Line | Content |
|---|---|
| 1 (top) | setlist name + engine online dot `E●` |
| 2 | artist |
| 3 | song name |
| 4 | state — `PLAYING` / `STOP` / `CUED` — + tuning label (`Drop D` / `Standard E`) |

Updates arrive over OSC whenever the engine state changes; the heartbeat
dot goes dark if the engine is offline for > 45 s. The display works fully
standalone — the web UI does not need to be open.

## Song files

Per song, two files in `media/`:

- `<song>.wav` — **multichannel, interleaved, 48 kHz**: ch1 L, ch2 R,
  ch3 Click, ch4 Cue, optional ch5 Timecode. Render from Reaper with the
  project sample rate set to 48000.
- `<song>.mid` — automation (PC/CC) with its own tempo map; events are
  converted to audio frames using the file's tempo so they stay locked
  to the audio. No tempo field exists in the setlist — the MIDI file
  **is** the timing source for automation.

The engine streams the WAV from disk (never loads it whole) and parses the
MIDI once at cue time — memory use is flat regardless of song length.
