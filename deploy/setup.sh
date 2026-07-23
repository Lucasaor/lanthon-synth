#!/usr/bin/env bash
# =============================================================================
# deploy/setup.sh — LANTH0N 5YNTH Deployment Script
# =============================================================================
# Run ONCE on a fresh Raspberry Pi OS (Bookworm Lite) as root:
#   sudo ./deploy/setup.sh
#
# What it does:
#   1. System packages: SuperCollider, JACK, Python, Node.js, ffmpeg, etc.
#   2. CPU governor → performance (persistent)
#   3. Enable I2C (for SSD1306 OLED)
#   4. Enable Bluetooth MIDI support (for SMK25)
#   5. Install Python packages (luma.oled, python-osc, Pillow)
#   6. Build SvelteKit web interface
#   7. Install and enable 3 systemd services
#   8. Create required directories + JACK helper script
#   9. Configure mDNS hostname (lanth0n.local)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SERVICE_USER="${SUDO_USER:-pi}"
LOG_DIR="/var/log/lanth0n"

echo ""
echo "============================================"
echo " LANTH0N 5YNTH — Raspberry Pi Deployment"
echo "============================================"
echo ""
echo "  Project dir : $PROJECT_DIR"
echo "  Service user: $SERVICE_USER"
echo ""

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root (sudo ./deploy/setup.sh)"
  exit 1
fi

if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
  echo "WARNING: Not a Raspberry Pi — some steps may fail (continuing anyway)."
fi

# ── Step 1: System packages ──────────────────────────────────────────────────
echo "=== [1/9] Installing system packages ==="
apt-get update -qq
apt-get install -y -qq \
  supercollider supercollider-server supercollider-sclang \
  jackd2 jack-tools \
  python3 python3-pip python3-smbus \
  i2c-tools \
  nodejs npm \
  ffmpeg \
  git cpufrequtils usbutils alsa-utils \
  avahi-daemon libnss-mdns \
  bluetooth bluez

echo "  Packages installed."

# ── Step 2: CPU governor → performance ──────────────────────────────────────
echo ""
echo "=== [2/9] CPU governor → performance ==="

# Immediate: set all cores
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$cpu" 2>/dev/null || true
done

# Persistent via lanth0n-cpugov.service (systemd unit)
# Installed in Step 8 below. Replaces the old rc.local hack which had
# an "append after exit 0" bug (mitigation plan issue #11).
echo "  CPU governor set to performance (persistent via systemd unit)."

# ── Step 3: Enable I2C ───────────────────────────────────────────────────────
echo ""
echo "=== [3/9] Enabling I2C ==="
if command -v raspi-config &>/dev/null; then
  raspi-config nonint do_i2c 0
else
  if ! grep -q "dtparam=i2c_arm=on" /boot/config.txt 2>/dev/null; then
    echo "dtparam=i2c_arm=on" >> /boot/config.txt
    echo "  Added i2c_arm=on to /boot/config.txt (reboot required)"
  fi
fi
modprobe i2c-dev 2>/dev/null || true
usermod -aG i2c "$SERVICE_USER" 2>/dev/null || true
echo "  I2C enabled. Verify with: i2cdetect -y 1"

# ── Step 4: Bluetooth MIDI (SMK25 support) ───────────────────────────────────
echo ""
echo "=== [4/9] Configuring Bluetooth MIDI ==="
systemctl enable bluetooth --now 2>/dev/null || true
usermod -aG bluetooth "$SERVICE_USER" 2>/dev/null || true

# Enable BlueZ MIDI plugin (required for SMK25 to appear as ALSA sequencer)
BLUEZ_CONF="/etc/bluetooth/main.conf"
if ! grep -q "Plugins=midi" "$BLUEZ_CONF" 2>/dev/null; then
  if grep -q "^Plugins=" "$BLUEZ_CONF" 2>/dev/null; then
    sed -i 's/^Plugins=.*/&,midi/' "$BLUEZ_CONF"
  elif grep -q "^\[General\]" "$BLUEZ_CONF" 2>/dev/null; then
    sed -i '/^\[General\]/a Plugins=midi' "$BLUEZ_CONF"
  fi
fi

# Install bluez-tools for bt-device CLI
apt-get install -y -qq bluez-tools 2>/dev/null || true
echo "  Bluetooth MIDI plugin enabled."
echo "  Pair the SMK25 after reboot: bluetoothctl"
echo "  Then: trust <MAC> && connect <MAC>"
echo "  After pairing, verify: aconnect -i (should show SMK-25)"

# ── Step 5: Python packages ──────────────────────────────────────────────────
echo ""
echo "=== [5/9] Installing Python packages ==="
pip3 install --break-system-packages luma.oled python-osc Pillow 2>/dev/null || \
pip3 install luma.oled python-osc Pillow
echo "  Python packages installed."

# ── Step 5b: Install SuperCollider JSONlib quark ─────────────────────────
echo ""
echo "=== [5b] Installing JSONlib quark ==="
# JSONlib is required for setlist loading, PC snapshots, and pad configs.
# The regex-based stubs in the SC code will fail on real JSON files.
sclang -c 'Quarks.install("JSONlib"); Quarks.install("JSONlib");' 2>/dev/null || \
  echo "  WARNING: JSONlib install failed — install manually: sclang -c 'Quarks.install(\"JSONlib\");'"
echo "  JSONlib quark installed."

# ── Step 6: Build SvelteKit web interface ────────────────────────────────────
echo ""
echo "=== [6/9] Building web interface ==="
cd "$PROJECT_DIR/web"
npm install --quiet
npm run build
echo "  Web interface built."
cd "$PROJECT_DIR"

# ── Step 7: Create directories + JACK helper (with auto-detect) ─────────────
echo ""
echo "=== [7/9] Creating directories and JACK helper ==="
mkdir -p "$LOG_DIR" "$PROJECT_DIR/media" "$PROJECT_DIR/samples" "$PROJECT_DIR/setlists"
chown -R "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR" "$PROJECT_DIR"

# Auto-detect USB audio interface for JACK.
# If no USB card found, fall back to hw:0 (onboard or first card).
USB_CARD=$(aplay -l 2>/dev/null | grep -i usb | head -1 | sed 's/.*card \([0-9]\).*/\1/')
USB_CARD=${USB_CARD:-0}
echo "  USB audio card detected: hw:${USB_CARD}"

# JACK start helper (called from lanthon-synth.service ExecStartPre)
cat > /usr/local/bin/lanthon-jack-start.sh << JACKEOF
#!/usr/bin/env bash
pkill jackd 2>/dev/null || true
sleep 1
jackd -R -d alsa \
  -d hw:${USB_CARD} \
  -r 44100 \
  -p 256 \
  -n 2 \
  -o 4 \
  -i 2 \
  &>/var/log/lanth0n/jack.log &
sleep 2
JACKEOF
chmod +x /usr/local/bin/lanthon-jack-start.sh
echo "  JACK helper installed (auto-detected hw:${USB_CARD})."
echo "  If wrong device, override: sudo nano /usr/local/bin/lanthon-jack-start.sh"

# ── Step 8: Install systemd services ────────────────────────────────────────
echo ""
echo "=== [8/9] Installing systemd services ==="

for SVC in lanth0n-cpugov lanthon-synth lanthon-oled lanthon-web; do
  TMPL="$SCRIPT_DIR/$SVC.service"
  DEST="/etc/systemd/system/$SVC.service"
  if [ -f "$TMPL" ]; then
    sed -e "s|%PROJECT_DIR%|$PROJECT_DIR|g" \
        -e "s|%USER%|$SERVICE_USER|g" \
        "$TMPL" > "$DEST"
    echo "  Installed $DEST"
  fi
done

systemctl daemon-reload
systemctl enable lanth0n-cpugov lanthon-synth lanthon-oled lanthon-web
echo "  Services enabled. They will auto-start on next boot."
echo "  Start now: systemctl start lanth0n-cpugov lanthon-synth lanthon-oled lanthon-web"

# ── Step 9: mDNS hostname ────────────────────────────────────────────────────
echo ""
echo "=== [9/9] Configuring mDNS ==="
HOSTNAME="lanth0n"
hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || echo "$HOSTNAME" > /etc/hostname
systemctl enable avahi-daemon --now 2>/dev/null || true
echo "  Hostname set to $HOSTNAME"
echo "  Access the web interface at: http://lanth0n.local:5000"

# ── Complete ─────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo " SETUP COMPLETE"
echo "============================================"
echo ""
echo " NEXT STEPS:"
echo "   1. sudo reboot"
echo "   2. After reboot:"
echo "        sudo systemctl status lanth0n-cpugov lanthon-synth lanthon-oled lanthon-web"
echo "        sudo journalctl -u lanthon-synth -f"
echo "   3. Pair the SMK25 (Bluetooth): bluetoothctl"
echo "        power on → agent on → scan on → pair <MAC> → trust <MAC> → connect <MAC>"
echo "        Verify MIDI: aconnect -i (should show SMK-25)"
echo "   4. Verify OLED I2C: i2cdetect -y 1 (should show 0x3C)"
echo "   5. Run calibration: sclang src/calibration.scd"
echo "   6. Open web UI from another device: http://lanth0n.local:5000"
echo "   7. Upload media files, create a setlist, and play"
echo ""
