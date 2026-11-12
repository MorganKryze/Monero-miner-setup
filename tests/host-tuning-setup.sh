#!/bin/bash
# What the systemd setup works out for a board set up with --mode (scripts/setup_service_tuning.sh):
# from the board profile and the kernel's cpufreq policies, one values-file line per policy (the
# ones holding a CPU the mode mines on get performance, capped in eco at the profile's eco-cap,
# at the hardware maximum in max; the others powersave), and 1280 huge pages only on a kernel
# whose default huge page is 2 MB, with memory for RandomX's fast mode and a fast-mode service
# config; the mode only from the installer's board-mode file, max or eco; the miner unit made a
# dedicated miner's (no Nice, restarted after any exit, the tuning wanted first); one closing line
# per change. The board functions are the installer's, byte for byte. Fixture device tree,
# meminfo and cpufreq trees with the values a Raspberry Pi 5 and an Orange Pi 5 Plus report; PATH
# holds only links to plain tools; nothing of this host's /sys, /proc or /etc is read.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
same() { # label, expected, got
  [ "$2" = "$3" ] || { fail "$1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/    /'; }
}
for f in board_compatible profile_value find_profile expand_cpus profile_ok total_mem_mib config_rx_mode; do
  a=$(sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/setup_service_tuning.sh")
  b=$(sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/install.sh")
  { [ -n "$b" ] && [ "$a" = "$b" ]; } || fail "$f differs between setup_service_tuning.sh and install.sh"
done
same "constants" 'TUNING_BIN="/usr/local/sbin/xmrig-host-tuning"
TUNING_CONF="/etc/xmrig-host-tuning.conf"
TUNING_UNIT="/etc/systemd/system/xmrig-host-tuning.service"
TUNING_CPUFREQ_DIR="/sys/devices/system/cpu/cpufreq"
DT_COMPATIBLE="/proc/device-tree/compatible"
MEMINFO="/proc/meminfo"
PROFILE_FILE="$BASE_DIR/scripts/board_profiles.conf"
RX_FLOOR_MIB=2560
TUNING_HUGEPAGES=1280' "$(sed -n '/^# ===== Constants =====$/,/^$/p' "$root/scripts/setup_service_tuning.sh" | sed '1d;$d')"
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/tools"
for t in awk cat grep head sort tr mktemp rm; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
printf '#!/bin/sh\n[ "$1" = -u ] && echo "${FAKE_UID:-1000}"\n' > "$w/tools/id"
chmod 755 "$w/tools/id"

pol() { # <board> <policy> <cpus>
  mkdir -p "$w/$1/cpufreq/$2"
  printf '%s\n' "$3" > "$w/$1/cpufreq/$2/related_cpus"
}
board() { # <name> <MemTotal kB> <Hugepagesize kB or -> <compatible...>
  local d="$w/$1"
  mkdir -p "$d/clone/configs" "$d/clone/scripts"
  cp "$root/scripts/board_profiles.conf" "$d/clone/scripts/"
  printf 'MemTotal:       %s kB\n' "$2" > "$d/meminfo"
  [ "$3" = - ] || printf 'Hugepagesize:       %s kB\n' "$3" >> "$d/meminfo"
  shift 3
  printf '%s\0' "$@" > "$d/compatible"
  printf '{\n    "randomx": {\n        "mode": "auto",\n    },\n}\n' > "$d/seed.json"
}
board opi 16184388 2048 xunlong,orangepi-5-plus rockchip,rk3588
pol opi policy0 "0 1 2 3"; pol opi policy4 "4 5"; pol opi policy6 "6 7"
board pi 8255824 - raspberrypi,5-model-b brcm,bcm2712
pol pi policy0 "0 1 2 3"
board small 2097152 2048 rockchip,rk3588s
pol small policy0 "0 1 2 3"; pol small policy4 "4 5"; pol small policy6 "6 7"
board three 3145728 2048 rockchip,rk3588
pol three policy0 "0 1 2 3"; pol three policy4 "4 5"; pol three policy6 "6 7"
board nopol 16184388 2048 rockchip,rk3588
board gib 16184388 1048576 rockchip,rk3588
pol gib policy0 "0 1 2 3"; pol gib policy4 "4 5"; pol gib policy6 "6 7"
board pc 16184388 2048 acme,desktop
pol pc policy0 "0 1 2 3"
# fn <board> <function> <args...>: runs one function of the sourced script against the board.
fn() {
  local d="$w/$1"; shift
  env -i PATH="$w/tools" FAKE_UID="${FAKE_UID:-1000}" "$BASH" --norc --noprofile -c '
    s=$1 d=$2; shift 2
    BASE_DIR=$d/clone
    source "$s" || exit 9
    TUNING_CPUFREQ_DIR=$d/cpufreq DT_COMPATIBLE=$d/compatible MEMINFO=$d/meminfo
    "$@"' host-tuning-setup "$root/scripts/setup_service_tuning.sh" "$d" "$@" 2>&1
  echo "exit $?"
}

same "opi eco" 'mode=eco
policy0=powersave
policy4=performance 1800000
policy6=performance 1800000
hugepages=1280
exit 0' "$(fn opi tuning_values eco "$w/opi/seed.json")"
same "opi max" 'mode=max
policy0=performance max
policy4=performance max
policy6=performance max
hugepages=1280
exit 0' "$(fn opi tuning_values max "$w/opi/seed.json")"
same "pi eco" 'mode=eco
policy0=performance 1800000
exit 0' "$(fn pi tuning_values eco "$w/pi/seed.json")"
same "pi max" 'mode=max
policy0=performance max
exit 0' "$(fn pi tuning_values max "$w/pi/seed.json")"
# Under the memory floor, with a default huge page of 1 GB, or a service config in light mode: no
# huge pages.
same "small board" 'mode=max
policy0=performance max
policy4=performance max
policy6=performance max
exit 0' "$(fn small tuning_values max "$w/small/seed.json")"
# 3 GB: above the floor, but 1280 pages would leave less than 1024 MiB, which the boot script
# refuses: no huge pages, so no closing line promising them.
same "3 GB board" 'mode=max
policy0=performance max
policy4=performance max
policy6=performance max
exit 0' "$(fn three tuning_values max "$w/three/seed.json")"
same "3 GB board lines" "" "$(fn three eval 'tuning_values max $d/seed.json | tuning_lines' | grep 'Huge pages')"
# On the boundary: 3584 MiB leaves exactly 1024 MiB outside 1280 pages, so the setup promises them
# and the boot script reserves them on the same meminfo; one MiB less, neither does.
board edge 3670016 2048 rockchip,rk3588
pol edge policy0 "0 1 2 3"; pol edge policy4 "4 5"; pol edge policy6 "6 7"
board under 3668992 2048 rockchip,rk3588
pol under policy0 "0 1 2 3"; pol under policy4 "4 5"; pol under policy6 "6 7"
reserve() { # <board>: the boot script's huge pages for 1280 on the board's meminfo, then the reservation
  printf '0\n' > "$w/$1/nr_hugepages"
  env -i PATH="$w/tools" "$BASH" --norc --noprofile -c '
    source "$1" || exit 9
    MEMINFO=$2/meminfo NR_HUGEPAGES=$2/nr_hugepages
    apply_hugepages 1280' host-tuning "$root/scripts/host_tuning.sh" "$w/$1" 2>&1
  echo "exit $?"
  cat "$w/$1/nr_hugepages"
}
same "3584 MiB board" 'mode=max
policy0=performance max
policy4=performance max
policy6=performance max
hugepages=1280
exit 0' "$(fn edge tuning_values max "$w/edge/seed.json")"
same "3584 MiB board, boot" 'xmrig-host-tuning: huge pages: 1280 of 2 MB reserved (wanted 1280).
exit 0
1280' "$(reserve edge)"
same "3583 MiB board" 'mode=max
policy0=performance max
policy4=performance max
policy6=performance max
exit 0' "$(fn under tuning_values max "$w/under/seed.json")"
same "3583 MiB board, boot" 'xmrig-host-tuning: huge pages: none reserved, 1280 would leave less than 1024 MiB free.
exit 0
0' "$(reserve under)"
same "1 GB default page" 'mode=eco
policy0=powersave
policy4=performance 1800000
policy6=performance 1800000
exit 0' "$(fn gib tuning_values eco "$w/gib/seed.json")"
printf '{\n    "randomx": {\n        "mode": "light",\n    },\n}\n' > "$w/opi/light.json"
same "light-mode config" 'mode=eco
policy0=powersave
policy4=performance 1800000
policy6=performance 1800000
exit 0' "$(fn opi tuning_values eco "$w/opi/light.json")"
# A kernel with no cpufreq policy: one error line, exit 1.
same "no cpufreq policy" "ERROR: The service config was written for --mode eco, and this kernel has no cpufreq policy under $w/nopol/cpufreq. Run the installer again without --mode.
exit 1" "$(fn nopol tuning_values eco "$w/nopol/seed.json")"
# No profile, or a profile that fails its check: one error line, exit 1.
same "no profile" "ERROR: The service config was written for --mode eco, and this board has no valid profile in $w/pc/clone/scripts/board_profiles.conf. Run the installer again without --mode, or update the clone: git -C $w/pc/clone pull
exit 1" "$(fn pc tuning_values eco "$w/pc/seed.json")"
printf 'rk3588.compatible=rockchip,rk3588\nrk3588.max=0-7\nrk3588.eco=4-7\nrk3588.eco-cap=policy4=1.8GHz\n' > "$w/opi/clone/scripts/board_profiles.conf"
same "bad profile" "exit 1" "$(fn opi tuning_values eco "$w/opi/seed.json" | tail -n 1)"
cp "$root/scripts/board_profiles.conf" "$w/opi/clone/scripts/"

# The mode: only max or eco, first line of configs/board-mode, nothing without the file.
same "no board-mode" "exit 0" "$(fn opi tuning_mode)"
for m in eco max; do
  printf '%s\n' "$m" > "$w/opi/clone/configs/board-mode"
  same "board-mode $m" "$m
exit 0" "$(fn opi tuning_mode)"
done
for m in 'eco; rm -rf /' ECO '' ' max' 'policy0=performance'; do
  printf '%s\n' "$m" > "$w/opi/clone/configs/board-mode"
  same "board-mode '$m'" "exit 0" "$(fn opi tuning_mode)"
done

# Closing lines: one per change.
same "opi eco lines" 'Host tuning for --mode eco, applied by xmrig-host-tuning.service at each boot before the miner:
  policy0 (CPUs 0 1 2 3): powersave governor, no mining there.
  policy4 (CPUs 4 5): performance governor, at most 1800 MHz.
  policy6 (CPUs 6 7): performance governor, at most 1800 MHz.
  Huge pages: 1280 of 2 MB reserved at each boot.
  The miner runs at normal priority (no Nice) and restarts 15 s after any exit.
  Files: /etc/systemd/system/xmrig-host-tuning.service, /usr/local/sbin/xmrig-host-tuning, /etc/xmrig-host-tuning.conf; '"'make service-disable'"' removes them and gives the CPU settings back.
exit 0' "$(fn opi eval 'tuning_values eco $d/seed.json | tuning_lines')"
same "pi max lines" 'Host tuning for --mode max, applied by xmrig-host-tuning.service at each boot before the miner:
  policy0 (CPUs 0 1 2 3): performance governor, at its hardware maximum.' \
  "$(fn pi eval 'tuning_values max $d/seed.json | tuning_lines' | head -n 2)"

# Staged as root: the profile is read through the account (sudo -u, recorded), into a staged copy
# that every later read uses; the error line still names the clone's file. While the file cut-read
# exists, a read of the profile stops before the RK3588 eco caps and fails.
cat > "$w/tools/sudo" <<EOS
#!/bin/sh
echo "sudo \$*" >> "$w/sudo.log"
[ "\$1" = -u ] || exit 1
shift 2
if [ -f "$w/cut-read" ] && [ "\${3##*/}" = board_profiles.conf ]; then
  awk '/^rk3588[.]eco-cap=/ { exit } { print }' "\$3"
  exit 1
fi
exec "\$@"
EOS
chmod 755 "$w/tools/sudo"
mkdir -p "$w/opi/clone/templates" "$w/tmp"
cp "$root/scripts/host_tuning.sh" "$w/opi/clone/scripts/"
cp "$root/templates/xmrig-host-tuning.service.template" "$w/opi/clone/templates/"
cp "$root/templates/xmrig.service.template" "$w/unit"
staged() { # <board>: stage_tuning eco as root, then the profile it read and its sudo calls
  rm -f "$w/sudo.log"
  FAKE_UID=0 fn "$1" eval 'ACCOUNT=miner SCRIPT_DIR=$BASE_DIR/scripts TMPDIR='"$w/tmp"' TUNING_STAGED=()
    stage_tuning eco '"$w/unit"' $d/seed.json; c=$?
    for f in "${TUNING_STAGED[@]}"; do [ "$f" = "$PROFILE_FILE" ] && echo "profile staged"; done
    rm -f -- "${TUNING_STAGED[@]}"; exit $c'
  cat "$w/sudo.log" 2>/dev/null
}
same "staged as root" "profile staged
exit 0
sudo -u miner cat -- $w/opi/clone/scripts/board_profiles.conf
sudo -u miner cat -- $w/opi/clone/scripts/host_tuning.sh
sudo -u miner cat -- $w/opi/clone/templates/xmrig-host-tuning.service.template" "$(staged opi)"
# A read of the profile that fails part way, after the RK3588 lines but before their eco caps:
# the staged copy is emptied, so the tuning is refused rather than staged uncapped.
: > "$w/cut-read"
same "profile read cut short" "ERROR: The service config was written for --mode eco, and this board has no valid profile in $w/opi/clone/scripts/board_profiles.conf. Run the installer again without --mode, or update the clone: git -C $w/opi/clone pull
profile staged
exit 1
sudo -u miner cat -- $w/opi/clone/scripts/board_profiles.conf" "$(staged opi)"
rm -f "$w/cut-read"
mkdir -p "$w/pc/clone/templates"
cp "$root/scripts/host_tuning.sh" "$w/pc/clone/scripts/"
cp "$root/templates/xmrig-host-tuning.service.template" "$w/pc/clone/templates/"
same "staged as root, no profile" "ERROR: The service config was written for --mode eco, and this board has no valid profile in $w/pc/clone/scripts/board_profiles.conf. Run the installer again without --mode, or update the clone: git -C $w/pc/clone pull
profile staged
exit 1
sudo -u miner cat -- $w/pc/clone/scripts/board_profiles.conf" "$(staged pc)"
[ -z "$(ls -A "$w/tmp")" ] || fail "staged files left behind"

# The miner unit of a dedicated miner, from the shipped template.
cp "$root/templates/xmrig.service.template" "$w/unit"
same "tuned unit" "exit 0" "$(fn opi tune_unit "$w/unit")"
# Every other line as shipped; Wants= right after After=; Restart=always where on-failure was.
same "tuned unit, other lines" "$(grep -vx -e 'Restart=on-failure' -e 'Nice=10' "$root/templates/xmrig.service.template")" \
  "$(grep -vx -e 'Wants=xmrig-host-tuning.service' -e 'Restart=always' "$w/unit")"
same "tuned unit, Wants" 'After=network.target
Wants=xmrig-host-tuning.service' "$(grep -A1 -x 'After=network.target' "$w/unit")"
same "tuned unit, Restart" 'Restart=always
RestartSec=15' "$(grep -A1 -x 'Restart=always' "$w/unit")"
grep -q '^Nice=' "$w/unit" && fail "the tuned unit keeps a Nice= line"
# A unit without one of the lines it changes is refused, left as it was.
grep -vx 'Nice=10' "$root/templates/xmrig.service.template" > "$w/unit"
cp "$w/unit" "$w/unit.before"
same "unit without Nice" "exit 1" "$(fn opi tune_unit "$w/unit")"
cmp -s "$w/unit" "$w/unit.before" || fail "a refused unit was changed"

[ "$rc" -eq 0 ] && echo "PASS host-tuning-setup"
exit "$rc"
