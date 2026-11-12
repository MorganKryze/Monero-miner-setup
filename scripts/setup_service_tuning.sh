#!/bin/bash
# Host tuning for a board set up with a mode (install.sh --mode): the systemd setup
# (setup_service_debian.sh) sources this file to stage, install and enable it, and
# `make service-disable` runs it with `remove`. What runs at boot is a root-owned copy of
# scripts/host_tuning.sh reading a root-owned values file: nothing in the clone is read at boot.
# The values are worked out here, at setup, from the board profile and the kernel's cpufreq
# policies: each policy holding a CPU the mode mines on gets the performance governor (in eco,
# capped at the profile's eco-cap), each other one powersave; on a kernel whose default huge page is
# 2 MB, with memory for RandomX's fast mode and a service config in fast mode, 1280 huge pages.

# ===== Constants =====
TUNING_BIN="/usr/local/sbin/xmrig-host-tuning"
TUNING_CONF="/etc/xmrig-host-tuning.conf"
TUNING_UNIT="/etc/systemd/system/xmrig-host-tuning.service"
TUNING_CPUFREQ_DIR="/sys/devices/system/cpu/cpufreq"
DT_COMPATIBLE="/proc/device-tree/compatible"
MEMINFO="/proc/meminfo"
PROFILE_FILE="$BASE_DIR/scripts/board_profiles.conf"
RX_FLOOR_MIB=2560
TUNING_HUGEPAGES=1280

# ===== Board profiles =====
# The functions down to config_rx_mode are scripts/install.sh's, byte for byte
# (tests/host-tuning-setup.sh).

# Prints the device tree's compatible strings that are well formed, one per line.
function board_compatible() {
    local word
    [ -r "$DT_COMPATIBLE" ] || return 0
    while read -r word; do
        [[ "$word" =~ ^[a-z0-9,._-]{1,64}$ ]] && echo "$word"
    done < <(tr '\0' '\n' <"$DT_COMPATIBLE")
    return 0
}

# Prints the value of <key> in <profile>'s first line of PROFILE_FILE; exit 1 when absent.
function profile_value() {
    local line
    [ -r "$PROFILE_FILE" ] || return 1
    while read -r line || [ -n "$line" ]; do
        if [[ "$line" == "$1.$2="* ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done <"$PROFILE_FILE"
    return 1
}

# Prints the first profile whose compatible words include one of the board's, compared as fixed
# strings; nothing when none does.
function find_profile() {
    local line name word board words
    board=$(board_compatible)
    [ -n "$board" ] && [ -r "$PROFILE_FILE" ] || return 0
    while read -r line || [ -n "$line" ]; do
        [[ "$line" == *.compatible=* ]] || continue
        name=${line%%.*}
        [[ "$name" =~ ^[a-z0-9]{1,16}$ ]] || continue
        read -ra words <<<"${line#*=}"
        for word in "${words[@]}"; do
            if [[ "$word" =~ ^[a-z0-9,._-]{1,64}$ ]] && [[ $'\n'"$board"$'\n' == *$'\n'"$word"$'\n'* ]]; then
                echo "$name"
                return 0
            fi
        done
    done <"$PROFILE_FILE"
    return 0
}

# Prints the CPU numbers of a kernel-form cpulist ("0,1,4-7"), ascending, one per line; exit 1
# when the list is malformed or a range runs backwards.
function expand_cpus() {
    local part cpu out=""
    [[ "$1" =~ ^[0-9]{1,4}(-[0-9]{1,4})?(,[0-9]{1,4}(-[0-9]{1,4})?)*$ ]] || return 1
    for part in ${1//,/ }; do
        [ "$((10#${part%-*}))" -le "$((10#${part#*-}))" ] || return 1
    done
    for part in ${1//,/ }; do
        for ((cpu = 10#${part%-*}; cpu <= 10#${part#*-}; cpu++)); do
            out+="$cpu"$'\n'
        done
    done
    printf '%s' "$out" | sort -n -u
}

# Exit 0 when every value of <profile> passes its check: compatible strings, max and eco CPU
# lists, layouts as CPU lists, eco-cap as policyN=kHz, measured as printable text.
function profile_ok() {
    local line key value word words seen=""
    [ -r "$PROFILE_FILE" ] || return 1
    while read -r line || [ -n "$line" ]; do
        [[ "$line" == "$1."* ]] || continue
        key=${line#*.}
        key=${key%%=*}
        value=${line#*=}
        seen+=" $key"
        case "$key" in
        compatible)
            read -ra words <<<"$value"
            [ "${#words[@]}" -ge 1 ] || return 1
            for word in "${words[@]}"; do [[ "$word" =~ ^[a-z0-9,._-]{1,64}$ ]] || return 1; done
            ;;
        max | eco) expand_cpus "$value" >/dev/null || return 1 ;;
        layouts)
            read -ra words <<<"$value"
            for word in "${words[@]}"; do expand_cpus "$word" >/dev/null || return 1; done
            ;;
        eco-cap)
            read -ra words <<<"$value"
            for word in "${words[@]}"; do [[ "$word" =~ ^policy[0-9]{1,4}=[0-9]{1,9}$ ]] || return 1; done
            ;;
        measured) [ "${#value}" -le 1024 ] && [[ "$value" =~ ^[[:print:]]*$ ]] || return 1 ;;
        *) return 1 ;;
        esac
    done <"$PROFILE_FILE"
    [[ "$seen " == *" compatible "* && "$seen " == *" max "* && "$seen " == *" eco "* ]]
}

# Prints the installed memory in MiB, or nothing when it cannot be read.
function total_mem_mib() {
    awk '/^MemTotal:/ && $2 ~ /^[0-9]+$/ { print int($2 / 1024) }' "$MEMINFO" 2>/dev/null
    return 0
}

# Prints the RandomX mode a config sets, from the "mode" line of its "randomx" block (another
# object's "mode" is not it). Prints nothing when the config sets none. No awk interval: mawk.
function config_rx_mode() {
    awk '
        /^[ \t]*"randomx": [{]$/ { inrx = 1; next }
        inrx && /^[ \t]*[}],?$/ { inrx = 0 }
        inrx && /^[ \t]*"mode": "[^"]*",?$/ {
            v = $0
            sub(/^[ \t]*"mode": "/, "", v)
            sub(/".*$/, "", v)
            print v
            exit
        }' "$1" 2>/dev/null
}

# ===== Tuning =====

# Reads a file of the clone as the user running the setup, or as the service account when that is
# root: root itself would follow a link planted in the clone to a file it alone can read.
function read_clone() {
    if [ "$(id -u)" = 0 ]; then
        sudo -u "$ACCOUNT" cat -- "$1"
    else
        cat -- "$1"
    fi
}

# Prints the mode the service config was written for (<clone>/configs/board-mode, which the
# installer writes with --mode), or nothing.
function tuning_mode() {
    local mode=""
    [ -f "$BASE_DIR/configs/board-mode" ] || return 0
    mode=$(read_clone "$BASE_DIR/configs/board-mode" 2>/dev/null | head -n 1)
    [[ "$mode" =~ ^(max|eco)$ ]] && echo "$mode"
    return 0
}

# Prints the values file for <mode>, with <seed config> the service config: mode, one line per
# cpufreq policy, the huge pages. Exit 1 with one line when the board has no valid profile or the
# kernel no cpufreq policy.
function tuning_values() {
    local mode="$1" seed="$2" profile cpus caps cap policy related cpu mining mem size
    profile=$(find_profile)
    if [ -z "$profile" ] || ! profile_ok "$profile"; then
        echo "ERROR: The service config was written for --mode $mode, and this board has no valid profile in $PROFILE_FILE. Run the installer again without --mode, or update the clone: git -C $BASE_DIR pull"
        return 1
    fi
    cpus=$(expand_cpus "$(profile_value "$profile" "$mode")") || cpus=""
    caps=""
    [ "$mode" != eco ] || caps=$(profile_value "$profile" eco-cap) || caps=""
    echo "mode=$mode"
    for policy in "$TUNING_CPUFREQ_DIR"/policy*; do
        [ -d "$policy" ] || continue
        policy=${policy##*/}
        [[ "$policy" =~ ^policy[0-9]{1,4}$ ]] || continue
        related=$(cat "$TUNING_CPUFREQ_DIR/$policy/related_cpus" 2>/dev/null) || related=""
        mining=no
        for cpu in $related; do
            [[ "$cpu" =~ ^[0-9]{1,4}$ ]] && [[ $'\n'"$cpus"$'\n' == *$'\n'"$cpu"$'\n'* ]] && mining=yes
        done
        if [ "$mining" = no ]; then
            echo "$policy=powersave"
        elif [ "$mode" = max ]; then
            echo "$policy=performance max"
        else
            cap=""
            for cpu in $caps; do [ "${cpu%%=*}" != "$policy" ] || cap=${cpu#*=}; done
            echo "$policy=performance${cap:+ $cap}"
        fi
    done
    mem=$(total_mem_mib)
    size=$(awk '/^Hugepagesize:/ && $3 == "kB" { print $2; exit }' "$MEMINFO" 2>/dev/null)
    if [ "$size" = 2048 ] && [[ "$mem" =~ ^[0-9]{1,9}$ ]] && [ "$mem" -ge "$RX_FLOOR_MIB" ] &&
        [ "$(config_rx_mode "$seed")" != light ]; then
        echo "hugepages=$TUNING_HUGEPAGES"
    fi
}

# Prints one line per host change a values file makes, for the setup's closing lines.
function tuning_lines() {
    local line name value related
    while read -r line; do
        name=${line%%=*}
        value=${line#*=}
        case $name in
        mode) echo "Host tuning for --mode $value, applied by xmrig-host-tuning.service at each boot before the miner:" ;;
        hugepages) echo "  Huge pages: $value of 2 MB reserved at each boot." ;;
        policy*)
            related=$(tr -cd '0-9 ' <"$TUNING_CPUFREQ_DIR/$name/related_cpus" 2>/dev/null)
            related=${related% }
            case $value in
            powersave) echo "  $name (CPUs $related): powersave governor, no mining there." ;;
            'performance max') echo "  $name (CPUs $related): performance governor, at its hardware maximum." ;;
            performance) echo "  $name (CPUs $related): performance governor." ;;
            *) echo "  $name (CPUs $related): performance governor, at most $((10#${value#performance } / 1000)) MHz." ;;
            esac
            ;;
        esac
    done
    echo "  The miner runs at normal priority (no Nice) and restarts 15 s after any exit."
    echo "  Files: $TUNING_UNIT, $TUNING_BIN, $TUNING_CONF; 'make service-disable' removes them and gives the CPU settings back."
}

# Makes the staged miner unit a dedicated miner's: no Nice, restarted after any exit, the tuning
# started first. Exit 1 when the unit does not hold the lines it changes.
function tune_unit() {
    local out
    grep -qx 'Nice=10' "$1" && grep -qx 'Restart=on-failure' "$1" && grep -qx 'After=network.target' "$1" || return 1
    out=$(awk '
        $0 == "Nice=10" { next }
        $0 == "Restart=on-failure" { print "Restart=always"; next }
        { print }
        $0 == "After=network.target" { print "Wants=xmrig-host-tuning.service" }' "$1") || return 1
    printf '%s\n' "$out" >"$1"
}

# Stages the values file, the boot script and the tuning unit in files mktemp creates for this
# user, and tunes the staged miner unit. Sets TUNING_STAGED (removed by the setup's exit trap) and
# TUNING_LINES. Exit 1 with one line on any failure, nothing installed.
function stage_tuning() {
    local mode="$1" unit="$2" seed="$3" values file
    values=$(tuning_values "$mode" "$seed") || { echo "$values"; return 1; }
    for file in values bin unit; do
        file=$(mktemp "${TMPDIR:-/tmp}/xmrig-tuning-$file.XXXXXXXXXX") || {
            echo "ERROR: Failed to create a temporary file."
            return 1
        }
        TUNING_STAGED+=("$file")
    done
    if ! printf '%s\n' "# Written by the miner's service setup; make service-disable removes it." "$values" >"${TUNING_STAGED[0]}" ||
        ! read_clone "$SCRIPT_DIR/host_tuning.sh" >"${TUNING_STAGED[1]}" ||
        ! read_clone "$BASE_DIR/templates/xmrig-host-tuning.service.template" >"${TUNING_STAGED[2]}" ||
        ! [ -s "${TUNING_STAGED[1]}" ] || ! [ -s "${TUNING_STAGED[2]}" ]; then
        echo "ERROR: Failed to stage the host tuning from $BASE_DIR."
        return 1
    fi
    if ! tune_unit "$unit"; then
        echo "ERROR: Failed to make the unit a dedicated miner's: it lacks Nice=10, Restart=on-failure or After=network.target."
        return 1
    fi
    TUNING_LINES=$(printf '%s\n' "$values" | tuning_lines)
}

# Installs the staged files as root, before the miner unit.
function install_tuning() {
    if ! sudo install -o root -g root -m 644 "${TUNING_STAGED[0]}" "$TUNING_CONF" ||
        ! sudo install -o root -g root -m 755 "${TUNING_STAGED[1]}" "$TUNING_BIN" ||
        ! sudo install -o root -g root -m 644 "${TUNING_STAGED[2]}" "$TUNING_UNIT"; then
        echo "ERROR: Failed to install the host tuning."
        return 1
    fi
}

# After daemon-reload: enabled for each boot; restarted when active, so a new mode applies now.
function enable_tuning() {
    if ! sudo systemctl enable xmrig-host-tuning.service || ! sudo systemctl try-restart xmrig-host-tuning.service; then
        echo "ERROR: Failed to enable xmrig-host-tuning.service."
        return 1
    fi
}

# Exit 0 when systemd knows the tuning unit (an earlier setup with a mode installed it).
function tuning_installed() {
    [ -n "$(systemctl show -p FragmentPath --value xmrig-host-tuning.service 2>/dev/null)" ]
}

# Stops the tuning, which gives the CPU settings back, then removes its unit, script and values;
# a partial install whose unit systemd does not know has nothing to stop. The huge pages are not
# written back: they are freed at the next boot (a live write would also drop a reservation the
# user made). A failed stop keeps everything, so a retry can finish.
function remove_tuning() {
    if tuning_installed; then
        if ! sudo systemctl stop xmrig-host-tuning.service || ! sudo systemctl disable xmrig-host-tuning.service; then
            echo "ERROR: Failed to stop xmrig-host-tuning.service, so the host tuning is kept. Fix the error, then run 'make service-disable' again."
            return 1
        fi
    fi
    if ! sudo rm -f -- "$TUNING_UNIT" "$TUNING_BIN" "$TUNING_CONF" || ! sudo systemctl daemon-reload; then
        echo "ERROR: Failed to remove $TUNING_UNIT, $TUNING_BIN or $TUNING_CONF."
        return 1
    fi
    echo "Host tuning removed: CPU settings given back; the huge pages are freed at the next boot."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        remove) remove_tuning ;;
        *)
            echo "Usage: $0 remove" >&2
            exit 2
            ;;
    esac
fi
