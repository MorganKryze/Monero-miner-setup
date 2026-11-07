#!/bin/bash

# ===== Constants =====
VERSION="0.1.0"
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
# the folder has extended attributes); Linux ends the mode with +.
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
    echo
    echo "Mining Configuration Options:"
    echo "  -t, --threads PERCENT Max CPU threads hint (1-100, default: $DEFAULT_MAX_THREADS)"
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

    # Root goes on to run the clone's scripts: a user who can change the base directory, a clone
    # already there or any directory above them would choose what root runs, as with the
    # installer's own clone above. This holds whatever chose the directory, -d included.
    if [ "$(id -u)" == "0" ] && [ "$(uname -s)" == "Linux" ]; then
        path=$(cd -- "$dir" && pwd -P) || return 1
        # Root acts on the directory it checked, never on a link a user could point elsewhere later.
        if [ "$path" != "$dir" ]; then
            info "Resolved to $path." >&2
            dir=$path
        fi
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

function check_if_built() {
    local target_dir="$BASE_DIR/$REPO_NAME"

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
    local target_dir="$BASE_DIR/$REPO_NAME"

    info "Cloning project repository to $target_dir..."

    if ! git clone --recurse-submodules "$REPO_URL" "$target_dir"; then
        error "Failed to clone repository (with submodules) from $REPO_URL."
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
function configs_exist() {
    local dest_config_dir="$BASE_DIR/$REPO_NAME/configs"
    [ -f "$dest_config_dir/config.json" ] && [ -f "$dest_config_dir/config_background.json" ]
}

# Writes a miner config from its template: each setting the installer fills in becomes one JSON
# value holding exactly what was passed. The values reach awk through its environment, as data;
# no command is built from them. Arguments: template, destination, log file, pool URL, worker name.
# The config is written next to the destination and moved over it only once complete: a failed
# write leaves no partial file that a later run would keep.
function write_miner_config() {
    XMRIG_HINT=$MAX_THREADS XMRIG_DONATE=$DONATE_LEVEL XMRIG_LOG=$3 XMRIG_URL=$4 XMRIG_USER=$WALLET \
        XMRIG_PASS=$5 XMRIG_BATTERY=$PAUSE_ON_BATTERY XMRIG_ACTIVE=$PAUSE_ON_ACTIVE awk '
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
    local name kept missing=()

    info "Generating miner configuration files..."

    # Create destination config directory if it doesn't exist
    mkdir -p "$dest_config_dir"

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
        fi
    done

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

# A first install, or a re-run that carries out what an earlier run left undone (a failed build, a
# service never set up), each missing step in the order a first install takes them.
function install_project() {
    local cloned=false built=false

    info "Checking project installation status..."

    if check_repo_exists; then
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
        if ! build_project; then
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
