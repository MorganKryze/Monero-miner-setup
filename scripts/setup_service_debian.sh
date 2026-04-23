#!/bin/bash

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
BASE_DIR=$(dirname "$SCRIPT_DIR")
TEMPLATE_FILE="$BASE_DIR/templates/xmrig.service.template"
TARGET_FILE="/tmp/xmrig.service"
LOGROTATE_TEMPLATE="$BASE_DIR/templates/logrotate.xmrig.template"
LOGROTATE_TARGET="/tmp/xmrig.logrotate"

# Check if systemd is available
if ! command -v systemctl >/dev/null 2>&1; then
    echo "ERROR: systemd is not available on this system."
    exit 1
fi

# Check if template exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "ERROR: Template file not found at $TEMPLATE_FILE"
    exit 1
fi

# Create logs directory if it doesn't exist
mkdir -p "$BASE_DIR/logs"

# Create temporary service file from template with replacements
cp "$TEMPLATE_FILE" "$TARGET_FILE"
sed -i "s|%%USER%%|$(whoami)|g" "$TARGET_FILE"
sed -i "s|%%WORKING_DIR%%|${BASE_DIR}|g" "$TARGET_FILE"

# Install systemd service file
sudo mv "$TARGET_FILE" /etc/systemd/system/xmrig.service
sudo chmod 644 /etc/systemd/system/xmrig.service
sudo systemctl daemon-reload
sudo systemctl enable xmrig.service

# Install logrotate config (best-effort: skip if logrotate is absent)
if command -v logrotate >/dev/null 2>&1 && [ -f "$LOGROTATE_TEMPLATE" ]; then
    cp "$LOGROTATE_TEMPLATE" "$LOGROTATE_TARGET"
    sed -i "s|%%LOG_DIR%%|${BASE_DIR}/logs|g" "$LOGROTATE_TARGET"
    sed -i "s|%%USER%%|$(whoami)|g" "$LOGROTATE_TARGET"
    sudo mv "$LOGROTATE_TARGET" /etc/logrotate.d/xmrig
    sudo chmod 644 /etc/logrotate.d/xmrig
    echo "Installed logrotate config at /etc/logrotate.d/xmrig (daily, 7 rotations)."
else
    echo "Skipping logrotate setup (logrotate not installed)."
fi

echo "XMRig service has been setup and enabled, but not started."
echo "Use 'make start' to start mining."

exit 0