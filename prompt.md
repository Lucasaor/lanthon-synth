# Prompt: SuperCollider Live Performance Rig for Raspberry Pi Zero 2W

## Role

You are implementing a headless, real-time performance instrument in SuperCollider, deployed on a Raspberry Pi Zero 2W, for a live power-duo (bass + drums) show. The person you're building this for plays bass separately through a Pi 4 pedalboard rig (out of scope — do not touch); this project is the *synth/loop/percussion companion rig* running entirely on the Zero 2W, controlled by three USB MIDI controllers.

**Work in the numbered steps below, in order. Do not skip ahead.** After each step, stop and produce the verification evidence requested (test output, logs, a short written confirmation of what was checked) before proceeding to the next step. The goal is to catch problems on a development machine or via simulated input wherever possible, so the person doesn't have to repeatedly flash/redeploy/reboot the physical Pi to find bugs that could have been caught earlier.

## Hardware

- **Raspberry Pi Zero 2W** — quad-core Cortex-A53 @ 1GHz, 512MB RAM, single micro-USB OTG port (shared via powered USB hub for all peripherals), headless (no display attached during normal operation).
- **AKAI APC Mini** — 8x8 RGB-LED grid of buttons + 8 vertical faders + top/side control row. Used as: clip/loop launcher (grid) and per-loop volume/FX control (faders).
- **Worlde Easypad 12** — 12 pads. Used as: drum/percussion/sample trigger pads.
- **M-VAVE SMK 25** — 25-key MIDI keyboard (plus onboard knobs/pads if present). Used as: melodic voice/lead/bass-line note input.
- Audio output via USB audio interface or I2S DAC HAT (implementer may assume a class-compliant stereo USB audio interface unless told otherwise).

## Non-negotiable technical constraints

1. **No Sonic Pi.** Use `sclang`/`scsynth` directly. Sonic Pi's default 0.5s scheduling-ahead model (and residual latency even with `use_real_time`) is not acceptable for hand-played, drummer-synced performance.
2. **Headless operation.** No GUI, no SuperCollider IDE dependency at runtime. Must autostart on boot via `systemd` and require no keyboard/monitor/mouse on stage.
3. **Low, consistent latency is the top priority**, ahead of feature richness. Prefer simple, cheap SynthDefs over elaborate per-voice effects; put heavier effects (reverb, etc.) on a shared bus/master effect, not per-voice, to protect headroom.
4. **~8 voices of simultaneous polyphony** must be sustainable without xruns.
5. **Multiple MIDI controllers must coexist without collisions.** Filter every `MIDIdef`/`MIDIFunc` by the sending device's `srcID`, never assume note/CC numbers are globally unique across devices.
6. **All loop/click timing must derive from one shared clock** (a single `TempoClock`), so loop quantization and the metronome/click can never drift apart from each other.
7. **CPU governor must be set to `performance`**, not `ondemand`, and this must be part of the deployment/setup script, not a manual one-off step someone has to remember.

## Architecture overview

- JITLib (`Ndef` / `NodeProxy`) based loop tracks: each "loop thread/section" the person mentioned is one `Ndef`, giving independent record/play/stop/mute state, plus built-in `.vol` and `.fx` hooks for per-loop volume and effects — this is exactly what the APC Mini grid + faders will control.
- APC Mini:
  - Grid buttons: launch/record/overdub/stop/mute per loop `Ndef`. Columns or rows map to distinct loop "sections"; exact grid layout is up to the implementer but must be documented in code comments and in a `CONTROLS.md` reference file (see Deliverables).
  - Grid LEDs: **drive real loop state back to the hardware** (e.g., off = empty, one color = recording, another = playing, another = muted) by sending note-on messages back to the APC Mini with velocity values that map to its RGB color codes.
  - Faders: continuous CC → mapped to each active `Ndef`'s `.vol` or a chosen FX parameter (implementer's choice which faders map to volume vs. FX send — document the mapping).
- Easypad 12: each of the 12 pads triggers a discrete drum/percussion/sample `Synth` (short one-shot voice, not a sustained note).
- SMK25: standard note-on/off drives the melodic lead/bass voice `Synth`(s), routed into whichever `Ndef`/loop track is currently "armed" for recording, or played live/dry if nothing is armed.
- A single shared `TempoClock` drives both the click/metronome `Synth` (routed only to a monitor/click output, never to the main mix) and all loop quantization.

## Implementation steps (do these in order; each has a stop-and-verify checkpoint)

### Step 0 — MIDI discovery & calibration tool
Write a small standalone sclang script that enumerates connected MIDI devices, prints each device's `uid`/`srcID`, and logs every incoming note/CC message with its source, so the actual note/CC numbers for all three controllers can be captured and recorded in a `CONTROLS.md` reference file (source of truth for every subsequent mapping — do not hardcode guessed note numbers).
**Verify:** run this against real hardware (or, if unavailable, against a virtual MIDI port with simulated input — see Testing Strategy) and confirm the log clearly disambiguates all three devices by `srcID`.

### Step 1 — Core audio engine (no MIDI yet)
Implement the SynthDefs needed: one or two lead/bass melodic voices, one or two percussion/one-shot voices, and a simple click voice. Keep them cheap (basic oscillators + a filter/envelope, no heavy per-voice FX).
**Verify:** trigger each SynthDef manually from the sclang interpreter (`Synth(...)` calls) and confirm clean audio, then check `s.avgCPU` / `s.peakCPU` with ~8 simultaneous voices running to confirm headroom before any MIDI or looping logic is added.

### Step 2 — MIDI input routing skeleton
Implement `MIDIdef`/`MIDIFunc` handlers filtered by `srcID` for all three controllers, but only logging (print/postln) what was received — no audio triggering yet.
**Verify:** exercise each controller (or simulated input) and confirm messages are correctly attributed to the right device with no cross-talk, using the `CONTROLS.md` mapping from Step 0.

### Step 3 — SMK25 → melodic voice
Wire SMK25 note-on/off to trigger/release the lead/bass voice SynthDef(s) from Step 1.
**Verify:** play notes, confirm correct pitch/velocity response and clean note-off (no stuck notes), log any dropped note-offs.

### Step 4 — Easypad 12 → percussion/samples
Wire each of the 12 pads to its own one-shot voice or sample trigger.
**Verify:** trigger all 12 pads individually and in rapid succession/overlap; confirm no voice-stealing glitches or audible clicks.

### Step 5 — Loop tracks (Ndef-based) + APC Mini grid control
Implement the `Ndef`-per-loop-track model with record/overdub/play/stop/mute logic bound to APC Mini grid buttons.
**Verify:** exercise the full record → overdub → stop → mute → clear cycle on at least two independent loop tracks and confirm state transitions are correct and don't affect other tracks.

### Step 6 — APC Mini faders → volume/FX
Map fader CCs continuously to `.vol` or FX parameters of the currently relevant `Ndef`s.
**Verify:** move each fader through its full range while a loop is playing and confirm smooth (not stepped/zippered) volume/FX changes.

### Step 7 — APC Mini LED feedback
Drive grid LED colors from actual loop state (empty/recording/playing/muted) so the hardware visually reflects what's happening.
**Verify:** confirm LED state updates immediately and correctly on every transition exercised in Step 5, including edge cases (e.g., clearing a loop, muting a playing loop).

### Step 8 — Shared clock + click
Implement the single `TempoClock` driving both loop quantization and the click voice, with the click routed to a separate/monitor-only output bus.
**Verify:** confirm loops quantize to the shared clock and the click never drifts from loop boundaries over an extended run (several minutes), and confirm the click does not bleed into the main/FOH output bus.

### Step 9 — Headless boot & performance tuning
Package everything into a `systemd` service that starts `jackd` (or the chosen audio backend) then `scsynth`/`sclang` with the full patch loaded, with the CPU governor set to `performance` as part of the same deployment script. No manual steps should be required after a cold boot.
**Verify:** power-cycle the actual Pi and confirm the rig comes up fully functional with zero manual intervention and no attached display/keyboard.

### Step 10 — Integration / stage rehearsal checklist
Run a full end-to-end rehearsal: all three controllers connected simultaneously, ~8 voices of polyphony exercised, multiple loop tracks running, click active, for an extended session (recommend 20+ minutes continuous) while monitoring for xruns/dropouts.
**Verify:** produce a short log/report of CPU load and any xrun counts over the session, and confirm zero audible glitches were observed.

## Testing strategy (to minimize physical back-and-forth on the Pi)

- **Develop and validate on a host machine first wherever possible.** SuperCollider code (SynthDefs, `Ndef` logic, MIDI handling logic) is portable — write and test it on a desktop/laptop running SuperCollider before ever deploying to the Pi.
- **Simulate MIDI input when hardware isn't attached to the dev machine.** Use a virtual MIDI port (e.g., IAC Driver on macOS, or a loopback MIDI device on Linux) and a small script that injects synthetic note-on/note-off/CC messages with the correct `srcID`-equivalent identifiers, so controller logic (Steps 2–7) can be exercised without any physical controller present.
- **Automate verification, don't rely on listening alone.** Where possible, write sclang test routines that assert on state (e.g., check an `Ndef`'s play/record state variable after a simulated button press) rather than requiring a human to listen and judge. Log results to a file for each test run.
- **Monitor CPU/xrun health quantitatively at every step from Step 1 onward**, not just at the end: `s.avgCPU`, `s.peakCPU`, and the audio backend's xrun counter. Log these numbers so regressions are visible early, before they compound into an on-stage failure.
- **Only Steps 9 and 10 strictly require the physical Pi.** Everything before that should be verified on the dev machine or via simulated input first; only bring code to the Pi once it has already passed verification off-device.
- **Commit to git after every step** with a clear message referencing the step number, so any regression can be bisected without guesswork.

## Deliverables expected

1. Source code, organized by concern (e.g., `synths.scd`, `midi_routing.scd`, `loops.scd`, `apc_leds.scd`, `clock.scd`, `main.scd` or equivalent, plus the calibration tool from Step 0).
2. `CONTROLS.md` — the authoritative note/CC/srcID mapping for all three controllers, populated from real (or simulated) captured data, not assumptions.
3. `DEPLOY.md` — exact steps (or fully automated script) to go from a fresh Raspberry Pi OS install to a working headless boot, including the `systemd` unit file(s) and the CPU governor setting.
4. A short `TEST_LOG.md` or equivalent recording the verification evidence from each step above.
5. Brief inline comments explaining any non-obvious timing/latency-related decisions, since these are the parts most likely to need revisiting later.