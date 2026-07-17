# Lanthon Synth

A **headless, real-time live performance instrument** in SuperCollider for the
Raspberry Pi Zero 2W.  Designed for a live power-duo (bass + drums), controlled
by three USB MIDI controllers.  No screen, no mouse — just hardware.

## Hardware

- **Raspberry Pi Zero 2W** — quad-core Cortex-A53 @ 1GHz, 512MB RAM
- **AKAI APC Mini** — 8×8 RGB grid + 8 faders (loop launcher & mixer)
- **Worlde Easypad 12** — 12 pads (drum/percussion triggers)
- **M-VAVE SMK 25** — 25-key MIDI keyboard (lead/bass voice)

## Quick Start

```bash
# On the Pi:
git clone https://github.com/lucasaor/lanthon-synth.git
cd lanthon-synth
sudo ./deploy/setup.sh
sudo reboot

# After reboot, the rig starts automatically.
# Check:  sudo systemctl status lanthon-synth
```

## Project Structure

```
├── src/
│   ├── main.scd           # Entry point — loads everything, boots server
│   ├── synths.scd         # SynthDefs (lead, bass, drums, click)
│   ├── midi_routing.scd   # MIDI handlers for all 3 controllers
│   ├── loops.scd          # Ndef loop tracks + APC grid state machine
│   ├── apc_leds.scd       # APC Mini LED color feedback
│   ├── clock.scd          # Shared TempoClock + metronome click
│   └── calibration.scd    # Step 0: MIDI discovery & mapping tool
├── deploy/
│   ├── setup.sh           # Automated deployment script
│   └── lanthon-synth.service  # systemd unit for headless auto-start
├── CONTROLS.md            # Authoritative MIDI note/CC/srcID mapping
├── DEPLOY.md              # Full deployment guide
├── TEST_LOG.md            # Verification checklist for each step
└── README.md
```

## Documentation

- **[CONTROLS.md](CONTROLS.md)** — MIDI mapping reference (populate from calibration)
- **[DEPLOY.md](DEPLOY.md)** — Full deployment instructions from fresh OS to auto-boot
- **[TEST_LOG.md](TEST_LOG.md)** — Step-by-step verification checklist

## Key Design Decisions

- **JITLib Ndefs** for loop tracks — independent record/play/stop/mute per track
- **Single shared TempoClock** — loop quantization and click can't drift apart
- **srcID-filtered MIDI** — all controllers coexist safely on one USB hub
- **CPU governor = performance** — enforced by setup script, not a manual step
- **Cheap SynthDefs** — basic oscillators + filter, no per-voice FX, to protect Pi headroom
- **Separate click bus** — click routed to monitor output, never bleeds into main/FOH mix

## License

MIT — see [LICENSE](LICENSE).
