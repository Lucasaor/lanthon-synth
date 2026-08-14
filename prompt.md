# Prompt: L4NTH0N-5YNTH revamp: Rewrite Live Playback App for Raspberry Pi Zero 2W (Backing Tracks / Click / Cue / MIDI Automation)

## Role

You are rewriting an existing Raspberry Pi Zero 2W live-performance app. The **previous** version ran SuperCollider for live synthesis plus sample/loop playback; that has been abandoned — synthesis now runs on a separate, more powerful board (Pi 4/5, out of scope for this project). The Zero 2W's job is now much narrower and lighter: **play pre-rendered, per-song multichannel backing tracks in perfect sync with a companion MIDI automation file, controlled from a web UI, physical MIDI controllers, and an OLED display.**

This is a rewrite of an existing codebase, not a greenfield build. **Your first step must be to audit the current repository** and document what exists before removing or changing anything — do not assume the tech stack; discover it.

## Background / why this design

Backing tracks and click were previously going to run alongside live synthesis on the same Zero 2W and caused out-of-memory failures. The fix: synthesis moved to its own board entirely, and the Zero 2W now does one job — sample-accurate multi-channel playback + MIDI dispatch. Per-song audio is a single pre-rendered multichannel interleaved WAV (not separate files per channel), and MIDI automation is a companion Standard MIDI File — both authored in Reaper and already exported by the user. Treating each song as exactly one audio file plus one MIDI file, both driven off the same playback clock, is what guarantees the channels and MIDI events can never drift apart from each other. Preserve this design; do not reintroduce multi-file-per-song synchronization.

## Hardware / environment

- Raspberry Pi Zero 2W, headless (OLED display for local status; no monitor/keyboard in normal use).
- USB MIDI controllers for transport control (play/stop/next/prev).
- USB audio interface(s) — must support hot-swapping to a different interface than whatever was used during development.
- Existing web UI (framework/stack: **discover from the current repo — do not assume**).
- Existing OLED integration and existing device-routing functionality — both to be preserved and extended, not rebuilt from scratch, unless the audit in Step 0 finds a compelling reason otherwise (state that reasoning explicitly if so).

## Non-negotiable constraints

1. **No SuperCollider, no synthesis, no sample playback of any kind.** Remove all of it, including now-unused dependencies, config, and code paths — don't leave dead code "just in case."
2. **One audio file + one MIDI file per song**, both played from a single shared transport/clock source. Never split a song's channels across separate files or separate playback processes.
3. **Sample-accurate sync** between all audio channels and MIDI dispatch — this is the entire point of the rewrite; regressions here defeat the purpose.
4. **Memory-safe streaming.** Stream audio from disk rather than loading full songs into RAM, given the Zero 2W's 512MB — this is the direct fix for the OOMs that forced this rewrite. Do not reintroduce full-file preloading.
5. **Web UI, MIDI transport control, OLED display, and device routing must all reflect one single source of truth for playback state** (current song, transport position, play/stopped/cued state) — no two of these should be able to disagree about what's currently happening.
6. **Hot-pluggable audio/MIDI interface discovery.** The routing configuration must not hardcode a specific USB interface; it must be able to enumerate whatever is currently connected and let the user (re)assign channels when the interface changes.

## Task breakdown

### 1. Remove SuperCollider and unused dependencies
Audit for every SuperCollider-related process, config file, systemd unit, Python/OSC bridge code, and dependency (system packages, Python packages, etc.) and remove all of it. Confirm nothing in the new playback path indirectly depends on anything being removed.

### 2. Web UI — keep, but scope down to playback-only
Keep the existing web UI's framework and general structure. Remove all synth/sample-related screens, endpoints, and state. Keep and adapt to the new backend:
   1. MIDI mapping for **Play / Stop / Next / Prev** from connected MIDI controllers.
   2. Setlist configuration: each song entry = one multitrack WAV path, one MIDI file path, plus **tuning** and **key** fields (already implemented today — carry these fields forward unchanged, just point them at the new single-file-per-song model instead of whatever the old model referenced).
   3. Play / Stop / Next / Prev controls directly in the web UI, wired to the same transport actions as the MIDI mapping in 2.1 (single control path, two input methods).
   4. OLED integration — full local status visibility (current song, tuning/key, transport state, etc.) **without requiring the web UI to be open**. Adapt whatever currently feeds the OLED to read from the new playback engine's state instead of the old one.
   5. All existing USB device routing functionality — carry forward, then extend per Task 4.

### 3. Rewrite project documentation
Rewrite the README/project description and setup documentation to reflect the new architecture: no synthesis, single multitrack-WAV + MIDI-file-per-song model, updated hardware role (Zero 2W = playback/click/cue/MIDI automation only; synth board is separate and out of scope), updated setup/install instructions matching the actual dependencies after Task 1's removals, and an accurate signal-routing diagram (audio channel assignments + MIDI out) reflecting Task 4.

### 4. Update the routing screen
   1. For each logical track — **Playback L, Playback R, Click, Cue, MIDI automation, Timecode (if present in the source file)** — allow selecting which USB audio/MIDI device and which channel on that device it's sent to.
   2. Add live enumeration of connected USB audio and MIDI interfaces (not a hardcoded list), so the whole rig can be re-hooked into a different external interface without code changes — the UI should show what's currently plugged in and let the user (re)map channels against it.

### 5. Deployment
Deploy the finished changes to the Pi via SSH and update the code repository (commit history should make the rewrite's scope traceable — don't squash the SuperCollider-removal and the new-feature work into one indistinguishable commit).

## Suggested implementation approach

- **Playback engine**: build around a backend that gives one authoritative, sample-accurate transport/frame position (e.g. JACK's transport), with:
  - Audio streamed from disk (not preloaded) into the multichannel output, channel-mapped per the routing config from Task 4.
  - The companion MIDI file pre-parsed into a sorted list of (frame-offset, message) pairs, dispatched by checking the same transport position — this is what keeps MIDI automation (PC/CC to the pedalboard) locked to the audio with no separate clock to drift.
  - Memory footprint should stay flat regardless of song length or setlist size — verify this explicitly (see Testing Strategy).
- **Song switching (Next/Prev)**: pre-cue the next song's file handles before it's needed, so switching doesn't introduce an audible gap or a disk-read stall.

## Implementation steps (do these in order; stop and verify before moving to the next)

### Step 0 — Audit the existing codebase
Document: web UI framework/stack, how the OLED integration currently gets its data, how device routing is currently implemented and stored, how the MIDI controller mapping currently works, and exactly which parts of the codebase are SuperCollender-related vs. reusable. Produce this as a short written summary before touching any code — this becomes the map for every later step.

### Step 1 — Remove SuperCollider and dead dependencies
Per Task 1. **Verify:** the app still boots (even if playback isn't wired up yet) with no errors referencing removed dependencies; no orphaned systemd units, config files, or unused packages remain.

### Step 2 — Core playback engine (headless, no UI yet)
Build the single-clock, multichannel-WAV + MIDI-dispatch engine described above, driven from the command line / a test harness, with no web UI or hardware controller wiring yet.
**Verify:** using a real (or synthetic — see Testing Strategy) multitrack WAV + MIDI file pair, confirm all audio channels and MIDI events stay in sync over a full song length, and confirm memory usage stays flat (not climbing) for at least one long song and for a rapid sequence of song switches.

### Step 3 — Routing configuration (backend)
Implement device/channel enumeration and the per-track assignment model (Playback L/R, Click, Cue, MIDI automation, Timecode) as data, independent of the UI.
**Verify:** with a USB audio/MIDI interface attached (and again with a different one substituted), confirm enumeration correctly reflects what's actually connected and channel assignments route audio/MIDI where configured.

### Step 4 — Web UI: playback-only scope
Strip synth/sample UI, wire setlist config (multitrack WAV + MIDI + tuning/key) and Play/Stop/Next/Prev to the Step 2 engine.
**Verify:** full control of the engine from the web UI, state shown in the UI matches actual engine state at all times, including immediately after Next/Prev.

### Step 5 — MIDI controller transport mapping
Wire physical MIDI controller input to the same Play/Stop/Next/Prev actions as the web UI (single action path, per architecture constraint 5).
**Verify:** trigger each action from the controller and confirm identical behavior and state reflection as the web UI path, including with both used interchangeably in the same session.

### Step 6 — OLED integration
Point the existing OLED code at the new engine's state.
**Verify:** OLED reflects current song, tuning/key, and transport state correctly with the web UI closed/not running, and stays correct across Next/Prev and Play/Stop from any control path.

### Step 7 — Routing screen (UI)
Build the UI for Task 4 on top of the Step 3 backend, including live device re-enumeration.
**Verify:** reassign a track's device/channel while the interface is connected, then disconnect and reconnect a different interface and confirm the screen reflects the change without a restart, if that's achievable — if a restart is required, document that clearly rather than silently leaving stale device info displayed.

### Step 8 — Documentation rewrite
Per Task 3, once the system's actual final shape is known from Steps 1–7 (don't write docs against a plan that implementation may have deviated from).
**Verify:** a fresh read-through of the setup docs, followed against a clean environment if feasible, actually results in a working setup.

### Step 9 — Deployment
Deploy via SSH to the Pi, commit and push the repo with clear, scoped commit history per Task 5.
**Verify:** a full end-to-end run on the real hardware — real setlist, real controllers, real OLED, real audio interface — with no manual intervention beyond normal show operation.

## Testing strategy (minimize physical back-and-forth on the Pi)

- **Develop and validate the playback engine (Step 2) on a dev machine first** wherever possible — the core sync/streaming logic doesn't require Pi-specific hardware to test.
- **Use synthetic test fixtures**: a short synthetic multitrack WAV (e.g. distinct test tones per channel) paired with a short synthetic MIDI file with known event timestamps, so sync accuracy can be checked programmatically (verify event N fires within an acceptable frame tolerance of its expected transport position) rather than only by ear.
- **Simulate MIDI controller input and USB device changes** via virtual MIDI ports / mock device lists when real hardware isn't attached to the dev machine, so Steps 3, 5, and 7 can be exercised without physical hardware present.
- **Monitor memory usage explicitly and log it**, not just at the end but from Step 2 onward — this is the specific failure mode being fixed, so treat flat memory usage as a first-class thing to verify at every later step too, not just once.
- **Only Steps 6 and 9 (and final parts of 7) strictly require the physical Pi with real peripherals.** Everything before that should be verified on a dev machine or with simulated input first.
- **Commit to git after each step**, with messages that make it possible to bisect a regression back to a specific step.

## Deliverables expected

1. Rewritten source code, organized so the removed synth/sample code is fully gone (not just disabled) and the new playback engine, routing, UI, MIDI mapping, and OLED integration are clearly separated concerns.
2. Updated `README.md` / setup documentation per Task 3 and Step 8.
3. A routing/signal-flow diagram reflecting the final channel assignments (Playback L/R, Click, Cue, MIDI automation, Timecode) and device mapping.
4. A short test log documenting the verification evidence from each step above, including the memory-usage and sync-accuracy checks.
5. A clean, scoped git commit history and confirmation of successful SSH deployment to the actual Pi Zero 2W.