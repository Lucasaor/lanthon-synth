# LANTH0N 5YNTH

A **headless, real-time live performance instrument** in SuperCollider for the
Raspberry Pi Zero 2W. Designed for a live power-duo (bass + drums), controlled
by three MIDI controllers. No screen, no mouse — just hardware.

## Hardware

- **Raspberry Pi Zero 2W** — quad-core Cortex-A53 @ 1GHz, 512MB RAM
- **AKAI APC Mini v2** — 8×8 RGB grid + 9 faders (metronome, 8-track looper, FX pads, PC pads)
- **Worlde Easypad 12** — 12 pads (sample triggers with velocity + ADSR)
- **M-VAVE SMK 25** — 25-key Bluetooth MIDI keyboard (lead voice, effect knobs, sample pads)

## APC Mini v2 Grid Layout (quick reference)

```
Row 7 (top) ── Metronome / loop-length selector (rolling beat + press to set loop bars)
Row 6       ── Loop track controls (8 independent record/play/pause tracks)
Rows 0–5    ── FX pads (cols 0–5) + Program Change pads (cols 6–7)
  Row 5: Reverb    Row 4: Delay    Row 3: Distortion
  Row 2: Oct Up    Row 1: Oct Dn   Row 0: SQ/Saw/Sup/Sine/TB303/WNoise
```

Faders 1–8 = loop track volumes. Fader 9 (master) = backtrack volume.  
Effect parameters (reverb room, delay time, LPF/HPF cutoff, etc.) are on **SMK25 knobs**.

## Quick Start

```bash
# On the Pi:
git clone https://github.com/lucasaor/lanthon-synth.git
cd lanthon-synth
sudo ./deploy/setup.sh
sudo reboot

# After reboot, all services start automatically.
# Check:  sudo systemctl status lanthon-synth lanthon-oled lanthon-web
```

## Project Structure

```
├── src/
│   ├── main.scd           # Entry point — loads everything, boots server
│   ├── synths.scd         # SynthDefs (voices, effect chain, sample player, backtrack)
│   ├── midi_routing.scd   # MIDI handlers for all 3 controllers
│   ├── apc_pads.scd       # FX pad + PC pad state machine (rows 0–5)
│   ├── apc_leds.scd       # APC Mini v2 LED colour feedback
│   ├── loops.scd          # Metronome row + 8-track loop recording engine (rows 6–7)
│   ├── backtrack.scd      # Disk-streaming backtrack player + setlist engine
│   ├── clock.scd          # Shared TempoClock + click voice
│   └── calibration.scd    # Step 0: MIDI discovery & mapping tool
├── config/
│   ├── midi_map.json      # Backtrack MIDI mapping + SMK25 knob assignments
│   ├── pads_worlde.json   # Worlde Easypad 12 sample assignments + ADSR
│   ├── pads_smk.json      # SMK25 pad sample assignments + ADSR
│   ├── pc_snapshots.json  # APC Mini PC pad snapshots (12 slots)
│   └── audio_routing.json # FOH/IEM bus assignments
├── setlists/
│   └── example.json       # Example setlist (edit via web UI)
├── deploy/
│   ├── setup.sh           # Automated deployment script
│   └── *.service          # systemd units for headless auto-start
├── web/                   # SvelteKit web configuration interface
├── oled_daemon.py         # Python OLED display daemon
├── CONTROLS.md            # Authoritative MIDI note/CC/srcID mapping + user manual
├── DEPLOY.md              # Full deployment instructions
└── TEST_LOG.md            # Step-by-step verification checklist
```

## Documentation

- **[CONTROLS.md](CONTROLS.md)** — Complete user manual and MIDI mapping reference
- **[DEPLOY.md](DEPLOY.md)** — Full deployment instructions: fresh OS to auto-boot
- **[TEST_LOG.md](TEST_LOG.md)** — Step-by-step verification checklist

## Key Design Decisions

- **8-track loop recorder** (Row 7) — TempoClock-quantized, bar-set boundaries, fader-per-track volume
- **Metronome row** (Row 8, top) — rolling LED beat indicator + pad-press to set loop length (1–8 bars)
- **SMK25 knobs control all effect parameters** — LPF, HPF, reverb, delay, ADSR via configurable MIDI-learn
- **Single shared TempoClock** — loop quantization, click, and BPM knob can't drift apart
- **srcID-filtered MIDI** — all three controllers coexist safely on one USB hub
- **CPU governor = performance** — enforced by setup script, not a manual step
- **Cheap SynthDefs** — effects on shared bus (not per-voice); AllpassC delay, FreeVerb reverb
- **Disk-streaming backtracks** — `VDiskIn` only; no full file loaded into RAM
- **Offline-resilient** — system boots and runs fully with zero controllers attached; hot-plug and BT reconnect handled transparently

## License

MIT — see [LICENSE](LICENSE).