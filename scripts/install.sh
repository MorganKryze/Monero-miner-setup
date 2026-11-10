#!/bin/bash

# ===== Constants =====
VERSION="0.1.1"
LOW_DELAY=0.5
HIGH_DELAY=15
# The commit dependencies/bash-toolbox pins: a fetch by commit cannot change under a running
# install, unlike the branch tip. tests/installer-sources.sh fails when the two differ.
TOOLBOX_COMMIT="b17a126be5390700e081e6f7ae6cddfdb47537e9"
TOOLBOX_URL="https://raw.githubusercontent.com/MorganKryze/bash-toolbox/${TOOLBOX_COMMIT}/src/prefix.sh"
PROJECT_URL="https://github.com/MorganKryze/Monero-miner-setup"
REPO_NAME="Monero-miner-setup"
REPO_URL="https://github.com/MorganKryze/Monero-miner-setup.git"
DEFAULT_MAX_THREADS=75
# The CPUs: on arm64 the miner runs on the ones the config lists, chosen from these files.
HOST_ARCH=$(uname -m 2>/dev/null) || HOST_ARCH=""
CPU_SYS_DIR="/sys/devices/system/cpu"
PROC_STATUS="/proc/self/status"
DEFAULT_DONATE_LEVEL=0
DEFAULT_POOL_URL="gulf.moneroocean.stream"
DEFAULT_PASS="x"
DEFAULT_PAUSE_ON_ACTIVE=false
DEFAULT_PAUSE_ON_BATTERY=false
DEFAULT_SERVICE_MODE="setup" # Options: "setup", "manual", "autostart"
DEFAULT_NON_INTERACTIVE=false
# Base directory as root on Linux: the service then runs the miner as another account, which can
# enter /opt but not root's home (mode 700).
ROOT_BASE_DIR="/opt"
# Where the service setup (scripts/setup_service_*.sh) installs the service: a re-run that finds
# it there leaves the service as it is.
SYSTEMD_UNIT="/etc/systemd/system/xmrig.service"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.moneroocean.xmrig.plist"
DOCKER_SCRIPT_URL="https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/docker_setup.sh"
# --prebuilt: the binary CI builds for Linux arm64 on Debian 13 and the SHA256SUMS beside it, from the
# release the clone is checked out at. The release jobs (.github/workflows/publish.yml) read the
# minimum glibc here and fail a tag whose binary needs a newer one.
RELEASE_URL="https://github.com/MorganKryze/Monero-miner-setup/releases/download"
RELEASE_ASSET="xmrig-linux-arm64"
RELEASE_MIN_GLIBC="2.38"
RELEASE_PACKAGES=(libuv1t64 libssl3t64 libhwloc15)

# ===== Own clone =====
# BASH_SOURCE is read here, at the top level: inside a function, bash 5 gives a script read from a
# pipe its $0 ("bash", or the first argument of `bash -c`), which may name a file in the current
# directory.
SELF_PATH="${BASH_SOURCE[0]-}"

# Prints the clone this file sits in (<clone>/scripts/install.sh), or nothing. Piped into bash, run
# through `bash <(...)` or `bash -c "$(...)"`, or saved outside a clone, the installer has no clone
# of its own and never looks in the current directory, where another user may have left a file.
# Nor has it one when someone else can write to the clone root, as in /tmp: they could have
# planted the .git and the toolbox there.
function find_own_clone() {
    local dir root
    [ -n "$SELF_PATH" ] && [ -f "$SELF_PATH" ] || return 0
    dir=$(cd -- "$(dirname -- "$SELF_PATH")" 2>/dev/null && pwd -P) || return 0
    root="${dir%/*}"
    if [ "${dir##*/}" = "scripts" ] && [ -e "$root/.git" ] && only_user_can_write "$root"; then
        printf '%s' "$root"
    fi
}

# Other users can never write to the folder. Its group can only when the group is the user's own:
# Ubuntu gives each user one and a umask of 0002, so a clone there is group-writable, while a
# shared group (macOS's staff holds every local user) or a project group holds other users. find
# prints the folder only when it is safe, so a failed check, or a failed id, falls back to the fetch.
# The mode bits miss an ACL, which can let anyone add files to the folder: one on the folder is a no
# too. macOS lists each entry on a line of its own under ls -e (its + marker gives way to @ when
# the folder has extended attributes), from /bin/ls: a GNU ls ahead of it in PATH has no -e;
# Linux ends the mode with +.
function only_user_can_write() {
    local group_ok listing
    group_ok=(! -perm -0020)
    if [ "$(id -gn 2>/dev/null)" = "$(id -un 2>/dev/null)" ]; then
        group_ok=("(" ! -perm -0020 -o -group "$(id -g)" ")")
    fi
    [ "$(find "$1/" -maxdepth 0 ! -perm -0002 "${group_ok[@]}" -print 2>/dev/null)" = "$1/" ] || return 1
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        listing=$(/bin/ls -lde -- "$1/" 2>/dev/null) || return 1
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

OWN_CLONE=$(find_own_clone)

# ===== Docker-mode dispatch =====
# If --docker appears anywhere in the args, hand off to docker_setup.sh: the own clone's copy,
# otherwise a fetch from GitHub. Runs before any other logic so the native install path never
# executes.
function maybe_dispatch_docker() {
    local is_docker=false
    local passthrough=()
    for arg in "$@"; do
        if [ "$arg" = "--docker" ]; then
            is_docker=true
        else
            passthrough+=("$arg")
        fi
    done

    if [ "$is_docker" != "true" ]; then
        return 0
    fi

    if [ -n "$OWN_CLONE" ] && [ -f "$OWN_CLONE/scripts/docker_setup.sh" ]; then
        echo "Dispatching to $OWN_CLONE/scripts/docker_setup.sh..."
        exec bash "$OWN_CLONE/scripts/docker_setup.sh" "${passthrough[@]}"
    fi

    local tmpfile
    tmpfile=$(mktemp) || { echo "[  ERROR  ] Failed to create temp file." >&2; exit 1; }
    if ! curl -fsSL --proto '=https' "$DOCKER_SCRIPT_URL" -o "$tmpfile"; then
        echo "[  ERROR  ] Failed to fetch $DOCKER_SCRIPT_URL. Check your network or install from a local clone." >&2
        rm -f "$tmpfile"
        exit 1
    fi
    # bash runs an empty file and exits 0: a cut download would look like a finished install.
    if [ ! -s "$tmpfile" ]; then
        echo "[  ERROR  ] Fetched an empty file from $DOCKER_SCRIPT_URL. Check your network or install from a local clone." >&2
        rm -f "$tmpfile"
        exit 1
    fi
    echo "Dispatching to docker_setup.sh (fetched)..."
    exec bash "$tmpfile" "${passthrough[@]}"
}

maybe_dispatch_docker "$@"

# ===== Error handling =====
set -o errexit  # Exit on error
set -o pipefail # Exit if any command in a pipe fails
trap cleanup EXIT

# ===== Function definitions =====
function cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "Script exited with error code $exit_code."
    fi
    # Add any cleanup tasks here
    return $exit_code
}

# The log helpers: the own clone's vendored copy when it is checked out, otherwise the pinned
# commit from GitHub. Without them nothing below can print, so a failed, empty or partial load
# stops here, before any other step.
function load_toolbox() {
    local from toolbox=""
    if [ -n "$OWN_CLONE" ] && [ -f "$OWN_CLONE/dependencies/bash-toolbox/src/prefix.sh" ]; then
        from="$OWN_CLONE/dependencies/bash-toolbox/src/prefix.sh"
        toolbox=$(cat -- "$from") || toolbox=""
    else
        from="$TOOLBOX_URL"
        toolbox=$(curl -fsSL --proto '=https' --connect-timeout 10 "$TOOLBOX_URL") || toolbox=""
    fi
    # eval, not `source <(...)`: macOS's bash 3.2 sources nothing from a process substitution.
    if [ -n "$toolbox" ] && eval "$toolbox" && declare -F txt info warning error success hint >/dev/null; then
        return 0
    fi
    echo "[  ERROR  ] Failed to load the log helpers from $from." >&2
    exit 1
}

function display_header() {
    txt ' ___      ___     ______    _____  ___    _______   _______     ______        ___      ___   __    _____  ___    _______   _______  '
    txt '|"  \    /"  |   /    " \  (\"   \|"  \  /"     "| /"      \   /    " \      |"  \    /"  | |" \  (\"   \|"  \  /"     "| /"      \ '
    txt ' \   \  //   |  // ____  \ |.\\\   \    |(: ______)|:        | // ____  \      \   \  //   | ||  | |.\\\   \    |(: ______)|:        |'
    txt ' /\\\  \/.    | /  /    ) :)|: \.   \\\  | \/    |  |_____/   )/  /    ) :)     /\\\  \/.    | |:  | |: \.   \\\  | \/    |  |_____/   )'
    txt '|: \.        |(: (____/ // |.  \    \. | // ___)_  //      /(: (____/ //     |: \.        | |.  | |.  \    \. | // ___)_  //      / '
    txt '|.  \    /:  | \        /  |    \    \ |(:      "||:  __   \ \        /      |.  \    /:  | /\  |\|    \    \ |(:      "||:  __   \ '
    txt '|___|\__/|___|  \"_____/    \___|\____\) \_______)|__|  \___) \"_____/       |___|\__/|___|(__\_|_)\___|\____\) \_______)|__|  \___)'

    sleep $LOW_DELAY
    txt
    txt "Open-source Monero miner setup script v${VERSION}."
    sleep $LOW_DELAY
    txt "The Project is NEITHER endorsed by Monero NOR MoneroOcean team, use at your own risk."
    sleep $LOW_DELAY
    txt "Licensed under the MIT License, Yann M. Vidamment © 2025."
    sleep $LOW_DELAY
    txt "Visit ${LINK}${UNDERLINE}${PROJECT_URL}${RESET} for more information."
    sleep $LOW_DELAY
    txt
    txt "=========================================================================================="
    txt
    sleep $LOW_DELAY
}

function usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Required Options:"
    echo "  -w, --wallet WALLET   Your Monero wallet address"
    echo
    echo "Installation Options:"
    echo "  -d, --dir DIR         Base directory for installation (defaults to HOME; as root on Linux, /opt)"
    echo "  --prebuilt            Install the release binary instead of compiling: Linux arm64, as root, glibc $RELEASE_MIN_GLIBC or newer"
    echo
    echo "Mining Configuration Options:"
    echo "  -t, --threads PERCENT Share of the CPUs to mine on (1-100, default: $DEFAULT_MAX_THREADS; on arm64, the biggest first)"
    echo "  --donate PERCENT      Donation level (0-5, default: $DEFAULT_DONATE_LEVEL)"
    echo "  -p, --pool URL        Mining pool URL (default: $DEFAULT_POOL_URL)"
    echo "  --name STRING         Display name for the mining worker (default: random adjective_noun_NNN)"
    echo "  --pause-active        Pause mining when computer is in active use (default: off)"
    echo "  --pause-battery       Pause mining when computer is on battery (default: off)"
    echo "  -h, --help            Display this help message"
    echo
    echo "Service Configuration Options:"
    echo "  --only-manual        Do not set up any service, only manual operation"
    echo "  --autostart          Start mining service immediately after installation"
    echo "  --service-as-root    Run the systemd service as root. Only for the x86 RandomX MSR boost, which"
    echo "                       needs root; without it, a root install runs the miner as the user who ran"
    echo "                       sudo, or as the system account xmrig"
    echo
    echo "Automation Options:"
    echo "  -y, --yes, --non-interactive"
    echo "                        Skip confirmations and pre-install delay (for CI / scripts)"
    echo
    echo "Examples:"
    echo "  $0 -w 4ABD..."
    echo "  $0 -w 4ABD... -d /opt/monero -t 50 --donate 1"
    echo "  $0 -w 4ABD... -p rx.unmineable.com:3333"
    echo "  $0 -w 4ABD... --name my_worker_name"
    echo
    echo "Note: For MoneroOcean pool, the script will automatically calculate optimal port."
}

function check_if_running_as_root() {
    if [ "$(id -u)" == "0" ]; then
        warning "Generally it is not advised to run this script under root."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            info "Continuing as root (non-interactive mode)."
            return 0
        fi
        read -p "Do you want to continue anyway? (y/N): " continue_as_root
        if [[ ! "$continue_as_root" =~ ^[Yy]$ ]]; then
            info "Exiting as requested."
            exit 0
        fi
    fi
}

function validate_wallet() {
    local wallet="$1"

    if [ -z "$wallet" ]; then
        error "No wallet address provided. Please provide your Monero wallet address using -w or --wallet."
        return 1
    fi

    # Strip optional ".paymentid" suffix before validating the base address.
    local wallet_base
    wallet_base=$(echo "$wallet" | cut -f1 -d".")
    local len=${#wallet_base}

    # Length check: 95 = standard/subaddress, 106 = integrated (w/ payment id).
    if [ "$len" != 95 ] && [ "$len" != 106 ]; then
        error "Invalid wallet length (expected 95 or 106, got $len)."
        return 1
    fi

    # Format check: Monero addresses start with '4' (standard/integrated)
    # or '8' (subaddress) and use the base58 alphabet (no 0, O, I, l).
    if ! [[ "$wallet_base" =~ ^[48][1-9A-HJ-NP-Za-km-z]+$ ]]; then
        error "Invalid wallet format: must start with '4' or '8' and use base58 characters only (no 0, O, I, l)."
        return 1
    fi

    if ! is_wallet "$wallet"; then
        error "Invalid wallet: 95 or 106 base58 characters starting with 4 or 8, then optionally one '.' and 1 to 64 letters or digits."
        return 1
    fi

    info "Using wallet address: $wallet."
    info "Wallet format looks valid (length $len, leading char '${wallet_base:0:1}')."
    return 0
}

# The value rules, the same in docker/entrypoint.sh, scripts/docker_setup.sh and here. Every
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


# Root, or the user who ran sudo (who holds root already), owns the path and neither its
# group nor others can write it (GNU stat, Linux only). A link counts as its own path (stat does
# not follow it, and a link's mode is 777), so a link is refused. stat drops a mode's leading zeros
# (0007 comes out as 7), so the mode is read as a whole octal number.
function trusted_by_root() {
    local info mode owner
    info=$(stat -c '%U %a' "$1") || return 1
    owner=${info%% *} mode=${info#* }
    [[ "$mode" =~ ^[0-7]+$ ]] && (( (8#$mode & 8#022) == 0 )) &&
        { [ "$owner" = root ] || { [ -n "${SUDO_USER:-}" ] && [ "$owner" = "$SUDO_USER" ]; }; }
}

function validate_directory() {
    local dir="$1" path check rest remedy

    # As root on Linux, the service runs the miner as another account (setup_service_debian.sh),
    # which root's home keeps out: the default is then /opt, unless an earlier install left its
    # clone in HOME, where a re-run finds it.
    if [ -z "$dir" ] && [ "$(id -u)" == "0" ] && [ "$(uname -s)" == "Linux" ] && [ -d "$ROOT_BASE_DIR" ] &&
        [ ! -d "${HOME:-}/$REPO_NAME" ]; then
        dir="$ROOT_BASE_DIR"
        # Redirect info message to stderr so it doesn't get captured by $()
        info "Running as root, no base directory provided: using $dir, which the account running the miner can enter." >&2
    elif [ -z "$dir" ]; then
        if [ -z "$HOME" ]; then
            error "Please define HOME environment variable to your home directory."
            return 1
        fi

        if [ ! -d "$HOME" ]; then
            error "Please make sure HOME directory $HOME exists or set it yourself using -d or --dir option."
            error '  export HOME=<dir>'
            return 1
        fi

        dir="$HOME"
        # Redirect info message to stderr so it doesn't get captured by $()
        info "No base directory provided, using default: $dir." >&2
    else
        if [ ! -d "$dir" ]; then
            error "Base directory does not exist: $dir."
            return 1
        fi
        # Redirect info message to stderr so it doesn't get captured by $()
        info "Using base directory: $dir." >&2
    fi

    # Every step acts on the directory the checks read, never on a link a user could point
    # elsewhere later.
    path=$(CDPATH= cd -- "$dir" && pwd -P) || return 1
    if [ "$path" != "$dir" ]; then
        info "Resolved to $path." >&2
        dir=$path
    fi

    # Root goes on to run the clone's scripts: a user who can change the base directory, a clone
    # already there or any directory above them would choose what root runs, as with the
    # installer's own clone above. This holds whatever chose the directory, -d included.
    if [ "$(id -u)" == "0" ] && [ "$(uname -s)" == "Linux" ]; then
        remedy="Pass -d"
        if [ -e "$path/$REPO_NAME" ] || [ -L "$path/$REPO_NAME" ]; then
            path="$path/$REPO_NAME"
            remedy="Remove $path, or pass -d"
        fi
        check=
        while :; do
            if ! trusted_by_root "${check:-/}"; then
                error "${check:-/} can be changed by a user other than root or the one who ran sudo, and root would run what they put there. $remedy with a directory only root can change." >&2
                return 1
            fi
            [ "${check:-/}" = "$path" ] && break
            rest=${path#"$check"/}
            check=$check/${rest%%/*}
        done
    fi

    if [ ! -w "$dir" ]; then
        error "No write permission to directory: $dir."
        return 1
    fi

    # Only the directory path will be captured now
    printf "%s" "$dir"
    return 0
}

function detect_os() {
    info "Detecting operating system..."

    # Default values
    OS_TYPE="unknown"
    OS_NAME="unknown"
    OS_VERSION="unknown"
    IS_WSL=0

    # Check for macOS
    if command -v sw_vers &>/dev/null; then
        OS_TYPE="macos"
        OS_NAME=$(sw_vers -productName)
        OS_VERSION=$(sw_vers -productVersion)
        info "Detected macOS: $OS_NAME $OS_VERSION."

    # Check for Linux
    elif command -v lsb_release &>/dev/null; then
        OS_TYPE="linux"
        OS_NAME=$(lsb_release -is)
        OS_VERSION=$(lsb_release -rs)

        # Check if running in WSL
        if grep -qi microsoft /proc/version 2>/dev/null; then
            IS_WSL=1
            info "Detected Linux (WSL): $OS_NAME $OS_VERSION."
        else
            info "Detected Linux: $OS_NAME $OS_VERSION."
        fi

    # Fallback Linux detection
    elif [ -f /etc/os-release ]; then
        OS_TYPE="linux"
        OS_NAME=$(grep -oP '(?<=^NAME=").+(?=")' /etc/os-release)
        OS_VERSION=$(grep -oP '(?<=^VERSION_ID=").+(?=")' /etc/os-release)

        # Check if running in WSL
        if grep -qi microsoft /proc/version 2>/dev/null; then
            IS_WSL=1
            info "Detected Linux (WSL): $OS_NAME $OS_VERSION."
        else
            info "Detected Linux: $OS_NAME $OS_VERSION."
        fi

    # Generic UNIX-like OS detection (unsupported for native install)
    elif command -v uname &>/dev/null; then
        OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
        OS_NAME=$(uname -s)
        OS_VERSION=$(uname -r)
        info "Detected UNIX-like system: $OS_NAME $OS_VERSION."

    else
        warning "Unable to determine operating system type."
    fi

    # Export variables for use in other functions
    export OS_TYPE
    export OS_NAME
    export OS_VERSION
    export IS_WSL

    return 0
}

function parse_arguments() {
    # Default values
    WALLET=""
    BASE_DIR=""
    MAX_THREADS=$DEFAULT_MAX_THREADS
    DONATE_LEVEL=$DEFAULT_DONATE_LEVEL
    POOL_URL=$DEFAULT_POOL_URL
    DISPLAY_NAME=$DEFAULT_PASS
    PAUSE_ON_ACTIVE=$DEFAULT_PAUSE_ON_ACTIVE
    PAUSE_ON_BATTERY=$DEFAULT_PAUSE_ON_BATTERY
    SERVICE_MODE=$DEFAULT_SERVICE_MODE
    NON_INTERACTIVE=$DEFAULT_NON_INTERACTIVE
    SERVICE_AS_ROOT=no
    PREBUILT=no

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
        -w | --wallet)
            WALLET="$2"
            shift 2
            ;;
        -d | --dir)
            BASE_DIR="$2"
            shift 2
            ;;
        -t | --threads)
            MAX_THREADS="$2"
            if ! [[ "$MAX_THREADS" =~ ^[0-9]+$ ]] || [ "$MAX_THREADS" -lt 1 ] || [ "$MAX_THREADS" -gt 100 ]; then
                error "Thread percentage must be between 1 and 100."
                exit 1
            fi
            shift 2
            ;;
        --donate)
            DONATE_LEVEL="$2"
            if ! [[ "$DONATE_LEVEL" =~ ^[0-9]+$ ]] || [ "$DONATE_LEVEL" -lt 0 ] || [ "$DONATE_LEVEL" -gt 5 ]; then
                error "Donation level must be between 0 and 5."
                exit 1
            fi
            shift 2
            ;;
        -p | --pool)
            POOL_URL="$2"
            if ! is_pool "$POOL_URL"; then
                error "--pool must be a host name or IPv4 address, optionally after stratum+tcp:// or stratum+ssl:// and before a :port from 1 to 65535."
                exit 1
            fi
            shift 2
            ;;
        --pass | --name) # Accept both for backward compatibility
            DISPLAY_NAME="$2"
            if ! is_worker_name "$DISPLAY_NAME"; then
                error "--name must be 1 to 64 letters, digits or . _ - @ : + characters."
                exit 1
            fi
            shift 2
            ;;
        --pause-active)
            PAUSE_ON_ACTIVE=true
            shift 1
            ;;
        --pause-battery)
            PAUSE_ON_BATTERY=true
            shift 1
            ;;
        --only-manual)
            SERVICE_MODE="manual"
            shift 1
            ;;
        --autostart)
            SERVICE_MODE="autostart"
            shift 1
            ;;
        --service-as-root)
            SERVICE_AS_ROOT=yes
            shift 1
            ;;
        --prebuilt)
            PREBUILT=yes
            shift 1
            ;;
        -y | --yes | --non-interactive)
            NON_INTERACTIVE=true
            shift 1
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1."
            usage
            exit 1
            ;;
        esac
    done

    # Check if required arguments are provided
    if [ -z "$WALLET" ]; then
        error "Wallet address is required."
        usage
        exit 1
    fi

    export WALLET
    export BASE_DIR
    export MAX_THREADS
    export DONATE_LEVEL
    export POOL_URL
    export PASS=$DISPLAY_NAME
    export PAUSE_ON_ACTIVE
    export PAUSE_ON_BATTERY
    export SERVICE_MODE
    export NON_INTERACTIVE
    # Read by scripts/setup_service_debian.sh: only this flag makes the service run as root.
    export SERVICE_AS_ROOT
    # A host --prebuilt cannot serve stops here, before anything is cloned, fetched or installed.
    if [ "$PREBUILT" = yes ] && ! check_prebuilt_host; then
        exit 1
    fi
}

# ===== MoneroOcean Miner Setup Functions =====

function check_dependencies() {
    if ! command -v curl &>/dev/null; then
        error "This script requires 'curl' utility to work correctly."
        return 1
    fi

    if ! command -v git &>/dev/null; then
        error "This script requires 'git' utility to work correctly."
        return 1
    fi

    if ! command -v make &>/dev/null; then
        error "This script requires 'make' utility to work correctly."
        return 1
    fi

    if ! command -v lscpu &>/dev/null; then
        warning "This script works better with 'lscpu' utility on linux systems."
        warning "You can install it using: sudo apt-get install -y util-linux"
    fi

    info "All required dependencies are installed (curl, git, make)."
    return 0
}

function calculate_hashrate_and_port() {
    # Calculate threads and estimated hashrate
    if command -v nproc &>/dev/null; then
        CPU_THREADS=$(nproc)
    elif command -v sysctl &>/dev/null; then
        CPU_THREADS=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
    else
        CPU_THREADS=1
    fi
    EXP_MONERO_HASHRATE=$((CPU_THREADS * 700 / 1000))

    if [ -z "$EXP_MONERO_HASHRATE" ]; then
        error "Can't compute projected Monero CN hashrate."
        return 1
    fi

    # Power2 function to calculate appropriate port
    function power2() {
        local input="$1"
        if ! command -v bc &>/dev/null; then
            if [ "$input" -gt "8192" ]; then
                echo "8192"
            elif [ "$input" -gt "4096" ]; then
                echo "4096"
            elif [ "$input" -gt "2048" ]; then
                echo "2048"
            elif [ "$input" -gt "1024" ]; then
                echo "1024"
            elif [ "$input" -gt "512" ]; then
                echo "512"
            elif [ "$input" -gt "256" ]; then
                echo "256"
            elif [ "$input" -gt "128" ]; then
                echo "128"
            elif [ "$input" -gt "64" ]; then
                echo "64"
            elif [ "$input" -gt "32" ]; then
                echo "32"
            elif [ "$input" -gt "16" ]; then
                echo "16"
            elif [ "$input" -gt "8" ]; then
                echo "8"
            elif [ "$input" -gt "4" ]; then
                echo "4"
            elif [ "$input" -gt "2" ]; then
                echo "2"
            else
                echo "1"
            fi
        else
            echo "x=l($input)/l(2); scale=0; 2^((x+0.5)/1)" | bc -l
        fi
    }

    # Calculate PORT based on hashrate
    PORT=$((EXP_MONERO_HASHRATE * 30))
    PORT=$((PORT == 0 ? 1 : PORT))
    PORT=$(power2 $PORT)
    PORT=$((10000 + PORT))

    if [ -z "$PORT" ]; then
        error "Can't compute port."
        return 1
    fi

    if [ "$PORT" -lt "10001" -o "$PORT" -gt "18192" ]; then
        error "Wrong computed port value: $PORT."
        return 1
    fi

    info "This host has $CPU_THREADS CPU threads, so projected Monero hashrate is around $EXP_MONERO_HASHRATE KH/s."
    info "Using port: $PORT."

    # Export variables for use in other functions
    export CPU_THREADS
    export EXP_MONERO_HASHRATE
    export PORT

    return 0
}

function check_repo_exists() {
    local target_dir="$BASE_DIR/$REPO_NAME"

    if [ -d "$target_dir" ] && [ -d "$target_dir/.git" ]; then
        info "Project repository found at $target_dir."
        return 0
    else
        info "Project repository not found at $target_dir."
        return 1
    fi
}

# A directory above the clone may carry an ACL its mode bits don't show. macOS lists each entry
# under /bin/ls -e (a GNU ls ahead of it in PATH has no -e); one that allows adding, removing or
# rewriting entries, or rewriting the ACL or the owner, lets another user in (1), while a deny
# entry doesn't (/Users/<you> carries group:everyone deny delete). On Linux the group bits then
# show the ACL's mask and the mode ends with + (2), so a group write there is no longer the private
# group's alone. 0: no ACL that counts.
function dir_acl() {
    local listing line
    if [ "$(uname -s 2>/dev/null)" != "Darwin" ]; then
        listing=$(ls -ld -- "$1/" 2>/dev/null) || return 1
        case ${listing%% *} in
            *+) return 2 ;;
        esac
        return 0
    fi
    listing=$(/bin/ls -lde -- "$1/" 2>/dev/null) || return 1
    case $listing in
        *$'\n'*) listing=${listing#*$'\n'} ;;
        *) return 0 ;;
    esac
    while IFS= read -r line; do
        case $line in
            *" allow "*add_file* | *" allow "*add_subdirectory* | *" allow "*delete_child* | \
                *" allow "*write* | *" allow "*chown*) return 1 ;;
        esac
    done <<< "$listing"
}

# The clone a native run builds, configures and sets up the service from, often as root: a git
# clone in which every path belongs to you or root (as root, also to the user who ran sudo, who can
# become root anyway) and none can be changed by another user. The run executes code from anywhere
# in it (git's config, the Makefile, the sources it compiles, the service scripts), so the whole
# tree is read, not a list of paths that goes stale as the tree grows. A link inside it counts by
# its owner alone: its own mode is 777 on Linux, and what it points to inside the clone is read
# anyway. A link at the clone's path is refused, as later steps would act through it; find never
# follows one (-P), so a link swapped in after that test is read as a link. An ACL is read on the
# clone's folder, whose default ACL every new path inherits, and on each directory above it. Above
# the clone, a user who can change the base directory or a directory above it could swap the clone
# between this check and the build, unless the directory is sticky (/tmp). It only reads. Nothing at the path passes once
# the directories above it do: the run then clones there. "fresh" says this run has just cloned it,
# so a path others can change points at the umask.
function check_base_clone() {
    local dir="$1" fresh="${2:-}" uid owners trusted groups dir_groups acl bad remedy base check rest
    remedy="Move $dir away and run the installer again, or pass -d with another base directory."
    uid=$(id -u 2>/dev/null)
    owners=(! -user "$uid" ! -user 0)
    trusted=(-user "$uid" -o -user 0)
    if [ "$uid" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        owners+=(! -user "$SUDO_USER")
        trusted+=(-o -user "$SUDO_USER")
    fi
    # The user's own group, as only_user_can_write takes it.
    groups=(-perm -0020)
    if [ "$(id -gn 2>/dev/null)" = "$(id -un 2>/dev/null)" ]; then
        groups+=(! -group "$(id -g 2>/dev/null)")
    fi
    if [ -L "$dir" ]; then
        # -d takes the base directory, so the remedy names the folder that holds the target.
        local target
        if target=$(cd -P -- "$dir" 2>/dev/null && pwd -P); then
            error "$dir is a link, so this run does not use it. Pass -d with ${target%/*}, the folder that holds the one it points to."
        else
            error "$dir is a link, so this run does not use it. Move $dir away and run the installer again, or pass -d with another base directory."
        fi
        return 1
    fi
    if [ -e "$dir" ]; then
        if [ ! -d "$dir" ] || [ ! -e "$dir/.git" ]; then
            error "$dir is not a git clone, so this run does not use it. $remedy"
            return 1
        fi
        if ! bad=$(find -P "$dir" "(" "${owners[@]}" ")" -print -quit 2>/dev/null); then
            error "$dir cannot be read whole, so this run does not use it. $remedy"
            return 1
        fi
        if [ -n "$bad" ]; then
            error "$bad belongs to another user, so this run does not use $dir. $remedy"
            return 1
        fi
        if ! bad=$(find -P "$dir" ! -type l "(" -perm -0002 -o "(" "${groups[@]}" ")" ")" -print -quit 2>/dev/null); then
            error "$dir cannot be read whole, so this run does not use it. $remedy"
            return 1
        fi
        if [ -z "$bad" ] && ! only_user_can_write "$dir"; then
            bad=$dir
        fi
        if [ -n "$bad" ]; then
            if [ -n "$fresh" ]; then
                remedy="This run has just cloned it, so your umask is the likely cause: remove $dir, run umask 022, and run the installer again."
            fi
            error "$bad can be changed by a user other than you, so this run does not use $dir. $remedy"
            return 1
        fi
    fi
    # Each directory from / down to the base directory, read on its real path.
    base=${dir%/*}
    if ! base=$(CDPATH= cd -- "${base:-/}" 2>/dev/null && pwd -P); then
        error "${dir%/*} can be changed by a user other than you, so this run does not use $dir. Pass -d with a directory only you can change."
        return 1
    fi
    check=
    while :; do
        dir_groups=("${groups[@]}")
        dir_acl "$check"
        acl=$?
        [ "$acl" = 2 ] && dir_groups=(-perm -0020)
        if [ "$acl" = 1 ] ||
            [ "$(find "$check/" -maxdepth 0 "(" "${trusted[@]}" ")" "(" "(" ! -perm -0002 ! "(" "${dir_groups[@]}" ")" ")" -o -perm -1000 ")" -print 2>/dev/null)" != "$check/" ]; then
            error "${check:-/} can be changed by a user other than you, so this run does not use $dir. Pass -d with a directory only you can change."
            return 1
        fi
        [ "${check:-/}" = "$base" ] && break
        rest=${base#"$check"/}
        check=$check/${rest%%/*}
    done
}

function check_if_built() {
    local target_dir="$BASE_DIR/$REPO_NAME" tag

    # --prebuilt installs the release the clone is checked out at, where only root can change it.
    if [ "$PREBUILT" = yes ]; then
        root_only_tree "$target_dir" || exit 1
        tag=$(release_tag_of "$target_dir")
        if [ -z "$tag" ]; then
            error "$target_dir is checked out at no release tag, and --prebuilt installs the release the clone is checked out at. Run git -C $target_dir checkout --recurse-submodules vX.Y.Z with a release from $PROJECT_URL/releases, then the installer again."
            exit 1
        fi
        if [ -f "$target_dir/xmrig.release" ] &&
            [ "$(binary_origin "$target_dir")" = "release $tag, sha256 $(binary_sha256 "$target_dir/xmrig")" ]; then
            success "XMRig of release $tag is already installed at $target_dir."
            return 0
        fi
        info "Monero miner not yet installed from release $tag."
        return 1
    fi

    # Check for evidence of a successful build: the Makefile produces
    # $target_dir/build-xmrig/xmrig and a symlink at $target_dir/xmrig.
    if [ -d "$target_dir/build-xmrig" ] && [ -e "$target_dir/xmrig" ]; then
        success "Monero miner appears to be already built at $target_dir."
        return 0
    else
        info "Monero miner not yet built."
        return 1
    fi
}

function clone_repository() {
    local target_dir="$BASE_DIR/$REPO_NAME" branch=()

    # --prebuilt clones the release this installer comes from, so its scripts and its binary match.
    if [ "$PREBUILT" = yes ]; then
        root_only_tree "$BASE_DIR" || return 1
        branch=(--branch "v$VERSION")
    fi

    info "Cloning project repository to $target_dir..."

    # git clones into an empty folder already at the path, and whoever made it there since the
    # first check could rename the .git git lays out in it and put in their own, whose hooks git
    # then runs. mkdir fails when anything is there, so the folder git fills is this run's own.
    if ! mkdir -- "$target_dir" 2>/dev/null; then
        error "$target_dir is already there or cannot be made, so this run does not clone into it. Move $target_dir away and run the installer again, or pass -d with another base directory."
        return 1
    fi
    if ! git clone --recurse-submodules "${branch[@]}" "$REPO_URL" "$target_dir"; then
        # The folder is this run's own and git left it empty: remove it, so a re-run can clone.
        rmdir -- "$target_dir" 2>/dev/null
        error "Failed to clone repository (with submodules) from $REPO_URL."
        return 1
    fi
    # git lays out the clone under your umask: the fresh clone gets the same check.
    if ! check_base_clone "$target_dir" fresh; then
        return 1
    fi

    success "Repository and submodules successfully cloned to $target_dir."
    return 0
}

function build_project() {
    local target_dir="$BASE_DIR/$REPO_NAME"

    info "Building project at $target_dir..."

    cd "$target_dir" || {
        error "Failed to navigate to $target_dir."
        return 1
    }

    # Build the commits this repository pins, never the upstream tip: that would build
    # whatever xmrig's master holds today, unreviewed.
    info "Checking out the pinned submodule commits..."
    if ! git submodule update --init --recursive; then
        error "Failed to check out the pinned submodules."
        return 1
    fi
    success "Submodules match the pinned commits."

    # Select the appropriate build command based on OS
    case "$OS_TYPE" in
    linux)
        if [ -f "/etc/debian_version" ] || [[ "$OS_NAME" =~ Debian|Ubuntu|Mint ]]; then
            info "Detected Debian-based system, running 'make install-debian'..."
            if ! make install-debian; then
                error "Failed to build project using 'make install-debian'."
                return 1
            fi
        else
            error "Unsupported Linux distribution: $OS_NAME."
            error "Only Debian/Ubuntu are supported natively. Use the Docker install instead."
            return 1
        fi
        ;;
    macos)
        info "Detected macOS, running 'make install-macos'..."
        if ! make install-macos; then
            error "Failed to build project using 'make install-macos'."
            return 1
        fi
        ;;
    *)
        error "Unsupported operating system: $OS_TYPE."
        error "Native install supports macOS and Debian/Ubuntu. Use the Docker install instead."
        return 1
        ;;
    esac

    success "Project built successfully."
    return 0
}
# Linux aarch64 and macOS arm64: there the miner starts one thread on every CPU whatever its
# thread hint, so the config lists the CPUs to mine on.
function is_arm64() {
    [ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ]
}

# Prints the CPUs this process may run on, one per line, best first: highest capacity, then highest
# maximum frequency, then lowest number. A value that cannot be read counts as 0; with no readable
# allowed list, every online CPU may be used.
function ranked_cpus() {
    local allowed count part cpu cap freq
    allowed=$(awk '/^Cpus_allowed_list:/ { print $2 }' "$PROC_STATUS" 2>/dev/null) || allowed=""
    if ! [[ "$allowed" =~ ^[0-9]{1,4}(-[0-9]{1,4})?(,[0-9]{1,4}(-[0-9]{1,4})?)*$ ]]; then
        count=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || count=""
        [[ "$count" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$count))" -ge 1 ] || count=1
        allowed="0-$((10#$count - 1))"
    fi
    for part in ${allowed//,/ }; do
        for ((cpu = 10#${part%-*}; cpu <= 10#${part#*-}; cpu++)); do
            cap=$(cat "$CPU_SYS_DIR/cpu$cpu/cpu_capacity" 2>/dev/null) || cap=""
            [[ "$cap" =~ ^[0-9]{1,9}$ ]] || cap=0
            freq=$(cat "$CPU_SYS_DIR/cpu$cpu/cpufreq/cpuinfo_max_freq" 2>/dev/null) || freq=""
            [[ "$freq" =~ ^[0-9]{1,12}$ ]] || freq=0
            echo "$cap $freq $cpu"
        done
    done | sort -k1,1nr -k2,2nr -k3,3n | awk '{ print $3 }'
}

# Prints the <count> best CPUs as a JSON list in ascending order ("[4, 5, 6, 7]"), or nothing when
# none can be found.
function arm_cpu_list() {
    ranked_cpus | head -n "$1" | sort -n | awk '{ printf "%s%s", (NR > 1 ? ", " : "["), $1 } END { if (NR) print "]" }'
}

# Sets CPU_LIST: on arm64, ceil(N x MAX_THREADS / 100) of the N usable CPUs, at least 1; on any
# other host nothing, and the miner's thread hint applies.
function pick_cpu_list() {
    local usable count
    CPU_LIST=""
    is_arm64 || return 0
    usable=$(ranked_cpus | awk 'END { print NR }')
    count=$(((usable * 10#$MAX_THREADS + 99) / 100))
    [ "$count" -ge 1 ] || count=1
    CPU_LIST=$(arm_cpu_list "$count")
}

function configs_exist() {
    local dest_config_dir="$BASE_DIR/$REPO_NAME/configs"
    [ -f "$dest_config_dir/config.json" ] && [ -f "$dest_config_dir/config_background.json" ]
}

# Writes a miner config from its template: each setting the installer fills in becomes one JSON
# value holding exactly what was passed. The values reach awk through its environment, as data;
# no command is built from them. Arguments: template, destination, log file, pool URL, worker name.
# A CPU list in CPU_LIST (arm64) goes under every algorithm the miner would otherwise give a thread
# on each CPU; the wildcard profile "*" is not used, as it makes the miner's algorithm calibration
# wait forever on kawpow, which has no CPU implementation.
# The config is written next to the destination and moved over it only once complete: a failed
# write leaves no partial file that a later run would keep.
function write_miner_config() {
    XMRIG_HINT=$MAX_THREADS XMRIG_DONATE=$DONATE_LEVEL XMRIG_LOG=$3 XMRIG_URL=$4 XMRIG_USER=$WALLET \
        XMRIG_PASS=$5 XMRIG_BATTERY=$PAUSE_ON_BATTERY XMRIG_ACTIVE=$PAUSE_ON_ACTIVE XMRIG_CPUS=$CPU_LIST awk '
        function str(v,   out, i, c) {
            out = ""
            for (i = 1; i <= length(v); i++) {
                c = substr(v, i, 1)
                if (c == "\\" || c == "\"") out = out "\\"
                out = out c
            }
            return "\"" out "\""
        }
        function put(key, value,   comma) {
            comma = ($0 ~ /,$/) ? "," : ""
            match($0, /^[ \t]*/)
            print substr($0, 1, RLENGTH) "\"" key "\": " value comma
        }
        /^[ \t]*"cpu": [{]$/ && ENVIRON["XMRIG_CPUS"] != "" {
            print
            match($0, /^[ \t]*/)
            pad = substr($0, 1, RLENGTH) "  "
            cpus = ENVIRON["XMRIG_CPUS"]
            n = split(substr(cpus, 2, length(cpus) - 2), cpu, /, /)
            pairs = ""
            for (i = 1; i <= n; i++) pairs = pairs (i > 1 ? ", " : "") "[8, " cpu[i] "]"
            split("argon2 cn cn-heavy cn-lite cn-pico cn/2 cn/gpu cn/upx2 flex panthera rx rx/wow", algo, " ")
            for (i = 1; i in algo; i++) print pad "\"" algo[i] "\": " cpus ","
            print pad "\"ghostrider\": [" pairs "],"
            next
        }
        /^[ \t]*"max-threads-hint": [0-9]*,$/ { put("max-threads-hint", ENVIRON["XMRIG_HINT"]); next }
        /^[ \t]*"donate-level": [0-9]*,$/ { put("donate-level", ENVIRON["XMRIG_DONATE"]); next }
        /^[ \t]*"log-file": null,$/ { put("log-file", str(ENVIRON["XMRIG_LOG"])); next }
        /^[ \t]*"url": "[^"]*",$/ { put("url", str(ENVIRON["XMRIG_URL"])); next }
        /^[ \t]*"user": "[^"]*",$/ { put("user", str(ENVIRON["XMRIG_USER"])); next }
        /^[ \t]*"pass": "[^"]*",$/ { put("pass", str(ENVIRON["XMRIG_PASS"])); next }
        /^[ \t]*"pause-on-battery": [a-z]*,?$/ { put("pause-on-battery", ENVIRON["XMRIG_BATTERY"]); next }
        /^[ \t]*"pause-on-active": [a-z]*,?$/ { put("pause-on-active", ENVIRON["XMRIG_ACTIVE"]); next }
        { print }
    ' "$1" >"$2.tmp" && mv -f "$2.tmp" "$2" && return 0
    rm -f "$2.tmp"
    return 1
}

function generate_config_files() {
    local target_dir="$BASE_DIR/$REPO_NAME"
    local source_config_dir="$target_dir/templates"
    local dest_config_dir="$target_dir/configs"
    local name kept listed every="" unlisted=false missing=()

    info "Generating miner configuration files..."

    # Create destination config directory if it doesn't exist
    mkdir -p "$dest_config_dir"

    # On arm64, the list naming every usable CPU, when --threads leaves one of them out.
    pick_cpu_list
    if is_arm64; then
        every=$(arm_cpu_list "$(ranked_cpus | awk 'END { print NR }')")
        [ "$CPU_LIST" != "$every" ] || every=""
    fi

    # A config from an earlier run holds the user's wallet, pool and worker name, and maybe their
    # own edits: it is kept as it is. The miner reads the one at the clone root, which is a link to
    # configs/ unless an edit replaced it with a file (GNU sed -i on the link does): that file is
    # the config the line names.
    for name in config.json config_background.json; do
        kept=""
        if [ -f "$dest_config_dir/$name" ]; then
            kept="$dest_config_dir/$name"
        else
            missing+=("$name")
        fi
        if [ -e "$target_dir/$name" ] && [ ! -L "$target_dir/$name" ]; then
            kept="$target_dir/$name"
        fi
        if [ -n "$kept" ]; then
            info "Keeping $kept. To regenerate it, run 'make clean-configs', then the installer again."
            # The "rx" list sits on a line of its own, whether this installer wrote it or the miner
            # saved it. The miner saves one naming every CPU; a list this installer wrote for a
            # share below 100 names fewer. A config with no list runs on every CPU too.
            if [ -n "$every" ]; then
                listed=$(awk '/^[ \t]*"rx": \[/ { n = gsub(/-?[0-9]+/, "") } END { print n + 0 }' "$kept")
                if [ "$listed" -eq 0 ] || [ "$listed" -ge "$(awk -F, '{ print NF }' <<<"$every")" ]; then
                    unlisted=true
                fi
            fi
        fi
    done
    if [ "$unlisted" = true ]; then
        warning "--threads does not apply to the kept configs: they let the miner run on every CPU. To apply it, run 'make clean-configs', the installer again, then 'make service-setup' and 'make restart'."
    fi

    # Set log file path
    local log_file="$target_dir/logs/xmrig.log"
    mkdir -p "$target_dir/logs"

    if [ ${#missing[@]} -gt 0 ]; then
        # Define full pool URL with port if needed
        local full_pool_url="$POOL_URL"
        # The computed port is a plain TCP one: only a bare or stratum+tcp:// URL gets it.
        if [[ "$POOL_URL" == *"moneroocean"* ]] && [[ "${POOL_URL#stratum+tcp://}" != *":"* ]]; then
            full_pool_url="${POOL_URL}:${PORT}"
            info "Using MoneroOcean with optimized port: $full_pool_url"
        fi

        function generate_random_worker_name() {
            local adjectives=("swift" "rapid" "blazing" "cosmic" "digital" "quantum" "stellar" "epic" "crypto" "atomic" "shadow" "hyper" "mega" "ultra" "power" "turbo")
            local nouns=("miner" "rig" "node" "worker" "machine" "server" "core" "unit" "beast" "hawk" "titan" "phoenix" "dragon" "ninja" "master" "runner")

            # Get random elements from arrays
            local rand_adj=${adjectives[$((RANDOM % ${#adjectives[@]}))]}
            local rand_noun=${nouns[$((RANDOM % ${#nouns[@]}))]}

            # Add a random number (1-999) at the end
            local rand_num=$((RANDOM % 999 + 1))

            # Combine elements to form the worker name
            echo "${rand_adj}_${rand_noun}_${rand_num}"
        }
        # Create worker pass
        local worker_name="$PASS"
        if [ "$worker_name" = "$DEFAULT_PASS" ]; then
            worker_name=$(generate_random_worker_name)
            info "Generated random worker name: $worker_name"
        fi

        # Each missing file from its template, with the same settings
        for name in "${missing[@]}"; do
            if ! write_miner_config "$source_config_dir/$name.template" "$dest_config_dir/$name" "$log_file" "$full_pool_url" "$worker_name"; then
                error "Failed to write $dest_config_dir/$name."
                return 1
            fi
        done
        success "Configuration files generated successfully."
    fi

    # Link each config at the clone root, where the miner reads it, unless something is already
    # there: an earlier run's link, or a config edited in its place.
    for name in config.json config_background.json; do
        if [ ! -e "$target_dir/$name" ] && [ ! -L "$target_dir/$name" ]; then
            ln -s "$dest_config_dir/$name" "$target_dir/$name"
        fi
    done

    info "Main config: $dest_config_dir/config.json"
    info "Background config: $dest_config_dir/config_background.json"
    info "Log file: $log_file"
    return 0
}

# The service step is done when the unit or the plist is where the service setup puts it, or when
# --only-manual asks for no service.
function service_is_set_up() {
    [ "$SERVICE_MODE" == "manual" ] && return 0
    case "$OS_TYPE" in
    linux) [ -f "$SYSTEMD_UNIT" ] ;;
    macos) [ -f "$LAUNCHD_PLIST" ] ;;
    *) return 1 ;;
    esac
}

function setup_service() {
    local target_dir="$BASE_DIR/$REPO_NAME"

    # Skip service setup if --only-manual was specified
    if [ "$SERVICE_MODE" == "manual" ]; then
        info "Skipping service setup as requested (--only-manual)."
        return 0
    fi

    cd "$target_dir" || {
        error "Failed to navigate to $target_dir."
        return 1
    }

    info "Setting up mining service..."

    case "$OS_TYPE" in
    linux)
        if [ -f "/etc/debian_version" ] || [[ "$OS_NAME" =~ Debian|Ubuntu|Mint ]]; then
            # Check if systemd is available
            if ! command -v systemctl >/dev/null 2>&1; then
                warning "systemd not found, skipping service setup."
                return 0
            fi

            if ! ./scripts/setup_service_debian.sh; then
                error "Failed to set up systemd service."
                return 1
            fi

            if [ "$SERVICE_MODE" == "autostart" ]; then
                info "Starting miner service immediately as requested (--autostart)."
                if ! sudo systemctl start xmrig; then
                    error "Failed to start mining service."
                    return 1
                fi
                success "Mining service started successfully."
            fi
        else
            warning "Service setup not implemented for this Linux distribution."
        fi
        ;;
    macos)
        if ! ./scripts/setup_service_macos.sh; then
            error "Failed to set up macOS service."
            return 1
        fi

        if [ "$SERVICE_MODE" == "autostart" ]; then
            info "Starting miner service immediately as requested (--autostart)."
            if ! launchctl start com.moneroocean.xmrig; then
                error "Failed to start mining service."
                return 1
            fi
            success "Mining service started successfully."
        fi
        ;;
    *)
        warning "Service setup not implemented for this OS: $OS_TYPE"
        ;;
    esac

    if [ "$SERVICE_MODE" != "autostart" ]; then
        info "Mining service has been set up but not started."
        info "Use 'make start' to start mining."
    fi

    return 0
}

function set_script_permissions() {
    local target_dir="$BASE_DIR/$REPO_NAME"

    info "Setting proper permissions for script files..."

    # Navigate to the project directory
    cd "$target_dir" || {
        error "Failed to navigate to $target_dir."
        return 1
    }

    # Set execution permissions for all scripts
    chmod +x scripts/*.sh

    success "Script permissions set successfully."
    return 0
}

# ===== Release binary =====
# --prebuilt installs the arm64 binary CI builds for Debian 13 instead of compiling it, and runs as
# root, so what root installs and runs is a file only root can change. A host the binary cannot run
# on, and a tree another user can change, are refused first: before anything is cloned, fetched or
# installed, with the command that gets the user a working install.
# The host: Linux arm64, root, and a glibc the binary links against.
function check_prebuilt_host() {
    local os arch glibc major minor min_major min_minor
    os=$(uname -s 2>/dev/null) || os=""
    arch=$(uname -m 2>/dev/null) || arch=""
    if [ "$os" != "Linux" ] || [ "$arch" != "aarch64" ]; then
        error "--prebuilt installs the Linux arm64 release binary, and this host is ${os:-unknown} ${arch:-unknown}. Run the installer without --prebuilt to compile the miner here."
        return 1
    fi
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        error "--prebuilt installs a binary only root can change, so it runs as root. Run the installer again with sudo, or without --prebuilt to compile the miner as you."
        return 1
    fi
    glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || glibc=""
    glibc=${glibc#glibc }
    if ! [[ "$glibc" =~ ^([0-9]+)\.([0-9]+) ]]; then
        error "--prebuilt needs glibc $RELEASE_MIN_GLIBC or newer, and this host's glibc version cannot be read. Run the installer without --prebuilt to compile the miner here."
        return 1
    fi
    major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}
    min_major=${RELEASE_MIN_GLIBC%%.*} min_minor=${RELEASE_MIN_GLIBC#*.}
    if (( 10#$major < 10#$min_major || (10#$major == 10#$min_major && 10#$minor < 10#$min_minor) )); then
        error "--prebuilt needs glibc $RELEASE_MIN_GLIBC or newer, and this host has $major.$minor (Debian 12 has 2.36). Run the installer without --prebuilt to compile the miner here, or use --docker."
        return 1
    fi
}

# Prints the release tag the clone is checked out at, or nothing. A final tag beats a pre-release
# and versions sort as numbers; a tag that is not vX.Y.Z (with an optional suffix) is no tag, as it
# ends up in a download URL.
function release_tag_of() {
    local tags tag
    tags=$(git -C "$1" tag --points-at HEAD --list 'v*' 2>/dev/null) || return 0
    tags=$(printf '%s\n' "$tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$') || return 0
    tag=$(printf '%s\n' "$tags" | grep -v -e - | sort -V | tail -n 1) || tag=""
    [ -n "$tag" ] || tag=$(printf '%s\n' "$tags" | sort -V | tail -n 1)
    printf '%s' "$tag"
}

# Root owns the directory and every one above it, and no one else can write them: the same walk
# from / that validate_directory makes. The user who ran sudo does not count (SUDO_USER is
# emptied), as the binary runs as root and that user is not root.
function root_only_tree() {
    local dir check rest
    if ! dir=$(CDPATH= cd -- "$1" 2>/dev/null && pwd -P); then
        error "$1 cannot be read, so --prebuilt does not install a binary there."
        return 1
    fi
    check=
    while :; do
        if ! SUDO_USER="" trusted_by_root "${check:-/}"; then
            if [ "${check:-/}" = "$dir" ] && [ "$dir" = "$BASE_DIR/$REPO_NAME" ]; then
                error "$dir can be changed by a user other than root, so --prebuilt does not install a binary under it. Move $dir away and run the installer again, or pass -d with a directory only root can change."
            else
                error "${check:-/} can be changed by a user other than root, so --prebuilt does not install a binary under it. Pass -d with a directory only root can change, such as /opt."
            fi
            return 1
        fi
        [ "${check:-/}" = "$dir" ] && break
        rest=${dir#"$check"/}
        check=$check/${rest%%/*}
    done
}

# The sha256 of a file, or nothing.
function binary_sha256() {
    local line
    line=$(sha256sum -- "$1" 2>/dev/null) || return 0
    printf '%s' "${line%% *}"
}

# Where the miner binary in a clone comes from, as one line of text.
function binary_origin() {
    local record hash
    if [ ! -f "$1/xmrig.release" ]; then
        printf '%s' "compiled on this host"
        return 0
    fi
    record=$(head -n 1 "$1/xmrig.release" 2>/dev/null) || record=""
    hash=$(binary_sha256 "$1/xmrig")
    if [ -n "$hash" ] && [ "${record#* }" = "$hash" ]; then
        printf '%s' "release ${record%% *}, sha256 $hash"
    else
        printf '%s' "unknown (sha256 ${hash:-unreadable} matches no release record)"
    fi
}

# The donate level a config holds, or unknown.
function donate_level_of() {
    local level
    level=$(grep -o 'donate-level.: *[0-9]*' "$1" 2>/dev/null | grep -o '[0-9]*$' | head -n 1)
    printf '%s' "${level:-unknown}"
}

# Installs the release binary at the clone's tag once its sha256 matches the release's SHA256SUMS.
# Every step is checked, and a refusal leaves the binary, the record and the clone as they were. It
# runs in a subshell, so its trap removes the staging folder however it ends.
function install_release_binary() (
    local dir=$1 tag stage file url lines want got out line lib
    root_only_tree "$dir" || exit 1
    tag=$(release_tag_of "$dir")
    if [ -z "$tag" ]; then
        error "$dir is checked out at no release tag, so --prebuilt has no release to install."
        exit 1
    fi
    if ! stage=$(mktemp -d "$dir/.xmrig-release.XXXXXX"); then
        error "Failed to create a folder for the download in $dir."
        exit 1
    fi
    trap 'rm -rf -- "$stage"' EXIT
    trap 'exit 1' HUP INT TERM
    for file in "$RELEASE_ASSET" SHA256SUMS; do
        url="$RELEASE_URL/$tag/$file"
        if ! curl -fsSL --proto '=https' --proto-redir '=https' -o "$stage/$file" "$RELEASE_URL/$tag/$file" || [ ! -s "$stage/$file" ]; then
            error "Failed to download $url, so the miner is left as it was. Check your network and that release $tag has this file, then run the installer again."
            exit 1
        fi
    done
    lines=$(grep -E "[ *]$RELEASE_ASSET\$" "$stage/SHA256SUMS") || lines=""
    if ! [[ $lines =~ ^([0-9a-f]{64})\ [\ *]$RELEASE_ASSET$ ]]; then
        error "SHA256SUMS of release $tag does not hold exactly one sum for $RELEASE_ASSET, so the miner is left as it was."
        exit 1
    fi
    want=${BASH_REMATCH[1]}
    got=$(binary_sha256 "$stage/$RELEASE_ASSET")
    if [ "$got" != "$want" ]; then
        error "$RELEASE_ASSET of release $tag has sha256 ${got:-unreadable} where SHA256SUMS says $want, so the miner is left as it was. Run the installer again; if it says the same, report it at $PROJECT_URL/issues."
        exit 1
    fi
    info "Installing ${RELEASE_PACKAGES[*]} for the release binary..."
    if ! apt-get update || ! apt-get install -y --no-upgrade "${RELEASE_PACKAGES[@]}"; then
        error "Failed to install ${RELEASE_PACKAGES[*]} through apt, so the miner is left as it was. Fix apt, then run the installer again."
        exit 1
    fi
    if ! out=$(ldd "$stage/$RELEASE_ASSET" 2>&1); then
        error "The release binary cannot be loaded on this host, so the miner is left as it was. Run the installer without --prebuilt to compile the miner here."
        exit 1
    fi
    line=$(printf '%s\n' "$out" | grep -m 1 '=> not found') || line=""
    if [ -n "$line" ]; then
        lib=${line#"${line%%[![:space:]]*}"}
        lib=${lib%% *}
        error "The release binary needs $lib, which this host lacks after apt installed ${RELEASE_PACKAGES[*]}, so the miner is left as it was. Run the installer without --prebuilt to compile the miner here."
        exit 1
    fi
    if [ -d "$dir/xmrig" ]; then
        error "$dir/xmrig is a folder, so the release binary cannot replace it. Remove it, then run the installer again."
        exit 1
    fi
    chmod 0755 "$stage/$RELEASE_ASSET" && printf '%s %s\n' "$tag" "$want" > "$stage/xmrig.release" && chmod 0644 "$stage/xmrig.release" || {
        error "Failed to install the release binary at $dir/xmrig."
        exit 1
    }
    if ! mv -f -- "$stage/$RELEASE_ASSET" "$dir/xmrig"; then
        error "Failed to install the release binary at $dir/xmrig."
        exit 1
    fi
    if ! mv -f -- "$stage/xmrig.release" "$dir/xmrig.release"; then
        error "Installed the release binary at $dir/xmrig, but failed to write $dir/xmrig.release, so its origin shows as unknown. Run the installer again."
        exit 1
    fi
    success "Installed XMRig of release $tag (sha256 $want) at $dir/xmrig."
)

# A first install, or a re-run that carries out what an earlier run left undone (a failed build, a
# service never set up), each missing step in the order a first install takes them.
function install_project() {
    local cloned=false built=false

    info "Checking project installation status..."

    if check_repo_exists; then
        # A clone made there since the check in main is checked before it is used.
        check_base_clone "$BASE_DIR/$REPO_NAME" || return 1
        cloned=true
        check_if_built && built=true
    fi

    if [ "$cloned" = true ] && [ "$built" = true ] && configs_exist && service_is_set_up; then
        success "Project is already installed. No further action required."
        return 0
    fi

    if [ "$cloned" = false ]; then
        info "Project not found. Cloning and building..."
        if ! clone_repository; then
            error "Failed to clone repository."
            return 1
        fi
    fi

    set_script_permissions

    if ! generate_config_files; then
        error "Failed to generate configuration files."
        return 1
    fi

    if [ "$built" = false ]; then
        if [ "$PREBUILT" = yes ]; then
            install_release_binary "$BASE_DIR/$REPO_NAME" || exit 1
        elif ! build_project; then
            error "Failed to build project."
            return 1
        fi
    fi

    # A unit or plist found beside a fresh clone was left by an earlier install and runs that
    # clone's binary and config: a fresh clone sets up its own.
    if [ "$cloned" = false ] || ! service_is_set_up; then
        if ! setup_service; then
            warning "Service setup failed, but installation will continue."
            # Don't return error here to allow installation to complete
        fi
    fi

    success "Project installed successfully."
    return 0
}

function clean_build() {
    local target_dir="$BASE_DIR/$REPO_NAME"

    info "Cleaning build artifacts..."

    # Navigate to the project directory
    cd "$target_dir" || {
        error "Failed to navigate to $target_dir."
        return 1
    }

    # Remove build directory and symbolic link
    if ! make clean; then
        error "Failed to clean build artifacts."
        return 1
    fi

    success "Build artifacts cleaned successfully."
    return 0
}

function show_resource_recommendations() {
    if [ "$MAX_THREADS" -gt "75" ]; then
        hint "Resource usage recommendations:"
        hint "If you are using a shared VPS, it is recommended to avoid running the miner at 100% CPU usage, as this may result in your account being suspended or banned."

        if [ "$CPU_THREADS" -lt "4" ]; then
            hint "For your system with $CPU_THREADS CPU threads, consider limiting CPU usage to avoid overheating:"
            hint "- Install cpulimit: sudo apt-get update && sudo apt-get install -y cpulimit"
            hint "- Limit XMRig: sudo cpulimit -e xmrig -l $((75 * CPU_THREADS)) -b"
        else
            hint "You've selected ${MAX_THREADS}% CPU usage which may cause system slowdowns."
            hint "Consider reducing to 75% if you notice performance issues."
            hint "This will help balance mining performance and system responsiveness."
        fi
    fi

    return 0
}

function display_next_steps() {
    hint "Miner binary: $(binary_origin "$BASE_DIR/$REPO_NAME"); donate level $(donate_level_of "$BASE_DIR/$REPO_NAME/config_background.json")"
    hint "Next steps:"
    hint "Move to the project directory: ${BLUE}cd $BASE_DIR/$REPO_NAME${RESET}"

    if [ "$SERVICE_MODE" == "manual" ]; then
        hint "You can try the miner using: ${BLUE}make test${RESET}"
        hint "To set up a background service later: ${BLUE}make service-setup${RESET}"
    elif [ "$SERVICE_MODE" == "autostart" ]; then
        hint "Mining service is already running."
        hint "To stop the service: ${BLUE}make stop${RESET}"
        hint "To check service status: ${BLUE}make status${RESET}"
    else # setup but not started
        hint "You can try the miner using: ${BLUE}make test${RESET}"
        hint "To start the mining service: ${BLUE}make start${RESET}"
        hint "To stop the service: ${BLUE}make stop${RESET}"
        hint "To check service status: ${BLUE}make status${RESET}"
    fi

    hint "For more information and commands, visit ${LINK}${UNDERLINE}${PROJECT_URL}${RESET}."
}

function warning_before_install() {
    warning "This script will install MoneroOcean miner in $BASE_DIR/$REPO_NAME."
    warning "It will also create a systemd service for automatic startup."
    if [ "$NON_INTERACTIVE" = "true" ]; then
        info "Skipping pre-install delay (non-interactive mode)."
        return 0
    fi
    warning "The installation will start in $HIGH_DELAY seconds."
    warning "If you want to cancel the installation, press Ctrl+C now."
    sleep $HIGH_DELAY
    info "Continuing with installation..."
    sleep $LOW_DELAY
}

# ===== Main script execution =====
function main() {
    # git lays out the clone, and make the build, under this umask: with group write on (umask 002),
    # a shared group (macOS's staff) could add a hook or rewrite .git/config while git still runs,
    # and git would run it as you. A stricter umask stays.
    umask g-w,o-w

    load_toolbox

    display_header

    parse_arguments "$@"

    check_if_running_as_root

    if ! validate_wallet "$WALLET"; then
        exit 1
    fi
    sleep $LOW_DELAY

    BASE_DIR=$(validate_directory "$BASE_DIR")
    if [ $? -ne 0 ]; then
        exit 1
    fi
    # A re-run builds and runs what it finds there: only a clone that passes this check.
    if ! check_base_clone "$BASE_DIR/$REPO_NAME"; then
        exit 1
    fi
    sleep $LOW_DELAY

    detect_os

    if ! check_dependencies; then
        exit 1
    fi
    sleep $LOW_DELAY

    if ! calculate_hashrate_and_port; then
        exit 1
    fi
    sleep $LOW_DELAY

    show_resource_recommendations
    sleep $LOW_DELAY

    warning_before_install

    if ! install_project; then
        error "Failed to install project."
        exit 1
    fi
    sleep $LOW_DELAY

    success "MoneroOcean miner setup complete!"
    sleep $LOW_DELAY

    display_next_steps
}

main "$@"
