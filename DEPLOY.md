# DEPLOY.md — Deployment Guide

How to go from a **fresh Raspberry Pi OS (Bookworm)** install to a fully
functional, auto-booting headless live performance rig.

---

## Prerequisites

- Raspberry Pi Zero 2W (quad-core Cortex-A53, 512MB RAM)
- Raspberry Pi OS Bookworm (Lite recommended — no desktop needed)
- USB audio interface (class-compliant) or I2S DAC HAT
- Powered USB hub (required — the Zero 2W has only one micro-USB OTG port)
- Three MIDI controllers (APC Mini, Easypad 12, SMK25) connected via the hub
- Internet access for initial package installation

---

## Quick Start (Automated)

```bash
# 1. Clone the repository on the Pi
git clone https://github.com/lucasaor/lanthon-synth.git
cd lanthon-synth

# 2. Run the setup script
sudo ./deploy/setup.sh

# 3. Reboot
sudo reboot

# 4. After reboot, the rig starts automatically.
#    Check status:
sudo systemctl status lanthon-synth
sudo journalctl -u lanthon-synth -f
```

---

## Manual Setup (Step-by-Step)

### Step 1: Flash Raspberry Pi OS

1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Flash **Raspberry Pi OS Lite (Bookworm, 64-bit)** to a microSD card
3. Before ejecting, configure:
   - Hostname: `lanthon-synth` (or your choice)
   - SSH: enabled
   - User: `pi` (or your choice)
   - Wi-Fi: pre-configure if not using Ethernet

### Step 2: First Boot & SSH

```bash
ssh pi@lanthon-synth.local
# or use the IP address
```

### Step 3: System Update

```bash
sudo apt update && sudo apt upgrade -y
sudo reboot
```

### Step 4: Install Dependencies

```bash
sudo apt install -y \
  supercollider \
  supercollider-server \
  supercollider-sclang \
  jackd2 \
  jack-tools \
  git \
  cpufrequtils \
  usbutils \
  alsa-utils
```

### Step 5: Set CPU Governor to `performance`

```bash
# Immediate:
echo "performance" | sudo tee /sys/devices/system/cpu/cpufreq/policy0/scaling_governor

# Persistent:
sudo bash -c 'cat > /etc/default/cpufrequtils << EOF
GOVERNOR="performance"
MAX_SPEED="0"
MIN_SPEED="0"
EOF'
sudo systemctl enable cpufrequtils
```

### Step 6: Configure Real-Time Audio Privileges

```bash
sudo usermod -a -G audio pi

sudo bash -c 'cat > /etc/security/limits.d/99-audio.conf << EOF
@audio   -  rtprio     95
@audio   -  memlock    unlimited
@audio   -  nice       -19
EOF'
```

### Step 7: Clone the Project

```bash
git clone https://github.com/lucasaor/lanthon-synth.git /home/pi/lanthon-synth
```

### Step 8: Run Calibration

```bash
# Connect all three MIDI controllers via the powered USB hub
# Run the calibration tool:
sclang /home/pi/lanthon-synth/src/calibration.scd

# Press every pad, key, fader, and grid button on each controller.
# Copy the output into CONTROLS.md.
# Update ~srcID_APC, ~srcID_Easy, ~srcID_SMK in midi_routing.scd.
# Update ~apcFaderMap and ~easyPadMap with real note/CC numbers.
```

### Step 9: Install the systemd Service

```bash
sudo cp /home/pi/lanthon-synth/deploy/lanthon-synth.service /etc/systemd/system/
sudo sed -i 's|%PROJECT_DIR%|/home/pi/lanthon-synth|g' /etc/systemd/system/lanthon-synth.service
sudo sed -i 's|%USER%|pi|g' /etc/systemd/system/lanthon-synth.service
sudo systemctl daemon-reload
sudo systemctl enable lanthon-synth
```

### Step 10: Test Before Rebooting

```bash
# Start the service manually to verify:
sudo systemctl start lanthon-synth

# Check logs:
sudo journalctl -u lanthon-synth -f

# Check CPU governor:
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
# Should print: performance

# Press controllers, verify audio + LEDs work.

# Stop the service:
sudo systemctl stop lanthon-synth
```

### Step 11: Reboot and Verify Auto-Start

```bash
sudo reboot

# After boot (give it ~30 seconds):
ssh pi@lanthon-synth.local
sudo systemctl status lanthon-synth
# Should show: active (running)

# Check for xruns:
sudo journalctl -u lanthon-synth | grep -i xrun
```

---

## Audio Interface Notes

### USB Audio (Recommended)

Most class-compliant USB audio interfaces work out of the box.  The JACK start
script auto-detects the first USB device.  Override with:

```bash
export JACK_DEVICE="hw:USB"
```

Edit `/usr/local/bin/lanthon-jack-start.sh` for permanent changes.

### I2S DAC HAT

If using an I2S DAC (e.g., Pisound, Audio Injector, HifiBerry):

1. Enable the overlay in `/boot/firmware/config.txt`:
   ```
   dtoverlay=hifiberry-dac
   ```
2. Set `JACK_DEVICE="hw:sndrpihifiberry"` (or the correct ALSA device name)
3. I2S may have higher latency than USB — test with `jack_bufsize`

### Separate Click/Monitor Output

The click signal is routed to bus 2-3 (separate from main bus 0-1).  
If your audio interface has 4+ output channels:
- Main (FOH): outputs 1-2
- Click (monitor): outputs 3-4

If only stereo output is available, the click is hard-panned left and main
mix panned right — split at the mixer.  Edit `~clickOutBus` and `~mainOutBus`
in `synths.scd` to change this.

---

## Troubleshooting

| Symptom                              | Likely Cause                      | Fix                                    |
|--------------------------------------|-----------------------------------|----------------------------------------|
| Service fails to start               | JACK can't find audio device      | Check `aplay -l`, set `JACK_DEVICE`    |
| Audio glitches / xruns               | CPU governor not `performance`    | Run Step 5 again                       |
| Audio glitches / xruns               | Buffer too small                  | Increase `-p` in JACK script (try 256) |
| MIDI controllers not responding      | srcID not set after calibration   | Set `~srcID_*` globals, update CONTROLS.md |
| APC LEDs not updating                | MIDI Out not connected            | Check USB cable, verify `~apcMidiOut`  |
| "Cannot connect to server"           | scsynth not running               | `scsynth -u 57110` manually to test    |
| Out of memory                        | Buffer too large or too many      | Reduce `~loopDuration` in loops.scd    |

---

## Useful Commands (on the Pi)

```bash
# Service control
sudo systemctl start lanthon-synth
sudo systemctl stop lanthon-synth
sudo systemctl restart lanthon-synth
sudo systemctl status lanthon-synth

# Live log tail
sudo journalctl -u lanthon-synth -f

# CPU governor status
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor

# List audio devices
aplay -l
arecord -l

# List USB devices
lsusb

# List MIDI devices
amidi -l
aconnect -l

# Check JACK
jack_lsp
jack_bufsize
```

---

## Updating the Code

```bash
cd /home/pi/lanthon-synth
git pull
sudo systemctl restart lanthon-synth
```

No reboot needed — the service restart is sufficient.
