#!/usr/bin/env bash
# install.sh — install unattended-upgrade-stuck-kill system-wide
#
# Run as root. Copies script + systemd units to canonical paths and
# enables + starts the timer. Idempotent: re-running is safe.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (use sudo)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_SRC="$SCRIPT_DIR/bin/unattended-upgrade-stuck-kill.sh"
SERVICE_SRC="$SCRIPT_DIR/systemd/unattended-upgrade-stuck-kill.service"
TIMER_SRC="$SCRIPT_DIR/systemd/unattended-upgrade-stuck-kill.timer"

SCRIPT_DST="/usr/local/bin/unattended-upgrade-stuck-kill.sh"
SERVICE_DST="/etc/systemd/system/unattended-upgrade-stuck-kill.service"
TIMER_DST="/etc/systemd/system/unattended-upgrade-stuck-kill.timer"
LOG_DIR="/var/log/unattended-upgrade-stuck-kill"

echo "=== Step 1: install script ==="
install -m 0755 "$SCRIPT_SRC" "$SCRIPT_DST"
echo "  $SCRIPT_DST"

echo "=== Step 2: install systemd units ==="
install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
install -m 0644 "$TIMER_SRC" "$TIMER_DST"
echo "  $SERVICE_DST"
echo "  $TIMER_DST"

echo "=== Step 3: ensure log dir exists ==="
mkdir -p "$LOG_DIR"
chmod 0755 "$LOG_DIR"
echo "  $LOG_DIR"

echo "=== Step 4: reload systemd + enable timer ==="
systemctl daemon-reload
systemctl enable unattended-upgrade-stuck-kill.timer
systemctl restart unattended-upgrade-stuck-kill.timer

echo "=== Step 5: validate via self-test ==="
"$SCRIPT_DST" --test-sentinel

echo ""
echo "OK. Check status: systemctl status unattended-upgrade-stuck-kill.timer"
echo "Next trigger:    systemctl list-timers unattended-upgrade-stuck-kill.timer"
echo "Manual run:      systemctl start unattended-upgrade-stuck-kill.service"
echo "Dry-run:         $SCRIPT_DST --dry-run"
echo "Logs:            tail -f $LOG_DIR/stuck-kill.log"
