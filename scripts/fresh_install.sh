#!/bin/bash

# ===== Gather the bash functions from the toolbox =====
source <(curl -s https://raw.githubusercontent.com/MorganKryze/bash-toolbox/main/src/prefix.sh)

# ===== Variables =====
VERSION=0.0.1
DELAY=0.5
WALLET=$1
BASE_DIR=$2 # Default to $HOME if not provided
EMAIL=$3    # Optional

# ===== Display Title =====
txt ' ___      ___     ______    _____  ___    _______   _______     ______        ___      ___   __    _____  ___    _______   _______  '
txt '|"  \    /"  |   /    " \  (\"   \|"  \  /"     "| /"      \   /    " \      |"  \    /"  | |" \  (\"   \|"  \  /"     "| /"      \ '
txt ' \   \  //   |  // ____  \ |.\\\   \    |(: ______)|:        | // ____  \      \   \  //   | ||  | |.\\\   \    |(: ______)|:        |'
txt ' /\\\  \/.    | /  /    ) :)|: \.   \\\  | \/    |  |_____/   )/  /    ) :)     /\\\  \/.    | |:  | |: \.   \\\  | \/    |  |_____/   )'
txt '|: \.        |(: (____/ // |.  \    \. | // ___)_  //      /(: (____/ //     |: \.        | |.  | |.  \    \. | // ___)_  //      / '
txt '|.  \    /:  | \        /  |    \    \ |(:      "||:  __   \ \        /      |.  \    /:  | /\  |\|    \    \ |(:      "||:  __   \ '
txt '|___|\__/|___|  \"_____/    \___|\____\) \_______)|__|  \___) \"_____/       |___|\__/|___|(__\_|_)\___|\____\) \_______)|__|  \___)'

# ===== Display intro script =====
sleep $DELAY
txt
txt "Open-source Monero miner setup script v${VERSION}"
sleep $DELAY
txt "The Project is NEITHER endorsed by Monero NOR MoneroOcean team, use at your own risk."
sleep $DELAY
txt "Licensed under the MIT License, Yann M. Vidamment © 2025."
sleep $DELAY
txt "Visit ${LINK}${UNDERLINE}https://github.com/MorganKryze/Monero-miner-setup${RESET} for more information."
sleep $DELAY
txt
txt "=========================================================================================="
txt
sleep $DELAY

# ===== Alert the use of root =====
if [ "$(id -u)" == "0" ]; then
    warning "Generally it is not advised to run this script under root"
fi

# ===== Check if the wallet is provided and valid =====
if [ -z "$WALLET" ]; then
    error "No wallet address provided. Please provide your Monero wallet address as the first argument."
    exit 1
fi
info "Using wallet address: $WALLET"

WALLET_BASE=$(echo $WALLET | cut -f1 -d".")
if [ ${#WALLET_BASE} != 106 -a ${#WALLET_BASE} != 95 ]; then
    error "Wrong wallet base address length (should be 106 or 95): ${#WALLET_BASE}"
    exit 1
fi
info "Wallet base address length is correct: ${#WALLET_BASE}"

# ===== Check if the base directory is provided and valid =====
if [ -z "$BASE_DIR" ]; then
    if [ -z $HOME ]; then
        error "Please define HOME environment variable to your home directory"
        exit 1
    fi
    if [ ! -d $HOME ]; then
        error "Please make sure HOME directory $HOME exists or set it yourself using this command:"
        error '  export HOME=<dir>'
        exit 1
    fi
    BASE_DIR="$HOME"
    info "No base directory provided, using default: $BASE_DIR"
else
    if [ ! -d "$BASE_DIR" ]; then
        error "Base directory does not exist: $BASE_DIR"
        exit 1
    fi
    info "Using base directory: $BASE_DIR"
fi

# ===== Check if the email is provided and valid =====
if [ -n "$EMAIL" ]; then
    if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        error "Invalid email address format: $EMAIL"
        exit 1
    fi
    info "Using email address: $EMAIL"
else
    info "No email address provided, proceeding without it."
fi
