#!/bin/bash

# ===== Constants =====
VERSION="0.0.1"
LOW_DELAY=0.5
HIGH_DELAY=1.5
TOOLBOX_URL="https://raw.githubusercontent.com/MorganKryze/bash-toolbox/main/src/prefix.sh"
PROJECT_URL="https://github.com/MorganKryze/Monero-miner-setup"
XMRIG_ARCHIVE_URL="https://raw.githubusercontent.com/MoneroOcean/xmrig_setup/master/xmrig.tar.gz"

# ===== Error handling =====
set -o errexit  # Exit on error
set -o pipefail # Exit if any command in a pipe fails
trap cleanup EXIT

# ===== Function definitions =====
function cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "Script exited with error code $exit_code"
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
        function error() { txt "[${RED}  ERROR  ${RESET}] ${RED}$1${RESET}" >&2; return 1; }
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
    txt "Open-source Monero miner setup script v${VERSION}"
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

function check_if_running_as_root() {
    if [ "$(id -u)" == "0" ]; then
        warning "Generally it is not advised to run this script under root"
        read -p "Do you want to continue anyway? (y/N): " continue_as_root
        if [[ ! "$continue_as_root" =~ ^[Yy]$ ]]; then
            info "Exiting as requested"
            exit 0
        fi
    fi
}

function validate_wallet() {
    local wallet="$1"

    if [ -z "$wallet" ]; then
        error "No wallet address provided. Please provide your Monero wallet address as the first argument."
        return 1
    fi

    local wallet_base=$(echo "$wallet" | cut -f1 -d".")
    if [ ${#wallet_base} != 106 -a ${#wallet_base} != 95 ]; then
        error "Wrong wallet base address length (should be 106 or 95): ${#wallet_base}"
        return 1
    fi

    info "Using wallet address: $wallet"
    info "Wallet base address length is correct: ${#wallet_base}"
    return 0
}

function validate_directory() {
    local dir="$1"

    if [ -z "$dir" ]; then
        if [ -z "$HOME" ]; then
            error "Please define HOME environment variable to your home directory"
            return 1
        fi

        if [ ! -d "$HOME" ]; then
            error "Please make sure HOME directory $HOME exists or set it yourself using this command:"
            error '  export HOME=<dir>'
            return 1
        fi

        dir="$HOME"
        info "No base directory provided, using default: $dir"
    else
        if [ ! -d "$dir" ]; then
            error "Base directory does not exist: $dir"
            return 1
        fi
        info "Using base directory: $dir"
    fi

    # Check write permissions
    if [ ! -w "$dir" ]; then
        error "No write permission to directory: $dir"
        return 1
    fi

    echo "$dir"
    return 0
}

function validate_email() {
    local email="$1"

    if [ -n "$email" ]; then
        if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            error "Invalid email address format: $email"
            return 1
        fi
        info "Using email address: $email"
    else
        info "No email address provided, proceeding without it."
    fi

    return 0
}

function usage() {
    echo "Usage: $0 WALLET_ADDRESS [BASE_DIR] [EMAIL]"
    echo
    echo "Arguments:"
    echo "  WALLET_ADDRESS  Your Monero wallet address (required)"
    echo "  BASE_DIR        Base directory for installation (optional, defaults to HOME)"
    echo "  EMAIL           Email address for notifications (optional)"
    echo
    echo "Example:"
    echo "  $0 4ABD..."
    echo "  $0 4ABD... /opt/monero"
    echo "  $0 4ABD... /opt/monero user@example.com"
}

# ===== MoneroOcean Miner Setup Functions =====

function check_dependencies() {
    info "Checking required dependencies..."
    
    if ! command -v curl &>/dev/null; then
        error "This script requires 'curl' utility to work correctly"
        return 1
    fi
    
    if ! command -v lscpu &>/dev/null; then
        warning "This script works better with 'lscpu' utility"
    fi
    
    return 0
}

function calculate_hashrate_and_port() {
    info "Calculating estimated hashrate and mining port..."
    
    # Calculate threads and estimated hashrate
    if command -v nproc &>/dev/null; then
        CPU_THREADS=$(nproc)
    elif command -v sysctl &>/dev/null; then
        CPU_THREADS=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
    else
        CPU_THREADS=1
    fi
    EXP_MONERO_HASHRATE=$(( CPU_THREADS * 700 / 1000))
    
    if [ -z "$EXP_MONERO_HASHRATE" ]; then
        error "Can't compute projected Monero CN hashrate"
        return 1
    fi
    
    # Power2 function to calculate appropriate port
    function power2() {
        local input="$1"
        if ! command -v bc &>/dev/null; then
            if   [ "$input" -gt "8192" ]; then
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
    PORT=$(( EXP_MONERO_HASHRATE * 30 ))
    PORT=$(( PORT == 0 ? 1 : PORT ))
    PORT=$(power2 $PORT)
    PORT=$(( 10000 + PORT ))
    
    if [ -z "$PORT" ]; then
        error "Can't compute port"
        return 1
    fi
    
    if [ "$PORT" -lt "10001" -o "$PORT" -gt "18192" ]; then
        error "Wrong computed port value: $PORT"
        return 1
    fi
    
    info "This host has $CPU_THREADS CPU threads, so projected Monero hashrate is around $EXP_MONERO_HASHRATE KH/s"
    info "Using port: $PORT"
    
    # Export variables for use in other functions
    export CPU_THREADS
    export EXP_MONERO_HASHRATE
    export PORT
    
    return 0
}

function show_resource_recommendations() {
    info "Resource usage recommendations:"
    
    if [ "$CPU_THREADS" -lt "4" ]; then
        info "For your system with $CPU_THREADS CPU threads, consider limiting CPU usage to avoid overheating:"
        info "- Install cpulimit: sudo apt-get update && sudo apt-get install -y cpulimit"
        info "- Limit XMRig: sudo cpulimit -e xmrig -l $((75*CPU_THREADS)) -b"
    else
        info "For your system with $CPU_THREADS CPU threads, consider setting max-threads-hint in config:"
        info "- Edit config.json: sed -i 's/\"max-threads-hint\": *[^,]*,/\"max-threads-hint\": 75,/' \$BASE_DIR/moneroocean/config.json"
        info "- Edit background config: sed -i 's/\"max-threads-hint\": *[^,]*,/\"max-threads-hint\": 75,/' \$BASE_DIR/moneroocean/config_background.json"
    fi
    
    return 0
}

# ===== Main script execution =====
function main() {
    load_toolbox

    display_header

    check_if_running_as_root

    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
        usage
        exit 0
    fi

    if ! validate_wallet "$WALLET"; then
        usage
        exit 1
    fi

    BASE_DIR=$(validate_directory "$BASE_DIR")
    if [ $? -ne 0 ]; then
        exit 1
    fi

    if ! validate_email "$EMAIL"; then
        exit 1
    fi

    if ! check_dependencies; then
        exit 1
    fi

    if ! calculate_hashrate_and_port; then
        exit 1
    fi

    show_resource_recommendations

    success "MoneroOcean miner setup complete!"
}

# ===== Script entry point =====
WALLET=$1
BASE_DIR=$2
EMAIL=$3

main "$@"