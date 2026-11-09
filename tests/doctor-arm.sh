#!/bin/bash
# make doctor on arm64 Linux reads AES from the CPU "Features" line, the board model from the
# device tree, and sizes the huge page advice in the kernel's own page size ("none (kernel)" with
# no advice when the kernel has none); the x86-only checks are skipped with one note line. Every
# host gets the CPU list of each native config, and on arm64 a warning for a config without one.
# On x86 the CPU, huge page, 1 GB page and MSR sections print as before.
# The doctor's functions run against fixture files; nothing is read from this host's /proc or
# /sys. Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT

# fx <name> <arch>: an empty fixture host; the files are added by each case.
fx() { mkdir -p "$w/$1/configs"; printf '%s\n' "$2" > "$w/$1/arch"; }
# doctor <fixture> <function>...: runs the functions, then the summary, on that fixture, colours off.
doctor() {
  local d="$w/$1"; shift
  (
    # shellcheck source=/dev/null
    source "$root/scripts/doctor.sh" || exit 1
    CPUINFO=$d/cpuinfo MEMINFO=$d/meminfo DT_MODEL=$d/model NR_HUGEPAGES=$d/nr_hugepages
    THP_ENABLED=$d/thp GB_PAGES=$d/gb_pages MSR_DEV=$d/msr CONFIG_DIR=$d/configs
    HOST_ARCH=$(cat "$d/arch")
    for f in "$@"; do "$f"; done
    print_summary
  ) 2>&1 | sed $'s/\033\\[[0-9;]*m//g'
}
has() { printf '%s\n' "$2" | grep -qxF -- "$3" || fail "$1: no line '$3'"; }
hasnt() { ! printf '%s\n' "$2" | grep -qF -- "$3" || fail "$1: unexpected '$3'"; }
arm="check_cpu_arm check_hugepages_linux check_thread_lists"

# A Pi 5: crypto extensions, a device tree model, a kernel built without huge pages.
fx pi5 aarch64
printf 'processor\t: %s\nBogoMIPS\t: 108.00\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp\nCPU implementer\t: 0x41\n\n' 0 1 2 3 > "$w/pi5/cpuinfo"
printf 'Raspberry Pi 5 Model B Rev 1.0\0' > "$w/pi5/model"
printf 'MemTotal:        8245632 kB\n' > "$w/pi5/meminfo"
out=$(doctor pi5 $arm)
has pi5 "$out" "       Model:   Raspberry Pi 5 Model B Rev 1.0"
has pi5 "$out" "       Threads: 4"
has pi5 "$out" "  OK   AES supported (ARMv8 Crypto Extensions, critical for RandomX throughput)"
has pi5 "$out" "       AES-NI, AVX2, 1 GB page and MSR checks are x86-only: skipped"
hasnt pi5 "$out" "AES-NI missing"
hasnt pi5 "$out" "FAIL"
has pi5 "$out" "       Huge page size: none (kernel)"
has pi5 "$out" "  OK   No tuning actions needed — you're good to mine."
hasnt pi5 "$out" "modprobe msr"
hasnt pi5 "$out" "GRUB"

# An RK3588: 2 MB pages, none reserved; no device tree model falls back to the cpuinfo model.
fx rk3588 aarch64
printf 'processor\t: %s\nFeatures\t: fp asimd aes pmull sha1 sha2 crc32\n\n' 0 1 2 3 4 5 6 7 > "$w/rk3588/cpuinfo"
printf 'Radxa ROCK 5B\0' > "$w/rk3588/model"
printf 'Hugepagesize:       2048 kB\n' > "$w/rk3588/meminfo"
echo 0 > "$w/rk3588/nr_hugepages"
printf 'always [madvise] never\n' > "$w/rk3588/thp"
out=$(doctor rk3588 $arm)
has rk3588 "$out" "       Model:   Radxa ROCK 5B"
has rk3588 "$out" "━━ Huge pages (2 MB) ━━"
has rk3588 "$out" "       Reserved 2 MB pages: 0"
has rk3588 "$out" "  WARN XMRig recommends ~1280 reserved 2 MB pages for RandomX"
has rk3588 "$out" "  1. sudo sysctl -w vm.nr_hugepages=1280  # add to /etc/sysctl.d/99-xmrig.conf to persist"
rm "$w/rk3588/model"
printf 'model name\t: Cortex-A76\n' >> "$w/rk3588/cpuinfo"
has rk3588-cpuinfo "$(doctor rk3588 check_cpu_arm)" "       Model:   Cortex-A76"
: > "$w/rk3588/cpuinfo"
has rk3588-unknown "$(doctor rk3588 check_cpu_arm)" "       Model:   unknown"

# A 16 KB-granule kernel: 32 MB huge pages, so 2560 MiB is 80 of them.
fx k16 aarch64
printf 'Hugepagesize:      32768 kB\n' > "$w/k16/meminfo"
echo 0 > "$w/k16/nr_hugepages"
out=$(doctor k16 check_hugepages_linux)
has k16 "$out" "━━ Huge pages (32 MB) ━━"
has k16 "$out" "  WARN XMRig recommends ~80 reserved 32 MB pages for RandomX"
has k16 "$out" "  1. sudo sysctl -w vm.nr_hugepages=80  # add to /etc/sysctl.d/99-xmrig.conf to persist"
echo 80 > "$w/k16/nr_hugepages"
has k16-enough "$(doctor k16 check_hugepages_linux)" "  OK   Sufficient 32 MB huge pages reserved (80)"

# An ARM CPU without the crypto extensions.
fx noaes aarch64
printf 'processor\t: 0\nFeatures\t: fp asimd evtstrm crc32 cpuid\n' > "$w/noaes/cpuinfo"
has noaes "$(doctor noaes check_cpu_arm)" "  FAIL AES missing — RandomX will be very slow on this CPU"

# Thread lists: a config with a list is reported; one without warns on arm64 only.
for f in rk3588 x86; do
  mkdir -p "$w/$f/configs"
  printf '{\n    "cpu": {\n        "rx": [0, 1, 4, 5, 6, 7],\n        "max-threads-hint": 75,\n    }\n}\n' > "$w/$f/configs/config.json"
  printf '{\n    "cpu": {\n        "max-threads-hint": 75,\n    }\n}\n' > "$w/$f/configs/config_background.json"
done
fx x86 x86_64
out=$(doctor rk3588 check_thread_lists)
has lists-arm "$out" "       config.json: CPUs [0, 1, 4, 5, 6, 7]"
has lists-arm "$out" "  WARN config_background.json: no CPU list, the miner runs on every CPU. To apply --threads, run 'make clean-configs', the installer again, then 'make service-setup'."
out=$(doctor x86 check_thread_lists)
has lists-x86 "$out" "       config.json: CPUs [0, 1, 4, 5, 6, 7]"
has lists-x86 "$out" "       config_background.json: no CPU list (the miner's thread hint applies)"
hasnt lists-x86 "$out" "WARN"
fx none aarch64; rmdir "$w/none/configs"
has lists-none "$(doctor none check_thread_lists)" "       No native config found in $w/none/configs"

# x86: the four sections exactly as the doctor printed them before arm64 support.
printf 'processor\t: %s\nmodel name\t: AMD Ryzen 9 5950X\nflags\t\t: fpu sse2 aes avx2 pdpe1gb\n\n' 0 1 > "$w/x86/cpuinfo"
printf 'Hugepagesize:       2048 kB\n' > "$w/x86/meminfo"
echo 1280 > "$w/x86/nr_hugepages"
printf 'always [madvise] never\n' > "$w/x86/thp"
echo 0 > "$w/x86/gb_pages"
out=$(doctor x86 check_cpu_linux check_hugepages_linux check_1gb_pages_linux check_msr_linux)
want=$(cat <<'X86'

━━ CPU ━━
       Model:   AMD Ryzen 9 5950X
       Threads: 2
  OK   AES-NI supported (critical for RandomX throughput)
  OK   AVX2 supported
  OK   1 GB huge pages supported by CPU

━━ Huge pages (2 MB) ━━
       Transparent huge pages: always [madvise] never
  OK   THP mode: madvise
       Reserved 2 MB pages: 1280
  OK   Sufficient 2 MB huge pages reserved (1280)

━━ 1 GB huge pages ━━
       Reserved 1 GB pages: 0
  WARN No 1 GB pages reserved. Enabling gives ~1–5% RandomX uplift.

━━ MSR (Model-Specific Registers) ━━
  WARN /dev/cpu/0/msr missing — the 'msr' kernel module is not loaded

━━ Recommendations ━━
       Consider the following to improve hashrate:

  1. Add 'hugepagesz=1G hugepages=3 default_hugepagesz=2M' to GRUB_CMDLINE_LINUX, then enable "1gb-pages": true in config.json
  2. sudo modprobe msr  # load now
  3. echo msr | sudo tee /etc/modules-load.d/msr.conf  # persist across reboots
X86
)
[ "$out" = "$want" ] || { fail "x86 sections differ from before:"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$out"); }

[ "$rc" -eq 0 ] && echo "PASS doctor-arm"
exit "$rc"
