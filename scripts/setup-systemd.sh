#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# setup-systemd.sh — systemd timer/serviceファイルをインストール
#
# Usage: sudo ./scripts/setup-systemd.sh <username>
#   例: sudo ./scripts/setup-systemd.sh miyaryo
#
# serviceファイル内のプレースホルダーを実行環境に合わせて置換し、
# /etc/systemd/system にインストールする。
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEM_DIR="$(dirname "$SCRIPT_DIR")"
SYSTEMD_DIR="${SYSTEM_DIR}/systemd"
TARGET_DIR="/etc/systemd/system"

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (sudo)" >&2
    exit 1
fi

TARGET_USER="${1:-}"
if [[ -z "$TARGET_USER" ]]; then
    echo "Usage: sudo $0 <username>" >&2
    echo "  例: sudo $0 miyaryo" >&2
    exit 1
fi

TARGET_HOME="$(eval echo "~${TARGET_USER}")"
if [[ ! -d "$TARGET_HOME" ]]; then
    echo "Error: Home directory not found for user '${TARGET_USER}'" >&2
    exit 1
fi

echo "Installing systemd unit files..."
echo "  User: ${TARGET_USER}"
echo "  Home: ${TARGET_HOME}"
echo "  System dir: ${SYSTEM_DIR}"
echo ""

for unit in "${SYSTEMD_DIR}"/trend-ch*.{timer,service}; do
    [[ -f "$unit" ]] || continue
    filename="$(basename "$unit")"
    echo "  ${filename}"

    sed -e "s|__USER__|${TARGET_USER}|g" \
        -e "s|__HOME__|${TARGET_HOME}|g" \
        -e "s|__SYSTEM_DIR__|${SYSTEM_DIR}|g" \
        "$unit" > "${TARGET_DIR}/${filename}"
done

echo ""
echo "Reloading systemd..."
systemctl daemon-reload

echo "Enabling timers..."
for timer in "${SYSTEMD_DIR}"/trend-ch*.timer; do
    [[ -f "$timer" ]] || continue
    name="$(basename "$timer")"
    systemctl enable --now "$name"
    echo "  Enabled: ${name}"
done

echo ""
echo "Status:"
systemctl list-timers 'trend-ch*' --no-pager
