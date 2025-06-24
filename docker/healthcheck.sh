#!/bin/bash

# Check if XMRig process is running
if ! pgrep -x xmrig >/dev/null; then
    echo "XMRig process not found"
    exit 1
fi

# Check if log file exists and has recent activity (within last 2 minutes)
LOG_FILE="/app/logs/xmrig.log"
if [ -f "$LOG_FILE" ]; then
    # Check if log file was modified in the last 120 seconds
    if [ $(find "$LOG_FILE" -mmin -2 | wc -l) -eq 0 ]; then
        echo "Log file not updated recently"
        exit 1
    fi
else
    echo "Log file not found"
    exit 1
fi

# Optional: Check if mining is actually happening by looking for specific patterns in logs
if tail -n 50 "$LOG_FILE" | grep -q "accepted\|speed"; then
    echo "XMRig is healthy and mining"
    exit 0
else
    echo "XMRig may not be mining properly"
    exit 1
fi