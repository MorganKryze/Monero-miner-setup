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

function is_arm64() {
    [ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ]
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
    local size label need
    size=$(awk '/^Hugepagesize:/ {print $2; exit}' "$MEMINFO" 2>/dev/null)
    if [ -z "$size" ]; then
        label=""
        header "Huge pages"
    else
        if [ $((size % 1024)) -eq 0 ]; then label="$((size / 1024)) MB"; else label="$size kB"; fi
        need=$(((2560 * 1024 + size - 1) / size))
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

    if [ -z "$size" ]; then
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
            warn "$name: no CPU list, the miner runs on every CPU. To apply --threads, run 'make clean-configs', the installer again, then 'make service-setup'."
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

# Sourced (by the regression checks), the script only defines its functions.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

case "$OS" in
    Linux)
        run_linux_checks
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
