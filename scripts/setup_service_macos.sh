#!/bin/bash

SCRIPT_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$(cd "$(dirname "$0")"; pwd)")")
BASE_DIR=$(dirname "$SCRIPT_DIR")
TEMPLATE_FILE="$BASE_DIR/templates/com.moneroocean.xmrig.plist.template"
TARGET_FILE="$HOME/Library/LaunchAgents/com.moneroocean.xmrig.plist"

# Create LaunchAgents directory if it doesn't exist
mkdir -p "$HOME/Library/LaunchAgents"

# Create logs directory
LOG_DIR="$HOME/.xmrig/logs"
mkdir -p "$LOG_DIR"

# Check if the template exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "Error: Template file not found: $TEMPLATE_FILE"
    exit 1
fi

# Copy the template to the target location
cp "$TEMPLATE_FILE" "$TARGET_FILE"

# Replace placeholders with actual values
XMRIG_PATH="$BASE_DIR/xmrig"
CONFIG_PATH="$BASE_DIR/config_background.json"
WORKING_DIR="$BASE_DIR"

# Use sed compatible with macOS
sed -i '' "s|%%XMRIG_PATH%%|${XMRIG_PATH}|g" "$TARGET_FILE"
sed -i '' "s|%%CONFIG_PATH%%|${CONFIG_PATH}|g" "$TARGET_FILE"
sed -i '' "s|%%LOG_PATH%%|${LOG_DIR}|g" "$TARGET_FILE"
sed -i '' "s|%%WORKING_DIR%%|${WORKING_DIR}|g" "$TARGET_FILE"

# Check if the file was created successfully
if [ ! -f "$TARGET_FILE" ]; then
    echo "Error: Failed to create plist file at $TARGET_FILE"
    exit 1
fi

# Unload the service if it's already loaded (to avoid conflicts)
launchctl unload "$TARGET_FILE" 2>/dev/null || true

# Load the service
echo "Loading XMRig service..."
launchctl load "$TARGET_FILE" 2>/dev/null || {
    echo "Warning: Failed to load service through launchctl."
    echo "XMRig service has been setup, but not started."
    echo "Use 'make start' to start mining."
    exit 0
}

echo "XMRig service has been setup and loaded successfully."
echo "Use 'make status' to check its status."
exit 0