#!/bin/bash
# Diagnostic script for Monero-miner-setup.
# Reports host tuning knobs relevant to XMRig / RandomX performance and
# suggests concrete actions when something is leaving hashrate on the table.

set -o pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
ORANGE='\033[0;33m'
RESET='\033[0m'

function header() { echo -e "\n${BLUE}━━ $* ━━${RESET}"; }
function ok()     { echo -e "  ${GREEN}OK${RESET}   $*"; }
function warn()   { echo -e "  ${ORANGE}WARN${RESET} $*"; }
function bad()    { echo -e "  ${RED}FAIL${RESET} $*"; }
function note()   { echo -e "       $*"; }

OS=$(uname -s)
HOST_ARCH=$(uname -m 2>/dev/null) || HOST_ARCH=""
RECOMMENDATIONS=()

CPUINFO=/proc/cpuinfo
MEMINFO=/proc/meminfo
DT_MODEL=/proc/device-tree/model
NR_HUGEPAGES=/proc/sys/vm/nr_hugepages
THP_ENABLED=/sys/kernel/mm/transparent_hugepage/enabled
GB_PAGES=/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
MSR_DEV=/dev/cpu/0/msr
CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/configs"
DT_COMPATIBLE=/proc/device-tree/compatible
CPUFREQ_DIR=/sys/devices/system/cpu/cpufreq
RX_FLOOR_MIB=2560
PROFILE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board_profiles.conf"

function is_arm64() {
    [ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ]
}

# ----- Board profiles -----
# These eight functions are the installer's, byte for byte (tests/board-doctor.sh).

# Prints the device tree's compatible strings that are well formed, one per line.
function board_compatible() {
    local word
    [ -r "$DT_COMPATIBLE" ] || return 0
    while read -r word; do
        [[ "$word" =~ ^[a-z0-9,._-]{1,64}$ ]] && echo "$word"
    done < <(tr '\0' '\n' <"$DT_COMPATIBLE")
    return 0
}

# Prints the device tree's model, printable characters only and no backslash (echo -e would revive escapes), 64 at most, or nothing.
function board_model() {
    local model
    [ -r "$DT_MODEL" ] || return 0
    model=$(tr -cd '[:print:]' <"$DT_MODEL" 2>/dev/null | tr -d '\\' | cut -c1-64)
    [ -z "$model" ] || echo "$model"
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

# Prints "measured on <model>" when <model> is one of the profile's measured models (compared
# whole, as a fixed string), else "untested".
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

# Prints the installed memory in MiB, or nothing when it cannot be read.
function total_mem_mib() {
    awk '/^MemTotal:/ && $2 ~ /^[0-9]+$/ { print int($2 / 1024) }' "$MEMINFO" 2>/dev/null
    return 0
}

# ----- Linux checks -----

function check_cpu_linux() {
    header "CPU"
    local model threads flags
    model=$(awk -F': ' '/^model name/ {print $2; exit}' "$CPUINFO")
    threads=$(grep -c '^processor' "$CPUINFO")
    flags=$(awk -F': ' '/^flags/ {print $2; exit}' "$CPUINFO")

    note "Model:   ${model:-unknown}"
    note "Threads: $threads"

    if echo " $flags " | grep -qw aes; then
        ok "AES-NI supported (critical for RandomX throughput)"
    else
        bad "AES-NI missing — RandomX will be very slow on this CPU"
    fi

    if echo " $flags " | grep -qw avx2; then
        ok "AVX2 supported"
    else
        warn "AVX2 missing — some RandomX paths will be slower"
    fi

    if echo " $flags " | grep -qw pdpe1gb; then
        ok "1 GB huge pages supported by CPU"
    else
        warn "1 GB huge pages not supported by this CPU"
    fi
}

# ARM boards list their CPU extensions on a "Features" line and name the board in the device tree.
function check_cpu_arm() {
    header "CPU"
    local model="" threads features
    [ -f "$DT_MODEL" ] && model=$(tr -d '\0' <"$DT_MODEL")
    [ -n "$model" ] || model=$(awk -F': ' '/^(model name|Model)[ \t]*:/ {print $2; exit}' "$CPUINFO" 2>/dev/null)
    threads=$(grep -c '^processor' "$CPUINFO" 2>/dev/null)
    features=$(awk -F': ' '/^Features/ {print $2; exit}' "$CPUINFO" 2>/dev/null)

    note "Model:   ${model:-unknown}"
    note "Threads: $threads"

    if echo " $features " | grep -qw aes; then
        ok "AES supported (ARMv8 Crypto Extensions, critical for RandomX throughput)"
    else
        bad "AES missing — RandomX will be very slow on this CPU"
    fi
    note "AES-NI, AVX2, 1 GB page and MSR checks are x86-only: skipped"
}

# The huge page size is the kernel's (2 MB on x86, 2 MB or 32 MB on arm64 by page granule); XMRig
# wants 2560 MiB of them for RandomX. A kernel without huge page support names no size.
function check_hugepages_linux() {
    local size label need mem
    mem=$(total_mem_mib)
    size=$(awk '/^Hugepagesize:/ {print $2; exit}' "$MEMINFO" 2>/dev/null)
    if [ -z "$size" ]; then
        label=""
        header "Huge pages"
    else
        if [ $((size % 1024)) -eq 0 ]; then label="$((size / 1024)) MB"; else label="$size kB"; fi
        need=$(((RX_FLOOR_MIB * 1024 + size - 1) / size))
        header "Huge pages ($label)"
    fi

    if [ -f "$THP_ENABLED" ]; then
        local thp active
        thp=$(cat "$THP_ENABLED")
        active=$(echo "$thp" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
        note "Transparent huge pages: $thp"
        case "$active" in
            always|madvise)
                ok "THP mode: $active" ;;
            never)
                warn "THP disabled — XMRig will need to reserve huge pages explicitly"
                RECOMMENDATIONS+=("echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled") ;;
            *)
                warn "THP mode unknown: $active" ;;
        esac
    else
        warn "THP sysfs entry missing"
    fi

    if [[ "$mem" =~ ^[0-9]{1,9}$ ]] && [ $((10#$mem)) -lt "$RX_FLOOR_MIB" ]; then
        warn "Memory $mem MiB is under the $RX_FLOOR_MIB MiB floor: the miner runs in RandomX light mode"
    elif [ -z "$size" ]; then
        note "Huge page size: none (kernel)"
    elif [ -f "$NR_HUGEPAGES" ]; then
        local reserved
        reserved=$(cat "$NR_HUGEPAGES")
        note "Reserved $label pages: $reserved"
        if [ "$reserved" -lt "$need" ]; then
            warn "XMRig recommends ~$need reserved $label pages for RandomX"
            RECOMMENDATIONS+=("sudo sysctl -w vm.nr_hugepages=$need  # add to /etc/sysctl.d/99-xmrig.conf to persist")
        else
            ok "Sufficient $label huge pages reserved ($reserved)"
        fi
    fi
}

function check_1gb_pages_linux() {
    header "1 GB huge pages"

    local mem
    mem=$(total_mem_mib)
    if [[ "$mem" =~ ^[0-9]{1,9}$ ]] && [ $((10#$mem)) -lt "$RX_FLOOR_MIB" ]; then
        note "Memory is under the $RX_FLOOR_MIB MiB floor: no 1 GB pages advised"
        return 0
    fi

    if ! grep -qw pdpe1gb "$CPUINFO"; then
        warn "CPU does not support 1 GB pages — skipping"
        return 0
    fi

    if [ -f "$GB_PAGES" ]; then
        local reserved
        reserved=$(cat "$GB_PAGES")
        note "Reserved 1 GB pages: $reserved"
        if [ "$reserved" -eq 0 ]; then
            warn "No 1 GB pages reserved. Enabling gives ~1–5% RandomX uplift."
            RECOMMENDATIONS+=("Add 'hugepagesz=1G hugepages=3 default_hugepagesz=2M' to GRUB_CMDLINE_LINUX, then enable \"1gb-pages\": true in config.json")
        else
            ok "$reserved × 1 GB page(s) reserved"
        fi
    else
        warn "1 GB huge-pages sysfs entry missing — kernel was not booted with hugepagesz=1G"
        RECOMMENDATIONS+=("Add 'hugepagesz=1G hugepages=3 default_hugepagesz=2M' to GRUB_CMDLINE_LINUX")
    fi
}

function check_msr_linux() {
    header "MSR (Model-Specific Registers)"

    if [ -c "$MSR_DEV" ]; then
        ok "/dev/cpu/0/msr present"
        if [ -w "$MSR_DEV" ]; then
            ok "MSR writable — XMRig can apply RandomX MSR tweaks (5–15% uplift on Ryzen/EPYC)"
        else
            warn "MSR present but not writable as current user"
            RECOMMENDATIONS+=("sudo bash dependencies/xmrig/scripts/randomx_boost.sh  # one-shot MSR tweak")
        fi
    else
        warn "/dev/cpu/0/msr missing — the 'msr' kernel module is not loaded"
        RECOMMENDATIONS+=("sudo modprobe msr  # load now")
        RECOMMENDATIONS+=("echo msr | sudo tee /etc/modules-load.d/msr.conf  # persist across reboots")
    fi
}

# The board, its profile and what the profile says about this host: memory against the floor, the
# eco cap beside each cpufreq policy's maximum, and which list each native config holds (compared
# as CPU sets). Reads only.
function check_board() {
    header "Board"
    local profile model mem entry pol cap now file name list nums max eco
    profile=$(find_profile)
    if [ -z "$profile" ]; then
        note "No board profile for this board: the CPU list follows --threads."
        return 0
    fi
    if ! profile_ok "$profile"; then
        warn "The $profile profile in $PROFILE_FILE is not valid and is ignored."
        return 0
    fi
    model=$(board_model)
    note "Board: ${model:-unknown model}, profile $profile, $(profile_status "$profile" "$model")"
    mem=$(total_mem_mib)
    if [[ "$mem" =~ ^[0-9]{1,9}$ ]] && [ $((10#$mem)) -ge "$RX_FLOOR_MIB" ]; then
        ok "Memory: $mem MiB (floor $RX_FLOOR_MIB MiB)"
    fi

    local capped=" "
    for entry in $(profile_value "$profile" eco-cap); do
        pol=${entry%%=*}
        cap=${entry#*=}
        capped+="$pol "
        now=$(cat "$CPUFREQ_DIR/$pol/scaling_max_freq" 2>/dev/null)
        [[ "$now" =~ ^[0-9]{1,9}$ ]] || continue
        note "$pol: max now $((10#$now / 1000)) MHz, eco cap $((10#$cap / 1000)) MHz"
    done
    for file in "$CPUFREQ_DIR"/policy[0-9]*/scaling_max_freq; do
        [ -f "$file" ] || continue
        pol=${file%/scaling_max_freq}
        pol=${pol##*/}
        [[ "$capped" == *" $pol "* ]] && continue
        now=$(cat "$file" 2>/dev/null)
        [[ "$now" =~ ^[0-9]{1,9}$ ]] || continue
        note "$pol: max now $((10#$now / 1000)) MHz"
    done

    max=$(expand_cpus "$(profile_value "$profile" max)" | tr '\n' ' ')
    eco=$(expand_cpus "$(profile_value "$profile" eco)" | tr '\n' ' ')
    for name in config.json config_background.json; do
        file="$CONFIG_DIR/$name"
        [ -f "$file" ] || continue
        list=$(sed -n 's/^[ \t]*"rx": \(\[[-0-9, ]*\]\),\{0,1\}$/\1/p' "$file" | head -n 1)
        [ -n "$list" ] || continue
        nums=$(printf '%s' "$list" | tr -cd '0-9,' | tr ',' '\n' | sort -n -u | tr '\n' ' ')
        if [ "$nums" = "$max" ] && [ "$nums" = "$eco" ]; then
            note "$name: the profile's max and eco list"
        elif [ "$nums" = "$eco" ]; then
            note "$name: the profile's eco list"
        elif [ "$nums" = "$max" ]; then
            note "$name: the profile's max list"
        else
            note "$name: another list"
        fi
    done
}

# ----- macOS checks -----

function check_cpu_macos() {
    header "CPU"
    local model threads features arch
    model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
    threads=$(sysctl -n hw.ncpu 2>/dev/null || echo "?")
    arch=$(uname -m)
    note "Model:   $model"
    note "Threads: $threads"
    note "Arch:    $arch"

    if [[ "$arch" == "arm64" ]] || [[ "$model" =~ Apple ]]; then
        ok "Apple Silicon — RandomX uses ARM NEON + Crypto extensions"
        warn "MSR tweaks, 2 MB / 1 GB huge pages don't apply on Apple Silicon"
        return 0
    fi

    features=$(sysctl -n machdep.cpu.features 2>/dev/null)
    features+=" "
    features+=$(sysctl -n machdep.cpu.leaf7_features 2>/dev/null)

    if echo " $features " | grep -qw AES; then
        ok "AES-NI supported"
    else
        bad "AES-NI missing — RandomX will be very slow"
    fi

    if echo " $features " | grep -qw AVX2; then
        ok "AVX2 supported"
    else
        warn "AVX2 missing — some RandomX paths will be slower"
    fi
}

function check_macos_tuning_notes() {
    header "Tuning notes (macOS)"
    note "macOS has no userspace equivalent of Linux huge pages or MSR writes."
    note "RandomX on macOS falls back to 4 KB pages — expect 10–30% lower hashrate"
    note "vs. a tuned Linux host of the same CPU."
    note ""
    note "If raw hashrate matters more than convenience, run the Docker install"
    note "on a Linux VM / host instead."
}

# ----- Shared -----

# The installer writes the CPUs to mine on as the "rx" list of each native config; with none, the
# miner's thread hint applies on x86, and every CPU mines on arm64.
function check_thread_lists() {
    header "Thread lists"
    local name file list found=false
    for name in config.json config_background.json; do
        file="$CONFIG_DIR/$name"
        [ -f "$file" ] || continue
        found=true
        list=$(sed -n 's/^[ \t]*"rx": \(\[[-0-9, ]*\]\),\{0,1\}$/\1/p' "$file" | head -n 1)
        if [ -n "$list" ]; then
            note "$name: CPUs $list"
        elif is_arm64; then
            warn "$name: no CPU list, the miner runs on every CPU. To apply --threads, run 'make clean-configs', the installer again, then 'make service-setup' and 'make restart'."
        else
            note "$name: no CPU list (the miner's thread hint applies)"
        fi
    done
    [ "$found" = true ] || note "No native config found in $CONFIG_DIR"
}

function check_docker() {
    header "Docker"
    if command -v docker >/dev/null 2>&1; then
        ok "docker: $(docker --version 2>/dev/null | head -1)"
        if docker compose version >/dev/null 2>&1; then
            ok "docker compose plugin available"
        else
            warn "docker compose plugin missing — 'docker compose up -d' won't work"
        fi
    else
        note "Docker not installed (optional — only needed for the Docker install path)"
    fi
}

function print_summary() {
    header "Recommendations"
    if [ ${#RECOMMENDATIONS[@]} -eq 0 ]; then
        ok "No tuning actions needed — you're good to mine."
    else
        note "Consider the following to improve hashrate:"
        echo
        local i=1
        for rec in "${RECOMMENDATIONS[@]}"; do
            echo "  $i. $rec"
            i=$((i + 1))
        done
    fi
    echo
}

# The Linux sections for this CPU: arm64 has no AES-NI, 1 GB page or MSR checks.
function run_linux_checks() {
    if is_arm64; then
        check_cpu_arm
        check_hugepages_linux
    else
        check_cpu_linux
        check_hugepages_linux
        check_1gb_pages_linux
        check_msr_linux
    fi
}

# The Board section where the host is arm64 or matches a profile, then the CPU sections.
function linux_sections() {
    if is_arm64 || [ -n "$(find_profile)" ]; then check_board; fi
    run_linux_checks
}

# Sourced (by the regression checks), the script only defines its functions.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

case "$OS" in
    Linux)
        linux_sections
        check_thread_lists
        check_docker
        ;;
    Darwin)
        check_cpu_macos
        check_macos_tuning_notes
        check_thread_lists
        check_docker
        ;;
    *)
        echo "Doctor is only implemented for Linux and macOS. Detected: $OS"
        exit 1
        ;;
esac

print_summary
