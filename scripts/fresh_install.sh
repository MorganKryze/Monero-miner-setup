#!/bin/bash

# Gather the bash functions from the toolbox
source <(curl -s https://raw.githubusercontent.com/MorganKryze/bash-toolbox/main/src/prefix.sh)

# Variables
VERSION=0.0.1
DELAY=0.5

# Display Title
txt ' ___      ___     ______    _____  ___    _______   _______     ______        ___      ___   __    _____  ___    _______   _______  '
txt '|"  \    /"  |   /    " \  (\"   \|"  \  /"     "| /"      \   /    " \      |"  \    /"  | |" \  (\"   \|"  \  /"     "| /"      \ '
txt ' \   \  //   |  // ____  \ |.\\\   \    |(: ______)|:        | // ____  \      \   \  //   | ||  | |.\\\   \    |(: ______)|:        |'
txt ' /\\\  \/.    | /  /    ) :)|: \.   \\\  | \/    |  |_____/   )/  /    ) :)     /\\\  \/.    | |:  | |: \.   \\\  | \/    |  |_____/   )'
txt '|: \.        |(: (____/ // |.  \    \. | // ___)_  //      /(: (____/ //     |: \.        | |.  | |.  \    \. | // ___)_  //      / '
txt '|.  \    /:  | \        /  |    \    \ |(:      "||:  __   \ \        /      |.  \    /:  | /\  |\|    \    \ |(:      "||:  __   \ '
txt '|___|\__/|___|  \"_____/    \___|\____\) \_______)|__|  \___) \"_____/       |___|\__/|___|(__\_|_)\___|\____\) \_______)|__|  \___)'

# Displai intro script
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

# Alert the use of root
if [ "$(id -u)" == "0" ]; then
    warning "Generally it is not advised to run this script under root"
fi
