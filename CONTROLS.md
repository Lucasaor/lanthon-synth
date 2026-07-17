# CONTROLS.md — MIDI Controller Mapping Reference

> **This is the authoritative source of truth for all MIDI note/CC/srcID mappings.**
> Populated by running `src/calibration.scd` with all three controllers connected.
> If any controller is replaced, re-run calibration and update this file.

---

## Device srcID Registry

| Device              | srcID (uid) | Notes                                  |
|---------------------|-------------|----------------------------------------|
| AKAI APC Mini       | `________`  | Grid controller + faders               |
| Worlde Easypad 12   | `________`  | 12 drum pads                           |
| M-VAVE SMK 25       | `________`  | 25-key melodic keyboard                |

> Fill in the blanks after running `calibration.scd`.

---

## 1. AKAI APC Mini

### 1.1 Grid Layout (8×8 buttons)

APC Mini grid buttons send MIDI **note-on/note-off**.  

Default assumption: note = `row × 8 + col`, with note 0 at bottom-left.
**Verify against calibration output.** If the base note is different, update
`~apcGridNoteBase` in `loops.scd`.

| Row (0=bottom) | Function       | Expected Note Range |
|----------------|----------------|---------------------|
| 0              | STOP (Play toggle) | 0–7            |
| 1              | REC (Record/Overdub) | 8–15         |
| 2              | PLAY (Play/Stop)    | 16–23         |
| 3              | MUTE (Mute toggle)  | 24–31         |
| 4              | *unused*       | 32–39               |
| 5              | *unused*       | 40–47               |
| 6              | *unused*       | 48–55               |
| 7              | CLEAR          | 56–63               |

**Actual captured notes (fill from calibration log):**

| Col | Row 0 | Row 1 | Row 2 | Row 3 | Row 4 | Row 5 | Row 6 | Row 7 |
|-----|-------|-------|-------|-------|-------|-------|-------|-------|
| 0   | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  |
| 1   | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  |
| 2   | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  |
| 3   | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  |
| 4   | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  |
| 5   | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  |
| 6   | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  |
| 7   | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  | `__`  |

### 1.2 Faders (CC Messages)

APC Mini faders send **CC** messages.

Default assumption: CC 48–55 for vertical faders, CC 56 for master.
**Verify against calibration output.**

| Fader # | Expected CC | Actual CC | Maps To        |
|---------|-------------|-----------|----------------|
| 1       | 48          | `___`     | Loop 0 volume  |
| 2       | 49          | `___`     | Loop 1 volume  |
| 3       | 50          | `___`     | Loop 2 volume  |
| 4       | 51          | `___`     | Loop 3 volume  |
| 5       | 52          | `___`     | Loop 4 volume  |
| 6       | 53          | `___`     | Loop 5 volume  |
| 7       | 54          | `___`     | Loop 6 volume  |
| 8       | 55          | `___`     | Loop 7 volume  |
| Master  | 56          | `___`     | Global FX send |

### 1.3 Control Row Buttons

| Button         | Note / CC   | Actual Value |
|----------------|-------------|--------------|
| (TBD)          | `___`       | `___`        |

### 1.4 LED Color Codes

Sent as note-on velocity back to the APC Mini:

| Velocity | Color   | Used For                  |
|----------|---------|---------------------------|
| 0        | Off     | Empty loop                |
| 1        | Green   | Playing / overdubbing     |
| 3        | Amber   | Stopped (has content) / Muted |
| 5        | Red     | Recording / REC-ready     |

---

## 2. Worlde Easypad 12

Each of the 12 pads sends a MIDI **note-on** (and note-off on release).  
The note numbers MUST be captured from calibration — they vary by firmware.

| Pad # | Note (from calib) | Voice Mapping   |
|-------|-------------------|-----------------|
| 1     | `___`             | TBD             |
| 2     | `___`             | TBD             |
| 3     | `___`             | TBD             |
| 4     | `___`             | TBD             |
| 5     | `___`             | TBD             |
| 6     | `___`             | TBD             |
| 7     | `___`             | TBD             |
| 8     | `___`             | TBD             |
| 9     | `___`             | TBD             |
| 10    | `___`             | TBD             |
| 11    | `___`             | TBD             |
| 12    | `___`             | TBD             |

### Available Percussion Voices

| Voice Name   | Description            |
|-------------|------------------------|
| `\kick`     | Electronic kick drum   |
| `\snare`    | Electronic snare       |
| `\hihat`    | Closed hi-hat          |
| `\openHat`  | Open hi-hat            |
| `\clap`     | 808-style hand clap    |
| `\rim`      | Rimshot / sidestick    |
| `\perc`     | Generic tuned percussion |

> After calibration, populate `~easyPadMap` in `midi_routing.scd` or use
> `~setEasyPadMap.([[36, \kick], [37, \snare], ...])` interactively.

### Pad CC/Knobs (if any)

| Control | CC # (from calib) |
|---------|-------------------|
| (TBD)   | `___`             |

---

## 3. M-VAVE SMK 25

### 3.1 Keyboard Notes

Standard MIDI note range: 0–127.  The SMK25 sends note-on/note-off on
a fixed MIDI channel (likely channel 1 / SC channel 0).  Verify with calibration.

- **Note range observed:** `__` to `__`
- **MIDI channel:** `__`
- **Velocity range observed:** `__` to `__`

### 3.2 Controls

| Control        | CC # (from calib) | Maps To              |
|----------------|-------------------|----------------------|
| Mod Wheel      | 1 (standard)      | Filter cutoff        |
| Sustain Pedal  | 64 (standard)     | Note hold            |
| Pitch Bend     | (bend messages)   | ±2 semitone bend     |
| Knob 1         | `___`             | TBD                  |
| Knob 2         | `___`             | TBD                  |
| Knob 3         | `___`             | TBD                  |
| Knob 4         | `___`             | TBD                  |
| Pad 1          | `___`             | TBD                  |
| Pad 2          | `___`             | TBD                  |
| Pad 3          | `___`             | TBD                  |
| Pad 4          | `___`             | TBD                  |

---

## Notes

- **All MIDIdefs filter by srcID** — this document is critical because the
  same note number from different controllers routes to completely different
  handlers.
- **If controllers are swapped or firmware is updated**, re-run `calibration.scd`
  and update this entire document.
- The LED color palette above was tested with an APC Mini mk1.  If using mk2
  or a different firmware version, the velocity→color mapping may differ — test
  with `~testLEDs.()` from `apc_leds.scd`.
