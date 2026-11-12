#!/bin/bash
# DietPi's custom script for a board that mines from its first boot. Put your settings between the
# two marker lines below: one `key = value` per line, `#` starts a comment line. They are read as
# data by this script's own parser, never run by bash (the block is a quoted here-document).
: <<'END_OF_MINER_SETTINGS'
# Your Monero wallet address (required).
wallet =
# max mines on every CPU the board profile allows; eco leaves headroom and runs cooler.
mode = eco
# The pool to mine on (default: the installer's, gulf.moneroocean.stream).
# pool = gulf.moneroocean.stream:10128
# The worker name the pool shows (default: the board's host name, such as rpi5-3fa2).
# name = rpi5-3fa2
# Donation level in percent, 0 to 5 (default: the installer's, 0).
# donate = 0
# yes lets a board under 2560 MiB of memory mine in RandomX's slower light mode.
# light = no
# on announces <host name>.local on your network.
# mdns = off
# A public key allowed to log in as root over SSH.
# ssh_key = ssh-ed25519 AAAA... you@laptop
END_OF_MINER_SETTINGS

# DietPi runs this file once, as root, near the end of its first run. It only hands off: it copies
# the settings to a root-only file, itself without the settings to a root-owned command, and
# installs, enables and starts xmrig-first-boot.service, which runs `xmrig-first-boot setup` at
# each boot until the setup is done. Every network step is the setup's.

# ===== Constants =====
# The release this file ships with and its installer's sha256, filled when the release is built.
RELEASE_TAG=""
INSTALLER_SHA256=""
STATE_DIR="/var/lib/xmrig-first-boot"
SETUP_BIN="/usr/local/sbin/xmrig-first-boot"
SETUP_UNIT="/etc/systemd/system/xmrig-first-boot.service"
LEDS_DIR="/sys/class/leds"
NET_DIR="/sys/class/net"
DT_COMPATIBLE="/proc/device-tree/compatible"
MEMINFO="/proc/meminfo"
HOSTNAME_FILE="/etc/hostname"
HOSTS_FILE="/etc/hosts"
ROOT_SSH_DIR="/root/.ssh"
CLONE_DIR="/opt/Monero-miner-setup"
# RandomX's fast mode needs this much memory; scripts/install.sh holds the same floor.
RX_FLOOR_MIB=2560
SETTINGS_START=": <<'END_OF_MINER_SETTINGS'"
SETTINGS_END="END_OF_MINER_SETTINGS"
SETTINGS_REMEDY="Fix it in the settings at the top of Automation_Custom_Script.sh and flash the card again, or edit /var/lib/xmrig-first-boot/settings as root on the board and reboot."
# The boards this setup knows: <SoC profile> <device-tree compatible> <short name> <status LED or ->.
BOARDS="bcm2712 raspberrypi,5-model-b rpi5 ACT
rk3588 xunlong,orangepi-5-plus opi5plus green:indicator-2
rk3588 xunlong,orangepi-5-max opi5max -"
STATUS_LED=""
BLINK_PID=""

function info() {
    printf '[  INFO   ] %s\n' "$*"
}

function warning() {
    printf '[ WARNING ] %s\n' "$*" >&2
}

function error() {
    printf '[  ERROR  ] %s\n' "$*" >&2
}

# Prints the lines between the opening line of the settings block and the first line that is
# exactly its terminator, as bash's here-document reads them. Exit 1, printing nothing, when the
# file has no complete block.
function settings_region() {
    local line inside=0
    local -a lines=()
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$inside" -eq 0 ]; then
            [ "$line" != "$SETTINGS_START" ] || inside=1
        elif [ "$line" = "$SETTINGS_END" ]; then
            [ "${#lines[@]}" -eq 0 ] || printf '%s\n' "${lines[@]}"
            return 0
        else
            lines+=("$line")
        fi
    done <"$1"
    return 1
}

# Prints the file without the settings block's inner lines: the setup's code holds no wallet.
function without_settings() {
    local line inside=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$inside" -eq 1 ] && [ "$line" != "$SETTINGS_END" ]; then
            continue
        fi
        inside=0
        [ "$line" != "$SETTINGS_START" ] || inside=1
        printf '%s\n' "$line"
    done <"$1"
}

function setting_error() {
    error "Setting '$1' $2. $SETTINGS_REMEDY"
}

# Exit 0 when <value> has the form setting <key> takes; else prints the rule it breaks.
function setting_rule() {
    local LC_ALL=C key="$1" value="$2"
    local ssh_re='^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+={0,3}( [A-Za-z0-9@._-]+)?$'
    case "$key" in
        wallet) [[ $value =~ ^[1-9A-HJ-NP-Za-km-z]{1,128}$ ]] || echo "must be 1 to 128 base58 characters" ;;
        mode) [[ $value =~ ^(max|eco)$ ]] || echo "must be max or eco" ;;
        pool) [[ $value =~ ^[A-Za-z0-9.+:/_-]{1,255}$ ]] || echo "must be 1 to 255 letters, digits or . + : / _ - characters" ;;
        name) [[ $value =~ ^[A-Za-z0-9._@:+-]{1,64}$ ]] || echo "must be 1 to 64 letters, digits or . _ - @ : + characters" ;;
        donate) [[ $value =~ ^[0-5]$ ]] || echo "must be a whole number from 0 to 5" ;;
        light) [[ $value =~ ^(yes|no)$ ]] || echo "must be yes or no" ;;
        mdns) [[ $value =~ ^(on|off)$ ]] || echo "must be on or off" ;;
        ssh_key) [[ $value =~ $ssh_re ]] || echo "must be one ssh-ed25519, ecdsa-sha2-nistp256, ecdsa-sha2-nistp384, ecdsa-sha2-nistp521 or ssh-rsa public key, then optionally a comment of letters, digits or @ . _ - characters" ;;
    esac
}

# Reads a settings file (the block's lines) into S_WALLET S_MODE S_POOL S_NAME S_DONATE S_LIGHT
# S_MDNS S_SSH_KEY. Each line is matched as text and its value checked for its key's form; nothing
# is run or expanded. An empty value leaves the key's default. On the first bad line, a key given
# twice or a missing wallet or mode: one error line, exit 1.
function read_settings() {
    local line key value rule n=0 seen=" "
    local key_re='^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=(.*)$'
    S_WALLET="" S_MODE="" S_POOL="" S_NAME="" S_DONATE="" S_LIGHT="no" S_MDNS="off" S_SSH_KEY=""
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        if ! [[ $line =~ $key_re ]]; then
            error "Line $n of the settings is not key = value."
            return 1
        fi
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        case " wallet mode pool name donate light mdns ssh_key " in
            *" $key "*) ;;
            *)
                setting_error "$key" "is not one this script knows: wallet, mode, pool, name, donate, light, mdns, ssh_key"
                return 1
                ;;
        esac
        if [[ $seen == *" $key "* ]]; then
            setting_error "$key" "is given twice"
            return 1
        fi
        seen="$seen$key "
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        if [[ $value =~ ^\"([^\"]*)\"$ || $value =~ ^\'([^\']*)\'$ ]]; then
            value=${BASH_REMATCH[1]}
        elif [[ $value != [\"\']* ]]; then
            # An unquoted value ends before a ` #` comment.
            value=${value%%[[:space:]]#*}
            value=${value%"${value##*[![:space:]]}"}
        fi
        [ -n "$value" ] || continue
        rule=$(setting_rule "$key" "$value")
        if [ -n "$rule" ]; then
            setting_error "$key" "$rule"
            return 1
        fi
        case "$key" in
            wallet) S_WALLET=$value ;;
            mode) S_MODE=$value ;;
            pool) S_POOL=$value ;;
            name) S_NAME=$value ;;
            donate) S_DONATE=$value ;;
            light) S_LIGHT=$value ;;
            mdns) S_MDNS=$value ;;
            ssh_key) S_SSH_KEY=$value ;;
        esac
    done <"$1"
    [ -n "$S_WALLET" ] || { setting_error wallet "is missing"; return 1; }
    [ -n "$S_MODE" ] || { setting_error mode "is missing"; return 1; }
    return 0
}

# Prints the board's status LED from BOARDS, or nothing with one warning when the board has none
# known or the kernel lacks it.
function led_find() {
    local compat soc board short led
    if [ -r "$DT_COMPATIBLE" ]; then
        while IFS= read -r -d '' compat || [ -n "$compat" ]; do
            while read -r soc board short led; do
                [ "$board" = "$compat" ] || continue
                if [ "$led" = - ]; then
                    break 2
                elif [ -d "$LEDS_DIR/$led" ]; then
                    printf '%s\n' "$led"
                else
                    warning "No status LED $led on this board: the setup goes on without LEDs."
                fi
                return 0
            done <<<"$BOARDS"
        done <"$DT_COMPATIBLE"
    fi
    warning "No status LED is known for this board: the setup goes on without LEDs."
}

# Prints the LED's full brightness, 1 when it cannot be read.
function led_max() {
    local max=""
    { read -r max <"$LEDS_DIR/$STATUS_LED/max_brightness"; } 2>/dev/null
    [[ $max =~ ^[0-9]{1,6}$ ]] || max=1
    printf '%s' "$max"
}

# Blinks STATUS_LED from a background loop, half a second on, half off: not every kernel offers
# the timer trigger. led_blink_stop or led_state ends it.
function led_blink_start() {
    [ -n "$STATUS_LED" ] || return 0
    local dir="$LEDS_DIR/$STATUS_LED" max
    max=$(led_max)
    printf 'none\n' >"$dir/trigger"
    (
        while :; do
            printf '%s\n' "$max" >"$dir/brightness"
            sleep 0.5
            printf '0\n' >"$dir/brightness"
            sleep 0.5
        done
    ) </dev/null >/dev/null &
    BLINK_PID=$!
}

function led_blink_stop() {
    [ -n "$BLINK_PID" ] || return 0
    kill "$BLINK_PID" 2>/dev/null
    # The loop ends on the signal, so its status is never 0.
    wait "$BLINK_PID" 2>/dev/null || true
    BLINK_PID=""
}

# Stops the blink and leaves STATUS_LED beating (set up) or steady on (error).
function led_state() {
    led_blink_stop
    [ -n "$STATUS_LED" ] || return 0
    local dir="$LEDS_DIR/$STATUS_LED"
    case "$1" in
        heartbeat) printf 'heartbeat\n' >"$dir/trigger" ;;
        error)
            printf 'none\n' >"$dir/trigger"
            led_max >"$dir/brightness"
            ;;
    esac
}

# Writes stdin to <file> with <mode> through a temp file in its folder, so the file is either the
# old one or the whole new one.
function put_file() {
    local file="$1" mode="$2" tmp
    [ ! -d "$file" ] || return 1
    tmp=$(mktemp "${file%/*}/.${file##*/}.XXXXXX") || return 1
    if cat >"$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$file"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

function unit_text() {
    printf '%s\n' "[Unit]" "Description=Monero miner first-boot setup" "After=network.target" "" \
        "[Service]" "Type=exec" "ExecStart=$SETUP_BIN setup" "" "[Install]" "WantedBy=multi-user.target"
}

# The part DietPi runs: copies and installs the setup, then returns. Nothing here needs the network.
function handoff() {
    local self="${BASH_SOURCE[0]}" step="" settings
    if [ "$(id -u)" != 0 ]; then
        error "The first-boot setup must run as root."
        return 1
    fi
    umask 077
    if ! mkdir -p "$STATE_DIR" || ! chmod 0700 "$STATE_DIR"; then
        step="the state folder"
    elif ! settings=$(settings_region "$self") || ! printf '%s\n' "$settings" | put_file "$STATE_DIR/settings" 0600; then
        step="the settings copy"
    elif ! without_settings "$self" | put_file "$SETUP_BIN" 0755; then
        step="the setup script"
    elif ! unit_text | put_file "$SETUP_UNIT" 0644; then
        step="the unit"
    elif ! systemctl daemon-reload; then
        step="systemctl daemon-reload"
    elif ! systemctl enable xmrig-first-boot.service; then
        step="systemctl enable"
    elif ! systemctl start --no-block xmrig-first-boot.service; then
        step="systemctl start"
    fi
    if [ -n "$step" ]; then
        error "Failed to install the first-boot setup: $step."
        return 1
    fi
    info "The first-boot setup is installed and starts now: the status LED blinks while it runs."
}

# The setup xmrig-first-boot.service runs at each boot until it is done.
function setup() {
    STATUS_LED=$(led_find)
    led_blink_start
    if ! read_settings "$STATE_DIR/settings"; then
        led_state error
        return 1
    fi
    led_blink_stop
}

function main() {
    case "${1:-}" in
        "") handoff ;;
        setup) setup ;;
        *)
            echo "Usage: $0 [setup]" >&2
            return 2
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
    exit $?
fi
