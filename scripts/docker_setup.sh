#!/bin/bash
# Docker-path installer for Monero-miner-setup.
# Symmetric to scripts/install.sh but for the container stack.
# Writes docker/.env (and docker/.env.vpn if --vpn was set), optionally brings
# the stack up.

# ===== Constants =====
VERSION="0.1.0"
REPO_URL="https://github.com/MorganKryze/Monero-miner-setup.git"
REPO_NAME="Monero-miner-setup"
PROJECT_URL="https://github.com/MorganKryze/Monero-miner-setup"

DEFAULT_WORKER_NAME="docker_miner"
DEFAULT_POOL_URL="gulf.moneroocean.stream"
DEFAULT_DONATE_LEVEL=0
DEFAULT_MAX_THREADS=75
DEFAULT_CPU_COUNT="2.0"
DEFAULT_MEMORY_LIMIT="3g"
DEFAULT_FORCE_THREAD_COUNT=""
DEFAULT_PAUSE_ON_BATTERY=false
DEFAULT_PAUSE_ON_ACTIVE=false
DEFAULT_VPN_PROVIDER="none"
DEFAULT_NON_INTERACTIVE=false
DEFAULT_AUTOSTART=false
DEFAULT_BUILD_LOCAL=false
DEFAULT_OVERWRITE_ENV=false
DEFAULT_XMRIG_IMAGE="ghcr.io/morgankryze/monero-miner-setup:latest"
# RandomX's fast mode needs this much memory for its dataset (measured: 2.30 GiB in use); under
# it the container mines in light mode.
FAST_MODE_MIB=2560

# ===== Own clone =====
# The same two functions as scripts/install.sh, byte for byte (tests/docker-own-clone.sh fails when
# they differ). BASH_SOURCE is read here, at the top level: inside a function, bash 5 gives a script
# read from a pipe its $0 ("bash", or the first argument of `bash -c`), which may name a file in the
# current directory.
SELF_PATH="${BASH_SOURCE[0]-}"

# Prints the clone this file sits in (<clone>/scripts/docker_setup.sh), or nothing. Piped into
# bash, fetched by install.sh --docker, or saved outside a clone, it has no clone of its own. Nor
# has it one when someone else can write to the clone root, as in /tmp.
function find_own_clone() {
    local dir root
    [ -n "$SELF_PATH" ] && [ -f "$SELF_PATH" ] || return 0
    dir=$(cd -- "$(dirname -- "$SELF_PATH")" 2>/dev/null && pwd -P) || return 0
    root="${dir%/*}"
    if [ "${dir##*/}" = "scripts" ] && [ -e "$root/.git" ] && only_user_can_write "$root"; then
        printf '%s' "$root"
    fi
}

# Other users can never write to the folder. Its group can only when the group is the user's own
# (Ubuntu's private group and umask 0002); a shared group, an ACL or a failed check is a no.
function only_user_can_write() {
    local group_ok listing
    group_ok=(! -perm -0020)
    if [ "$(id -gn 2>/dev/null)" = "$(id -un 2>/dev/null)" ]; then
        group_ok=("(" ! -perm -0020 -o -group "$(id -g)" ")")
    fi
    [ "$(find "$1/" -maxdepth 0 ! -perm -0002 "${group_ok[@]}" -print 2>/dev/null)" = "$1/" ] || return 1
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        listing=$(ls -lde -- "$1/" 2>/dev/null) || return 1
    else
        listing=$(ls -ld -- "$1/" 2>/dev/null) || return 1
    fi
    case $listing in
        *$'\n'*) return 1 ;;
    esac
    case ${listing%% *} in
        *+) return 1 ;;
    esac
}

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
  --worker-name NAME           Worker name, 1-64 letters, digits or . _ - @ : +
                               (default: ${DEFAULT_WORKER_NAME})
  --pool URL                   Pool host[:port], optionally after stratum+tcp:// or
                               stratum+ssl:// (default: ${DEFAULT_POOL_URL})
  --donate N                   Donation level 0-5 (default: ${DEFAULT_DONATE_LEVEL})
  --threads N                  Threads as a percentage 1-100 of the container's CPU quota,
                               at most xmrig's own count (default: ${DEFAULT_MAX_THREADS})
  --force-threads N            Mine with exactly N threads, 1-1024 (default: none)
  --cpus N                     Container CPU quota (default: ${DEFAULT_CPU_COUNT})
  --memory LIMIT               Container memory limit, digits with b, k, m or g
                               (default: ${DEFAULT_MEMORY_LIMIT}; under ${FAST_MODE_MIB}m, RandomX light mode)
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
  --overwrite-env              Rewrite docker/.env (and docker/.env.vpn with --vpn) from
                               this run's flags; without it, existing files are kept

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

    if ! is_wallet "$wallet"; then
        error "Invalid wallet: 95 or 106 base58 characters starting with 4 or 8, then optionally one '.' and 1 to 64 letters or digits."
        return 1
    fi

    info "Wallet looks valid (length $len, leading char '${wallet_base:0:1}')."
    return 0
}

# The value rules, the same in docker/entrypoint.sh, scripts/install.sh and here. Every
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

function is_one_line() {
    local LC_ALL=C
    [[ $1 != *[[:cntrl:]]* ]]
}

# Every flag's value against its rule, before anything is written. One error line names the flag
# and the rule.
function check_values() {
    local LC_ALL=C mib
    if ! is_worker_name "$WORKER_NAME"; then
        error "--worker-name must be 1 to 64 letters, digits or . _ - @ : + characters."; return 1
    fi
    if ! is_pool "$POOL_URL"; then
        error "--pool must be a host name or IPv4 address, optionally after stratum+tcp:// or stratum+ssl:// and before a :port from 1 to 65535."; return 1
    fi
    if ! is_whole_number "$DONATE_LEVEL" 0 5; then
        error "--donate must be a whole number from 0 to 5."; return 1
    fi
    if ! is_whole_number "$MAX_THREADS" 1 100; then
        error "--threads must be a whole number from 1 to 100."; return 1
    fi
    if [ -n "$FORCE_THREAD_COUNT" ] && ! is_whole_number "$FORCE_THREAD_COUNT" 1 1024; then
        error "--force-threads must be a whole number from 1 to 1024."; return 1
    fi
    if ! [[ $CPU_COUNT =~ ^[0-9]{1,4}([.][0-9]{1,3})?$ && $CPU_COUNT =~ [1-9] ]]; then
        error "--cpus must be a positive decimal number, such as 2 or 1.5."; return 1
    fi
    # Compose reads a zero limit as no limit at all, so zero is refused like a malformed value.
    if ! [[ $MEMORY_LIMIT =~ ^[0-9]{1,12}[bkmg]?$ && $MEMORY_LIMIT =~ [1-9] ]]; then
        error "--memory must be digits with an optional b, k, m or g, such as 3g."; return 1
    fi
    if ! [[ $XMRIG_IMAGE =~ ^[A-Za-z0-9._/:@-]{1,255}$ ]]; then
        error "--image must hold only letters, digits and . _ - / : @ characters."; return 1
    fi
    if ! is_one_line "$VPN_LOCATION"; then
        error "--vpn-location must be one line with no control character."; return 1
    fi
    case $MEMORY_LIMIT in
        *g) mib=$((10#${MEMORY_LIMIT%g} * 1024)) ;;
        *m) mib=$((10#${MEMORY_LIMIT%m})) ;;
        *k) mib=$((10#${MEMORY_LIMIT%k} / 1024)) ;;
        *) mib=$((10#${MEMORY_LIMIT%b} / 1048576)) ;;
    esac
    if [ "$mib" -lt "$FAST_MODE_MIB" ]; then
        warning "--memory $MEMORY_LIMIT is under the ${FAST_MODE_MIB} MiB RandomX's fast mode needs: the miner will run in light mode, at a fraction of the hashrate."
    fi
}

# A value as Compose reads it back byte for byte inside double quotes: \, " and $ escaped. Pure
# bash, so it cannot fail half way (bash 3.2 to 5.3 give the same result).
function env_value() {
    local v="$1"
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    v=${v//\$/\\\$}
    printf '%s' "$v"
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
        # The file's final newline goes; any other stays, for the one-line rule to refuse.
        printf '%s' "$(cat "$file_path")"
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
    WORKER_NAME="$DEFAULT_WORKER_NAME"
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
    OVERWRITE_ENV="$DEFAULT_OVERWRITE_ENV"

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
            --overwrite-env) OVERWRITE_ENV=true; shift ;;
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
# The nearest folder at or above the current directory holding this project's two Docker files,
# by its physical path, or nothing.
function nearest_lookalike() {
    local search
    search=$(pwd -P) || return 0
    while true; do
        if [ -f "$search/docker/compose.yml" ] && [ -f "$search/docker/Dockerfile" ]; then
            printf '%s' "$search"
            return 0
        fi
        if [ "$search" = "/" ]; then return 0; fi
        search=$(dirname "$search")
    done
}

# The clone the script sits in when only the write check keeps it from being its own, or nothing:
# the run then names that cause instead of falling back to the base clone.
function open_own_clone() {
    local dir
    [ -n "$SELF_PATH" ] && [ -f "$SELF_PATH" ] || return 0
    dir=$(cd -- "$(dirname -- "$SELF_PATH")" 2>/dev/null && pwd -P) || return 0
    if [ "${dir##*/}" = "scripts" ] && [ -e "${dir%/*}/.git" ] && ! only_user_can_write "${dir%/*}"; then
        printf '%s' "${dir%/*}"
    fi
}

# only_user_can_write for a file, the one a link points to: that one takes folders only. Group
# write passes only for a private group, as there.
function only_user_can_write_file() {
    local group_ok listing
    group_ok=(! -perm -0020)
    if [ "$(id -gn 2>/dev/null)" = "$(id -un 2>/dev/null)" ]; then
        group_ok=("(" ! -perm -0020 -o -group "$(id -g)" ")")
    fi
    [ "$(find -H "$1" -maxdepth 0 -type f ! -perm -0002 "${group_ok[@]}" -print 2>/dev/null)" = "$1" ] || return 1
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        listing=$(ls -leL -- "$1" 2>/dev/null) || return 1
    else
        listing=$(ls -lL -- "$1" 2>/dev/null) || return 1
    fi
    case $listing in
        *$'\n'*) return 1 ;;
    esac
    case ${listing%% *} in
        *+) return 1 ;;
    esac
}

# A clone this run may write its settings into and start: a git clone owned by you or root (as
# root, also by the user who ran sudo, who can become root anyway), that no other user can write
# to, nor to its docker/ folder, nor to the files there the root daemon acts on: the Compose files
# (a privileged service, a host folder mounted) and the Dockerfile (the image's user). The rest of
# the build context is not checked, as nothing in it runs as root.
function check_clone() {
    local dir="$1" f bad="" owners
    if [ ! -d "$dir" ] || [ ! -e "$dir/.git" ]; then
        error "$dir is not a git clone. Move it away, or pass -d with another base directory."
        return 1
    fi
    owners=(-user "$(id -u 2>/dev/null)" -o -user 0)
    if [ "$(id -u 2>/dev/null)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        owners+=(-o -user "$SUDO_USER")
    fi
    for f in "$dir" "$dir/docker"; do
        if [ "$(find "$f/" -maxdepth 0 "(" "${owners[@]}" ")" -print 2>/dev/null)" != "$f/" ] || ! only_user_can_write "$f"; then
            bad=$f
            break
        fi
    done
    if [ -z "$bad" ]; then
        for f in "$dir/docker/compose.yml" "$dir/docker/compose.vpn.yml" "$dir/docker/Dockerfile"; do
            # A missing file is one only those who can write to docker/, checked above, could add.
            if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
            if [ "$(find -H "$f" -maxdepth 0 "(" "${owners[@]}" ")" -print 2>/dev/null)" != "$f" ] || ! only_user_can_write_file "$f"; then
                bad=$f
                break
            fi
        done
    fi
    if [ -z "$bad" ]; then return 0; fi
    # A run in another base directory would start a fresh .env under the same Compose project and
    # replace the running miner's settings, so that remedy is offered only when there are none.
    if [ -e "$dir/docker/.env" ]; then
        error "$bad can be changed by a user other than you, so this run does not use it. Restrict it to you, then run again."
    else
        error "$bad can be changed by a user other than you, so this run does not use it. Restrict it to you, or pass -d with another base directory."
    fi
    return 1
}

# Sets REPO_DIR to the clone this run uses: the one this script sits in, else
# $BASE_DIR/$REPO_NAME, cloned when missing. A folder that only looks like this project is never
# adopted: when the nearest one at or above the current directory is not REPO_DIR, the run stops,
# so a re-run from another copy never starts a fresh .env under the same Compose project.
function ensure_repo() {
    local own open_own found base
    own=$(find_own_clone)
    if [ -n "$own" ]; then
        REPO_DIR="$own"
    else
        base=$(cd -P -- "$BASE_DIR" 2>/dev/null && pwd -P) || base="$BASE_DIR"
        REPO_DIR="$base/$REPO_NAME"
        if [ -d "$REPO_DIR" ]; then
            REPO_DIR=$(cd -P -- "$REPO_DIR" && pwd -P) || return 1
        fi
    fi

    if [ -z "$own" ]; then
        open_own=$(open_own_clone)
        if [ -n "$open_own" ]; then
            error "$open_own is this script's clone, but a user other than you can change it, so this run does not use it. Run chmod -R go-w '$open_own', then run again."
            return 1
        fi
    fi

    found=$(nearest_lookalike)
    if [ -n "$found" ] && [ "$found" != "$REPO_DIR" ]; then
        # A run from outside a folder holding settings would start a second set under the same
        # Compose project, so that remedy is offered only when there are none.
        if [ -e "$found/docker/.env" ]; then
            error "$found looks like a copy of $REPO_NAME, but this run uses $REPO_DIR. If it is your own clone, run its scripts/install.sh --docker."
        else
            error "$found looks like a copy of $REPO_NAME, but this run uses $REPO_DIR. Run again from outside $found, or, if it is your own clone, with its scripts/install.sh --docker."
        fi
        return 1
    fi

    if [ -n "$own" ]; then
        check_clone "$REPO_DIR" || return 1
        info "Using this script's clone at $REPO_DIR."
        return 0
    fi
    if [ -e "$REPO_DIR" ] || [ -L "$REPO_DIR" ]; then
        check_clone "$REPO_DIR" || return 1
        info "Found existing clone at $REPO_DIR."
        return 0
    fi

    info "Cloning repository to $REPO_DIR..."
    if ! git clone --recurse-submodules "$REPO_URL" "$REPO_DIR"; then
        error "Failed to clone $REPO_URL."
        return 1
    fi
    # A fresh clone gets the same checks: git keeps the mode of an empty folder someone else made
    # at that path first, and lays out the rest under the user's umask.
    REPO_DIR=$(cd -P -- "$REPO_DIR" && pwd -P) && check_clone "$REPO_DIR" || return 1
    success "Clone complete."
}

# ===== Settings files =====
# A settings file from an earlier run is the user's: it is kept as it is unless --overwrite-env
# says otherwise. Returns 0 when the file is to be written.
function should_write() {
    local file="$1" mode

    if [ ! -e "$file" ] && [ ! -L "$file" ]; then return 0; fi
    if [ "$OVERWRITE_ENV" = "true" ]; then return 0; fi

    info "Keeping $file: this run's flags are not applied to it. To rewrite it from them, run again with --overwrite-env."
    mode=$(ls -ld -- "$file" 2>/dev/null) || mode=""
    case "${mode:4:6}" in
        ------) ;;
        *) warning "$file can be read or changed by other users. Restrict it with: chmod 600 $file" ;;
    esac
    return 1
}

# Writes the output of a function into a file: mktemp creates the new file with mode 600 before
# any byte goes in, and a rename replaces the old one whole, so a failed write leaves it as it was.
function write_settings_file() {
    local file="$1" content="$2" tmp existed=false

    if [ -e "$file" ]; then existed=true; fi
    if [ -d "$file" ]; then
        error "Could not write $file: it is a directory."
        return 1
    fi
    # The rename would replace the link itself, and the file it points to would keep the old
    # values with nothing reading it.
    if [ -L "$file" ]; then
        error "Could not write $file: it is a link. Edit the file it points to, or remove the link and run again."
        return 1
    fi
    if ! tmp=$(mktemp "$file.XXXXXX"); then
        error "Could not write $file: it is left as it was."
        return 1
    fi
    if ! "$content" >"$tmp" || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        error "Could not write $file: it is left as it was."
        return 1
    fi
    if [ "$existed" = "true" ]; then
        success "Replaced $file with this run's flags (mode 0600)."
    else
        success "Wrote $file (mode 0600)."
    fi
}

# ===== docker/.env =====
function env_content() {
    cat <<EOF
# Generated by scripts/docker_setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
WALLET_ADDRESS="$(env_value "$WALLET")"
WORKER_NAME="$(env_value "$WORKER_NAME")"
POOL_URL="$(env_value "$POOL_URL")"
DONATE_LEVEL="$(env_value "$DONATE_LEVEL")"
MAX_THREADS_PERCENT="$(env_value "$MAX_THREADS")"
FORCE_THREAD_COUNT="$(env_value "$FORCE_THREAD_COUNT")"
CPU_COUNT="$(env_value "$CPU_COUNT")"
MEMORY_LIMIT="$(env_value "$MEMORY_LIMIT")"
PAUSE_ON_BATTERY="$(env_value "$PAUSE_ON_BATTERY")"
PAUSE_ON_ACTIVE="$(env_value "$PAUSE_ON_ACTIVE")"
XMRIG_IMAGE="$(env_value "$XMRIG_IMAGE")"
EOF
}

# ===== Resolve VPN secrets based on provider =====
function collect_vpn_secrets() {
    case "$VPN_PROVIDER" in
        mullvad|protonvpn)
            RESOLVED_WG_KEY=$(resolve_secret "$WG_KEY_FILE" "WIREGUARD_PRIVATE_KEY" "$WG_KEY" "WireGuard private key") || return 1
            RESOLVED_WG_ADDRESS=$(resolve_secret "$WG_ADDRESS_FILE" "WIREGUARD_ADDRESSES" "$WG_ADDRESS" "WireGuard address (e.g. 10.64.0.1/32)") || return 1
            is_one_line "$RESOLVED_WG_KEY" || { error "The WireGuard private key must be one line with no control character."; return 1; }
            is_one_line "$RESOLVED_WG_ADDRESS" || { error "The WireGuard address must be one line with no control character."; return 1; }
            ;;
        pia|nordvpn)
            RESOLVED_VPN_USER=$(resolve_secret "$VPN_USER_FILE" "OPENVPN_USER" "$VPN_USER" "OpenVPN username") || return 1
            RESOLVED_VPN_PASS=$(resolve_secret "$VPN_PASS_FILE" "OPENVPN_PASSWORD" "$VPN_PASS" "OpenVPN password") || return 1
            is_one_line "$RESOLVED_VPN_USER" || { error "The OpenVPN username must be one line with no control character."; return 1; }
            is_one_line "$RESOLVED_VPN_PASS" || { error "The OpenVPN password must be one line with no control character."; return 1; }
            ;;
    esac
}

# ===== docker/.env.vpn for the selected provider =====
function env_vpn_content() {
    local location_key
    echo "# Generated by scripts/docker_setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    case "$VPN_PROVIDER" in
        mullvad | protonvpn)
            echo "VPN_SERVICE_PROVIDER=\"$VPN_PROVIDER\""
            echo "VPN_TYPE=\"wireguard\""
            echo "WIREGUARD_PRIVATE_KEY=\"$(env_value "$RESOLVED_WG_KEY")\""
            echo "WIREGUARD_ADDRESSES=\"$(env_value "$RESOLVED_WG_ADDRESS")\""
            location_key=SERVER_COUNTRIES
            [ "$VPN_PROVIDER" = "mullvad" ] && location_key=SERVER_CITIES
            ;;
        pia | nordvpn)
            if [ "$VPN_PROVIDER" = "pia" ]; then
                echo "VPN_SERVICE_PROVIDER=\"private internet access\""
                location_key=SERVER_REGIONS
            else
                echo "VPN_SERVICE_PROVIDER=\"nordvpn\""
                location_key=SERVER_COUNTRIES
            fi
            echo "VPN_TYPE=\"openvpn\""
            echo "OPENVPN_USER=\"$(env_value "$RESOLVED_VPN_USER")\""
            echo "OPENVPN_PASSWORD=\"$(env_value "$RESOLVED_VPN_PASS")\""
            ;;
    esac
    if [ -n "$VPN_LOCATION" ]; then
        echo "$location_key=\"$(env_value "$VPN_LOCATION")\""
    fi
    # Gluetun's killswitch is on by its own default; nothing here turns it off.
    echo "TZ=\"UTC\""
    echo "LOG_LEVEL=\"info\""
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
    if ! check_values; then exit 1; fi
    if ! check_docker; then exit 1; fi
    if ! ensure_repo; then exit 1; fi

    local env_file="$REPO_DIR/docker/.env" vpn_file="$REPO_DIR/docker/.env.vpn"
    local write_env=false write_vpn=false
    if should_write "$env_file"; then write_env=true; fi
    if [ "$VPN_PROVIDER" != "none" ] && should_write "$vpn_file"; then write_vpn=true; fi

    # Every secret is in hand before the first file is written.
    if [ "$write_vpn" = "true" ]; then
        collect_vpn_secrets || exit 1
    fi
    if [ "$write_env" = "true" ]; then
        write_settings_file "$env_file" env_content || exit 1
    fi
    if [ "$write_vpn" = "true" ]; then
        write_settings_file "$vpn_file" env_vpn_content || exit 1
        if [ "$VPN_PROVIDER" = "nordvpn" ]; then
            warning "NordVPN's terms may prohibit crypto-mining on your plan. Verify before running long."
        fi
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
