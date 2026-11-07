#!/bin/bash

set -e

# Where the image keeps the miner, its config and the wallet secret. A check sources this file
# and points them at fixtures.
XMRIG_BIN=/app/xmrig
CONFIG_DIR=/app/configs
WALLET_SECRET=/run/secrets/wallet_address

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

# A jq program: the values come in as $variables, never as text.
CONFIG_TEMPLATE='{
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
        "init-avx2": -1,
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
        "max-threads-hint": $hint,
        "asm": true,
        "argon2-impl": null,
        "astrobwt-max-size": 550,
        "astrobwt-avx2": false,
        "cn/0": false,
        "cn-lite/0": false,
        "kawpow": false
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
        "astrobwt": false,
        "bfactor-hint": 6,
        "bsleep-hint": 25
    },
    "donate-level": $donate,
    "donate-over-proxy": 1,
    "log-file": "/app/logs/xmrig.log",
    "pools": [
        {
            "algo": null,
            "coin": null,
            "url": $url,
            "user": $user,
            "pass": $pass,
            "rig-id": null,
            "nicehash": false,
            "keepalive": true,
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
    "verbose": 1,
    "watch": true,
    "pause-on-battery": $battery,
    "pause-on-active": $active
} | if $threads == null then . else .cpu["*"] = {"threads": $threads, "affinity": -1} end'

# The value rules, the same in scripts/install.sh, scripts/docker_setup.sh and here. Every
# value that reaches the miner's config passes one of them first.
function is_wallet() {
    local LC_ALL=C re='^[48]([1-9A-HJ-NP-Za-km-z]{94}|[1-9A-HJ-NP-Za-km-z]{105})([.][A-Za-z0-9]{1,64})?$'
    [[ $1 =~ $re ]]
}

function is_worker_name() {
    local LC_ALL=C re='^[A-Za-z0-9._@:+-]{1,64}$'
    [[ $1 =~ $re ]]
}

function is_pool() {
    local LC_ALL=C hostport re='^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(:([0-9]{1,5}))?$'
    case $1 in
        stratum+tcp://* | stratum+ssl://*) hostport=${1#stratum+???://} ;;
        *) hostport=$1 ;;
    esac
    [[ $hostport =~ $re ]] || return 1
    [ -z "${BASH_REMATCH[3]}" ] || { [ "$((10#${BASH_REMATCH[3]}))" -ge 1 ] && [ "$((10#${BASH_REMATCH[3]}))" -le 65535 ]; }
}

# Arguments: value, lowest, highest.
function is_whole_number() {
    local LC_ALL=C re='^[0-9]{1,5}$'
    [[ $1 =~ $re ]] && [ "$((10#$1))" -ge "$2" ] && [ "$((10#$1))" -le "$3" ]
}

function check_values() {
    if ! is_wallet "$WALLET_ADDRESS"; then
        log_error "Invalid wallet: 95 or 106 base58 characters starting with 4 or 8, then optionally one '.' and 1 to 64 letters or digits."
        return 1
    fi
    if ! is_worker_name "$WORKER_NAME"; then
        log_error "WORKER_NAME must be 1 to 64 letters, digits or . _ - @ : + characters."
        return 1
    fi
    if ! is_pool "$POOL_URL"; then
        log_error "POOL_URL must be a host name or IPv4 address, optionally after stratum+tcp:// or stratum+ssl:// and before a :port from 1 to 65535."
        return 1
    fi
    if ! is_whole_number "$DONATE_LEVEL" 0 5; then
        log_error "DONATE_LEVEL must be a whole number from 0 to 5."
        return 1
    fi
    if ! is_whole_number "$MAX_THREADS_PERCENT" 1 100; then
        log_error "MAX_THREADS_PERCENT must be a whole number from 1 to 100."
        return 1
    fi
    if [ -n "$FORCE_THREAD_COUNT" ] && ! is_whole_number "$FORCE_THREAD_COUNT" 1 1024; then
        log_error "FORCE_THREAD_COUNT must be empty or a whole number from 1 to 1024."
        return 1
    fi
    case $PAUSE_ON_BATTERY in true | false) ;; *) log_error "PAUSE_ON_BATTERY must be true or false."; return 1 ;; esac
    case $PAUSE_ON_ACTIVE in true | false) ;; *) log_error "PAUSE_ON_ACTIVE must be true or false."; return 1 ;; esac
}

function main() {
    # Check if wallet address is provided
    if [ -z "$WALLET_ADDRESS" ]; then
        if [ -f "$WALLET_SECRET" ]; then
            WALLET_ADDRESS=$(cat "$WALLET_SECRET")
        else
            log_error "WALLET_ADDRESS environment variable is required"
            exit 1
        fi
    fi

    # Set default values
    WORKER_NAME=${WORKER_NAME:-docker_miner}
    POOL_URL=${POOL_URL:-gulf.moneroocean.stream}
    DONATE_LEVEL=${DONATE_LEVEL:-0}
    MAX_THREADS_PERCENT=${MAX_THREADS_PERCENT:-75}
    PAUSE_ON_BATTERY=${PAUSE_ON_BATTERY:-false}
    PAUSE_ON_ACTIVE=${PAUSE_ON_ACTIVE:-false}
    FORCE_THREAD_COUNT=${FORCE_THREAD_COUNT:-}

    check_values || exit 1
    log_info "Using wallet address: $WALLET_ADDRESS"

    # Calculate thread count
    AVAILABLE_CPUS=$(nproc)
    log_info "Available CPU cores: $AVAILABLE_CPUS"

    if [ -n "$FORCE_THREAD_COUNT" ]; then
        THREAD_COUNT=$FORCE_THREAD_COUNT
        log_info "Using forced thread count: $THREAD_COUNT"
    else
        THREAD_COUNT=$((AVAILABLE_CPUS * MAX_THREADS_PERCENT / 100))
        if [ "$THREAD_COUNT" -lt 1 ]; then
            THREAD_COUNT=1
        fi
        log_info "Calculated thread count: $THREAD_COUNT (${MAX_THREADS_PERCENT}% of $AVAILABLE_CPUS cores)"
    fi

    # Handle pool URL and port
    local hostport=${POOL_URL#stratum+???://}
    if [[ "$hostport" != *":"* ]]; then
        # No port specified, calculate optimal port for MoneroOcean
        if [[ "$POOL_URL" == *"moneroocean"* ]]; then
            EXP_MONERO_HASHRATE=$((THREAD_COUNT * 700 / 1000))
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
        else
            # Default port for other pools
            FULL_POOL_URL="${POOL_URL}:3333"
        fi
    else
        FULL_POOL_URL="$POOL_URL"
    fi

    log_info "Using pool: $FULL_POOL_URL"

    # Test pool connectivity
    log_info "Testing pool connectivity..."
    hostport=${FULL_POOL_URL#stratum+???://}
    if timeout 10 nc -z "${hostport%:*}" "${hostport##*:}" 2>/dev/null; then
        log_success "Pool is reachable"
    else
        log_warning "Pool connectivity test failed, but continuing anyway..."
    fi

    write_config || exit 1

    log_success "Configuration generated successfully"
    log_info "Worker name: $WORKER_NAME"
    log_info "Thread count: $THREAD_COUNT"
    log_info "Pool URL: $FULL_POOL_URL"
    log_info "Donate level: ${DONATE_LEVEL}%"

    # Start XMRig with verbose logging
    log_info "Starting XMRig miner with verbose logging..."
    exec "$XMRIG_BIN" --config="$CONFIG_DIR/config.json" --verbose
}

# The miner's config, built as data: every value goes in as a JSON string, number or boolean
# holding exactly that value. It is written beside the old one and renamed over it, so a failed
# write leaves no partial config and the miner does not start.
function write_config() {
    local tmp forced=null
    if [ -n "$FORCE_THREAD_COUNT" ]; then forced=$THREAD_COUNT; fi
    mkdir -p "$CONFIG_DIR" && tmp=$(mktemp "$CONFIG_DIR/config.json.XXXXXX") || {
        log_error "Could not write the miner's config in $CONFIG_DIR."
        return 1
    }
    if ! jq -n \
        --arg url "$FULL_POOL_URL" --arg user "$WALLET_ADDRESS" --arg pass "$WORKER_NAME" \
        --argjson donate "$DONATE_LEVEL" --argjson hint "$MAX_THREADS_PERCENT" --argjson threads "$forced" \
        --argjson battery "$PAUSE_ON_BATTERY" --argjson active "$PAUSE_ON_ACTIVE" "$CONFIG_TEMPLATE" >"$tmp" \
        || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$CONFIG_DIR/config.json"; then
        rm -f "$tmp"
        log_error "Could not write the miner's config in $CONFIG_DIR."
        return 1
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
