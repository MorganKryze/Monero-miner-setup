#!/bin/bash

SCRIPT_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$(
    cd "$(dirname "$0")"
    pwd
)")")
BASE_DIR=$(dirname "$SCRIPT_DIR")
TEMPLATE_FILE="$BASE_DIR/templates/com.moneroocean.xmrig.plist.template"
TARGET_FILE="$HOME/Library/LaunchAgents/com.moneroocean.xmrig.plist"

# shellcheck source=setup_service_common.sh
source "$SCRIPT_DIR/setup_service_common.sh" || { echo "Error: $SCRIPT_DIR/setup_service_common.sh not found."; exit 1; }

# Ensure XMRig is executable
if [ ! -x "$BASE_DIR/xmrig" ]; then
    echo "Making XMRig executable..."
    chmod +x "$BASE_DIR/xmrig"
fi

# Check if XMRig exists
if [ ! -f "$BASE_DIR/xmrig" ]; then
    echo "Error: XMRig executable not found at $BASE_DIR/xmrig"
    echo "Please build XMRig first using 'make build'"
    exit 1
fi

# Check if config exists, create if it doesn't
CONFIG_FILE="$BASE_DIR/config_background.json"
if [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "$BASE_DIR/config.json" ]; then
        echo "Creating background config from existing config.json..."
        cp "$BASE_DIR/config.json" "$CONFIG_FILE"
    else
        echo "Error: No configuration file found"
        exit 1
    fi
fi

# The job runs this config: in background mode, launchd would start a new miner each time the
# last one forks away.
if ! turn_background_off "$CONFIG_FILE"; then
    echo "Error: Failed to turn off background mode in $CONFIG_FILE"
    exit 1
fi

# Create LaunchAgents directory if it doesn't exist
mkdir -p "$HOME/Library/LaunchAgents"

# Create logs directory within the repository
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

# Check if the template exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "Error: Template file not found: $TEMPLATE_FILE"
    exit 1
fi

# Write the plist from the template with the actual paths
XMRIG_PATH="$BASE_DIR/xmrig"
CONFIG_PATH="$CONFIG_FILE"
WORKING_DIR="$BASE_DIR"
sed -e "s|%%XMRIG_PATH%%|${XMRIG_PATH}|g" -e "s|%%CONFIG_PATH%%|${CONFIG_PATH}|g" \
    -e "s|%%LOG_PATH%%|${LOG_DIR}|g" -e "s|%%WORKING_DIR%%|${WORKING_DIR}|g" "$TEMPLATE_FILE" > "$TARGET_FILE"

# Set correct permissions on the plist file
chmod 644 "$TARGET_FILE"

report_detached_miners "$CONFIG_FILE" "$(launchctl list | awk '$3 == "com.moneroocean.xmrig" {print $1}')"

# Unload the service if it's already loaded (to avoid conflicts)
launchctl unload "$TARGET_FILE" 2>/dev/null || true

# Load the service
echo "Loading XMRig service..."
launchctl load -w "$TARGET_FILE"
LOAD_RESULT=$?

if [ $LOAD_RESULT -eq 0 ]; then
    echo "XMRig service has been setup and loaded successfully."
    echo "Use 'make status' to check its status."
else
    echo "Warning: Failed to load service through launchctl (error $LOAD_RESULT)."

    # Check logs in case of failure
    if [ -f "$LOG_DIR/xmrig_stderr.log" ]; then
        echo "Checking error log:"
        tail -n 10 "$LOG_DIR/xmrig_stderr.log"
    fi

    echo "XMRig service has been setup, but not started."
    echo "Use 'make start' to start mining."
fi

exit 0
