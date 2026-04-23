#!/bin/bash
# Docker-path installer for Monero-miner-setup.
# Symmetric to scripts/install.sh but for the container stack.
# Writes docker/.env (and docker/.env.vpn if --vpn was set), optionally brings
# the stack up.

# ===== Constants =====
VERSION="0.0.1"
REPO_URL="https://github.com/MorganKryze/Monero-miner-setup.git"
REPO_NAME="Monero-miner-setup"
PROJECT_URL="https://github.com/MorganKryze/Monero-miner-setup"

DEFAULT_WORKER_NAME=""
DEFAULT_POOL_URL="gulf.moneroocean.stream"
DEFAULT_DONATE_LEVEL=0
DEFAULT_MAX_THREADS=75
DEFAULT_CPU_COUNT="2.0"
DEFAULT_MEMORY_LIMIT="1g"
DEFAULT_FORCE_THREAD_COUNT="2"
DEFAULT_PAUSE_ON_BATTERY=false
DEFAULT_PAUSE_ON_ACTIVE=false
DEFAULT_VPN_PROVIDER="none"
DEFAULT_NON_INTERACTIVE=false
DEFAULT_AUTOSTART=false
DEFAULT_BUILD_LOCAL=false
DEFAULT_XMRIG_IMAGE="ghcr.io/morgankryze/monero-miner-setup:latest"

set -o errexit
set -o pipefail

# ===== Logging (inline, no external deps) =====
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
ORANGE='\033[0;33m'
RESET='\033[0m'

function info()    { echo -e "[${BLUE}  INFO   ${RESET}] ${BLUE}$1${RESET}"; }
function success() { echo -e "[${GREEN} SUCCESS ${RESET}] ${GREEN}$1${RESET}"; }
function warning() { echo -e "[${ORANGE} WARNING ${RESET}] ${ORANGE}$1${RESET}" >&2; }
function error()   { echo -e "[${RED}  ERROR  ${RESET}] ${RED}$1${RESET}" >&2; }

function usage() {
    cat <<EOF
Monero-miner-setup: Docker installer (v${VERSION})

Usage: $0 -w WALLET [options]

Required:
  -w, --wallet WALLET          Your Monero wallet (95/106 chars, base58)

Mining:
  --worker-name NAME           Worker name (default: docker_miner)
  --pool URL                   Pool URL (default: ${DEFAULT_POOL_URL})
  --donate N                   Donation level 0-5 (default: ${DEFAULT_DONATE_LEVEL})
  --threads N                  Max threads percentage 1-100 (default: ${DEFAULT_MAX_THREADS})
  --force-threads N            Override auto-computed thread count (default: ${DEFAULT_FORCE_THREAD_COUNT})
  --cpus N                     Container CPU quota (default: ${DEFAULT_CPU_COUNT})
  --memory LIMIT               Container memory limit (default: ${DEFAULT_MEMORY_LIMIT})
  --pause-battery              Pause on battery
  --pause-active               Pause on user input

Install:
  -d, --dir DIR                Base directory if clone needed (default: \$HOME)
  -y, --yes, --non-interactive Skip prompts; fail fast on missing secrets
  --autostart                  Bring the stack up after setup
  --build                      Build the image locally from source instead of
                               pulling the prebuilt multi-arch image from GHCR
  --image REF                  Override the image ref used by compose
                               (default: ${DEFAULT_XMRIG_IMAGE})

VPN (optional, via Gluetun):
  --vpn PROVIDER               One of: mullvad, protonvpn, pia, nordvpn, none (default: none)
  --vpn-location LOC           Country / city / region filter (provider-dependent)

  WireGuard providers (mullvad, protonvpn):
    --wg-key KEY               Private key  (WARN: leaks to shell history)
    --wg-key-file PATH         Read key from file
    --wg-address ADDR          Interface address (e.g. 10.64.x.x/32)
    --wg-address-file PATH     Read address from file

  OpenVPN providers (pia, nordvpn):
    --vpn-user USER            OpenVPN username (for NordVPN: Service username)
    --vpn-user-file PATH       Read username from file
    --vpn-pass PASS            OpenVPN password (WARN: leaks to shell history)
    --vpn-pass-file PATH       Read password from file

Secret precedence (each flag independent):
  1. --*-file path           file path visible in history, content not
  2. matching env variable   WIREGUARD_PRIVATE_KEY, WIREGUARD_ADDRESSES,
                             OPENVPN_USER, OPENVPN_PASSWORD
  3. direct --* flag         works but warns (secret visible in history)
  4. interactive prompt      silent (read -s); skipped under -y

Examples:
  # Plain Docker install (pulls prebuilt image), no VPN
  $0 -w 4ABC... --autostart

  # Build the image locally from source instead of pulling
  $0 -w 4ABC... --build --autostart

  # Mullvad with WireGuard, key from file (no history leak)
  $0 -w 4ABC... --vpn mullvad --wg-key-file ~/.secrets/mullvad.key --wg-address 10.64.0.1/32 --autostart

  # NordVPN with env vars
  OPENVPN_USER=... OPENVPN_PASSWORD=... $0 -w 4ABC... --vpn nordvpn --autostart

More info: ${PROJECT_URL}
EOF
}

# ===== Wallet validator (same logic as install.sh) =====
function validate_wallet() {
    local wallet="$1"

    if [ -z "$wallet" ]; then
        error "No wallet address provided. Use -w or --wallet."
        return 1
    fi

    local wallet_base
    wallet_base=$(echo "$wallet" | cut -f1 -d".")
    local len=${#wallet_base}

    if [ "$len" != 95 ] && [ "$len" != 106 ]; then
        error "Invalid wallet length (expected 95 or 106, got $len)."
        return 1
    fi

    if ! [[ "$wallet_base" =~ ^[48][1-9A-HJ-NP-Za-km-z]+$ ]]; then
        error "Invalid wallet format: must start with '4' or '8' and use base58 characters only."
        return 1
    fi

    info "Wallet looks valid (length $len, leading char '${wallet_base:0:1}')."
    return 0
}

# ===== Secret resolver =====
# Usage: resolve_secret "file_path" "env_var_name" "direct_value" "prompt_label"
# Precedence: file > env var > direct flag (warns) > interactive prompt > error
# Prints the resolved value to stdout; writes logs to stderr.
function resolve_secret() {
    local file_path="$1"
    local env_var="$2"
    local direct_value="$3"
    local prompt_label="$4"

    if [ -n "$file_path" ]; then
        if [ ! -r "$file_path" ]; then
            error "Cannot read secret file: $file_path"
            return 1
        fi
        # Strip any trailing newline.
        tr -d '\n' <"$file_path"
        return 0
    fi

    if [ -n "$env_var" ] && [ -n "${!env_var:-}" ]; then
        printf '%s' "${!env_var}"
        return 0
    fi

    if [ -n "$direct_value" ]; then
        warning "Secret passed on CLI for '$prompt_label'. It will appear in shell history. Use --*-file or $env_var env var for automation."
        printf '%s' "$direct_value"
        return 0
    fi

    if [ "$NON_INTERACTIVE" != "true" ] && [ -t 0 ]; then
        local value
        printf '%s' "$prompt_label: " >&2
        read -rs value
        echo >&2
        printf '%s' "$value"
        return 0
    fi

    error "Required secret not provided: '$prompt_label'. Pass --*-file, set $env_var, or drop -y to get a prompt."
    return 1
}

# ===== Docker availability =====
function check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        error "docker not installed. Install from https://docs.docker.com/get-docker/ first."
        return 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        error "docker compose plugin not available. Install from https://docs.docker.com/compose/install/ first."
        return 1
    fi
    info "Docker available: $(docker --version | head -1)"
    return 0
}

# ===== Argument parsing =====
function parse_args() {
    WALLET=""
    BASE_DIR=""
    WORKER_NAME=""
    POOL_URL="$DEFAULT_POOL_URL"
    DONATE_LEVEL="$DEFAULT_DONATE_LEVEL"
    MAX_THREADS="$DEFAULT_MAX_THREADS"
    CPU_COUNT="$DEFAULT_CPU_COUNT"
    MEMORY_LIMIT="$DEFAULT_MEMORY_LIMIT"
    FORCE_THREAD_COUNT="$DEFAULT_FORCE_THREAD_COUNT"
    PAUSE_ON_BATTERY="$DEFAULT_PAUSE_ON_BATTERY"
    PAUSE_ON_ACTIVE="$DEFAULT_PAUSE_ON_ACTIVE"

    VPN_PROVIDER="$DEFAULT_VPN_PROVIDER"
    VPN_LOCATION=""
    WG_KEY=""
    WG_KEY_FILE=""
    WG_ADDRESS=""
    WG_ADDRESS_FILE=""
    VPN_USER=""
    VPN_USER_FILE=""
    VPN_PASS=""
    VPN_PASS_FILE=""

    NON_INTERACTIVE="$DEFAULT_NON_INTERACTIVE"
    AUTOSTART="$DEFAULT_AUTOSTART"
    BUILD_LOCAL="$DEFAULT_BUILD_LOCAL"
    XMRIG_IMAGE="$DEFAULT_XMRIG_IMAGE"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -w|--wallet) WALLET="$2"; shift 2 ;;
            -d|--dir) BASE_DIR="$2"; shift 2 ;;
            --worker-name) WORKER_NAME="$2"; shift 2 ;;
            --pool) POOL_URL="$2"; shift 2 ;;
            --donate) DONATE_LEVEL="$2"; shift 2 ;;
            --threads) MAX_THREADS="$2"; shift 2 ;;
            --force-threads) FORCE_THREAD_COUNT="$2"; shift 2 ;;
            --cpus) CPU_COUNT="$2"; shift 2 ;;
            --memory) MEMORY_LIMIT="$2"; shift 2 ;;
            --pause-battery) PAUSE_ON_BATTERY=true; shift ;;
            --pause-active) PAUSE_ON_ACTIVE=true; shift ;;
            --vpn) VPN_PROVIDER="$2"; shift 2 ;;
            --vpn-location) VPN_LOCATION="$2"; shift 2 ;;
            --wg-key) WG_KEY="$2"; shift 2 ;;
            --wg-key-file) WG_KEY_FILE="$2"; shift 2 ;;
            --wg-address) WG_ADDRESS="$2"; shift 2 ;;
            --wg-address-file) WG_ADDRESS_FILE="$2"; shift 2 ;;
            --vpn-user) VPN_USER="$2"; shift 2 ;;
            --vpn-user-file) VPN_USER_FILE="$2"; shift 2 ;;
            --vpn-pass) VPN_PASS="$2"; shift 2 ;;
            --vpn-pass-file) VPN_PASS_FILE="$2"; shift 2 ;;
            -y|--yes|--non-interactive) NON_INTERACTIVE=true; shift ;;
            --autostart) AUTOSTART=true; shift ;;
            --build) BUILD_LOCAL=true; shift ;;
            --image) XMRIG_IMAGE="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    case "$VPN_PROVIDER" in
        none|mullvad|protonvpn|pia|nordvpn) ;;
        *) error "Unknown --vpn provider: $VPN_PROVIDER. Expected: mullvad, protonvpn, pia, nordvpn, none."; exit 1 ;;
    esac

    if [ -z "$BASE_DIR" ]; then BASE_DIR="$HOME"; fi
}

# ===== Ensure repo checkout =====
# Sets REPO_DIR to the absolute path of the repo root. Clones if not already inside one.
function ensure_repo() {
    local search="$PWD"
    while [ "$search" != "/" ]; do
        if [ -f "$search/docker/compose.yml" ] && [ -f "$search/docker/Dockerfile" ]; then
            REPO_DIR="$search"
            info "Using existing checkout at $REPO_DIR."
            return 0
        fi
        search=$(dirname "$search")
    done

    REPO_DIR="$BASE_DIR/$REPO_NAME"
    if [ -d "$REPO_DIR/.git" ]; then
        info "Found existing clone at $REPO_DIR."
        return 0
    fi

    info "Cloning repository to $REPO_DIR..."
    if ! git clone --recurse-submodules "$REPO_URL" "$REPO_DIR"; then
        error "Failed to clone $REPO_URL."
        return 1
    fi
    success "Clone complete."
}

# ===== Write docker/.env =====
function write_env() {
    local env_file="$REPO_DIR/docker/.env"
    info "Writing $env_file"

    cat >"$env_file" <<EOF
# Generated by scripts/docker_setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
WALLET_ADDRESS=$WALLET
WORKER_NAME=${WORKER_NAME:-docker_miner}
POOL_URL=$POOL_URL
DONATE_LEVEL=$DONATE_LEVEL
MAX_THREADS_PERCENT=$MAX_THREADS
FORCE_THREAD_COUNT=$FORCE_THREAD_COUNT
CPU_COUNT=$CPU_COUNT
MEMORY_LIMIT=$MEMORY_LIMIT
PAUSE_ON_BATTERY=$PAUSE_ON_BATTERY
PAUSE_ON_ACTIVE=$PAUSE_ON_ACTIVE
XMRIG_IMAGE=$XMRIG_IMAGE
EOF
    chmod 600 "$env_file"
    success "Wrote $env_file (mode 0600)."
}

# ===== Resolve VPN secrets based on provider =====
function collect_vpn_secrets() {
    case "$VPN_PROVIDER" in
        mullvad|protonvpn)
            RESOLVED_WG_KEY=$(resolve_secret "$WG_KEY_FILE" "WIREGUARD_PRIVATE_KEY" "$WG_KEY" "WireGuard private key") || return 1
            RESOLVED_WG_ADDRESS=$(resolve_secret "$WG_ADDRESS_FILE" "WIREGUARD_ADDRESSES" "$WG_ADDRESS" "WireGuard address (e.g. 10.64.0.1/32)") || return 1
            ;;
        pia|nordvpn)
            RESOLVED_VPN_USER=$(resolve_secret "$VPN_USER_FILE" "OPENVPN_USER" "$VPN_USER" "OpenVPN username") || return 1
            RESOLVED_VPN_PASS=$(resolve_secret "$VPN_PASS_FILE" "OPENVPN_PASSWORD" "$VPN_PASS" "OpenVPN password") || return 1
            ;;
    esac
}

# ===== Write docker/.env.vpn for the selected provider =====
function write_env_vpn() {
    local env_file="$REPO_DIR/docker/.env.vpn"
    info "Writing $env_file for provider: $VPN_PROVIDER"

    case "$VPN_PROVIDER" in
        mullvad)
            cat >"$env_file" <<EOF
# Generated by scripts/docker_setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
VPN_SERVICE_PROVIDER=mullvad
VPN_TYPE=wireguard
WIREGUARD_PRIVATE_KEY=$RESOLVED_WG_KEY
WIREGUARD_ADDRESSES=$RESOLVED_WG_ADDRESS
${VPN_LOCATION:+SERVER_CITIES=$VPN_LOCATION}
FIREWALL=on
TZ=UTC
LOG_LEVEL=info
EOF
            ;;
        protonvpn)
            cat >"$env_file" <<EOF
# Generated by scripts/docker_setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
VPN_SERVICE_PROVIDER=protonvpn
VPN_TYPE=wireguard
WIREGUARD_PRIVATE_KEY=$RESOLVED_WG_KEY
WIREGUARD_ADDRESSES=$RESOLVED_WG_ADDRESS
${VPN_LOCATION:+SERVER_COUNTRIES=$VPN_LOCATION}
FIREWALL=on
TZ=UTC
LOG_LEVEL=info
EOF
            ;;
        pia)
            cat >"$env_file" <<EOF
# Generated by scripts/docker_setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
VPN_SERVICE_PROVIDER=private internet access
VPN_TYPE=openvpn
OPENVPN_USER=$RESOLVED_VPN_USER
OPENVPN_PASSWORD=$RESOLVED_VPN_PASS
${VPN_LOCATION:+SERVER_REGIONS=$VPN_LOCATION}
FIREWALL=on
TZ=UTC
LOG_LEVEL=info
EOF
            ;;
        nordvpn)
            cat >"$env_file" <<EOF
# Generated by scripts/docker_setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
VPN_SERVICE_PROVIDER=nordvpn
VPN_TYPE=openvpn
OPENVPN_USER=$RESOLVED_VPN_USER
OPENVPN_PASSWORD=$RESOLVED_VPN_PASS
${VPN_LOCATION:+SERVER_COUNTRIES=$VPN_LOCATION}
FIREWALL=on
TZ=UTC
LOG_LEVEL=info
EOF
            warning "NordVPN's terms may prohibit crypto-mining on your plan. Verify before running long."
            ;;
    esac

    chmod 600 "$env_file"
    success "Wrote $env_file (mode 0600)."
}

# ===== Start the stack =====
function start_stack() {
    info "Bringing the stack up..."
    local compose_args=("-f" "$REPO_DIR/docker/compose.yml")
    if [ "$VPN_PROVIDER" != "none" ]; then
        compose_args+=("-f" "$REPO_DIR/docker/compose.vpn.yml")
    fi

    if [ "$BUILD_LOCAL" = "true" ]; then
        info "Building image locally from source (--build)..."
        (cd "$REPO_DIR/docker" && docker compose "${compose_args[@]}" up -d --build)
    else
        info "Pulling prebuilt image: $XMRIG_IMAGE"
        (cd "$REPO_DIR/docker" && docker compose "${compose_args[@]}" pull xmrig) || {
            warning "Image pull failed. Falling back to a local build from source."
            (cd "$REPO_DIR/docker" && docker compose "${compose_args[@]}" up -d --build)
            return $?
        }
        (cd "$REPO_DIR/docker" && docker compose "${compose_args[@]}" up -d)
    fi

    if [ "$VPN_PROVIDER" = "none" ]; then
        success "Stack up. Tail logs: cd $REPO_DIR/docker && docker compose logs -f"
        return 0
    fi

    info "Waiting for VPN tunnel to become healthy (up to 2 minutes)..."
    local attempts=0
    while true; do
        local status
        status=$(docker inspect --format '{{.State.Health.Status}}' monero_xmrig_gluetun 2>/dev/null || echo "missing")
        if [ "$status" = "healthy" ]; then break; fi
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 24 ]; then
            error "Gluetun didn't report healthy within 2 minutes (status: $status)."
            error "Check: docker compose -f $REPO_DIR/docker/compose.yml -f $REPO_DIR/docker/compose.vpn.yml logs gluetun"
            return 1
        fi
        sleep 5
    done

    local exit_ip
    exit_ip=$(docker exec monero_xmrig_gluetun wget -qO- https://ifconfig.io 2>/dev/null | tr -d '\n' || echo "")
    if [ -n "$exit_ip" ]; then
        success "VPN tunnel up. Exit IP: $exit_ip"
    else
        warning "VPN tunnel reports healthy, but couldn't retrieve exit IP. Try: docker exec monero_xmrig_gluetun wget -qO- https://ifconfig.io"
    fi
    info "Tail logs: cd $REPO_DIR/docker && docker compose -f compose.yml -f compose.vpn.yml logs -f"
}

# ===== Main =====
function main() {
    parse_args "$@"

    if ! validate_wallet "$WALLET"; then exit 1; fi
    if ! check_docker; then exit 1; fi
    if ! ensure_repo; then exit 1; fi

    write_env

    if [ "$VPN_PROVIDER" != "none" ]; then
        collect_vpn_secrets || exit 1
        write_env_vpn
    fi

    if [ "$AUTOSTART" = "true" ]; then
        start_stack || exit 1
    else
        local up_suffix="up -d"
        if [ "$BUILD_LOCAL" = "true" ]; then
            up_suffix="up -d --build"
        fi
        info "Setup done. To start: cd $REPO_DIR/docker && docker compose \\"
        if [ "$VPN_PROVIDER" != "none" ]; then
            info "  -f compose.yml -f compose.vpn.yml $up_suffix"
        else
            info "  $up_suffix"
        fi
    fi
}

main "$@"
