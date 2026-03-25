#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# setup-systemd.sh — systemd timer/serviceファイルをインストール
#
# Usage: sudo ./scripts/setup-systemd.sh
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEMD_DIR="$(dirname "$SCRIPT_DIR")/systemd"
TARGET_DIR="/etc/systemd/system"

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (sudo)" >&2
    exit 1
fi

echo "Installing systemd unit files..."

for unit in "${SYSTEMD_DIR}"/trend-ch*.{timer,service}; do
    filename="$(basename "$unit")"
    echo "  ${filename}"
    cp "$unit" "${TARGET_DIR}/${filename}"
done

echo "Reloading systemd..."
systemctl daemon-reload

echo "Enabling timers..."
for timer in "${SYSTEMD_DIR}"/trend-ch*.timer; do
    name="$(basename "$timer")"
    systemctl enable --now "$name"
    echo "  Enabled: ${name}"
done

echo ""
echo "Status:"
systemctl list-timers 'trend-ch*' --no-pager
