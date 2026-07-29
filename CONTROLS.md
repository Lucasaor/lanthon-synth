# CONTROLS.md — LANTH0N 5YNTH User Manual & MIDI Mapping Reference

> **This file is both the authoritative MIDI mapping reference AND the performer's
> quick-start guide.** Fill in the srcID/note/CC columns after running
> `sclang src/calibration.scd` with all controllers connected.

---

## Quick-Start Checklist (Pre-show)

1. Power on the Pi Zero 2W — all three services start automatically (~30 s).
2. Connect the USB hub with APC Mini v2 + Worlde Easypad plugged in.
3. Pair the SMK25 via Bluetooth (`bluetoothctl connect <MAC>` or auto-reconnect).
4. OLED shows the last loaded setlist name and STOP state.
5. Open `http://lanth0n.local:5000` on your phone, load today's setlist.
6. Set loop length on the APC metronome row (press pad 2 for 2-bar loops, etc.).
7. Press the MIDI-mapped Play button (or `/backtrack/play` via OSC).
8. Play notes on SMK25 — oscillator tone is set by APC FX pads (row 1).
9. Press a loop track pad to start recording, press again to play/pause.

---

## Device srcID Registry

| Device              | srcID (uid) | Connection type | Notes                              |
|---------------------|-------------|-----------------|-------------------------------------|
| AKAI APC Mini v2    | `________`  | USB             | Grid + faders + LEDs               |
| Worlde Easypad 12   | `________`  | USB             | 12 sample trigger pads             |
| M-VAVE SMK 25       | `________`  | Bluetooth MIDI  | Keys + knobs + pads + wheels       |

**Populate from** `sclang src/calibration.scd` output.

---

## 1. AKAI APC Mini v2

### 1.1 Grid Layout Overview

```
Col:  0        1        2        3        4        5        6    7
Row 7 Metro 1  Metro 2  Metro 3  Metro 4  Metro 5  Metro 6  M7   M8   ← Metronome/loop-length
Row 6 Loop 1   Loop 2   Loop 3   Loop 4   Loop 5   Loop 6   L7   L8   ← Loop tracks
Row 5 Reverb   Reverb   Reverb   Reverb   Reverb   Reverb   PC   PC
Row 4 Delay    Delay    Delay    Delay    Delay    Delay    PC   PC
Row 3 Dist     Dist     Dist     Dist     Dist     Dist     PC   PC
Row 2 Oct Up   Oct Up   Oct Up   Oct Up   Oct Up   Oct Up   PC   PC
Row 1 Oct Dn   Oct Dn   Oct Dn   Oct Dn   Oct Dn   Oct Dn   PC   PC
Row 0 SQ       Saw      SuperSaw Sine     TB-303   WNoise   PC   PC   ← Oscillators
(bottom)
```

---

### 1.2 Row 7 — Metronome / Loop-Length Selector

| Colour       | Meaning                                              |
|--------------|------------------------------------------------------|
| Dim yellow   | Background (all 8 pads)                              |
| Light blue   | Rolling beat indicator (advances each beat)          |
| Bright cyan  | Downbeat / bar-set start (pad 0)                     |

**Setting loop length:** press any pad in this row.

| Pad pressed | Loop length | Total beats (4/4) |
|-------------|-------------|-------------------|
| 0 (leftmost)| 1 bar       | 4 beats           |
| 1           | 2 bars      | 8 beats           |
| 2           | 3 bars      | 12 beats          |
| 3           | 4 bars      | 16 beats          |
| 4           | 5 bars      | 20 beats          |
| 5           | 6 bars      | 24 beats          |
| 6           | 7 bars      | 28 beats          |
| 7 (rightmost)| 8 bars    | 32 beats          |

---

### 1.3 Row 6 — Loop Track Controls (Tracks 1–8)

Each pad corresponds to one loop track. Fader 1–8 controls the volume of track 1–8.

| LED colour   | Track state   | Press action                                          |
|--------------|---------------|-------------------------------------------------------|
| Off          | Empty         | Schedules recording at next bar-set downbeat          |
| Amber        | Waiting       | (ignore press — will start recording automatically)   |
| Red          | Recording     | (ignore press — recording in progress)                |
| Green        | Playing       | Pauses playback; LED turns yellow                     |
| Yellow       | Paused        | Resumes playback; LED turns green                     |

**Overdub / re-record:** hold a green or yellow pad for **2 seconds** — recording
restarts at the next bar-set downbeat and overwrites the previous take.

---

### 1.4 Rows 0–5, Columns 0–5 — FX Control Pads (36 pads)

| Row | Function                                                         |
|-----|------------------------------------------------------------------|
| 0   | Oscillator (col 0=Square, 1=Saw, 2=SuperSaw, 3=Sine, 4=TB-303, 5=WNoise) |
| 1   | Octave Down (adds same oscillator 1 oct below)                   |
| 2   | Octave Up (adds same oscillator 1 oct above)                     |
| 3   | Distortion                                                       |
| 4   | Delay                                                            |
| 5   | Reverb                                                           |

| LED colour | Meaning                                |
|------------|----------------------------------------|
| Off        | Pad not configured / unconfigured      |
| Yellow     | Configured, inactive (effect/osc OFF)  |
| Green      | Active (effect/osc ON)                 |

**To activate:** press any yellow pad → turns green, effect/oscillator activates.  
**To deactivate:** press any green pad → turns yellow.

**Effect parameters** (reverb room, delay time, etc.) are controlled by **SMK25 knobs** — no pad hold-to-edit. See Section 3.

---

### 1.5 Rows 0–5, Columns 6–7 — Program Change Pads (12 pads)

Each pad stores a snapshot of the 36 FX control pad states.

| LED colour | State         | Press action                                  |
|------------|---------------|-----------------------------------------------|
| Off        | Empty         | No action until you save                      |
| Purple     | Saved, inactive | Loads that FX configuration instantly       |
| Blue       | Currently active | —                                          |

**Save gesture:** hold any pad for **2 seconds** → blinks blue for 1 s → snapshot saved.  
Only one PC pad is active (blue) at a time.

---

### 1.6 Faders

| Fader | CC (verify) | Function                      |
|-------|-------------|-------------------------------|
| 1     | 48          | Loop track 1 volume           |
| 2     | 49          | Loop track 2 volume           |
| 3     | 50          | Loop track 3 volume           |
| 4     | 51          | Loop track 4 volume           |
| 5     | 52          | Loop track 5 volume           |
| 6     | 53          | Loop track 6 volume           |
| 7     | 54          | Loop track 7 volume           |
| 8     | 55          | Loop track 8 volume           |
| 9 (M) | 56         | Backtrack (VS) volume         |

No parameter-edit mode — effect parameters are exclusively on SMK25 knobs.

---

### 1.7 Notes Mode (Shift + Notes on controller)

Activating Notes Mode turns the entire 8×8 grid into a MIDI keyboard (sends note-on/off
to the melodic voice, same as SMK25). All pad states (metronome, loop tracks, FX pads,
PC pads) are preserved and fully restored when you exit Notes Mode.

### 1.8 APC Mini v2 Note Map (fill from calibration.scd)

Grid note formula: `note = row × 8 + col` (row 0 = bottom-left)

| Position       | Expected note | Actual (fill in) |
|----------------|---------------|------------------|
| col=0, row=0   | 0             | `__`             |
| col=7, row=7   | 63            | `__`             |

---

## 2. Worlde Easypad 12

12 pads trigger samples. Configure sample files and ADSR at `http://lanth0n.local:5000/worlde`.

### 2.1 Pad Layout (physical)

```
[  9][ 10][ 11][ 12]
[  5][  6][  7][  8]
[  1][  2][  3][  4]
```

### 2.2 Pad Note Map (fill from calibration.scd)

| Pad |Expected note| Actual note | Assigned sample |
|-----|-------------|-------------|-----------------|
|  1  | 36          | `__`        |                 |
|  2  | 37          | `__`        |                 |
|  3  | 38          | `__`        |                 |
|  4  | 39          | `__`        |                 |
|  5  | 40          | `__`        |                 |
|  6  | 41          | `__`        |                 |
|  7  | 42          | `__`        |                 |
|  8  | 43          | `__`        |                 |
|  9  | 44          | `__`        |                 |
| 10  | 45          | `__`        |                 |
| 11  | 46          | `__`        |                 |
| 12  | 47          | `__`        |                 |

---

## 3. M-VAVE SMK 25 (Bluetooth)

The SMK25 is the primary melodic and parameter controller.

### 3.1 Keys & Wheels

| Input           | Behavior                                                   |
|-----------------|------------------------------------------------------------|
| Note on/off     | Triggers/releases `\lanth0nVoice` with active oscillator stack |
| Velocity        | Scales amplitude                                           |
| Pitch Wheel     | ±2 semitones pitch bend on active voices                   |
| Mod Wheel CC 1  | Sweeps filter cutoff (80–18 000 Hz)                        |
| Polyphony       | 8 voices max; oldest note released if exceeded             |

### 3.2 Knob Assignments (default; configurable via web MIDI-learn)

| Knob CC | Default parameter     | Range              |
|---------|-----------------------|--------------------|
| 70      | LPF cutoff            | 80 Hz – 20 kHz     |
| 71      | HPF cutoff            | 20 Hz – 8 kHz      |
| 72      | Global attack         | 1 ms – 4 s         |
| 73      | Global decay          | 1 ms – 4 s         |
| 74      | Global sustain        | 0 – 1              |
| 75      | Global release        | 10 ms – 8 s        |
| 76      | Tempo (TempoClock BPM)| 40 – 240 BPM       |
| 77      | FX wet/dry mix        | 0 – 1              |
| 78      | Delay time            | 10 ms – 1 s        |
| 79      | Delay feedback        | 10 ms – 3 s decay  |
| 80      | Reverb room size      | 0 – 1              |
| 81      | Reverb damping        | 0 – 1              |
| 82      | Distortion drive      | 0 – 1              |

Reassign any knob CC in the web interface: **MIDI Mapping → SMK25 Knob Assignment**.

### 3.3 SMK25 Pads

The SMK25 pads trigger samples exactly like the Worlde pads — velocity-sensitive,
per-pad ADSR. Configure at `http://lanth0n.local:5000/smkpads`.

### 3.4 Bluetooth Pairing (first time)

```bash
bluetoothctl
power on
agent on
scan on
# Wait for "SMK-25" to appear
pair <MAC_ADDRESS>
trust <MAC_ADDRESS>
connect <MAC_ADDRESS>
exit
```

Auto-reconnect: the device watcher in `midi_routing.scd` rescans every 5 seconds
and re-registers handlers when the SMK25 reconnects without any manual step.

---

## 4. Backtrack / VS / Click / Cue

### 4.1 File Naming

Place files in the `media/` directory. Names must match exactly (case-sensitive):

| Type  | Filename format          | Output bus |
|-------|--------------------------|------------|
| VS    | `Song Name (VS).wav`     | FOH (1–2)  |
| Click | `Song Name (click).wav`  | IEM (3–4)  |
| Cue   | `Song Name (Dica).wav`   | IEM (3–4)  |

MP3 files uploaded via the web interface are converted to stereo WAV automatically.

### 4.2 MIDI-Mapped Playback Controls

Configure in the web interface at `http://lanth0n.local:5000/midi`.

| Action    | Controller | Note/CC | Value |
|-----------|------------|---------|-------|
| Play      | `______`   | `___`   | `___` |
| Stop      | `______`   | `___`   | `___` |
| Next Song | `______`   | `___`   | `___` |
| Prev Song | `______`   | `___`   | `___` |

### 4.3 OSC Direct Control

Send UDP OSC to port 57120:

| Message                  | Action                               |
|--------------------------|--------------------------------------|
| `/backtrack/play`        | Start backtrack playback             |
| `/backtrack/stop`        | Stop playback                        |
| `/backtrack/next`        | Next song in setlist                 |
| `/backtrack/prev`        | Previous song in setlist             |
| `/backtrack/load <name>` | Load setlist by name (no extension)  |

---

## 5. OLED Display (SSD1306)

The 0.96″ I2C display shows backtrack state only. Layout:

```
┌──────────────────────────────┐  ← blue region
│ Night 1                      │  Line 1: setlist name
├──────────────────────────────┤
│ Tool                         │  Line 2: artist
│ Sober                        │  Line 3: song name
│ PLAYING  BPM:120             │  Line 4: state + tempo
└──────────────────────────────┘  ← yellow region
```

---

## 6. Web Configuration Interface

URL: `http://lanth0n.local:5000` (or `http://<pi-ip>:5000`)

| Page         | Purpose                                                        |
|--------------|----------------------------------------------------------------|
| Dashboard    | Quick play/stop/prev/next, setlist loader, SC health indicator |
| Files        | Upload VS/click/Dica/sample files (MP3 auto-converted to WAV) |
| Setlists     | Create, edit, reorder, delete setlists (name/artist/BPM/files)|
| MIDI Map     | Assign backtrack control, SMK25 knob MIDI-learn                |
| Routing      | FOH/IEM channel assignment per track type and loop outputs     |
| APC Pads     | 8×8 grid view: configure oscillator per pad in row 0          |
| Worlde Pads  | 2×6 grid: assign sample + ADSR to each of 12 pads             |
| SMK25 Pads   | Grid: assign sample + ADSR to each SMK25 pad                  |
| Programs     | Import/export 12 PC pad snapshots (JSON)                       |

---

## 7. Emergency Commands (sclang interpreter)

```supercollider
~panicStop.()           // Stop all voices, playback, loops, and clock immediately
~stopAllLoops.()        // Stop all 8 loop tracks without stopping everything else
~setBpm.(140)           // Change tempo (updates TempoClock + OLED + metronome)
~tapTempo.()            // Tap 4× to set BPM from tapping interval
~testLEDs.()            // Cycle APC Mini LEDs through all colours
s.avgCPU.postln         // Check audio CPU load
~loadSetlist.("name")   // Load a setlist by filename (no extension)
~btPlay.()              // Start backtrack
~btStop.()              // Stop backtrack
```

---

## 8. Troubleshooting

| Symptom                         | Likely cause & fix                                                 |
|---------------------------------|--------------------------------------------------------------------|
| No audio from FOH               | Check routing in web UI; verify `~mainOutBus = 0`                  |
| Click audible in FOH            | Check `~iemOutBus`; click SynthDef must use `out = 2`              |
| APC LEDs not updating           | `~apcMidiOut` is nil; check USB & reconnect APC Mini               |
| SMK25 not responding            | BT disconnect; reconnect or wait for device watcher (5 s)          |
| Knob has no effect              | Check CC number in web MIDI-learn; default map may differ          |
| Worlde / SMK25 pad silent       | No buffer loaded; assign a sample in web UI                        |
| Loop not quantized              | TempoClock BPM must be set before recording; check OLED BPM        |
| Loop playback out of sync       | Re-record at correct tempo; metronome row shows current position   |
| Backtrack won't play            | File missing or wrong format; check `media/` directory             |
| OLED blank                      | Check I2C: `i2cdetect -y 1`; verify `lanthon-oled` service         |
| Web UI unreachable              | `systemctl status lanth0n-web`; try `http://<ip>:5000`             |
| xruns / audio glitches          | Check `s.avgCPU`; verify CPU governor = performance                |


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

