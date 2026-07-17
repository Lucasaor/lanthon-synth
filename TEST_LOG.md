# TEST_LOG.md — Verification Evidence

This file records the verification evidence for each implementation step
as required by the prompt.  Fill in dates, results, and notes as each
step is validated.

---

## Step 0 — MIDI Discovery & Calibration

**Date:** `________`  
**Machine:** `________` (dev machine / Pi Zero 2W)  
**SuperCollider version:** `________`

### Verification Checklist

- [ ] `calibration.scd` runs without errors
- [ ] All three controllers appear in the enumeration output with unique srcIDs
- [ ] Pressing a button on each controller produces a log line with the correct
      device prefix (APC / EASY / SMK)
- [ ] No cross-talk: pressing APC button does NOT log as EASY or SMK
- [ ] All 64 APC grid buttons logged with correct (row, col)
- [ ] All 8+1 APC faders logged with correct CC numbers
- [ ] All 12 Easypad pads logged with correct note numbers
- [ ] SMK25 keys, pitch bend, mod wheel, sustain pedal all logged correctly

### srcID Values Captured

| Device              | srcID      |
|---------------------|------------|
| AKAI APC Mini       | `________` |
| Worlde Easypad 12   | `________` |
| M-VAVE SMK 25       | `________` |

### Notes

```
(Any issues, surprises, or observations during calibration)
```

---

## Step 1 — Core Audio Engine (SynthDefs)

**Date:** `________`  
**Machine:** `________`

### Verification Checklist

- [ ] All SynthDefs load without errors (`SynthDescLib.global.synthDescs.keys`)
- [ ] Each voice triggered manually produces clean audio:
  - [ ] `\leadBass` — clean saw tone, velocity-sensitive, filter envelope works
  - [ ] `\leadBassSub` — sub-bass tone with sine/saw mix
  - [ ] `\leadPad` — slow-attack pad, no clicks
  - [ ] `\kick` — punchy kick with pitch drop
  - [ ] `\snare` — snare with body + noise
  - [ ] `\hihat` — short, bright hi-hat
  - [ ] `\openHat` — longer decay
  - [ ] `\clap` — layered clap
  - [ ] `\rim` — short rimshot
  - [ ] `\perc` — tuned percussion with pitch sweep
  - [ ] `\click` — short beep, routed to monitor bus
- [ ] Notes release cleanly (no stuck notes, no clicks on gate-off)
- [ ] Velocity sensitivity works (soft = quiet, hard = loud + brighter filter)

### CPU Load (8 simultaneous voices)

| Metric     | Value      |
|------------|------------|
| `s.avgCPU` | `_____%`   |
| `s.peakCPU`| `_____%`   |

### Notes

```
```

---

## Step 2 — MIDI Input Routing Skeleton

**Date:** `________`  
**Machine:** `________`

### Verification Checklist

- [ ] srcID globals set to calibration values
- [ ] Pressing APC button → `[APC] GRID NOTE ON ...` logged
- [ ] Pressing Easypad → `[EASY] PAD NOTE ON ...` logged
- [ ] Pressing SMK25 key → `[SMK] KEY NOTE ON ...` logged
- [ ] No cross-talk between device handlers
- [ ] Note-off messages logged correctly
- [ ] CC messages logged with correct CC number and value

### Notes

```
```

---

## Step 3 — SMK25 → Melodic Voice

**Date:** `________`  
**Machine:** `________`

### Verification Checklist

- [ ] Playing a key on SMK25 triggers `\leadBass` with correct pitch
- [ ] Note-off releases the voice (no stuck notes)
- [ ] Velocity affects amplitude and filter
- [ ] Sustain pedal holds notes after key release
- [ ] Releasing sustain pedal releases held notes
- [ ] Pitch bend works (±2 semitone range)
- [ ] Mod wheel sweeps filter cutoff smoothly
- [ ] Monophonic note stealing works (no overlapping voices)

### Notes

```
```

---

## Step 4 — Easypad 12 → Percussion

**Date:** `________`  
**Machine:** `________`

### Verification Checklist

- [ ] `~easyPadMap` populated with calibration note numbers
- [ ] Each of the 12 pads triggers a distinct voice
- [ ] All 12 voices produce clean one-shot sounds
- [ ] Rapid-fire triggering does not cause voice-stealing glitches
- [ ] Overlapping triggers do not produce audible clicks
- [ ] Pad velocity maps to amplitude correctly

### Notes

```
```

---

## Step 5 — Loop Tracks (Ndef) + APC Grid Control

**Date:** `________`  
**Machine:** `________`

### Verification Checklist

- [ ] `~initLoops` allocates 8 buffers without error
- [ ] APC grid buttons correctly mapped via `~apcGridPress`
- [ ] State transitions tested on at least 2 independent tracks:

| Transition                               | Track 0 | Track 1 |
|------------------------------------------|---------|---------|
| EMPTY → RECORDING (press REC)            | [ ]     | [ ]     |
| RECORDING → PLAYING (press REC again)    | [ ]     | [ ]     |
| PLAYING → OVERDUBBING (press REC)        | [ ]     | [ ]     |
| OVERDUBBING → PLAYING (press REC again)  | [ ]     | [ ]     |
| PLAYING → STOPPED (press PLAY/STOP)      | [ ]     | [ ]     |
| STOPPED → PLAYING (press PLAY/STOP)      | [ ]     | [ ]     |
| PLAYING → MUTED (press MUTE)             | [ ]     | [ ]     |
| MUTED → PLAYING (press MUTE again)       | [ ]     | [ ]     |
| Any state → EMPTY (press CLEAR)          | [ ]     | [ ]     |

- [ ] State changes on track 0 do not affect track 1 (isolation)
- [ ] Audio is actually being recorded and played back
- [ ] Overdub adds new input to existing loop content

### Notes

```
```

---

## Step 6 — APC Faders → Volume/FX

**Date:** `________`  
**Machine:** `________`

### Verification Checklist

- [ ] `~apcFaderMap` populated with calibration CC numbers
- [ ] Fader 1 controls Loop 0 volume smoothly (no zippering)
- [ ] Fader 2 controls Loop 1 volume smoothly
- [ ] ...all 8 faders mapped to their respective loops
- [ ] Fader at minimum → loop silent
- [ ] Fader at maximum → loop at full volume
- [ ] Volume changes are smooth (no audible stepping)
- [ ] Master fader controls global FX level (if FX Ndef is set up)

### Notes

```
```

---

## Step 7 — APC LED Feedback

**Date:** `________`  
**Machine:** `________`

### Verification Checklist

- [ ] `~apcMidiOut` connected to APC Mini (not nil)
- [ ] `~testLEDs` cycles all LEDs through off→green→amber→red→off
- [ ] LED state updates immediately on every transition:
  - [ ] EMPTY → all LEDs off for that column
  - [ ] RECORDING → REC row red, PLAY rows red
  - [ ] PLAYING → REC row red, PLAY rows green
  - [ ] STOPPED → REC row red, PLAY rows amber
  - [ ] MUTED → REC row red, PLAY rows off, MUTE row amber
- [ ] Clearing a loop turns all LEDs off for that column
- [ ] Muting/unmuting toggles MUTE row LED

### Notes

```
```

---

## Step 8 — Shared Clock + Click

**Date:** `________`  
**Machine:** `________`

### Verification Checklist

- [ ] `~startClock` starts the click at the specified BPM
- [ ] Click is audible ONLY through monitor bus (not main mix)
- [ ] Downbeat (beat 1) has higher pitch than subdivisions
- [ ] `~setBpm` changes tempo immediately and click follows
- [ ] `~tapTempo` calculates correct BPM after 4 taps
- [ ] Loops quantize to the shared clock (edges align with click)
- [ ] Extended run (>5 min): no audible drift between click and loop edges
- [ ] `~stopClock` stops click and frees clock resources

### Drift Test (run for 5+ minutes)

| Elapsed Time | Drift Observed? |
|-------------|-----------------|
| 1 min       | `____`          |
| 3 min       | `____`          |
| 5 min       | `____`          |

### Notes

```
```

---

## Step 9 — Headless Boot & Performance Tuning

**Date:** `________`  
**Machine:** Pi Zero 2W

### Verification Checklist

- [ ] `deploy/setup.sh` runs without errors
- [ ] CPU governor is `performance` after reboot:
      `cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor`
- [ ] `systemd` service starts on boot without manual intervention
- [ ] `sudo systemctl status lanthon-synth` shows `active (running)`
- [ ] Rig is fully functional with NO display/keyboard/mouse attached
- [ ] Power-cycle test: unplug power, plug back in, rig auto-starts within 30s

### Boot Test Log

```
(Output of: sudo journalctl -u lanthon-synth -b)
```

### Notes

```
```

---

## Step 10 — Integration / Stage Rehearsal

**Date:** `________`  
**Machine:** Pi Zero 2W  
**Duration:** `____` minutes

### Verification Checklist

- [ ] All three controllers connected simultaneously
- [ ] ~8 voices of polyphony exercised (SMK25 + Easypad simultaneously)
- [ ] Multiple loop tracks running (≥4 tracks simultaneously)
- [ ] Click active throughout
- [ ] No audible glitches, dropouts, or xruns
- [ ] No stuck notes
- [ ] LED feedback remains consistent throughout

### CPU / xrun Report

| Metric              | Start      | Mid (10min) | End (20min) |
|--------------------|------------|-------------|-------------|
| `s.avgCPU`         | `_____%`   | `_____%`    | `_____%`    |
| `s.peakCPU`        | `_____%`   | `_____%`    | `_____%`    |
| xrun count          | `____`     | `____`      | `____`      |
| Audible glitches    | `____`     | `____`      | `____`      |

### Notes

```
(Any issues, observations, or improvements needed)
```

---

## Summary

| Step | Status | Date Completed |
|------|--------|---------------|
| 0 — Calibration        | ☐       |               |
| 1 — SynthDefs          | ☐       |               |
| 2 — MIDI Routing       | ☐       |               |
| 3 — SMK25 Melodic      | ☐       |               |
| 4 — Easypad Percussion | ☐       |               |
| 5 — Loop Tracks + Grid | ☐       |               |
| 6 — Faders → Volume    | ☐       |               |
| 7 — LED Feedback       | ☐       |               |
| 8 — Clock + Click      | ☐       |               |
| 9 — Headless Boot      | ☐       |               |
| 10 — Integration       | ☐       |               |
