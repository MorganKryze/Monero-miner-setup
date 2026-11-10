#!/bin/bash
# Boot-time host tuning for a board set up as a dedicated miner. The service setup copies this file
# to /usr/local/sbin/xmrig-host-tuning, owned by root, and xmrig-host-tuning.service runs it as root
# at each boot, after the OS's own CPU settings and before the miner: `apply` sets each cpufreq
# policy and the huge pages the values file names, `restore` gives each policy it changed the
# governor and maximum it found. It reads only the root-owned values file and the kernel's files,
# checks the form of every value before writing it, and never stops the miner from starting: a
# policy it cannot set is left as found with one line in the journal.

# ===== Constants =====
TUNING_CONF="/etc/xmrig-host-tuning.conf"
RECORD="/run/xmrig-host-tuning/found"
CPUFREQ_DIR="/sys/devices/system/cpu/cpufreq"
MEMINFO="/proc/meminfo"
NR_HUGEPAGES="/proc/sys/vm/nr_hugepages"

function say() {
    echo "xmrig-host-tuning: $*"
}

# Prints the first line of a kernel file, or nothing.
function read_first() {
    local value=""
    { read -r value <"$1"; } 2>/dev/null
    printf '%s' "$value"
}

# Exit 0 when <word> is one of the space-separated words of the kernel file <file>.
function file_lists() {
    local words
    words=$(read_first "$1") || return 1
    [[ " $words " == *" $2 "* ]]
}

# Sets one policy as a values-file line asks: policy<N>=<governor> [<kHz>|max]. A policy the host
# lacks, a governor it does not offer, or a maximum above its hardware maximum or absent from its
# frequency list leaves the policy as found, with one line naming it and the reason. The governor
# and maximum found are recorded once, before anything is written, for restore.
function apply_policy() {
    local name="$1" governor="$2" freq="$3" dir hw found_gov found_max
    dir="$CPUFREQ_DIR/$name"
    if [ ! -d "$dir" ]; then
        say "$name: left as found, this host has no such policy."
        return 0
    fi
    if ! file_lists "$dir/scaling_available_governors" "$governor"; then
        say "$name: left as found, it does not offer the $governor governor."
        return 0
    fi
    hw=$(read_first "$dir/cpuinfo_max_freq")
    if ! [[ "$hw" =~ ^[0-9]{1,9}$ ]]; then
        say "$name: left as found, its hardware maximum cannot be read."
        return 0
    fi
    [ "$freq" != max ] || freq=$hw
    if [ -n "$freq" ]; then
        if [ $((10#$freq)) -gt $((10#$hw)) ]; then
            say "$name: left as found, $freq kHz is above its hardware maximum of $hw kHz."
            return 0
        fi
        if [ "$freq" != "$hw" ] && ! file_lists "$dir/scaling_available_frequencies" "$freq"; then
            say "$name: left as found, $freq kHz is not one of its available frequencies."
            return 0
        fi
    fi
    found_gov=$(read_first "$dir/scaling_governor")
    found_max=$(read_first "$dir/scaling_max_freq")
    if ! [[ "$found_gov" =~ ^[a-z]{1,16}$ && "$found_max" =~ ^[0-9]{1,9}$ ]]; then
        say "$name: left as found, its current governor or maximum cannot be read."
        return 0
    fi
    if ! grep -q "^$name " "$RECORD" 2>/dev/null; then
        echo "$name $found_gov $found_max" >>"$RECORD" || {
            say "$name: left as found, the record of what was found cannot be written."
            return 0
        }
    fi
    if ! echo "$governor" >"$dir/scaling_governor"; then
        say "$name: the $governor governor could not be set."
        return 0
    fi
    if [ -n "$freq" ] && ! echo "$freq" >"$dir/scaling_max_freq"; then
        say "$name: governor $governor, but its maximum could not be set to $freq kHz."
        return 0
    fi
    say "$name: governor $governor${freq:+, at most $((10#$freq / 1000)) MHz}."
}

# Raises the 2 MB huge page reservation to <count>, never lowers it (a larger one is the user's),
# and only on a kernel whose default huge page is 2 MB.
function apply_hugepages() {
    local want="$1" size have
    size=$(awk '/^Hugepagesize:/ && $3 == "kB" { print $2; exit }' "$MEMINFO" 2>/dev/null)
    if [ "$size" != 2048 ]; then
        say "huge pages: none reserved, the kernel's default huge page is not 2 MB."
        return 0
    fi
    have=$(read_first "$NR_HUGEPAGES")
    [[ "$have" =~ ^[0-9]{1,9}$ ]] || have=0
    if [ $((10#$have)) -lt $((10#$want)) ] && ! echo "$want" >"$NR_HUGEPAGES"; then
        say "huge pages: the reservation of $want could not be written."
        return 0
    fi
    have=$(read_first "$NR_HUGEPAGES")
    say "huge pages: ${have:-unknown} of 2 MB reserved (wanted $want)."
}

# Reads the values file line by line; a line not of the expected form is skipped with one line.
function apply() {
    local line
    if [ ! -f "$TUNING_CONF" ]; then
        say "no values file at $TUNING_CONF: nothing set."
        return 0
    fi
    while read -r line || [ -n "$line" ]; do
        case $line in '' | '#'*) continue ;; esac
        if [[ "$line" =~ ^(policy[0-9]{1,4})=(performance|powersave)(\ ([0-9]{1,9}|max))?$ ]]; then
            apply_policy "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"
        elif [[ "$line" =~ ^hugepages=([0-9]{1,6})$ ]]; then
            apply_hugepages "${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^mode=(max|eco)$ ]]; then
            say "mode ${BASH_REMATCH[1]}."
        else
            say "skipped a line of $TUNING_CONF that is not of the expected form."
        fi
    done <"$TUNING_CONF"
    return 0
}

# Gives each recorded policy the maximum, then the governor, it had before apply.
function restore() {
    local name governor max dir
    [ -f "$RECORD" ] || return 0
    while read -r name governor max; do
        if ! [[ "$name" =~ ^policy[0-9]{1,4}$ && "$governor" =~ ^[a-z]{1,16}$ && "$max" =~ ^[0-9]{1,9}$ ]]; then
            say "skipped a record line that is not of the expected form."
            continue
        fi
        dir="$CPUFREQ_DIR/$name"
        if echo "$max" >"$dir/scaling_max_freq" && echo "$governor" >"$dir/scaling_governor"; then
            say "$name: given back governor $governor, at most $((10#$max / 1000)) MHz."
        else
            say "$name: could not be given back governor $governor and maximum $max kHz."
        fi
    done <"$RECORD"
    rm -f -- "$RECORD"
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        apply) apply ;;
        restore) restore ;;
        *)
            echo "Usage: $0 apply|restore" >&2
            exit 2
            ;;
    esac
fi
