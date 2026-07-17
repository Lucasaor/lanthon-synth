#!/usr/bin/env bash
# =============================================================================
# deploy/setup.sh — Lanthon Synth Deployment Script
# =============================================================================
# Run this ONCE on a fresh Raspberry Pi OS (Bookworm) install to go from
# bare OS → fully functional headless boot.
#
# Usage:
#   chmod +x deploy/setup.sh
#   sudo ./deploy/setup.sh
#
# What this script does:
#   1. Installs system packages (SuperCollider, JACK, git, etc.)
#   2. Sets CPU governor to `performance` (persistent across reboots)
#   3. Configures JACK for low-latency USB audio
#   4. Installs the systemd service for auto-start on boot
#   5. Creates necessary directories and permissions
#
# After running this, reboot.  The rig should come up fully functional with
# no keyboard/monitor/mouse attached.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$PROJECT_DIR/src"

echo "============================================"
echo " Lanthon Synth — Raspberry Pi Deployment"
echo "============================================"
echo ""

# ---- Check we're on a Pi ----
if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
	echo "WARNING: This doesn't appear to be a Raspberry Pi."
	echo "  Continuing anyway (you may be testing on a different machine)."
fi

# ---- Step 1: System packages ----
echo "=== Step 1: Installing system packages ==="
sudo apt-get update -qq
sudo apt-get install -y -qq \
	supercollider \
	supercollider-server \
	supercollider-sclang \
	jackd2 \
	jack-tools \
	git \
	cpufrequtils \
	usbutils \
	alsa-utils

echo "  Packages installed."

# ---- Step 2: CPU governor → performance ----
echo ""
echo "=== Step 2: CPU governor → performance ==="

# Immediate: set all cores to performance
if [ -d /sys/devices/system/cpu/cpufreq ]; then
	for policy in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
		echo "performance" | sudo tee "$policy" > /dev/null
	done
fi

# Persistent: use cpufrequtils (installed above) to set on boot
# Create /etc/default/cpufrequtils if it doesn't exist
CPU_CONF="/etc/default/cpufrequtils"
if [ ! -f "$CPU_CONF" ]; then
	sudo bash -c "cat > $CPU_CONF << 'EOF'
# Lanthon Synth — force performance governor at all times
GOVERNOR=\"performance\"
MAX_SPEED=\"0\"
MIN_SPEED=\"0\"
EOF"
else
	# Update existing config
	sudo sed -i 's/^GOVERNOR=.*/GOVERNOR="performance"/' "$CPU_CONF"
fi

# Enable the cpufrequtils service
sudo systemctl enable cpufrequtils 2>/dev/null || true

# Verify
echo "  CPU governor: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || echo 'unknown')"
echo "  CPU governor persistence: configured via $CPU_CONF"

# ---- Step 3: Real-time audio privileges ----
echo ""
echo "=== Step 3: Real-time audio privileges ==="

# Add the pi user (or current user) to the audio group
CURRENT_USER="${SUDO_USER:-$USER}"
sudo usermod -a -G audio "$CURRENT_USER" 2>/dev/null || true

# Set rtprio and memlock limits for JACK/SC
LIMITS_CONF="/etc/security/limits.d/99-audio.conf"
sudo bash -c "cat > $LIMITS_CONF << 'EOF'
# Lanthon Synth — real-time audio limits
@audio   -  rtprio     95
@audio   -  memlock    unlimited
@audio   -  nice       -19
EOF"

echo "  Audio group membership and RT limits configured."

# ---- Step 4: JACK configuration ----
echo ""
echo "=== Step 4: JACK configuration ==="

# Create a JACK startup script used by the systemd service
JACK_SCRIPT="/usr/local/bin/lanthon-jack-start.sh"
sudo bash -c "cat > $JACK_SCRIPT << 'JACKEOF'
#!/usr/bin/env bash
# Start JACK with low-latency settings for the Pi Zero 2W.
# USB audio class-compliant interface assumed.
#
# Buffer: 128 frames @ 44100 Hz = ~2.9 ms latency
# Periods: 2 (standard for USB)
#
# If you have a specific USB device name, set it via JACK_DEVICE env var.
# Otherwise we try to auto-detect the first USB audio device.

JACK_DEVICE=\"\${JACK_DEVICE:-}\"

if [ -z \"\$JACK_DEVICE\" ]; then
	# Auto-detect: find the first USB audio card
	JACK_DEVICE=\$(cat /proc/asound/cards 2>/dev/null | grep -i -E 'USB|CODEC' | head -1 | awk '{print \$1}' || echo "")
	if [ -z \"\$JACK_DEVICE\" ]; then
		echo \"No USB audio device found — trying hw:0\"
		JACK_DEVICE=\"hw:0\"
	else
		JACK_DEVICE=\"hw:\$JACK_DEVICE\"
	fi
fi

echo \"Starting JACK with device: \$JACK_DEVICE\"

exec jackd -R -d alsa \
	-d \"\$JACK_DEVICE\" \
	-r 44100 \
	-p 128 \
	-n 2 \
	-S
JACKEOF"
sudo chmod +x "$JACK_SCRIPT"
echo "  JACK start script: $JACK_SCRIPT"

# ---- Step 5: Install systemd service ----
echo ""
echo "=== Step 5: Installing systemd service ==="

SERVICE_FILE="/etc/systemd/system/lanthon-synth.service"
sudo cp "$PROJECT_DIR/deploy/lanthon-synth.service" "$SERVICE_FILE"
sudo chmod 644 "$SERVICE_FILE"

# Update the service file with the correct paths
# (The .service file uses placeholders that we resolve here)
sudo sed -i "s|%PROJECT_DIR%|$PROJECT_DIR|g" "$SERVICE_FILE"
sudo sed -i "s|%USER%|$CURRENT_USER|g" "$SERVICE_FILE"

sudo systemctl daemon-reload
sudo systemctl enable lanthon-synth.service

echo "  Service installed: $SERVICE_FILE"
echo "  Service enabled (will start on next boot)."

# ---- Step 6: Create log directory ----
echo ""
echo "=== Step 6: Creating log directory ==="
LOG_DIR="/var/log/lanthon-synth"
sudo mkdir -p "$LOG_DIR"
sudo chown "$CURRENT_USER:$CURRENT_USER" "$LOG_DIR"
echo "  Log directory: $LOG_DIR"

# ---- Done ----
echo ""
echo "============================================"
echo " DEPLOYMENT COMPLETE"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Reboot:   sudo reboot"
echo "  2. After boot, check status:"
echo "       sudo systemctl status lanthon-synth"
echo "       sudo journalctl -u lanthon-synth -f"
echo "  3. Check CPU governor persisted:"
echo "       cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor"
echo "  4. Verify audio: connect speakers, press a controller button"
echo ""
echo "To stop the rig:"
echo "  sudo systemctl stop lanthon-synth"
echo ""
echo "To disable auto-start:"
echo "  sudo systemctl disable lanthon-synth"
