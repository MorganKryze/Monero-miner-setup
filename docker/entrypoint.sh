#!/bin/bash

set -e

# Colors for logging
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
ORANGE='\033[0;33m'
RESET='\033[0m'

function log_info() {
    echo -e "[${BLUE}  INFO   ${RESET}] ${BLUE}$1${RESET}"
}

function log_success() {
    echo -e "[${GREEN} SUCCESS ${RESET}] ${GREEN}$1${RESET}"
}

function log_warning() {
    echo -e "[${ORANGE} WARNING ${RESET}] ${ORANGE}$1${RESET}"
}

function log_error() {
    echo -e "[${RED}  ERROR  ${RESET}] ${RED}$1${RESET}" >&2
}

# Check if wallet address is provided
if [ -z "$WALLET_ADDRESS" ]; then
    # Check if using secrets
    if [ -f "/run/secrets/wallet_address" ]; then
        WALLET_ADDRESS=$(cat /run/secrets/wallet_address)
    else
        log_error "WALLET_ADDRESS environment variable is required"
        exit 1
    fi
fi

# Validate wallet address
wallet_base=$(echo "$WALLET_ADDRESS" | cut -f1 -d".")
if [ ${#wallet_base} != 106 ] && [ ${#wallet_base} != 95 ]; then
    log_error "Invalid wallet address length: ${#wallet_base} (should be 106 or 95)"
    exit 1
fi

log_info "Using wallet address: $WALLET_ADDRESS"

# Set default values
WORKER_NAME=${WORKER_NAME:-"docker_miner_$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"}
POOL_URL=${POOL_URL:-"gulf.moneroocean.stream"}
DONATE_LEVEL=${DONATE_LEVEL:-0}
MAX_THREADS_PERCENT=${MAX_THREADS_PERCENT:-75}
PAUSE_ON_BATTERY=${PAUSE_ON_BATTERY:-false}
PAUSE_ON_ACTIVE=${PAUSE_ON_ACTIVE:-false}

# Calculate optimal port for MoneroOcean
if [[ "$POOL_URL" == *"moneroocean"* ]] && [[ "$POOL_URL" != *":"* ]]; then
    CPU_THREADS=$(nproc)
    EXP_MONERO_HASHRATE=$((CPU_THREADS * 700 / 1000))
    PORT=$((EXP_MONERO_HASHRATE * 30))
    PORT=$((PORT == 0 ? 1 : PORT))
    
    # Calculate power of 2
    if [ "$PORT" -gt "8192" ]; then
        PORT="8192"
    elif [ "$PORT" -gt "4096" ]; then
        PORT="4096"
    elif [ "$PORT" -gt "2048" ]; then
        PORT="2048"
    elif [ "$PORT" -gt "1024" ]; then
        PORT="1024"
    elif [ "$PORT" -gt "512" ]; then
        PORT="512"
    elif [ "$PORT" -gt "256" ]; then
        PORT="256"
    elif [ "$PORT" -gt "128" ]; then
        PORT="128"
    elif [ "$PORT" -gt "64" ]; then
        PORT="64"
    elif [ "$PORT" -gt "32" ]; then
        PORT="32"
    elif [ "$PORT" -gt "16" ]; then
        PORT="16"
    elif [ "$PORT" -gt "8" ]; then
        PORT="8"
    elif [ "$PORT" -gt "4" ]; then
        PORT="4"
    elif [ "$PORT" -gt "2" ]; then
        PORT="2"
    else
        PORT="1"
    fi
    
    PORT=$((10000 + PORT))
    FULL_POOL_URL="${POOL_URL}:${PORT}"
    log_info "Using MoneroOcean with optimized port: $FULL_POOL_URL"
else
    FULL_POOL_URL="$POOL_URL"
    log_info "Using pool: $FULL_POOL_URL"
fi

# Create configuration directory if it doesn't exist
mkdir -p /app/configs

# Generate XMRig configuration
cat > /app/configs/config.json << EOF
{
    "api": {
        "id": null,
        "worker-id": null
    },
    "http": {
        "enabled": false,
        "host": "127.0.0.1",
        "port": 0,
        "access-token": null,
        "restricted": true
    },
    "autosave": true,
    "background": false,
    "colors": true,
    "title": true,
    "randomx": {
        "init": -1,
        "init-avx2": 0,
        "mode": "auto",
        "1gb-pages": false,
        "rdmsr": true,
        "wrmsr": true,
        "cache_qos": false,
        "numa": true,
        "scratchpad_prefetch_mode": 1
    },
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": false,
        "hw-aes": null,
        "priority": null,
        "memory-pool": true,
        "yield": true,
        "max-threads-hint": ${MAX_THREADS_PERCENT},
        "asm": true,
        "argon2-impl": null,
        "cn/0": false,
        "cn-lite/0": false
    },
    "opencl": {
        "enabled": false,
        "cache": true,
        "loader": null,
        "platform": "AMD",
        "adl": true,
        "cn/0": false,
        "cn-lite/0": false,
        "panthera": false
    },
    "cuda": {
        "enabled": false,
        "loader": null,
        "nvml": true,
        "cn/0": false,
        "cn-lite/0": false,
        "panthera": false,
        "astrobwt": false
    },
    "donate-level": ${DONATE_LEVEL},
    "donate-over-proxy": 0,
    "log-file": "/app/logs/xmrig.log",
    "pools": [
        {
            "algo": null,
            "coin": null,
            "url": "${FULL_POOL_URL}",
            "user": "${WALLET_ADDRESS}",
            "pass": "${WORKER_NAME}",
            "rig-id": null,
            "nicehash": false,
            "keepalive": false,
            "enabled": true,
            "tls": false,
            "tls-fingerprint": null,
            "daemon": false,
            "socks5": null,
            "self-select": null,
            "submit-to-origin": false
        }
    ],
    "print-time": 60,
    "health-print-time": 60,
    "dmi": true,
    "retries": 5,
    "retry-pause": 5,
    "syslog": false,
    "tls": {
        "enabled": false,
        "protocols": null,
        "cert": null,
        "cert_key": null,
        "ciphers": null,
        "ciphersuites": null,
        "dhparam": null
    },
    "dns": {
        "ipv6": false,
        "ttl": 30
    },
    "user-agent": null,
    "verbose": 0,
    "watch": true,
    "pause-on-battery": ${PAUSE_ON_BATTERY},
    "pause-on-active": ${PAUSE_ON_ACTIVE}
}
EOF

log_success "Configuration generated successfully"
log_info "Worker name: $WORKER_NAME"
log_info "Max threads: ${MAX_THREADS_PERCENT}%"
log_info "Donate level: ${DONATE_LEVEL}%"

# Start XMRig
log_info "Starting XMRig miner..."
exec /app/xmrig --config=/app/configs/config.json