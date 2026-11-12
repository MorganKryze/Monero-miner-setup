#!/bin/bash
# The board readout `make status` prints on Linux, after the service's status: the hottest thermal
# zone, each cpufreq policy's frequency, and on a board with a profile the throttling (Pi 5: the
# firmware's flags; RK3588: a mining policy below the maximum its mode set), the last hashrate the
# miner logged, the power the board can honestly give, and the cost per day from the user's own
# wall-meter figure (WALL_WATTS, KWH_PRICE). It only reads; a reading it cannot get is printed as
# unavailable, and it always exits 0.

# ===== Constants =====
THERMAL_DIR="/sys/class/thermal"
CPUFREQ_DIR="/sys/devices/system/cpu/cpufreq"
DT_COMPATIBLE="/proc/device-tree/compatible"
TUNING_CONF="/etc/xmrig-host-tuning.conf"
LOG_ROOT="/var/log/xmrig"
PROFILE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board_profiles.conf"

# ===== Board profiles =====
# The functions down to profile_ok are scripts/install.sh's, byte for byte (tests/board-status.sh).

# Prints the device tree's compatible strings that are well formed, one per line.
function board_compatible() {
    local word
    [ -r "$DT_COMPATIBLE" ] || return 0
    while read -r word; do
        [[ "$word" =~ ^[a-z0-9,._-]{1,64}$ ]] && echo "$word"
    done < <(tr '\0' '\n' <"$DT_COMPATIBLE")
    return 0
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

# ===== Readout =====

# Prints the first line of a kernel file when it is a whole number, else nothing.
function read_number() {
    local value=""
    { read -r value <"$1"; } 2>/dev/null
    [[ "$value" =~ ^-?[0-9]{1,12}$ ]] && printf '%s' "$value"
}

# The hottest thermal zone by name (milli-degrees in its temp file).
function temperature_line() {
    local zone type temp best="" best_type="" n=0
    for zone in "$THERMAL_DIR"/thermal_zone*; do
        temp=$(read_number "$zone/temp") || continue
        type=$(tr -cd 'A-Za-z0-9_-' <"$zone/type" 2>/dev/null | cut -c1-32)
        n=$((n + 1))
        if [ -z "$best" ] || [ "$temp" -gt "$best" ]; then
            best=$temp
            best_type=${type:-unnamed}
        fi
    done
    if [ -z "$best" ]; then
        echo "  Temperature: unavailable."
        return 0
    fi
    awk -v t="$best" -v z="$best_type" -v n="$n" 'BEGIN { printf "  Temperature: %s at %.1f °C, the hottest of %d zones.\n", z, t / 1000, n }'
}

# Each cpufreq policy's current and maximum frequency, in MHz.
function policy_lines() {
    local p cur max maxs any=no
    for p in "$CPUFREQ_DIR"/policy*; do
        cur=$(read_number "$p/scaling_cur_freq") || cur=""
        max=$(read_number "$p/scaling_max_freq") || max=""
        [ -n "$cur$max" ] || continue
        any=yes
        maxs="unavailable"
        [ -z "$max" ] || maxs="$((max / 1000)) MHz"
        echo "  CPU ${p##*/}: ${cur:+$((cur / 1000)) MHz now, }at most $maxs."
    done
    [ "$any" = yes ] || echo "  CPU frequencies: unavailable."
}

# Pi 5: the firmware's throttle flags in words, now and since boot.
function throttle_lines() {
    local raw value
    raw=$(vcgencmd get_throttled 2>/dev/null) || raw=""
    if ! [[ "$raw" =~ ^throttled=0x([0-9a-fA-F]{1,8})$ ]]; then
        echo "  Throttling: unavailable (vcgencmd get_throttled gave no answer)."
        return 0
    fi
    value=$((16#${BASH_REMATCH[1]}))
    echo "  Throttling now: $(flag_words $((value & 15)))."
    echo "  Throttling since boot: $(flag_words $(((value >> 16) & 15)))."
}

function flag_words() {
    local words=()
    (($1 & 1)) && words+=("under-voltage")
    (($1 & 2)) && words+=("frequency capped")
    (($1 & 4)) && words+=("throttled")
    (($1 & 8)) && words+=("soft temperature limit")
    if [ "${#words[@]}" -eq 0 ]; then echo none; else (IFS=,; echo "${words[*]}" | sed 's/,/, /g'); fi
}

# RK3588 has no throttle flag: a tuned mining policy running below the maximum its mode set.
function held_lines() {
    local line name want cur
    [ -r "$TUNING_CONF" ] || return 0
    while read -r line; do
        [[ "$line" =~ ^(policy[0-9]{1,4})=performance\ ([0-9]{1,9}|max)$ ]] || continue
        name=${BASH_REMATCH[1]}
        want=${BASH_REMATCH[2]}
        [ "$want" != max ] || want=$(read_number "$CPUFREQ_DIR/$name/cpuinfo_max_freq") || continue
        cur=$(read_number "$CPUFREQ_DIR/$name/scaling_cur_freq") || continue
        if [ "$cur" -lt "$want" ]; then
            echo "  CPU $name runs at $((cur / 1000)) MHz, below the $((want / 1000)) MHz its mode set: likely held by heat."
        fi
    done <"$TUNING_CONF"
}

# The last speed line of the service's log, read as the service's account (as make status reads it).
function hashrate_value() {
    local user
    user=$(systemctl show -p User --value xmrig.service 2>/dev/null) || user=""
    [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
    sudo -u "$user" tail -n 500 -- "$LOG_ROOT/$user/xmrig.log" 2>/dev/null |
        awk '{ for (i = 1; i < NF; i++) if ($i == "10s/60s/15m") { v = ($(i + 2) ~ /^[0-9.]+$/) ? $(i + 2) : $(i + 1) } }
             END { if (v ~ /^[0-9]+([.][0-9]+)?$/) print v; else exit 1 }'
}

# Pi 5: the sum of each PMIC rail's volts times amps; never the board's or the wall's power.
function pmic_watts() {
    vcgencmd pmic_read_adc 2>/dev/null | awk '
        match($0, /^[ \t]*[A-Z0-9_]+_[AV] (current|volt)\([0-9]+\)=[0-9.]+[AV]$/) {
            split($1, a, "_"); kind = a[length(a)]
            rail = substr($1, 1, length($1) - 2)
            v = $2; sub(/^[^=]*=/, "", v); sub(/[AV]$/, "", v)
            if (kind == "A") amps[rail] = v; else volts[rail] = v
        }
        END { for (r in amps) if (r in volts) { w += amps[r] * volts[r]; n++ }; if (!n) exit 1; printf "%.1f\n", w }'
}

function is_positive() {
    [[ "$1" =~ ^[0-9]{1,6}([.][0-9]{1,6})?$ ]] || return 1
    awk -v x="$1" 'BEGIN { exit !(x > 0) }'
}

function main() {
    local profile hashrate watts
    [ "$(uname -s)" = Linux ] || return 0
    echo ""
    echo "Board readout:"
    temperature_line
    policy_lines
    profile=$(find_profile)
    if [ -z "$profile" ] || ! profile_ok "$profile"; then
        return 0
    fi
    case $profile in
    bcm2712) throttle_lines ;;
    *) held_lines ;;
    esac
    if hashrate=$(hashrate_value); then
        echo "  Hashrate: $hashrate H/s, the last the miner logged."
    else
        echo "  Hashrate: unavailable (no speed line in the service log yet)."
    fi
    if [ "$profile" = bcm2712 ]; then
        if watts=$(pmic_watts); then
            echo "  Power: PMIC ≈ $watts W (excludes USB, fan, 5 V)."
        else
            echo "  Power: PMIC unavailable (vcgencmd pmic_read_adc gave no answer)."
        fi
    else
        echo "  Power: no power sensor: use a wall meter."
    fi
    if is_positive "${WALL_WATTS:-}" && is_positive "${KWH_PRICE:-}"; then
        awk -v w="$WALL_WATTS" -v p="$KWH_PRICE" -v h="${hashrate:-}" 'BEGIN {
            printf "  Cost: %.2f per day at %s W from the wall and %s per kWh", w * 24 / 1000 * p, w, p
            if (h != "") printf "; %.1f H/s per wall watt", h / w
            print "."
        }'
    else
        echo "  Cost: give your wall meter's watts and your price per kWh, such as: make status WALL_WATTS=9.5 KWH_PRICE=0.25"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main
    exit 0
fi
