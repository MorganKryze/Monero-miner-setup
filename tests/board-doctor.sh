#!/bin/bash
# make doctor on a board with a profile prints a Board section: the board, its profile and status,
# the memory against the 2560 MiB floor, the eco cap beside each cpufreq policy's maximum, and
# whether each native config holds the profile's max list, its eco list or another (compared as CPU
# sets, not text). Under the floor the huge page section warns of light mode and advises no huge
# pages, on any CPU. A host with no profile prints what it printed before, plus on arm64 one note.
# The board functions are the installer's, byte for byte. Fixture files only; nothing is read from
# this host's /proc or /sys. Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT

for f in board_compatible board_model profile_value find_profile expand_cpus profile_ok profile_status total_mem_mib; do
  a=$(sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/doctor.sh")
  b=$(sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/install.sh")
  { [ -n "$b" ] && [ "$a" = "$b" ]; } || fail "$f differs between doctor.sh and install.sh"
done

# fx <name> <arch> <MemTotal kB> <model> <compatible...>
fx() {
  local d=$w/$1; mkdir -p "$d/configs" "$d/cpufreq"
  printf '%s\n' "$2" > "$d/arch"
  printf 'MemTotal:       %s kB\n' "$3" > "$d/meminfo"
  printf '%s\0' "$4" > "$d/model"
  shift 4
  printf '%s\0' "$@" > "$d/compatible"
}
doctor() {
  local d="$w/$1"; shift
  (
    # shellcheck source=/dev/null
    source "$root/scripts/doctor.sh" || exit 1
    CPUINFO=$d/cpuinfo MEMINFO=$d/meminfo DT_MODEL=$d/model DT_COMPATIBLE=$d/compatible
    NR_HUGEPAGES=$d/nr_hugepages THP_ENABLED=$d/thp GB_PAGES=$d/gb_pages MSR_DEV=$d/msr
    CONFIG_DIR=$d/configs CPUFREQ_DIR=$d/cpufreq PROFILE_FILE=$root/scripts/board_profiles.conf
    HOST_ARCH=$(cat "$d/arch")
    for f in "$@"; do "$f"; done
    print_summary
  ) 2>&1 | sed $'s/\033\\[[0-9;]*m//g'
}
has() { printf '%s\n' "$2" | grep -qxF -- "$3" || fail "$1: no line '$3'"; }
hasnt() { ! printf '%s\n' "$2" | grep -qF -- "$3" || fail "$1: unexpected '$3'"; }
rx() { printf '{\n    "cpu": {\n        "rx": %s,\n        "max-threads-hint": 75,\n    }\n}\n' "$2" > "$w/$1/configs/$3"; }

# An Orange Pi 5 Plus, 16 GiB.
fx opi5plus aarch64 16272000 "Xunlong Orange Pi 5 Plus" xunlong,orangepi-5-plus rockchip,rk3588
printf 'processor\t: 0\nFeatures\t: fp asimd aes\n' > "$w/opi5plus/cpuinfo"
for p in 0:1800000 4:2400000 6:2400000; do
  mkdir -p "$w/opi5plus/cpufreq/policy${p%:*}"; echo "${p#*:}" > "$w/opi5plus/cpufreq/policy${p%:*}/scaling_max_freq"
done
rx opi5plus "[4, 5, 6, 7]" config.json
rx opi5plus "[0, 1, 4, 5, 6, 7]" config_background.json
out=$(doctor opi5plus linux_sections)
has opi5plus "$out" "━━ Board ━━"
has opi5plus "$out" "       Board: Xunlong Orange Pi 5 Plus, profile rk3588, untested"
has opi5plus "$out" "  OK   Memory: 15890 MiB (floor 2560 MiB)"
has opi5plus "$out" "       policy4: max now 2400 MHz, eco cap 1800 MHz"
has opi5plus "$out" "       policy6: max now 2400 MHz, eco cap 1800 MHz"
has opi5plus "$out" "       policy0: max now 1800 MHz"
has opi5plus "$out" "       config.json: the profile's eco list"
has opi5plus "$out" "       config_background.json: another list"
# CPU sets, not text: no spaces, and a max list.
rx opi5plus "[4,5,6,7]" config.json
rx opi5plus "[0,1,2,3,4,5,6,7]" config_background.json
out=$(doctor opi5plus check_board)
has sets "$out" "       config.json: the profile's eco list"
has sets "$out" "       config_background.json: the profile's max list"

# A Pi 5 with 2 GB: light mode, no huge page advice (a kernel with no huge pages names no size).
fx pi5 aarch64 2030592 "Raspberry Pi 5 Model B Rev 1.0" raspberrypi,5-model-b brcm,bcm2712
printf 'processor\t: 0\nFeatures\t: fp asimd aes\n' > "$w/pi5/cpuinfo"
rx pi5 "[0, 1, 2, 3]" config.json
out=$(doctor pi5 linux_sections)
has pi5 "$out" "       Board: Raspberry Pi 5 Model B Rev 1.0, profile bcm2712, untested"
has pi5 "$out" "       config.json: the profile's max and eco list"
has pi5 "$out" "  WARN Memory 1983 MiB is under the 2560 MiB floor: the miner runs in RandomX light mode"
hasnt pi5 "$out" "nr_hugepages"
hasnt pi5 "$out" "OK   Memory:"

# x86 under the floor: the same warning, no advice; at 16 GiB, no Board section.
fx x86 x86_64 2030592 "" generic,pc
printf 'processor\t: 0\nmodel name\t: Xeon\nflags\t\t: aes avx2\n' > "$w/x86/cpuinfo"
printf 'Hugepagesize:       2048 kB\n' >> "$w/x86/meminfo"
echo 0 > "$w/x86/nr_hugepages"
out=$(doctor x86 linux_sections)
has x86-small "$out" "  WARN Memory 1983 MiB is under the 2560 MiB floor: the miner runs in RandomX light mode"
hasnt x86-small "$out" "nr_hugepages"
hasnt x86-small "$out" "Board"
fx x86big x86_64 16272000 "" generic,pc
cp "$w/x86/cpuinfo" "$w/x86big/cpuinfo"
printf 'MemTotal: 16272000 kB\nHugepagesize:       2048 kB\n' > "$w/x86big/meminfo"
echo 0 > "$w/x86big/nr_hugepages"
out=$(doctor x86big linux_sections)
hasnt x86-big "$out" "Board"
hasnt x86-big "$out" "floor"
has x86-big "$out" "  1. sudo sysctl -w vm.nr_hugepages=1280  # add to /etc/sysctl.d/99-xmrig.conf to persist"
# An x86 host with a profile's compatible string gets the section.
fx x86rk x86_64 16272000 "" rockchip,rk3588
cp "$w/x86/cpuinfo" "$w/x86rk/cpuinfo"
has x86-profile "$(doctor x86rk linux_sections)" "━━ Board ━━"

# Another arm64 board: the header and one note.
fx other aarch64 16272000 "Some Board" vendor,thing
printf 'processor\t: 0\nFeatures\t: fp asimd aes\n' > "$w/other/cpuinfo"
out=$(doctor other linux_sections)
has other "$out" "━━ Board ━━"
has other "$out" "       No board profile for this board: the CPU list follows --threads."
hasnt other "$out" "Board:"
hasnt other "$out" "Memory:"

# macOS: no Board section.
mkdir -p "$w/bin"
printf '#!/bin/sh\necho Darwin\n' > "$w/bin/uname"; chmod +x "$w/bin/uname"
out=$(PATH="$w/bin:$PATH" bash "$root/scripts/doctor.sh" 2>&1)
hasnt macos "$out" "Board"

[ "$rc" -eq 0 ] && echo "PASS board-doctor"
exit "$rc"
