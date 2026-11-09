#!/bin/bash
# Benches each CPU layout of the board profile offline, one XMRig run per layout (make bench-layouts).
# MODE=max (default) tries the profile's layouts, MODE=eco its eco list; BENCH sets the size.
# Runs from a throwaway folder: the clone's configs and logs are never touched. No pool, no submit.

OS=$(uname -s)
HOST_ARCH=$(uname -m 2>/dev/null) || HOST_ARCH=""
CPU_SYS_DIR="/sys/devices/system/cpu"
PROC_STATUS="/proc/self/status"
DT_COMPATIBLE=/proc/device-tree/compatible
DT_MODEL=/proc/device-tree/model
MEMINFO=/proc/meminfo
CPUFREQ_DIR=/sys/devices/system/cpu/cpufreq
RX_FLOOR_MIB=2560
SCRIPT_DIR=$(CDPATH= cd -- "${BASH_SOURCE[0]%/*}" && pwd)
PROFILE_FILE="$SCRIPT_DIR/board_profiles.conf"
XMRIG="${SCRIPT_DIR%/*}/xmrig"
SIZE_RE="^(250K|500K|[1-9]M|10M)\$"
TMP=""
PID=""

function info() { echo "[  INFO   ] $*"; }
function err() { echo "[  ERROR  ] $*" >&2; }

# ----- Board profiles -----
# These ten functions are the installer's, byte for byte (tests/bench-layouts.sh).

function board_compatible() {
    local word
    [ -r "$DT_COMPATIBLE" ] || return 0
    while read -r word; do
        [[ "$word" =~ ^[a-z0-9,._-]{1,64}$ ]] && echo "$word"
    done < <(tr '\0' '\n' <"$DT_COMPATIBLE")
    return 0
}

function board_model() {
    local model
    [ -r "$DT_MODEL" ] || return 0
    model=$(tr -cd '[:print:]' <"$DT_MODEL" 2>/dev/null | tr -d '\\' | cut -c1-64)
    [ -z "$model" ] || echo "$model"
    return 0
}

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

function profile_status() {
    local list model
    IFS=';' read -ra list <<<"$(profile_value "$1" measured)"
    for model in "${list[@]}"; do
        if [ -n "$2" ] && [ "$model" = "$2" ]; then
            echo "measured on $2"
            return 0
        fi
    done
    echo "untested"
}

function total_mem_mib() {
    awk '/^MemTotal:/ && $2 ~ /^[0-9]+$/ { print int($2 / 1024) }' "$MEMINFO" 2>/dev/null
    return 0
}

function is_arm64() {
    [ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ]
}

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

# ----- Bench -----

# Kills a running XMRig, then removes the throwaway folder.
function cleanup() {
    if [ -n "$PID" ]; then
        kill "$PID" 2>/dev/null
        wait "$PID" 2>/dev/null
        PID=""
    fi
    [ -z "$TMP" ] || rm -rf -- "$TMP"
    TMP=""
}

# Prints the CPU lists to bench, one per line: the profile's, else every usable CPU and, where the
# capacities differ, the highest-capacity CPUs alone.
function layouts_for() {
    local profile word cpu cap top=0 all="" best="" line caps=()
    profile=$(find_profile)
    if [ -n "$profile" ] && profile_ok "$profile"; then
        if [ "${MODE:-max}" = eco ]; then
            profile_value "$profile" eco
        else
            line=$(profile_value "$profile" layouts)
            [ -n "$line" ] || line=$(profile_value "$profile" max)
            for word in $line; do echo "$word"; done
        fi
        return 0
    fi
    for cpu in $(ranked_cpus | sort -n); do
        cap=$(cat "$CPU_SYS_DIR/cpu$cpu/cpu_capacity" 2>/dev/null) || cap=""
        [[ "$cap" =~ ^[0-9]{1,9}$ ]] || cap=0
        all+=",$cpu"
        caps[10#$cpu]=$((10#$cap))
        [ "$((10#$cap))" -le "$top" ] || top=$((10#$cap))
    done
    echo "${all#,}"
    for cpu in $(ranked_cpus | sort -n); do
        [ "${caps[10#$cpu]}" -eq "$top" ] && best+=",$cpu"
    done
    [ "${best#,}" = "${all#,}" ] || echo "${best#,}"
}

# Benches one layout; prints its result line, exit 1 (one error line) without a result.
function run_layout() {
    local rx log pol cap line h hp out=""
    info "Benching CPUs $1 ($BENCH${LIGHT:+, light mode})..."
    TMP=$(mktemp -d) && [ -d "$TMP" ] || { err "Cannot create a temporary folder."; return 1; }
    rx=$(expand_cpus "$1" | awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $1 }')
    printf '{\n    "autosave": false,\n    "cpu": {\n        "enabled": true,\n        "huge-pages": true,\n        "rx": [%s]\n    }\n}\n' "$rx" >"$TMP/config.json"
    log="$TMP/xmrig.log"
    (cd "$TMP" && exec taskset -c "$1" "$XMRIG" --bench="$BENCH" --no-color --config="$TMP/config.json" -l "$log" ${LIGHT:+--randomx-mode=light} >/dev/null 2>&1) &
    PID=$!
    # XMRig waits for Ctrl+C after a finished bench: stop it once the result is in the log.
    while kill -0 "$PID" 2>/dev/null; do
        grep -q 'benchmark finished in' "$log" 2>/dev/null && break
        sleep 2
    done
    kill "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
    PID=""
    line=$(grep 'benchmark finished in' "$log" 2>/dev/null | tail -n 1)
    if [[ "$line" =~ \(([0-9]+\.[0-9]+)\ h/s\) ]]; then
        h=${BASH_REMATCH[1]}
    else
        err "CPUs $1: no result from XMRig."
        cleanup
        return 1
    fi
    hp=0
    line=$(grep 'huge pages' "$log" 2>/dev/null | head -n 1)
    [[ "$line" =~ huge\ pages\ ([0-9]+)% ]] && hp=${BASH_REMATCH[1]}
    for pol in "$CPUFREQ_DIR"/policy[0-9]*; do
        [ -f "$pol/scaling_max_freq" ] || continue
        cap=$(cat "$pol/scaling_max_freq" 2>/dev/null)
        [[ "$cap" =~ ^[0-9]{1,9}$ ]] && out+=", ${pol##*/} $((10#$cap / 1000)) MHz"
    done
    cleanup
    echo "CPUs $1: $h H/s, huge pages $hp%$out"
}

function main() {
    local layouts layout mem rc=0
    if [ "$OS" != "Linux" ] || ! is_arm64; then
        err "make bench-layouts runs on arm64 Linux only. Use 'make benchmark' here."
        return 1
    fi
    case "${MODE:-max}" in max | eco) ;; *)
        err "MODE must be max or eco (MODE=max|eco)."
        return 1
        ;;
    esac
    BENCH=${BENCH:-250K}
    if ! [[ "$BENCH" =~ $SIZE_RE ]]; then
        err "BENCH=$BENCH is not a size XMRig accepts: 250K, 500K or 1M to 10M."
        return 1
    fi
    command -v taskset >/dev/null || { err "taskset is missing: install util-linux."; return 1; }
    command -v pgrep >/dev/null || { err "pgrep is missing: install procps."; return 1; }
    [ -x "$XMRIG" ] || { err "XMRig is not built at $XMRIG. Run 'make build' first."; return 1; }
    if pgrep -x xmrig >/dev/null; then
        err "A miner is running. Run 'make stop' first."
        return 1
    fi
    LIGHT=""
    mem=$(total_mem_mib)
    if [ -n "$mem" ] && [ "$mem" -lt "$RX_FLOOR_MIB" ]; then
        LIGHT=1
        info "Memory is $mem MiB: the bench runs in light mode under the $RX_FLOOR_MIB MiB floor."
    fi
    trap cleanup EXIT
    trap 'cleanup; exit 130' INT TERM
    layouts=$(layouts_for)
    while read -r layout; do
        [ -n "$layout" ] || continue
        run_layout "$layout" || rc=1
    done <<<"$layouts"
    return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
