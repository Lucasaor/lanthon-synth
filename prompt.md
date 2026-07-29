# Prompt: LANTH0N 5YNTH — Live Performance Rig for Raspberry Pi Zero 2W

## Role

You are implementing **LANTH0N 5YNTH**: a headless, real-time performance instrument in SuperCollider, deployed on a Raspberry Pi Zero 2W, for a live power-duo (bass + drums) show. The person you're building this for plays bass separately through a Pi 4 pedalboard rig (out of scope — do not touch); this project is the *synth/percussion/backtrack companion rig* running entirely on the Zero 2W, controlled by three MIDI controllers and a web configuration interface.

**Work in the numbered steps below, in order. Do not skip ahead.** After each step, stop and produce the verification evidence requested (test output, logs, a short written confirmation of what was checked) before proceeding to the next step. The goal is to catch problems on a development machine or via simulated input wherever possible, so the person doesn't have to repeatedly flash/redeploy/reboot the physical Pi to find bugs that could have been caught earlier.

## Hardware

- **Raspberry Pi Zero 2W** — quad-core Cortex-A53 @ 1GHz, 512MB RAM, single micro-USB OTG port (shared via powered USB hub for all peripherals), headless (no display attached during normal operation).
- **SSD1306 OLED Display** — 0.96″ blue/yellow I2C display (128×64 px), connected via I2C bus. Used exclusively to show backtrack/setlist state (current setlist name, song name, artist, and playback state). Driven from a small Python daemon (using `luma.oled` or equivalent) that subscribes to OSC or a Unix socket from sclang.
- **AKAI APC Mini v2** — 8×8 RGB-LED grid (64 pads) + 8 column faders + 1 master fader (9 faders total). The grid is organized as: **Row 8 (top)** = Metronome / loop-length selector (8 pads), **Row 7** = Loop track controls (8 independent loop tracks), **Rows 1–6 / Columns 1–6** = FX Control pads (36 pads), **Rows 1–6 / Columns 7–8** = Program Change pads (12 pads). Faders 1–8 control individual loop track volumes; fader 9 (master) controls the backtrack (VS) volume. The APC Mini v2 also has a **Notes Mode** (Shift + Notes on the hardware) in which the grid sends MIDI notes directly instead of pad-function messages — the system must gracefully handle mode transitions.
- **Worlde Easypad 12** — 12 pads. Each pad triggers a **sample** with velocity sensitivity and configurable ADSR envelopes. Sample assignments are configured via the web interface.
- **M-VAVE SMK 25** — 25-key MIDI keyboard connected via **Bluetooth MIDI** (not USB). Used as the melodic voice/lead input.
- **USB audio interface** — class-compliant, assumed to expose at least **4 output channels**: channels 1–2 = FOH (main mix), channels 3–4 = IEM (monitor mix). Backtracks and synth go to FOH; click and cue (Dica) tracks go to IEM only. Exact channel assignment is configurable via the web interface.

## Non-negotiable technical constraints

1. **No Sonic Pi.** Use `sclang`/`scsynth` directly.
2. **Headless operation.** No GUI, no SuperCollider IDE dependency at runtime. Must autostart on boot via `systemd` and require no keyboard/monitor/mouse on stage.
3. **Low, consistent latency is the top priority**, ahead of feature richness. Prefer simple, cheap SynthDefs over elaborate per-voice effects; put heavier effects (reverb, LPF, HPF, etc.) on shared buses, not per-voice, to protect headroom.
4. **~8 voices of simultaneous polyphony** must be sustainable without xruns.
5. **Multiple MIDI controllers must coexist without collisions.** Filter every `MIDIdef`/`MIDIFunc` by the sending device's `srcID`. Never assume note/CC numbers are globally unique across devices.
6. **All synth timing must derive from one shared `TempoClock`.** The tempo is set from the active song's metadata in the setlist — not inferred from audio files.
7. **CPU governor must be set to `performance`** as part of the deployment script, not a manual step.
8. **No controller should crash the system when offline.** All MIDI handlers must be guarded so the system boots and runs fully if any or all controllers are absent. Hot-plug detection should re-register handlers when a controller reconnects (including Bluetooth reconnect for SMK25). Log a warning, never throw an unhandled exception.
9. **RAM preservation is mandatory.** The Pi Zero 2W has 512 MB shared with the GPU. All backtrack audio files must be streamed from disk (never fully loaded into RAM). The web configuration interface must run in a low-footprint mode and must not allocate audio buffers or hold large files in memory. Prefer disk-backed streaming for all media.
10. **The web configuration interface is a management tool, not a performance tool.** It runs as a separate lightweight process; its load must not degrade audio performance. It may be stopped during performance if CPU pressure demands it.

## Architecture overview

### Audio engine (SuperCollider)
- **Oscillator/SynthDef library**: six selectable waveforms (square, saw, supersaw, sine, TB-303 style, WhiteNoise), each implemented as a cheap `SynthDef`. Per-waveform octave-up and octave-down doublers are additive layers, not separate synths — they are mixed internally when active.
- **Effect chain** (shared buses, not per-voice): Distortion → Delay → Reverb → LPF → HPF. Each stage is an `Ndef` or `Bus`-routed `SynthDef` that can be toggled on/off. Effect parameters (reverb room size, delay time/frequency, LPF/HPF cutoff, drive, etc.) are controlled exclusively via SMK25 knobs — not via faders.
- **Loop recording engine**: up to 8 independent loop tracks, each corresponding to one pad in Row 7 of the APC Mini. Loops record in real time from the synth/sample output bus, quantized to bar-set boundaries driven by the shared `TempoClock`. (`src/loops.scd`)
- **Percussion/sample engine**: Worlde Easypad 12 pads and SMK25 pads both trigger one-shot `Buffer`-backed sample playback synths, with per-pad velocity scaling and ADSR parameters loaded from the config file.
- **SMK25 (Bluetooth)**: note-on/off drives the active oscillator stack (whichever Row 1 waveform pads are active). Pitch Wheel = pitch bend; Mod Wheel (CC 1) = filter cutoff. Knobs map to LPF, HPF, global ADSR, tempo, FX mix, and per-effect parameters — all assignments configurable via web interface MIDI-learn.

### Backtrack player
- A separate `sclang` routine (or a lightweight Python process communicating via OSC) handles streaming playback of MP3 files from disk using `DiskIn` / `VDiskIn` UGens (or equivalent disk-streaming approach).
- **File naming convention** per song: `<song name> (VS).mp3` (main backtrack → FOH), `<song name> (click).mp3` (click → IEM), `<song name> (Dica).mp3` (cue → IEM).
- **Setlist** is a JSON file listing songs in order, each with: `name`, `artist`, `tempo` (BPM), and optionally file paths. The active setlist is loaded at runtime; the `TempoClock` is updated to the song's BPM when a song is selected.
- **Output routing** is configurable: VS → FOH bus, click/Dica → IEM bus. Routing table is stored in the config file and editable via the web interface.
- **Playback MIDI mapping**: play, stop, next song, and previous song are assignable to any note/CC on any controller, configured via the web interface.

### AKAI APC Mini v2 grid layout

The 8×8 grid is addressed row 1 (bottom) to row 8 (top), column 1 (left) to column 8 (right).

**Row 8 (top) — Metronome / Loop-length selector (8 pads):**
- The entire row displays dim yellow as a background.
- A single "rolling" light-blue pad advances left to right, one step per beat, tracking the current position within the bar set. The first pad (column 1) blinks brighter at bar-set start; the pad at the current loop-length index blinks brighter at bar-set end.
- **Pressing a pad sets the loop length**: pad 1 = 1 bar (4 beats), pad 2 = 2 bars (8 beats), …, pad 8 = 8 bars (32 beats).
- If loops are running when the length changes: **increase** → existing patterns repeat to fill the added bars; **decrease** → patterns truncate to fit.

**Row 7 — Loop track controls (8 loop tracks):**
Each pad represents one independent loop track (tracks 1–8, corresponding to faders 1–8).

- **Empty** (off): press → start recording from the next bar-set downbeat. Pad blinks amber while waiting, then blinks red while recording. When the recording ends, the pad turns green and the loop plays back continuously.
- **Playing** (green): press → stop playback but keep the recording; pad turns yellow.
- **Paused** (yellow): press → resume playback; pad turns green.
- **Overdub / re-record**: hold a pad that has a recording for 2 seconds → new recording starts at the next bar-set downbeat; old recording is replaced when the new one completes.

**Rows 1–6, Columns 1–6 — FX Control pads (36 pads total):**
Each row in columns 1–6 maps to one FX/oscillator function.

| Row | Function |
|-----|----------|
| 1 (bottom) | Oscillator / noise / wavetable selection (square, saw, supersaw, sine, TB-303, WhiteNoise — one waveform per pad, configured via the web interface) |
| 2 | Octave down (doubles the active oscillator one octave below) |
| 3 | Octave up (doubles the active oscillator one octave above) |
| 4 | Distortion |
| 5 | Delay |
| 6 | Reverb |

- **Idle / configured**: yellow LED.
- **Active (pressed = on)**: green LED. Press again to deactivate → returns to yellow.
- **Unconfigured pad**: off.

Effect parameters (reverb room size, delay time/frequency, LPF/HPF cutoff, drive, etc.) are controlled exclusively via SMK25 knobs — not via faders.

**Rows 1–6, Columns 7–8 — Program Change pads (12 pads total):**
Each pad stores a full snapshot of the 36 FX Control pad states (which pads are on/off).

- **Saved but inactive**: purple LED.
- **Currently active**: blue LED. Goes back to purple when another PC pad is activated.
- **Unsaved / empty**: off.
- **Save gesture**: hold pad for 2 seconds → pad blinks blue for 1 second → snapshot saved. Overwrites any previous snapshot at that position. Only one PC pad is active at a time.

**APC Mini v2 Notes Mode:**
Activated on the hardware by pressing Shift + Notes. While active, the grid sends MIDI notes instead of pad-function messages — routed to the melodic voice (same as SMK25). All pad LED states (metronome row, loop track row, FX pads, PC pads) and all snapshots must be fully preserved and restored when the controller exits Notes Mode.

### APC Mini faders

The APC Mini v2 has 8 column faders (faders 1–8) and 1 master fader (fader 9).

| Fader | Function |
|-------|----------|
| 1 | Loop track 1 volume |
| 2 | Loop track 2 volume |
| 3 | Loop track 3 volume |
| 4 | Loop track 4 volume |
| 5 | Loop track 5 volume |
| 6 | Loop track 6 volume |
| 7 | Loop track 7 volume |
| 8 | Loop track 8 volume |
| 9 (master) | Backtrack (VS) volume |

There is no parameter-edit mode via faders. All effect parameters (LPF cutoff, HPF cutoff, reverb room size, delay time/frequency, drive, etc.) are controlled exclusively by the SMK25 knobs.

### Worlde Easypad 12
- Each pad triggers a sample file assigned via the web interface.
- Velocity scales amplitude.
- Per-pad ADSR is configurable via the web interface.
- Pads must handle rapid overlapping hits without voice-stealing artifacts.

### SMK25 (Bluetooth MIDI)
The SMK25 connects exclusively via Bluetooth MIDI (no USB). It is the primary source of melodic note input and real-time parameter control.

- **25 keys**: note-on/off drives the active oscillator stack (whichever Row 1 waveform pads are currently active). Pitch, velocity, and the full shared effect chain apply.
- **Pitch Wheel**: standard pitch bend / detune applied to all active oscillator voices.
- **Mod Wheel (CC 1)**: maps to filter cutoff in real time.
- **Knobs**: each knob CC maps to one engine parameter. Default assignments:

| Knob | Default parameter |
|------|-------------------|
| 1 | LPF cutoff frequency |
| 2 | HPF cutoff frequency |
| 3 | Global attack |
| 4 | Global decay |
| 5 | Global sustain |
| 6 | Global release |
| 7 | Tempo (TempoClock BPM) |
| 8 | FX wet/dry mix |
| 9+ | Per-effect parameters (reverb room size, delay time/frequency, etc.) |

All knob assignments are configurable via the web interface MIDI-learn panel. The table above is the factory default and can be fully reassigned.

- **Pads**: trigger sample playback exactly as Worlde Easypad 12 pads — velocity-sensitive, per-pad ADSR, disk-streaming playback. Pad-to-sample assignments are configured via the web interface.

Handle Bluetooth reconnect gracefully: on disconnect, log a warning and automatically re-register all handlers on reconnect without manual intervention.

### Web configuration interface
A **SvelteKit** web application (SvelteKit is a good fit here: lightweight, SSR-optional, minimal runtime overhead, easy to run as a Node.js service). It must be accessible from the local network and provides:

1. **File upload**: upload VS/click/Dica MP3 files and sample files to the Pi's local storage.
2. **Setlist manager**: create, edit, reorder, load, and delete setlists. Each song entry has: name, artist, tempo (BPM), and paths to its VS/click/Dica files.
3. **MIDI mapping**: assign any note/CC on any controller to: play, stop, next song, previous song, and other assignable functions. Displays detected controllers, allows learn-mode mapping. Includes a **SMK25 knob assignment** panel where each SMK25 knob CC can be MIDI-learned to any engine parameter (LPF cutoff, HPF cutoff, attack, decay, sustain, release, reverb room size, delay time/frequency, FX mix, tempo, etc.).
4. **Output routing**: configure which audio channels receive VS, click, Dica, synth, and loop track outputs (FOH vs IEM).
5. **APC Mini pad configuration**: an 8×8 grid UI. Row 1 allows configuring the oscillator waveform per pad; rows 2–6 show fixed function labels; rows 7–8 show loop track and metronome status (read-only in this view).
6. **Worlde pad configuration**: a 2×6 grid UI for assigning sample files and ADSR parameters to each of the 12 Worlde pads.
7. **SMK25 pad configuration**: a grid UI for assigning sample files and ADSR parameters to each SMK25 pad, same style as the Worlde pad configuration.
8. **Program Change import/export**: download or upload PC pad snapshot JSON files for backup or sharing (12 slots).

The web interface runs as a separate `systemd` service. It communicates with the SuperCollider engine via OSC (or a Unix socket). It must not hold audio buffers in memory.

### OLED display (SSD1306)
A small Python daemon (driven by `luma.oled`) renders to the 128×64 display over I2C. It subscribes to OSC messages from the sclang backtrack engine and displays:
- Line 1: Setlist name
- Line 2: Artist name
- Line 3: Song name
- Line 4: Playback state (STOP / PLAYING / …) + current BPM

All backtrack-related state changes must immediately push an OSC update to the OLED daemon. No other system state (synth voices, FX pads) is shown on the OLED — it is exclusively a backtrack monitor.

### Shared clock
A single `TempoClock` instance is the authoritative timing source for all synth quantization. Its tempo is updated whenever a new song is selected from the setlist (using the song's configured BPM). The clock is never derived from audio content.

---

## Implementation steps (do these in order; each has a stop-and-verify checkpoint)

### Step 0 — MIDI discovery & calibration tool
Write a standalone sclang script that enumerates all connected MIDI devices (USB and Bluetooth), prints each device's `uid`/`srcID`, and logs every incoming note/CC message with its source. Note that the SMK25 connects via **Bluetooth MIDI** — the script must handle BT MIDI devices appearing on different source IDs than USB devices. The script must not crash if a device is absent; it must simply log which devices were not found.

Capture real note/CC numbers for all three controllers and record them in `CONTROLS.md`.

**Verify:** run against real hardware (or virtual MIDI ports with simulated input). Confirm the log clearly disambiguates all three devices by `srcID`, BT device is identified, and the script runs cleanly with one or more controllers unplugged.

---

### Step 1 — Core audio engine & SynthDef library (no MIDI yet)
Implement all SynthDefs:
- **Oscillators**: `\sq` (square), `\saw`, `\supersaw`, `\sine`, `\tb303`, `\wnoise`. All share the same argument interface (`freq`, `amp`, `gate`, `attack`, `sustain`, `release`, `cutoff`).
- **Effect chain nodes**: distortion, delay, reverb, LPF, HPF — each as a bus-routed SynthDef that can be instantiated/freed independently.
- **Percussion/sample voice**: a one-shot `DiskIn`-backed sample player with velocity scaling and ADSR.
- **Click voice**: a short sine-burst, routed only to the IEM bus, never FOH.

Keep all SynthDefs cheap. No per-voice reverb — reverb is always on the shared bus.

**Verify:** trigger each SynthDef manually via `Synth(...)` calls. Check `s.avgCPU` / `s.peakCPU` with ~8 simultaneous voices. Log the numbers. Confirm no xruns.

---

### Step 2 — MIDI routing skeleton (offline-resilient)
Implement `MIDIdef`/`MIDIFunc` handlers filtered by `srcID` for all three controllers (APC Mini, Worlde Easypad, SMK25 via BT), plus a MIDI device watcher that:
- Catches `MIDIClient` connect/disconnect notifications.
- Re-registers handlers when a device reconnects (including Bluetooth reconnect for SMK25).
- Logs a warning (never throws) when a message arrives from an unrecognised device.
- Logs a warning (never throws) on startup if an expected device is absent.

At this step, handlers only log received messages — no audio or state changes yet.

**Verify:** exercise each controller or simulated input. Confirm messages are attributed to the correct device with no cross-talk. Unplug and replug each controller and confirm handlers re-register. Confirm system runs cleanly with zero controllers attached.

---

### Step 3 — I2C OLED display daemon
Write a Python daemon (`oled_daemon.py`) using `luma.oled` (SSD1306 driver) that:
- Listens on a UDP OSC port for display-update messages from sclang.
- Renders the four-line backtrack display (setlist / artist / song / state+BPM) in a clear, readable font.
- Handles I2C bus unavailability gracefully (log error and continue — do not crash sclang if the display is disconnected).
- Runs as its own `systemd` service.

**Verify:** on a dev machine (with a real or emulated I2C display), send test OSC messages and confirm correct rendering. Test with display unplugged — confirm no crash propagates.

---

### Step 4 — Backtrack engine (disk-streaming, setlist, routing)
Implement the backtrack player:
- Loads a setlist JSON file (`setlists/<name>.json`) containing an ordered array of songs, each with `name`, `artist`, `tempo` (BPM), and optionally `vs`, `click`, `dica` file paths.
- Streams VS/click/Dica MP3 files from disk using `VDiskIn` (or `DiskIn` with appropriate buffer sizing). **Never load the full file into RAM.**
- Routes VS → FOH bus, click/Dica → IEM bus. Routing is read from the config file at startup.
- Exposes OSC commands: `/backtrack/play`, `/backtrack/stop`, `/backtrack/next`, `/backtrack/prev`, `/backtrack/load <setlist_name>`. These OSC commands are also the targets for MIDI-mapped controls.
- On song selection, updates the shared `TempoClock` to the song's BPM and sends an OSC update to the OLED daemon.
- When a file is missing for a song, log a warning and continue — do not crash or halt playback of other channels.

**Verify:** load a test setlist with real MP3 files. Confirm disk-streaming playback with no full-file RAM load (check `s.avgCPU` and system `free` memory). Confirm next/prev navigation, tempo clock update, and OLED update. Test with a missing file — confirm graceful warning.

---

### Step 5 — APC Mini FX pad engine + LED feedback
Implement the FX pad state machine for rows 1–6, columns 1–6 (36 pads total):
- Maintain a 6×6 state matrix tracking: `\off`, `\idle` (configured/yellow), `\active` (green).
- On pad press: toggle `\idle` ↔ `\active`; apply or remove the corresponding oscillator/effect layer in the audio engine.
- LED feedback: send MIDI note-on messages back to the APC Mini v2 with the correct velocity color codes (yellow = idle, green = active, off = unconfigured). Use the documented APC Mini v2 color code table — do not guess velocity values.
- There is no per-pad parameter-edit mode via faders; effect parameters are controlled exclusively via SMK25 knobs.

**Verify:** exercise all 36 FX pads, confirm correct LED transitions (yellow ↔ green ↔ off). Confirm oscillator/effect layers activate and deactivate correctly in the audio engine. Confirm state is preserved across pad cycles. Confirm faders 1–8 control loop track volumes. Confirm system runs without crash when APC Mini is offline.

---

### Step 5b — APC Mini Metronome row + Loop recording engine
Implement the metronome row (Row 8), loop track row (Row 7), and loop recording engine (`src/loops.scd`):

**Metronome row (Row 8):**
- At startup, light all 8 pads dim yellow.
- Run a `TempoClock`-quantized routine that advances a single light-blue "rolling pad" left to right, one step per beat. The pad at column 1 blinks brighter at bar-set start; the pad at the current loop-length index blinks brighter at bar-set end.
- **Press a pad**: set the loop length to that pad's index (1–8) in bars (e.g., pad 2 = 2 bars = 8 beats). If loops are running: length increase → repeat patterns to fill added bars; length decrease → truncate patterns to fit.

**Loop track row (Row 7):**
- Maintain an 8-element state array per pad: `\empty` (off), `\waiting` (amber blink), `\recording` (red blink), `\playing` (green), `\paused` (yellow).
- **Press empty pad**: transition to `\waiting` until the next bar-set downbeat, then `\recording` for exactly one bar set, then `\playing`.
- **Press playing pad**: stop playback → `\paused` (recording preserved).
- **Press paused pad**: resume → `\playing`.
- **Hold pad with recording for 2 seconds**: transition to `\waiting` (overdub), then `\recording` on the next bar-set downbeat; new take replaces old on completion.
- Faders 1–8 control loop track volumes 1–8 in real time.

All loop boundaries are strictly quantized to bar-set downbeats from the shared `TempoClock`. Never allow loop drift.

**Verify:** record a 2-bar loop; confirm playback in sync with the metronome row LED. Increase loop length (confirm repeat) and decrease (confirm truncation). Pause and resume. Overdub and confirm old take is replaced. Confirm faders 1–8 affect only their respective track volumes. Confirm all LED transitions match the spec. Confirm no crash when APC Mini is offline.

---

### Step 6 — APC Mini Program Change system
Implement the PC pad state machine (rows 1–6, columns 7–8 — 12 pads total):
- Maintain a 6×2 state matrix tracking: `\empty` (off), `\saved` (purple), `\active` (blue).
- On pad press: load the saved snapshot onto the FX Control pad matrix, re-render all 36 FX LED states, and update the audio engine to match.
- **Save gesture**: 2-second hold → blink blue for 1 second → save current FX pad matrix as snapshot at this position. Overwrites previous snapshot if present. If pad was empty, it becomes `\saved`.
- Snapshots are persisted to a JSON config file immediately on save.
- Only one PC pad can be `\active` at a time; pressing a new PC pad deactivates the previous one.

**Verify:** save snapshots to two PC pads, switch between them, confirm FX pad states and LEDs update correctly. Confirm snapshots survive a system restart (reload from JSON). Confirm save gesture correctly overwrites.

---

### Step 7 — APC Mini v2 Notes Mode
Detect when the APC Mini v2 switches to Notes Mode (Shift + Notes on the hardware):
- Detect the mode-toggle message and set an internal flag `apcNotesMode = true`.
- While in Notes Mode, route grid note messages to the melodic voice (same pitch/velocity handling as SMK25) instead of FX pad logic.
- On exit from Notes Mode: restore all 64 pad LEDs to exactly the state they were in before Notes Mode was entered — metronome row (row 8), loop track row (row 7), FX pads (rows 1–6, cols 1–6), and PC pads (rows 1–6, cols 7–8).
- Do not alter any pad state (loop recordings, FX active states, PC snapshots) while in Notes Mode.

**Verify:** enter Notes Mode, play notes, confirm melodic voice triggers. Exit Notes Mode, confirm all LED states are exactly restored including metronome and loop rows.

---

### Step 8 — SMK25 (Bluetooth) → melodic voice, knobs, and pads
Wire all SMK25 Bluetooth MIDI inputs:
- **Keys (note-on/off)**: trigger/release the active oscillator stack (whichever Row 1 waveform pads are active). Pitch, velocity, and the full effect chain apply.
- **Pitch Wheel**: standard pitch bend on all active voices.
- **Mod Wheel (CC 1)**: maps to filter cutoff in real time.
- **Knobs**: dispatch each knob CC to its assigned engine parameter (per MIDI-learn config). Default: knob 1 = LPF cutoff, knob 2 = HPF cutoff, knobs 3–6 = attack/decay/sustain/release, knob 7 = TempoClock BPM, knob 8 = FX wet/dry mix, additional knobs = per-effect parameters.
- **Pads**: trigger sample playback (velocity-sensitive, per-pad ADSR, disk-streaming) identical to Worlde Easypad 12 pads. Assignments loaded from config.

Handle Bluetooth reconnect gracefully: log a warning on disconnect and automatically re-register all handlers on reconnect.

**Verify:** play notes, confirm pitch/velocity and clean note-off. Move pitch wheel — confirm bend. Move mod wheel — confirm cutoff change. Move each knob — confirm corresponding parameter responds. Trigger SMK25 pads — confirm sample playback with velocity/ADSR. Simulate BT disconnect/reconnect — confirm automatic re-registration. Log any dropped note-offs.

---

### Step 9 — Worlde Easypad 12 + SMK25 pads → sample playback
Wire each of the 12 Worlde pads and each SMK25 pad to its configured sample file (assigned via web config). Both controllers use the same disk-streaming playback path (`VDiskIn` or `Buffer.readChannel` with appropriate size) and the same per-pad ADSR and velocity scaling from the config.

Pads from both controllers must handle rapid overlapping hits without voice-stealing (up to 4 simultaneous voices per pad).

**Verify:** trigger all 12 Worlde pads and all SMK25 pads individually and in rapid overlapping succession. Confirm velocity response, ADSR shaping, no voice-stealing clicks. Confirm with a missing sample file — log warning, do not crash.

---

### Step 10 — Backtrack MIDI control mapping
Load the MIDI-to-backtrack mapping from the config file (populated via the web interface). Each of play, stop, next, prev is mapped to a `(controller, note/CC, value)` tuple.

Re-use the offline-resilient MIDI routing from Step 2 — if the mapped controller is offline, the function simply does not fire (no crash).

**Verify:** assign test mappings for all four functions. Trigger each and confirm correct backtrack engine response. Test with the mapped controller offline — confirm no crash.

---

### Step 11 — Shared clock + tempo sync
Confirm the single `TempoClock` is the authoritative source for all synth quantization. Its BPM is set only from the active song's `tempo` field in the setlist — never from audio content analysis.

When a song is selected, update `TempoClock.tempo`, push the update to the OLED daemon, and confirm no drift between synth timing and the new tempo setting over an extended run.

**Verify:** set two songs with different BPMs, switch between them, confirm `TempoClock` updates immediately and the click voice (IEM-only) matches. Confirm click does not bleed to FOH bus. Run for 5+ minutes, confirm no drift.

---

### Step 12 — Web configuration interface (SvelteKit)
Implement the SvelteKit web app as described in the Architecture section. The app runs as a Node.js process on a port accessible from the local network (e.g., `http://lanth0n.local:5000`). It communicates with the SuperCollider engine via OSC.

Required pages:
1. **Files** — upload VS/click/Dica MP3 files and sample files. Files are saved to a dedicated directory on the Pi's storage; no file content is kept in process memory after the upload stream completes.
2. **Setlists** — create, edit, reorder, load, and delete setlists. Each song: name, artist, BPM, file assignments.
3. **MIDI Mapping** — learn-mode assignment for play/stop/next/prev and other assignable functions. Includes **SMK25 knob assignment** panel: MIDI-learn each knob CC to any engine parameter (LPF, HPF, attack, decay, sustain, release, reverb room size, delay time/frequency, FX mix, tempo, etc.).
4. **Output Routing** — channel assignment for VS, click, Dica, synth, and loop track outputs (FOH/IEM/both).
5. **APC Mini Pads** — 8×8 grid UI; configure oscillator waveform per pad in Row 1; rows 2–6 show fixed function labels; rows 7–8 show loop track and metronome status (read-only).
6. **Worlde Pads** — 2×6 grid UI; assign sample file and ADSR per pad.
7. **SMK25 Pads** — grid UI; assign sample file and ADSR per SMK25 pad.
8. **Program Change** — list of 12 PC pad slots with import/export (JSON) per slot.

**Verify:** access the interface from a second device on the local network. Upload a test file, create a setlist, save a MIDI mapping. Confirm the SuperCollider engine receives and applies each change via OSC. Confirm system `free` memory does not decrease significantly while the interface is in use.

---

### Step 13 — Headless boot & performance tuning
Package everything into `systemd` services:
- `lanth0n-synth.service` — starts JACK (or chosen audio backend) then `sclang` with the full patch.
- `lanth0n-oled.service` — starts the Python OLED daemon.
- `lanth0n-web.service` — starts the SvelteKit web config interface.

The deployment script (`deploy/setup.sh`) must:
- Set CPU governor to `performance` (persistent across reboots via `/etc/rc.local` or `cpufrequtils`).
- Enable I2C on the Pi.
- Install all dependencies (SuperCollider, Python packages, Node.js, SvelteKit build).
- Enable and start all three `systemd` services.
- Require zero manual steps after running the script on a fresh Raspberry Pi OS install.

**Verify:** power-cycle the Pi. Confirm all three services start automatically, the OLED displays the default state, and the synth is playable — all with no attached display, keyboard, or manual intervention.

---

### Step 14 — Integration / stage rehearsal checklist
Run a full end-to-end rehearsal: all three controllers connected (APC Mini USB, Worlde USB, SMK25 Bluetooth), backtrack playback running, ~8 synth voices, web interface open on a second device, for 20+ continuous minutes.

Monitor and log: `s.avgCPU`, `s.peakCPU`, JACK xrun count, system RAM (`free -m`), and any error/warning messages in the sclang post window log.

**Verify:** produce a report in `TEST_LOG.md` covering CPU load range, xrun count, RAM usage, and a statement confirming zero audible glitches were observed.

---

## Testing strategy (to minimize physical back-and-forth on the Pi)

- **Develop and validate on a host machine first wherever possible.** SuperCollider SynthDefs, MIDI routing logic, backtrack engine, and OLED OSC protocol are all portable — write and test on a desktop/laptop before deploying to the Pi.
- **Write automated tests, not just listening checks.** For every step, write sclang test routines (and Python unit tests for the OLED daemon and web backend) that assert on state — e.g., verify an FX pad's state variable after a simulated button press, verify the `TempoClock` BPM after a song selection, verify OSC messages are emitted with correct arguments. Log all test results to a file.
- **Simulate MIDI input when hardware is absent.** Use a virtual MIDI port (IAC Driver on macOS, ALSA loopback on Linux). Write a small simulation script that injects note/CC/program-change messages with the correct `srcID`-equivalent, covering normal operation and offline/reconnect scenarios.
- **Test the offline-resilience requirement at every step from Step 2 onward.** Before marking any step as complete, explicitly test with each controller absent and confirm the system does not crash.
- **Test disk-streaming under memory pressure.** Before deploying to the Pi, simulate 512 MB RAM by constraining the test process and confirm no file is fully loaded into RAM.
- **Monitor CPU/xrun health quantitatively from Step 1 onward.** Log `s.avgCPU`, `s.peakCPU`, and xrun counts at each step. Regressions must be caught before they compound into on-stage failures.
- **Only Steps 13 and 14 strictly require the physical Pi.** All earlier steps must pass on the dev machine first.
- **Commit to git after every step** with a message referencing the step number.

## Deliverables expected

1. **Source code**, organized by concern:
   - `src/synths.scd` — all SynthDefs
   - `src/midi_routing.scd` — offline-resilient MIDI handler registration and device watcher
   - `src/apc_leds.scd` — APC Mini LED state machine and color code table
   - `src/apc_pads.scd` — FX pad and Program Change pad logic
   - `src/loops.scd` — loop recording engine (metronome row, loop track controls, quantized record/playback/overdub)
   - `src/backtrack.scd` — backtrack engine (disk streaming, setlist, routing, OSC commands)
   - `src/clock.scd` — shared `TempoClock` management
   - `src/main.scd` — top-level boot, service orchestration, OSC server
   - `src/calibration.scd` — Step 0 MIDI discovery tool
   - `oled_daemon.py` — I2C OLED display daemon
   - `web/` — SvelteKit web configuration interface

2. **`CONTROLS.md`** — authoritative note/CC/srcID mapping for all three controllers, populated from real or simulated captured data (not assumptions); also serves as the user manual explaining how to operate LANTH0N 5YNTH in a live context.

3. **`DEPLOY.md`** — exact steps (or a fully automated script) to go from a fresh Raspberry Pi OS install to a fully working headless boot, including all three `systemd` services, I2C enablement, CPU governor, and Bluetooth MIDI pairing instructions for the SMK25.

4. **`TEST_LOG.md`** — verification evidence from each step, including CPU/RAM/xrun numbers and automated test results.

5. **Brief inline comments** explaining non-obvious timing/latency/RAM decisions, since these are the parts most likely to need revisiting later.