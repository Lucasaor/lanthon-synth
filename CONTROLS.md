# CONTROLS.md — LANTH0N 5YNTH User Manual & MIDI Mapping Reference

> **This file is both the authoritative MIDI mapping reference AND the performer's
> quick-start guide.** Fill in the srcID/note/CC columns after running
> `sclang src/calibration.scd` with all controllers connected.

---

## Quick-Start Checklist (Pre-show)

1. Power on the Pi Zero 2W. Services start automatically in ~30 seconds.
2. Connect the USB hub with APC Mini + Worlde Easypad plugged in.
3. Pair the SMK25 via Bluetooth (first time only: `bluetoothctl`).
4. Verify OLED shows the last setlist loaded.
5. Open `http://lanth0n.local:5000` on your phone to load today's setlist.
6. Press `btPlay` mapped button (or send `/backtrack/play` OSC) to start.
7. Use APC Mini pads to build your oscillator tone. Notes from SMK25 go live.

---

## Device srcID Registry

| Device              | srcID (uid) | Connection type | Notes                            |
|---------------------|-------------|-----------------|----------------------------------|
| AKAI APC Mini       | `________`  | USB             | Grid + faders + LEDs             |
| Worlde Easypad 12   | `________`  | USB             | 12 sample trigger pads           |
| M-VAVE SMK 25       | `________`  | Bluetooth MIDI  | 25-key melodic keyboard          |

**Populate from** `sclang src/calibration.scd` output.

---

## 1. AKAI APC Mini

### 1.1 Grid Layout — FX Control Pads (columns 1–6, rows 1–8)

Addressed as row 1 = bottom, row 8 = top. Column 1 = leftmost.

```
Col:  1        2        3        4        5        6       | 7    8
Row 8 HPF      HPF      HPF      HPF      HPF      HPF     | PC   PC
Row 7 LPF      LPF      LPF      LPF      LPF      LPF     | PC   PC
Row 6 Reverb   Reverb   Reverb   Reverb   Reverb   Reverb   | PC   PC
Row 5 Tremolo  Tremolo  Tremolo  Tremolo  Tremolo  Tremolo  | PC   PC
Row 4 Dist     Dist     Dist     Dist     Dist     Dist     | PC   PC
Row 3 Oct Up   Oct Up   Oct Up   Oct Up   Oct Up   Oct Up   | PC   PC
Row 2 Oct Down Oct Down Oct Down Oct Down Oct Down Oct Down | PC   PC
Row 1 SQ       Saw      SuperSaw Sine     TB-303   WNoise   | PC   PC
(bottom)
```

### 1.2 FX Pad LED Colors

| Color         | Meaning                                      |
|---------------|----------------------------------------------|
| **Off**       | Pad not configured / not available           |
| **Yellow**    | Configured and idle (ready to activate)      |
| **Green**     | Active (effect/oscillator is ON)             |
| **Green blink** | Parameter-edit mode active (faders 1–6 remapped) |
| **Red blink** | PC pad: saved but not currently active       |
| **Green**     | PC pad: currently loaded/active snapshot     |

### 1.3 FX Pad Operations

| Action                     | Result                                                   |
|----------------------------|----------------------------------------------------------|
| **Press** idle pad         | Activate → green. Oscillator/effect turns ON.           |
| **Press** active pad       | Deactivate → yellow. Oscillator/effect turns OFF.        |
| **Hold 2 s** active pad    | Enter parameter-edit mode → green blink.                 |
| **Press** while editing    | Save parameters, exit edit mode → back to green.         |

### 1.4 Program Change Pads (columns 7–8, rows 1–8)

16 pads total; each stores a complete snapshot of all 48 FX pad states.

| Action                   | Result                                                     |
|--------------------------|------------------------------------------------------------|
| **Press** saved pad      | Load that snapshot (all FX pads update instantly).         |
| **Press** empty pad      | No action until you save.                                  |
| **Hold 2 s** any pad     | Blink blue × 1 s → snapshot saved. LED turns red-blink.   |
| **Press another PC pad** | Previous goes back to red-blink, new becomes green.        |

### 1.5 Faders — Normal Mode

| Fader | CC (verify) | Parameter                          |
|-------|-------------|------------------------------------|
| 1     | 48          | Synth volume                       |
| 2     | 49          | Filter cutoff (pre-FX chain)       |
| 3     | 50          | Oscillator dry/wet mix             |
| 4     | 51          | Global attack                      |
| 5     | 52          | Global sustain                     |
| 6     | 53          | Global release                     |
| 7     | 54          | Backtracks (VS) volume             |
| 8     | 55          | Click track volume                 |
| 9 (M) | 56         | Cue (Dica) track volume            |

### 1.6 Faders — Parameter-Edit Mode

When a FX pad is in edit mode (blinking), faders 1–6 control that effect:

| Effect Row | Fader 1       | Fader 2    | Fader 3    | Fader 4+ |
|------------|---------------|------------|------------|----------|
| Row 4 Dist | Drive         | Tone       | Dry/Wet    | —        |
| Row 5 Trm  | Rate (Hz)     | Depth      | —          | —        |
| Row 6 Rev  | Room size     | Damping    | Dry/Wet    | —        |
| Row 7 LPF  | Cutoff        | Resonance  | —          | —        |
| Row 8 HPF  | Cutoff        | —          | —          | —        |

Faders 7–9 always control VS/click/cue volumes, even in edit mode.

### 1.7 Notes Mode

Pressing the APC Mini's hardware **Notes Mode** button switches the grid from
FX pad mode to a note-playing mode (the grid sends MIDI notes to the melodic
voice, same as the SMK25). All FX pad states are preserved and restored on exit.

- **LED during Notes Mode**: all pads blank (off) to signal Notes Mode.
- **On exit**: LEDs restore exactly to the pre-Notes-Mode state.

### 1.8 APC Mini Note Map (fill from calibration.scd)

Grid note formula (default): `note = row × 8 + col` (row 0 = bottom, col 0 = left)

| Position      | Expected MIDI Note | Actual (fill in) |
|---------------|--------------------|------------------|
| (col=0, row=0) | 0                 | `__`             |
| (col=7, row=7) | 63                | `__`             |

Control row notes (above the grid, from calibration):

| Button        | MIDI Note | Actual |
|---------------|-----------|--------|
| (TBD)         | `___`     | `__`   |

---

## 2. Worlde Easypad 12

12 pads trigger samples. Each pad has independent velocity scaling and ADSR.
Configure in the web interface at `http://lanth0n.local:5000/worlde`.

### 2.1 Pad Layout (physical, numbered 1–12)

```
[ 9][ 10][ 11][ 12]
[ 5][  6][  7][  8]
[ 1][  2][  3][  4]
```

### 2.2 Pad Note Map (fill from calibration.scd)

| Pad | Expected Note | Actual Note | Assigned Sample |
|-----|---------------|-------------|-----------------|
|  1  | 36            | `__`        |                 |
|  2  | 37            | `__`        |                 |
|  3  | 38            | `__`        |                 |
|  4  | 39            | `__`        |                 |
|  5  | 40            | `__`        |                 |
|  6  | 41            | `__`        |                 |
|  7  | 42            | `__`        |                 |
|  8  | 43            | `__`        |                 |
|  9  | 44            | `__`        |                 |
| 10  | 45            | `__`        |                 |
| 11  | 46            | `__`        |                 |
| 12  | 47            | `__`        |                 |

---

## 3. M-VAVE SMK 25 (Bluetooth)

The SMK25 plays the active oscillator stack. Whatever oscillator pads are
currently active (green) on the APC Mini determines the timbre.

| Feature         | Behavior                                             |
|-----------------|------------------------------------------------------|
| Note on/off     | Triggers/releases \lanth0nVoice with active stack    |
| Velocity        | Scales amplitude                                     |
| Pitch bend      | ±2 semitones on active voices                        |
| Mod wheel CC 1  | Sweeps filter cutoff (80–18000 Hz)                   |
| Polyphony       | 8 voices max; oldest note stolen if exceeded         |

**Bluetooth pairing (first time):**
```bash
bluetoothctl
power on
agent on
scan on
# Wait for "SMK-25" to appear
pair <MAC>
trust <MAC>
connect <MAC>
```

---

## 4. Backtrack / VS / Click / Cue

### 4.1 File Naming

Place files in the `media/` directory. Names must match exactly (case-sensitive):

| Type    | Filename format             | Output bus |
|---------|-----------------------------|------------|
| VS      | `Song Name (VS).wav`        | FOH (1–2)  |
| Click   | `Song Name (click).wav`     | IEM (3–4)  |
| Cue     | `Song Name (Dica).wav`      | IEM (3–4)  |

MP3 files uploaded via the web interface are converted to WAV automatically.

### 4.2 MIDI-Mapped Playback Controls

Configure in the web interface at `http://lanth0n.local:5000/midi`.

| Action    | Controller | Note/CC | Value |
|-----------|-----------|---------|-------|
| Play      | `______` | `___`   | `___` |
| Stop      | `______` | `___`   | `___` |
| Next Song | `______` | `___`   | `___` |
| Prev Song | `______` | `___`   | `___` |

### 4.3 OSC Direct Control (from web or another device)

Send UDP OSC to port 57120 (sclang default):

| Message                         | Action                              |
|---------------------------------|-------------------------------------|
| `/backtrack/play`               | Start backtrack playback            |
| `/backtrack/stop`               | Stop playback                       |
| `/backtrack/next`               | Next song in setlist                |
| `/backtrack/prev`               | Previous song in setlist            |
| `/backtrack/load <name>`        | Load setlist by name (no extension) |

---

## 5. OLED Display

The 0.96" I2C display shows only backtrack state. Layout:

```
┌─────────────────────────────┐  ← blue region (top 16 px)
│ Night 1                     │  Setlist name
├─────────────────────────────┤
│ Tool                        │  Artist
│ Sober                       │  Song name
│ PLAYING  BPM:120            │  State + tempo
└─────────────────────────────┘  ← yellow region (bottom 20 px)
```

---

## 6. Web Configuration Interface

URL: `http://lanth0n.local:5000`  (or `http://<pi-ip>:5000`)

| Page        | Purpose                                              |
|-------------|------------------------------------------------------|
| Dashboard   | Quick play/stop/prev/next, setlist loader            |
| Files       | Upload VS/click/Dica/sample files                    |
| Setlists    | Create, edit, reorder, delete setlists               |
| MIDI Map    | Assign backtrack control to any note/CC              |
| Routing     | FOH/IEM assignment per track type                    |
| APC Pads    | 8×8 grid view, configure oscillator type per pad     |
| Worlde Pads | Assign samples + ADSR to each of 12 pads             |
| Programs    | Import/export Program Change snapshots               |

---

## 7. Emergency Commands (sclang interpreter)

```supercollider
~panicStop.()          // Stop all voices, playback, and clock immediately
~setBpm.(140)          // Change tempo (also updates OLED)
~tapTempo.()           // Tap 4× to calculate tempo from tapping
~testLEDs.()           // Cycle APC Mini LEDs through all colors
s.avgCPU.postln        // Check audio CPU load
~loadSetlist.("name")  // Load a setlist by name
~btPlay.()             // Start backtrack
~btStop.()             // Stop backtrack
```

---

## 8. Troubleshooting

| Symptom                        | Likely cause & fix                                          |
|-------------------------------|-------------------------------------------------------------|
| No audio from FOH             | Check audio routing in web UI; verify `~mainOutBus=0`       |
| Click audible in FOH          | Check `~iemOutBus`; verify click SynthDef uses `out=2`      |
| APC LEDs not updating         | `~apcMidiOut` is nil; check USB connection & reconnect      |
| SMK25 not responding          | BT disconnect; reconnect via `bluetoothctl connect <MAC>`   |
| Worlde pad silent             | No buffer loaded; upload sample in web UI                   |
| Backtrack won't play          | File missing or wrong format; check `media/` directory      |
| OLED blank                    | Check I2C: `i2cdetect -y 1`; verify `lanth0n-oled` service  |
| Web UI unreachable            | `systemctl status lanth0n-web`; try `http://<ip>:5000`      |
| xruns / audio glitches        | Reduce polyphony; check `s.avgCPU`; verify governor=performance |

