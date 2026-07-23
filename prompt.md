# Prompt: LANTH0N 5YNTH — Live Performance Rig for Raspberry Pi Zero 2W

## Role

You are implementing **LANTH0N 5YNTH**: a headless, real-time performance instrument in SuperCollider, deployed on a Raspberry Pi Zero 2W, for a live power-duo (bass + drums) show. The person you're building this for plays bass separately through a Pi 4 pedalboard rig (out of scope — do not touch); this project is the *synth/percussion/backtrack companion rig* running entirely on the Zero 2W, controlled by three MIDI controllers and a web configuration interface.

**Work in the numbered steps below, in order. Do not skip ahead.** After each step, stop and produce the verification evidence requested (test output, logs, a short written confirmation of what was checked) before proceeding to the next step. The goal is to catch problems on a development machine or via simulated input wherever possible, so the person doesn't have to repeatedly flash/redeploy/reboot the physical Pi to find bugs that could have been caught earlier.

## Hardware

- **Raspberry Pi Zero 2W** — quad-core Cortex-A53 @ 1GHz, 512MB RAM, single micro-USB OTG port (shared via powered USB hub for all peripherals), headless (no display attached during normal operation).
- **SSD1306 OLED Display** — 0.96″ blue/yellow I2C display (128×64 px), connected via I2C bus. Used exclusively to show backtrack/setlist state (current setlist name, song name, artist, and playback state). Driven from a small Python daemon (using `luma.oled` or equivalent) that subscribes to OSC or a Unix socket from sclang.
- **AKAI APC Mini** — 8x8 RGB-LED grid (64 pads) + 9 vertical faders + top/side control row. The grid is split into **FX Control pads** (columns 1–6, 48 pads) and **Program Change pads** (columns 7–8, 16 pads). Faders control synth/backtrack parameters. The APC Mini also has a **Notes Mode** in which the grid plays MIDI notes directly instead of triggering pad functions — the system must gracefully handle mode transitions.
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
- **Effect chain** (shared buses, not per-voice): Distortion → Envelope shaper → Reverb → LPF → HPF. Each stage is an `Ndef` or `Bus`-routed `SynthDef` that can be toggled on/off.
- **Percussion/sample engine**: Worlde Easypad 12 triggers one-shot `Buffer`-backed sample playback synths, with per-pad velocity scaling and ADSR parameters loaded from the config file.
- **SMK25 (Bluetooth)**: note-on/off drives the active oscillator stack (whichever waveform pads are currently "on" in the APC Mini FX grid). Pitch and velocity route through the full effect chain.

### Backtrack player
- A separate `sclang` routine (or a lightweight Python process communicating via OSC) handles streaming playback of MP3 files from disk using `DiskIn` / `VDiskIn` UGens (or equivalent disk-streaming approach).
- **File naming convention** per song: `<song name> (VS).mp3` (main backtrack → FOH), `<song name> (click).mp3` (click → IEM), `<song name> (Dica).mp3` (cue → IEM).
- **Setlist** is a JSON file listing songs in order, each with: `name`, `artist`, `tempo` (BPM), and optionally file paths. The active setlist is loaded at runtime; the `TempoClock` is updated to the song's BPM when a song is selected.
- **Output routing** is configurable: VS → FOH bus, click/Dica → IEM bus. Routing table is stored in the config file and editable via the web interface.
- **Playback MIDI mapping**: play, stop, next song, and previous song are assignable to any note/CC on any controller, configured via the web interface.

### AKAI APC Mini grid layout

The 8×8 grid is addressed row 1 (bottom) to row 8 (top), column 1 (left) to column 8 (right).

**Columns 1–6 — FX Control pads (48 pads total):**
Each row in columns 1–6 maps to one FX/oscillator function. Within a row, up to 6 independent instances or variants can be active simultaneously (e.g., multiple oscillator waveforms, multiple distortion flavors — exact per-pad assignment is configured via the web interface).

| Row | Function |
|-----|----------|
| 1 (bottom) | Oscillator / noise / wavetable selection (square, saw, supersaw, sine, TB-303, WhiteNoise — one waveform per pad) |
| 2 | Octave down (doubles the active oscillator one octave below) |
| 3 | Octave up (doubles the active oscillator one octave above) |
| 4 | Distortion |
| 5 | Envelope shaper |
| 6 | Reverb |
| 7 | LPF |
| 8 (top) | HPF |

- **Idle / configured**: yellow LED.
- **Active (pressed = on)**: green LED. Press again to deactivate → returns to yellow.
- **Unconfigured pad**: off.

**Columns 7–8 — Program Change pads (16 pads total):**
Each pad stores a full snapshot of the 48 FX Control pad states (which pads are on/off and their parameter values).

- **Saved but inactive**: purple LED.
- **Currently active**: blue LED. Goes back to purple when another PC pad is activated.
- **Unsaved / empty**: off.
- **Save gesture**: hold pad for 2 seconds → pad blinks blue for 1 second → snapshot saved. Overwrites any previous snapshot at that position.

**Parameter edit mode (per FX pad):**
Hold any active FX Control pad for 2 seconds → pad starts blinking green. While blinking, faders 1–6 control that effect's parameters (e.g., room size, mix, cutoff, tone, drive — whichever are relevant to that effect). When the pad is pressed again, parameters are saved and the pad returns to steady green/yellow.

**APC Mini Notes Mode:**
When the APC Mini is switched to its hardware Notes Mode, the grid sends MIDI notes instead of pad-function messages. The system must detect this (via the mode toggle message or by recognizing the note range) and pass those notes through to the melodic voice instead of treating them as FX pad events. All pad LED states and Program Change snapshots must be fully preserved and restored when the controller exits Notes Mode.

### APC Mini faders

The APC Mini has 8 column faders (faders 1–8) and 1 master fader (fader 9).

**Normal mode (no pad in parameter-edit mode):**

| Fader | Function |
|-------|----------|
| 1 | Synth volume |
| 2 | Filter cutoff |
| 3 | Dry/Wet mix of the active oscillator stack |
| 4 | Global attack |
| 5 | Global sustain |
| 6 | Global release |
| 7 | Backtracks (VS) volume |
| 8 | Click track volume |
| 9 (master) | Cue (Dica) track volume |

**Parameter-edit mode:** faders 1–6 are remapped to the held effect's parameters (see above). Faders 7–9 continue to control backtrack/click/cue volumes uninterrupted.

### Worlde Easypad 12
- Each pad triggers a sample file assigned via the web interface.
- Velocity scales amplitude.
- Per-pad ADSR is configurable via the web interface.
- Pads must handle rapid overlapping hits without voice-stealing artifacts.

### Web configuration interface
A **SvelteKit** web application (SvelteKit is a good fit here: lightweight, SSR-optional, minimal runtime overhead, easy to run as a Node.js service). It must be accessible from the local network and provides:

1. **File upload**: upload VS/click/Dica MP3 files and sample files to the Pi's local storage.
2. **Setlist manager**: create, edit, reorder, load, and delete setlists. Each song entry has: name, artist, tempo (BPM), and paths to its VS/click/Dica files.
3. **MIDI mapping**: assign any note/CC on any controller to: play, stop, next song, previous song, and any other assignable functions. Displays detected controllers and allows learn-mode mapping.
4. **Output routing**: configure which audio channels receive VS, click, Dica, and synth outputs (FOH vs IEM).
5. **APC Mini FX pad configuration**: an 8×8 grid UI showing the current function/waveform assigned to each pad. Allows reconfiguring oscillator waveforms and FX assignments per pad.
6. **Worlde pad configuration**: a 2×6 grid UI for assigning sample files and ADSR parameters to each of the 12 pads.
7. **Program Change import/export**: download or upload PC pad snapshot JSON files for backup or sharing.

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
- **Effect chain nodes**: distortion, envelope shaper, reverb, LPF, HPF — each as a bus-routed SynthDef that can be instantiated/freed independently.
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
Implement the FX pad state machine:
- Maintain a 8×6 state matrix (rows × columns 1–6) tracking: `\off`, `\idle` (configured/yellow), `\active` (green), `\editing` (blinking green).
- On pad press: toggle `\idle` ↔ `\active`; apply or remove the corresponding oscillator/effect layer in the audio engine.
- **Parameter edit mode**: a 2-second hold starts a timer (non-blocking). On timeout, enter `\editing` — redirect faders 1–6 to that effect's parameters via a CC-to-parameter mapping table. On next press of same pad, exit `\editing`, save parameters to config.
- LED feedback: send MIDI note-on messages back to the APC Mini with the correct velocity color codes (yellow = idle, green = active, blinking = editing, off = unconfigured). Use the APC Mini's documented color code table — do not guess velocity values.
- Faders 7–9 must continue controlling backtrack/click/cue volumes at all times, including during parameter edit mode.

**Verify:** exercise all 48 FX pads, confirm correct LED state transitions. Trigger parameter-edit mode on two different effect rows, confirm faders 1–6 remap correctly and faders 7–9 are unaffected. Confirm state is preserved across pad cycles.

---

### Step 6 — APC Mini Program Change system
Implement the PC pad state machine (columns 7–8):
- Maintain a 8×2 state matrix tracking: `\empty` (off), `\saved` (purple), `\active` (blue).
- On pad press: load the saved snapshot onto the FX Control pad matrix, re-render all 48 FX LED states, and update the audio engine to match.
- **Save gesture**: 2-second hold → blink blue for 1 second → save current FX pad matrix as snapshot at this position. Overwrites previous snapshot if present. If pad was empty, it becomes `\saved`.
- Snapshots are persisted to a JSON config file immediately on save.
- Only one PC pad can be `\active` at a time; pressing a new PC pad deactivates the previous one.

**Verify:** save snapshots to two PC pads, switch between them, confirm FX pad states and LEDs update correctly. Confirm snapshots survive a system restart (reload from JSON). Confirm save gesture correctly overwrites.

---

### Step 7 — APC Mini notes mode
Detect when the APC Mini switches to Notes Mode:
- Identify the mode-toggle message (program change or sysex, per APC Mini documentation) and set an internal flag `apcNotesMode = true`.
- While in Notes Mode, route grid messages to the melodic voice (same pitch/velocity handling as SMK25) instead of FX pad logic.
- On exit from Notes Mode: restore all 64 pad LEDs to exactly the state they were in before Notes Mode was entered (FX pads + PC pads).
- Do not alter any FX pad or PC pad state while in Notes Mode.

**Verify:** enter Notes Mode, play notes, confirm melodic voice triggers. Exit Notes Mode, confirm all LED states are exactly restored.

---

### Step 8 — SMK25 (Bluetooth) → melodic voice
Wire SMK25 Bluetooth MIDI note-on/off to trigger/release the active oscillator stack (whichever Row 1 waveform pads are currently active). Pitch, velocity, and the full effect chain apply.

Handle Bluetooth reconnect gracefully: if the SMK25 disconnects mid-performance, log a warning and re-register the handler on reconnect without any manual intervention.

**Verify:** play notes, confirm correct pitch/velocity response and clean note-off (no stuck notes). Simulate disconnect/reconnect and confirm automatic handler re-registration. Log any dropped note-offs.

---

### Step 9 — Worlde Easypad 12 → sample playback
Wire each of the 12 pads to its configured sample file (assigned via web config). Use disk-streaming playback (`VDiskIn` or `Buffer.readChannel` with appropriate size). Apply per-pad ADSR and velocity scaling from the config.

Pads must handle rapid overlapping hits: a new hit on a pad should start a new voice without cutting off the previous one (up to a reasonable polyphony cap — 4 simultaneous voices per pad is sufficient).

**Verify:** trigger all 12 pads individually and in rapid overlapping succession. Confirm velocity response, ADSR shaping, no voice-stealing clicks. Confirm with a missing sample file — log warning, do not crash.

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
3. **MIDI Mapping** — learn-mode assignment for play/stop/next/prev and other assignable functions.
4. **Output Routing** — channel assignment for VS, click, Dica, synth (FOH/IEM/both).
5. **APC Mini Pads** — 8×8 grid UI; configure oscillator type per pad in Row 1; label/function shown for all other rows.
6. **Worlde Pads** — 2×6 grid UI; assign sample file and ADSR per pad.
7. **Program Change** — list of 16 PC pad slots with import/export (JSON) per slot.

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