#!/bin/bash

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
BASE_DIR=$(dirname "$SCRIPT_DIR")
TEMPLATE_FILE="$BASE_DIR/templates/xmrig.service.template"
TARGET_FILE="/etc/systemd/system/xmrig.service"
LOGROTATE_TEMPLATE="$BASE_DIR/templates/logrotate.xmrig.template"
LOGROTATE_TARGET="/etc/logrotate.d/xmrig"

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

# Root installs what this user stages. Staged under a fixed name in the shared /tmp, another local
# user could create that name first and rewrite the unit, its User= line included; mktemp adds a
# random part nobody can guess and creates the file for this user alone (macOS's mktemp ignores
# TMPDIR without a template, hence the explicit one). Both are created before anything
# is installed, so a failure leaves the host as it was.
LOGROTATE=false
if command -v logrotate >/dev/null 2>&1 && [ -f "$LOGROTATE_TEMPLATE" ]; then
    LOGROTATE=true
fi
UNIT_STAGED=$(mktemp "${TMPDIR:-/tmp}/xmrig-unit.XXXXXXXXXX") || { echo "ERROR: Failed to create a temporary file."; exit 1; }
trap 'rm -f -- "$UNIT_STAGED" "${LOGROTATE_STAGED:-}"' EXIT
if [ "$LOGROTATE" = true ]; then
    LOGROTATE_STAGED=$(mktemp "${TMPDIR:-/tmp}/xmrig-logrotate.XXXXXXXXXX") || { echo "ERROR: Failed to create a temporary file."; exit 1; }
fi

# Install systemd service file
sed -e "s|%%USER%%|$(whoami)|g" -e "s|%%WORKING_DIR%%|${BASE_DIR}|g" "$TEMPLATE_FILE" > "$UNIT_STAGED"
if ! sudo install -o root -g root -m 644 "$UNIT_STAGED" "$TARGET_FILE"; then
    echo "ERROR: Failed to install $TARGET_FILE."
    exit 1
fi
sudo systemctl daemon-reload
sudo systemctl enable xmrig.service

# Install logrotate config (best-effort: skip if logrotate is absent)
if [ "$LOGROTATE" = true ]; then
    sed -e "s|%%LOG_DIR%%|${BASE_DIR}/logs|g" -e "s|%%USER%%|$(whoami)|g" "$LOGROTATE_TEMPLATE" > "$LOGROTATE_STAGED"
    if ! sudo install -o root -g root -m 644 "$LOGROTATE_STAGED" "$LOGROTATE_TARGET"; then
        echo "ERROR: Failed to install $LOGROTATE_TARGET."
        exit 1
    fi
    echo "Installed logrotate config at $LOGROTATE_TARGET (daily, 7 rotations)."
else
    echo "Skipping logrotate setup (logrotate not installed)."
fi

echo "XMRig service has been setup and enabled, but not started."
echo "Use 'make start' to start mining."

exit 0
