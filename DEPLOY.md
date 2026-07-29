# DEPLOY.md — LANTH0N 5YNTH Deployment Guide

How to go from a **fresh Raspberry Pi OS Bookworm Lite** to a fully functional
headless boot of LANTH0N 5YNTH with three auto-starting services.

---

## Prerequisites

| Item | Notes |
|------|-------|
| Raspberry Pi Zero 2W | 512 MB RAM, quad-core Cortex-A53 |
| Raspberry Pi OS **Bookworm Lite** (64-bit) | No desktop needed |
| USB audio interface (class-compliant, ≥4 outputs) | FOH = ch 1–2, IEM = ch 3–4 |
| SSD1306 OLED (0.96", I2C, SDA/SCL on GPIO 2/3) | Optional but recommended |
| Powered USB hub | Required (Pi has one OTG port) |
| AKAI APC Mini **v2** | USB, plugged into hub |
| Worlde Easypad 12 | USB, plugged into hub |
| M-VAVE SMK 25 | Bluetooth MIDI |
| Internet access on Pi | For initial package installation |

---

## Quick Start (Automated)

```bash
# 1. Flash Raspberry Pi OS Bookworm Lite to SD card with SSH enabled
#    (use Raspberry Pi Imager, set hostname=lanth0n, enable SSH, set user=pi)

# 2. SSH into the Pi after first boot
ssh pi@lanth0n.local

# 3. Clone the repo
git clone https://github.com/lucasaor/lanthon-synth.git
cd lanthon-synth

# 4. Run the automated setup (takes ~5-10 min)
sudo ./deploy/setup.sh

# 5. Configure the JACK audio device (find your device index)
aplay -l                  # find your USB audio interface
sudo nano /usr/local/bin/lanthon-jack-start.sh
# Change: -d alsa -d hw:USB  →  -d alsa -d hw:N  (N = device index)

# 6. Pair the SMK25 Bluetooth keyboard (first time only)
bluetoothctl
  power on
  agent on
  scan on
  # Wait for "SMK-25" to appear in the scan output
  pair <MAC_ADDRESS>
  trust <MAC_ADDRESS>
  connect <MAC_ADDRESS>
  exit

# 7. Reboot
sudo reboot

# 8. After reboot (~30 seconds), check service status
sudo systemctl status lanth0n-synth lanth0n-oled lanth0n-web
```

---

## Services Overview

After installation, three `systemd` services run on boot:

| Service             | Description                                  | Port |
|---------------------|----------------------------------------------|------|
| `lanth0n-synth`     | SuperCollider audio engine (sclang)          | 57120 (OSC) |
| `lanth0n-oled`      | Python OLED display daemon                   | 9000 (OSC in) |
| `lanth0n-web`       | SvelteKit web configuration UI               | 5000 (HTTP) |

> The loop engine (`src/loops.scd`) runs **inside** `lanth0n-synth` — it is loaded by `main.scd` and shares the same process.

Manage services:
```bash
sudo systemctl status lanth0n-synth     # check status
sudo systemctl restart lanth0n-synth    # restart after config change
sudo journalctl -u lanth0n-synth -f     # live logs
sudo systemctl stop lanth0n-web         # stop web UI during performance
```

---

## Audio Routing

The Pi requires a class-compliant USB audio interface with **at least 4 output channels**.

| SC Bus | Physical Channels | Destination |
|--------|-----------------|-------------|
| 0–1    | 1–2             | FOH (main PA / VS backtrack) |
| 2–3    | 3–4             | IEM (click + cue, monitor only) |

JACK is configured in `/usr/local/bin/lanthon-jack-start.sh`. Key flags:
```bash
jackd -R -d alsa \
  -d hw:USB \    # ← change to hw:N matching your interface (aplay -l)
  -r 44100 \
  -p 256 \       # buffer size: lower = less latency, more risk of xruns
  -n 2 \         # number of JACK periods
  -o 4 \         # 4 output channels
  -i 2
```

---

## I2C OLED Wiring (SSD1306)

| OLED Pin | Pi GPIO Pin | Pi Physical Pin |
|----------|-------------|-----------------|
| VCC      | 3.3V        | Pin 1           |
| GND      | GND         | Pin 6           |
| SDA      | GPIO 2      | Pin 3           |
| SCL      | GPIO 3      | Pin 5           |

Verify detection: `i2cdetect -y 1` → should show `3c` at address 0x3C.

The OLED address can be changed via `LANTH0N_I2C_ADDR` env var in
`/etc/systemd/system/lanth0n-oled.service`.

---

## Bluetooth MIDI (SMK25 Pairing)

1. Pair once with `bluetoothctl` (see Quick Start above).
2. The `auto-connect` feature in bluez should reconnect on boot.
3. If it doesn't auto-reconnect, add a post-boot connect script:
   ```bash
   # /etc/rc.local (add before "exit 0"):
   sleep 15 && bluetoothctl connect <SMK25_MAC> &
   ```
4. The MIDI routing code auto-detects the SMK25 when it connects and
   re-registers handlers. No manual restart required.

---

## CPU Performance Governor

The setup script sets the CPU to `performance` mode persistently via `/etc/rc.local`.
Verify: `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` → should print `performance`.

---

## Post-Deployment Calibration

After the rig is running, run the calibration tool to capture real MIDI mappings:

```bash
# On the Pi (SSH):
sclang src/calibration.scd

# Then press every button/fader/pad/knob on each controller.
# Copy the srcID values and note/CC numbers into CONTROLS.md.
# Update the device name fragments in src/midi_routing.scd if needed.
# For SMK25 knob CCs: update ~smkKnobMap in src/midi_routing.scd or
#   use the web MIDI-learn page at http://lanth0n.local:5000/midi
```

## Initial Configuration

After calibration, configure the rig via the web interface:

1. **Upload samples** for Worlde pads and SMK25 pads (Files page).
2. **Create a setlist** with at least one song to test backtrack (Setlists page).
3. **Assign Worlde pad samples** (Worlde Pads page).
4. **Assign SMK25 pad samples** (SMK25 Pads page) if using pad samples.
5. **Verify SMK25 knob CCs** match the defaults in CONTROLS.md (MIDI Map page).
6. **Set APC Mini loop length** on row 7 (default: pad 1 = 2 bars).

---

## Updating the Rig

```bash
cd ~/lanthon-synth
git pull
# Rebuild web interface if web/ changed:
cd web && npm install && npm run build && cd ..
# Restart services:
sudo systemctl restart lanth0n-synth lanth0n-oled lanth0n-web
```

---

## Log Locations

| Log file                         | Contents                    |
|----------------------------------|-----------------------------|
| `/var/log/lanth0n/synth.log`     | SuperCollider output + errors |
| `/var/log/lanth0n/oled.log`      | OLED daemon output          |
| `/var/log/lanth0n/web.log`       | Web interface output        |
| `/var/log/lanth0n/jack.log`      | JACK audio server output    |

Tail all logs:
```bash
tail -f /var/log/lanth0n/*.log
```

---

## Known Package Differences: Pi OS vs Debian Bookworm

The setup script handles these automatically, but here is what differs:

| Package            | Debian Bookworm | Pi OS Bookworm | Notes |
|--------------------|-----------------|----------------|-------|
| `supercollider-sclang` | ✓ available | ✗ not split | Installed as `supercollider` meta-package |
| `supercollider-server` | ✓ available | ✗ not split | Same as above |
| `jack-tools`       | ✓ available     | ✗ not in repos | Not needed — `jackd2` provides all runtime tools |
| `cpufrequtils`     | ✓ available     | ✗ not in repos | Not needed — CPU governor set via `/sys/` directly |
| `a2jmidid`         | ✓ available     | ✓ available    | ALSA→JACK MIDI bridge (optional but recommended) |

If `sclang` is missing after install, verify with:
```bash
which sclang        # should print /usr/bin/sclang
sclang --version    # should print a version number
```

If `sclang` is not present, install SuperCollider manually:
```bash
sudo apt-get install supercollider
# If still not found, check if sclang is provided by the package:
dpkg -L supercollider | grep sclang
```

---

## Troubleshooting Boot Issues

```bash
# Check all service statuses at once
sudo systemctl status lanth0n-synth lanth0n-oled lanth0n-web

# Check JACK
cat /var/log/lanth0n/jack.log

# Verify OLED I2C
i2cdetect -y 1

# Check audio devices
aplay -l && arecord -l

# Verify CPU governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# Check BT
bluetoothctl show | grep Powered
```

