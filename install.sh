#!/bin/bash
# Installer for the Huawei MateBook HWSP0001 speaker amp fix.
# Installs to /usr/local/bin when writable, otherwise falls back to /opt
# (e.g. on ostree/immutable systems where /usr is a read-only overlay).
set -e

SRC_DIR="$(dirname "$(readlink -f "$0")")"
SCRIPT_SRC="$SRC_DIR/huawei-speaker-mute.sh"
SERVICE_SRC="$SRC_DIR/huawei-speaker-mute.service"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this installer as root: sudo bash install.sh" >&2
    exit 1
fi

if [ -w /usr/local/bin ]; then
    BIN_DIR=/usr/local/bin
else
    BIN_DIR=/opt
fi
INSTALL_BIN="$BIN_DIR/huawei-speaker-mute.sh"
echo "Installing script to $INSTALL_BIN ..."
install -m 0755 "$SCRIPT_SRC" "$INSTALL_BIN"

echo "Installing systemd service (ExecStart=$INSTALL_BIN) ..."
sed "s#/usr/local/bin/huawei-speaker-mute.sh#$INSTALL_BIN#" "$SERVICE_SRC" \
    > /etc/systemd/system/huawei-speaker-mute.service

echo "Reloading and enabling service ..."
systemctl daemon-reload
systemctl enable --now huawei-speaker-mute.service

echo "Done. Check status with: sudo systemctl status huawei-speaker-mute.service"
