# DEPLOY.md — LANTH0N 5YNTH Deployment Guide

From a **fresh Raspberry Pi OS Lite** to a fully functional headless
playback rig with four auto-starting services.

---

## Prerequisites

| Item | Notes |
|------|-------|
| Raspberry Pi Zero 2W | 512 MB RAM, quad-core Cortex-A53 |
| Raspberry Pi OS **Bookworm/Trixie Lite** (64-bit) | No desktop needed |
| USB audio interface (class-compliant, ≥4 outputs recommended) | Playback L/R + Click + Cue |
| USB MIDI controller | transport buttons (Play/Stop/Next/Prev) |
| USB MIDI output for automation | can be a port on the audio interface or a separate device |
| SSD1306 OLED (0.96", I2C on GPIO 2/3) | Optional but recommended |
| Powered USB hub | Recommended (Pi has one OTG port) |
| Internet access on Pi | For initial package installation |

## Fresh install

```bash
# 1. Flash Raspberry Pi OS Lite with SSH enabled
#    (Raspberry Pi Imager: set hostname, user, WiFi)

# 2. SSH in and clone
ssh <user>@<pi>.local
git clone https://github.com/lucasaor/lanthon-synth.git
cd lanthon-synth

# 3. Automated setup (installs packages, builds the web UI,
#    installs + enables all systemd services)
sudo ./deploy/setup.sh

# 4. Reboot
sudo reboot
```

## Services

| Service | What it runs | Ports |
|---|---|---|
| `lanth0n-cpugov` | sets CPU governor = performance (oneshot) | — |
| `lanthon-engine` | playback engine — `python3 -m engine.main` | OSC in 57120, OLED out 9000 |
| `lanthon-oled` | OLED display daemon — `oled_daemon.py` | OSC in 9000 |
| `lanthon-web` | SvelteKit web UI | HTTP 5000 |

Check / follow logs:

```bash
sudo systemctl status lanthon-engine lanthon-oled lanthon-web
sudo journalctl -u lanthon-engine -f        # engine log
tail -f /var/log/lanth0n/engine.log /var/log/lanth0n/oled.log /var/log/lanth0n/web.log
```

Healthy boot: engine logs `Engine started (offline=False, sr=48000...)` +
`OSC control server on 0.0.0.0:57120` + `Cued song ...` (if a setlist was
auto-loaded). Web UI shows `🔊 ENGINE ONLINE` within ~15 s.

## First-run configuration

1. Open `http://<pi>.local:5000`.
2. **Files** — upload each song's multichannel WAV + MID files.
3. **Setlists** — create a setlist; per song pick WAV, MID, tuning, key.
   Press "Load to Rig".
4. **Routing** — for each track (Playback L/R, Click, Cue, Timecode,
   MIDI automation) choose the connected device + channel. Save. If a
   device is missing from the list it is simply not connected — plug it
   in and the list refreshes within ~5 s (no restart).
5. **MIDI Map** — Start Learning, press the controller button, assign
   Play / Stop / Next / Prev.
6. **Play** from the dashboard or the controller.

## Pairing a Bluetooth MIDI controller (optional)

```bash
bluetoothctl
  power on
  agent on
  scan on
  # wait for the controller in the scan output
  pair <MAC> && trust <MAC> && connect <MAC>
  exit
# verify it appears as an ALSA MIDI port:
aconnect -i
```

The engine opens every available MIDI input port (refreshed every 2 s),
so the controller needs no further configuration.

## Updating an installed rig

```bash
cd lanthon-synth
git pull
sudo ./deploy/setup.sh            # re-runs installs, rebuilds web, reinstalls units
sudo systemctl restart lanthon-engine lanthon-web lanthon-oled
```

## Troubleshooting

| Symptom | Check |
|---|---|
| Engine restarts in a loop | `journalctl -u lanthon-engine -e` — usually a missing Python package or a bad WAV sample rate (engine requires 48 kHz renders) |
| `🔇 ENGINE OFFLINE` in web UI | engine heartbeat stale — check `lanthon-engine` service + `config/state.json` `engineHeartbeat` |
| No sound on one track | `/routing`: device present? channel within the device's channel count? WAV has that channel? |
| Wrong pitch/speed | WAV sample rate ≠ 48 kHz — re-export from Reaper at 48000 Hz |
| MIDI automation missing | setlist song has a `mid` file, `/routing` MIDI automation device matches a connected MIDI out |
| OLED blank | `i2cdetect -y 1` should show `0x3C`; check `lanthon-oled` log |
| Controller ignored | mapping exists (`/midi`), controller shows under "MIDI in" on `/routing`, channel matches the mapping |

## USB device hot-swap behaviour

- The engine re-enumerates audio + MIDI devices every 5 s and the routing
  screen polls every 3 s — plugging a **different interface** is visible
  immediately and you can re-map tracks on the spot.
- If the configured device is missing, tracks **fall back to the default
  output** (the routing screen shows a warning). Re-assign and Save when
  the replacement device appears.
- If the interface in use is unplugged mid-song, PortAudio reports an
  error and the systemd unit restarts the engine (`Restart=on-failure`).
  On a live rig, prefer to re-map before physically swapping.
