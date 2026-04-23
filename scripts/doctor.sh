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
RECOMMENDATIONS=()

# ----- Linux checks -----

function check_cpu_linux() {
    header "CPU"
    local model threads flags
    model=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)
    threads=$(grep -c '^processor' /proc/cpuinfo)
    flags=$(awk -F': ' '/^flags/ {print $2; exit}' /proc/cpuinfo)

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

function check_hugepages_linux() {
    header "Huge pages (2 MB)"

    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        local thp active
        thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled)
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

    if [ -f /proc/sys/vm/nr_hugepages ]; then
        local reserved
        reserved=$(cat /proc/sys/vm/nr_hugepages)
        note "Reserved 2 MB pages: $reserved"
        if [ "$reserved" -lt 1280 ]; then
            warn "XMRig recommends ~1280 reserved 2 MB pages for RandomX"
            RECOMMENDATIONS+=("sudo sysctl -w vm.nr_hugepages=1280  # add to /etc/sysctl.d/99-xmrig.conf to persist")
        else
            ok "Sufficient 2 MB huge pages reserved ($reserved)"
        fi
    fi
}

function check_1gb_pages_linux() {
    header "1 GB huge pages"

    if ! grep -qw pdpe1gb /proc/cpuinfo; then
        warn "CPU does not support 1 GB pages — skipping"
        return 0
    fi

    if [ -f /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages ]; then
        local reserved
        reserved=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages)
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

    if [ -c /dev/cpu/0/msr ]; then
        ok "/dev/cpu/0/msr present"
        if [ -w /dev/cpu/0/msr ]; then
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

case "$OS" in
    Linux)
        check_cpu_linux
        check_hugepages_linux
        check_1gb_pages_linux
        check_msr_linux
        check_docker
        ;;
    Darwin)
        check_cpu_macos
        check_macos_tuning_notes
        check_docker
        ;;
    *)
        echo "Doctor is only implemented for Linux and macOS. Detected: $OS"
        exit 1
        ;;
esac

print_summary
