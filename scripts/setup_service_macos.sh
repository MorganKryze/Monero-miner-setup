#!/bin/bash

SCRIPT_DIR=$(dirname "$(readlink -f "$0" || echo "$(echo "$0" | sed -e 's,\\,/,g')")")
BASE_DIR=$(dirname "$SCRIPT_DIR")
TEMPLATE_FILE="$BASE_DIR/config/com.moneroocean.xmrig.plist.template"
TARGET_FILE="$HOME/Library/LaunchAgents/com.moneroocean.xmrig.plist"

# Check if template exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "ERROR: Template file not found at $TEMPLATE_FILE"
    exit 1
fi

# Create LaunchAgents directory if it doesn't exist
mkdir -p "$HOME/Library/LaunchAgents"

# Create logs directory if it doesn't exist
mkdir -p "$BASE_DIR/logs"

# Create the plist file for launchd from template with replacements
cp "$TEMPLATE_FILE" "$TARGET_FILE"

# Use sed based on platform
if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s|%%WORKING_DIR%%|${BASE_DIR}|g" "$TARGET_FILE"
else
    sed -i "s|%%WORKING_DIR%%|${BASE_DIR}|g" "$TARGET_FILE"
fi

# Load the service (but don't start it)
launchctl load "$TARGET_FILE"

echo "XMRig service has been setup, but not started."
echo "Use 'make start' to start mining."

exit 0