#!/bin/bash

# ===== Constants =====
VERSION="0.0.1"
LOW_DELAY=0.5
HIGH_DELAY=1.5
TOOLBOX_URL="https://raw.githubusercontent.com/MorganKryze/bash-toolbox/main/src/prefix.sh"
PROJECT_URL="https://github.com/MorganKryze/Monero-miner-setup"
REPO_NAME="Monero-miner-setup"
REPO_URL="https://github.com/MorganKryze/Monero-miner-setup.git"
DEFAULT_MAX_THREADS=75
DEFAULT_DONATE_LEVEL=0
DEFAULT_POOL_URL="gulf.moneroocean.stream"
DEFAULT_PASS="x"
DEFAULT_PAUSE_ON_ACTIVE=false
DEFAULT_PAUSE_ON_BATTERY=false

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

function load_toolbox() {
    if ! source <(curl -s --connect-timeout 10 "$TOOLBOX_URL"); then
        echo "Error: Failed to load bash toolbox. Check your internet connection."
        echo "Using fallback basic functions..."

        GREEN='\033[0;32m'
        BLUE='\033[0;34m'
        RED='\033[0;31m'
        ORANGE='\033[0;33m'
        RESET='\033[0m'
        LINK='\033[0;36m'
        UNDERLINE='\033[4m'

        function txt() { echo -e "${RESET}$1"; }
        function info() { txt "[${BLUE}  INFO   ${RESET}] ${BLUE}$1${RESET}"; }
        function warning() { txt "[${ORANGE} WARNING ${RESET}] ${ORANGE}$1${RESET}" >&2; }
        function error() {
            txt "[${RED}  ERROR  ${RESET}] ${RED}$1${RESET}" >&2
            return 1
        }
        function success() { txt "[${GREEN} SUCCESS ${RESET}] ${GREEN}$1${RESET}"; }
    fi
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
    echo "  -d, --dir DIR         Base directory for installation (defaults to HOME)"
    echo "  -e, --email EMAIL     Email address for notifications"
    echo
    echo "Mining Configuration Options:"
    echo "  -t, --threads PERCENT Max CPU threads hint (1-100, default: $DEFAULT_MAX_THREADS)"
    echo "  --donate PERCENT      Donation level (0-5, default: $DEFAULT_DONATE_LEVEL)"
    echo "  -p, --pool URL        Mining pool URL (default: $DEFAULT_POOL_URL)"
    echo "  --pass STRING         Password for mining pool (default: hostname)"
    echo "  --pause-active        Pause mining when computer is in active use (default: off)"
    echo "  --pause-battery       Pause mining when computer is on battery (default: off)"
    echo "  -h, --help            Display this help message"
    echo
    echo "Examples:"
    echo "  $0 -w 4ABD..."
    echo "  $0 -w 4ABD... -d /opt/monero -t 50 --donate 1"
    echo "  $0 -w 4ABD... -p rx.unmineable.com:3333"
    echo
    echo "Note: For MoneroOcean pool, the script will automatically calculate optimal port."
}

function check_if_running_as_root() {
    if [ "$(id -u)" == "0" ]; then
        warning "Generally it is not advised to run this script under root."
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

    local wallet_base=$(echo "$wallet" | cut -f1 -d".")
    if [ ${#wallet_base} != 106 -a ${#wallet_base} != 95 ]; then
        error "Wrong wallet base address length (should be 106 or 95): ${#wallet_base}."
        return 1
    fi

    info "Using wallet address: $wallet."
    info "Wallet base address length is correct: ${#wallet_base}."
    return 0
}

function validate_directory() {
    local dir="$1"

    if [ -z "$dir" ]; then
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

    if [ ! -w "$dir" ]; then
        error "No write permission to directory: $dir."
        return 1
    fi

    # Only the directory path will be captured now
    printf "%s" "$dir"
    return 0
}

function validate_email() {
    local email="$1"

    if [ -n "$email" ]; then
        if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            error "Invalid email address format: $email."
            return 1
        fi
        info "Using email address: $email."
    else
        info "No email address provided, proceeding without it."
    fi

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

    # Check for FreeBSD
    elif command -v uname &>/dev/null && uname -s | grep -q "FreeBSD"; then
        OS_TYPE="freebsd"
        OS_NAME="FreeBSD"
        OS_VERSION=$(uname -r)
        info "Detected FreeBSD: $OS_VERSION."

    # Generic UNIX-like OS detection
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
    EMAIL=""
    MAX_THREADS=$DEFAULT_MAX_THREADS
    DONATE_LEVEL=$DEFAULT_DONATE_LEVEL
    POOL_URL=$DEFAULT_POOL_URL
    PASS=$DEFAULT_PASS
    PAUSE_ON_ACTIVE=$DEFAULT_PAUSE_ON_ACTIVE
    PAUSE_ON_BATTERY=$DEFAULT_PAUSE_ON_BATTERY

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
        -e | --email)
            EMAIL="$2"
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
            shift 2
            ;;
        --pass)
            PASS="$2"
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

    # Export variables
    export WALLET
    export BASE_DIR
    export EMAIL
    export MAX_THREADS
    export DONATE_LEVEL
    export POOL_URL
    export PASS
    export PAUSE_ON_ACTIVE
    export PAUSE_ON_BATTERY
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
        warning "This script works better with 'lscpu' utility."
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

    # Check for evidence of a successful build
    if [ -d "$target_dir/build" ] || [ -f "$target_dir/xmrig/build/xmrig" ]; then
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

    info "Updating Git submodules to ensure all dependencies are up-to-date..."
    if ! git submodule update --remote; then
        error "Failed to update submodules."
        return 1
    fi
    success "Submodules are up-to-date."

    # Select the appropriate build command based on OS
    case "$OS_TYPE" in
    linux)
        if [ -f "/etc/debian_version" ] || [[ "$OS_NAME" =~ Debian|Ubuntu|Mint ]]; then
            info "Detected Debian-based system, running 'make install-debian'..."
            if ! make install-debian; then
                error "Failed to build project using 'make install-debian'."
                return 1
            fi
        elif [[ "$OS_NAME" =~ Fedora|CentOS|Red\ Hat ]]; then
            info "Detected Red Hat-based system, running 'make install-fedora'..."
            if ! make install-fedora; then
                error "Failed to build project using 'make install-fedora'."
                return 1
            fi
        else
            error "Unsupported Linux distribution: $OS_NAME."
            error "Please build the project manually following instructions in the README."
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
    freebsd)
        info "Detected FreeBSD, running 'make install-freebsd'..."
        if ! make install-freebsd; then
            error "Failed to build project using 'make install-freebsd'."
            return 1
        fi
        ;;
    *)
        error "Unsupported operating system: $OS_TYPE."
        error "Please build the project manually following instructions in the README."
        return 1
        ;;
    esac

    success "Project built successfully."
    return 0
}

function install_project() {
    info "Checking project installation status..."

    if check_repo_exists; then
        if check_if_built; then
            success "Project is already installed. No further action required."
            return 0
        else
            info "Project is cloned but not built. Proceeding with build..."
            if ! build_project; then
                error "Failed to build project."
                return 1
            fi
        fi
    else
        info "Project not found. Cloning and building..."
        if ! clone_repository; then
            error "Failed to clone repository."
            return 1
        fi

        if ! build_project; then
            error "Failed to build project."
            return 1
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
    info "Resource usage recommendations:"

    if [ "$CPU_THREADS" -lt "4" ]; then
        info "For your system with $CPU_THREADS CPU threads, consider limiting CPU usage to avoid overheating:"
        info "- Install cpulimit: sudo apt-get update && sudo apt-get install -y cpulimit"
        info "- Limit XMRig: sudo cpulimit -e xmrig -l $((75 * CPU_THREADS)) -b"
    else
        info "For your system with $CPU_THREADS CPU threads, consider setting max-threads-hint in config:"
        info "- Edit config.json: sed -i 's/\"max-threads-hint\": *[^,]*,/\"max-threads-hint\": 75,/' \$BASE_DIR/moneroocean/config.json"
        info "- Edit background config: sed -i 's/\"max-threads-hint\": *[^,]*,/\"max-threads-hint\": 75,/' \$BASE_DIR/moneroocean/config_background.json"
    fi

    return 0
}

function display_next_steps() {
    cd "$BASE_DIR/$REPO_NAME" || {
        error "Failed to navigate to project directory."
        exit 1
    }
    hint "You can now try the miner using: ${BLUE}make test${RESET}"
    hint "Then start the service using: ${BLUE}make start${RESET}"
    hint "To stop the service, use: ${BLUE}make stop${RESET}"
    hint "For more information and commands, visit ${LINK}${UNDERLINE}${PROJECT_URL}${RESET}."
}

# ===== Main script execution =====
function main() {
    load_toolbox

    display_header

    check_if_running_as_root

    parse_arguments "$@"

    if ! validate_wallet "$WALLET"; then
        exit 1
    fi
    sleep $LOW_DELAY

    BASE_DIR=$(validate_directory "$BASE_DIR")
    if [ $? -ne 0 ]; then
        exit 1
    fi
    sleep $LOW_DELAY

    if ! validate_email "$EMAIL"; then
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

    if ! install_project; then
        error "Failed to install project."
        exit 1
    fi
    sleep $LOW_DELAY

    show_resource_recommendations

    success "MoneroOcean miner setup complete!"
    sleep $LOW_DELAY

    display_next_steps
}

# ===== Script entry point =====
main "$@"
