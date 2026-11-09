#!/bin/bash
# A known board's profile (scripts/board_profiles.conf, read as data) gives --mode max|eco the
# CPUs to mine on: the native installer writes the profile's list under every algorithm it lists
# CPUs for, and prints one board line. Without --mode the lists are v0.1.1's. --mode on a host
# with no profile is refused with one line before anything is written; a profile value that is
# not well formed makes the profile unusable and nothing in it runs. The functions run against
# device tree, sysfs and status fixtures; PATH holds only the tool-link directory. Nothing is
# cloned, built or installed. Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/tools"
for t in awk cat cmp cp cut head ln mkdir mv rm sort touch tr; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
printf '#!/bin/sh\necho 4\n' > "$w/tools/getconf" && chmod +x "$w/tools/getconf"

shared="board_compatible board_model profile_value find_profile expand_cpus profile_ok profile_status total_mem_mib"
fns="is_arm64 ranked_cpus arm_cpu_list pick_cpu_list $shared mode_cpu_list resolve_board check_board usage validate_wallet is_wallet is_worker_name is_pool parse_arguments write_miner_config generate_config_files"
{
  sed -n '/^# ===== Constants =====$/,/^DOCKER_SCRIPT_URL=/p' "$root/scripts/install.sh"
  for f in $fns; do sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/install.sh"; done
} > "$w/functions.sh"
for f in $fns; do grep -qx "function $f() {" "$w/functions.sh" || fail "no function $f in scripts/install.sh"; done
[ "$rc" -eq 0 ] || exit 1
wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge

# Fixtures: <name>/{sys/cpuN/..., status, compat, model}.
cpu() { # fixture cpu capacity freq
  mkdir -p "$w/fx/$1/sys/cpu$2/cpufreq"
  printf '%s\n' "$3" > "$w/fx/$1/sys/cpu$2/cpu_capacity"
  printf '%s\n' "$4" > "$w/fx/$1/sys/cpu$2/cpufreq/cpuinfo_max_freq"
}
board() { # fixture, allowed list, then printf formats for compat and model
  mkdir -p "$w/fx/$1"
  printf 'Name:\tbash\nCpus_allowed_list:\t%s\n' "$2" > "$w/fx/$1/status"
  printf "$3" > "$w/fx/$1/compat"
  printf "$4" > "$w/fx/$1/model"
}
for c in 0 1 2 3; do cpu pi5 "$c" 1024 2400000; done
board pi5 0-3 'raspberrypi,5-model-b\0brcm,bcm2712\0' 'Raspberry Pi 5 Model B Rev 1.0\0'
cp -R "$w/fx/pi5" "$w/fx/evil-model"
printf 'Evil\033[31m Board\0' > "$w/fx/evil-model/model"
for f in opi5plus rk3588s; do
  for c in 0 1 2 3; do cpu "$f" "$c" 530 1800000; done
  for c in 4 5; do cpu "$f" "$c" 1024 2400000; done
  for c in 6 7; do cpu "$f" "$c" 1024 2256000; done
done
board opi5plus 0-7 'xunlong,orangepi-5-plus\0rockchip,rk3588\0' 'Xunlong Orange Pi 5 Plus\0'
board rk3588s 0-7 'xunlong,orangepi-5-plus\0rockchip,rk3588s\0' 'Xunlong Orange Pi 5 Plus\0'
for c in 0 1 2 3; do cpu other "$c" 1024 1800000; done
board other 0-3 'vendor,board\0allwinner,sun50i-h616\0' 'Some Board\0'
mkdir -p "$w/fx/x86"

# on <fixture> <arch> <function or command...>: in a subshell on the fixture. Sets out, code.
on() {
  local fx=$1 arch=$2; shift 2
  ( PATH="$w/tools"
    info() { echo "[INFO] $1"; }; success() { echo "[SUCCESS] $1"; }; warning() { echo "[WARNING] $1"; }
    error() { echo "[ERROR] $1"; return 1; }
    # shellcheck source=/dev/null
    source "$w/functions.sh"
    HOST_ARCH=$arch CPU_SYS_DIR="$w/fx/$fx/sys" PROC_STATUS="$w/fx/$fx/status"
    DT_COMPATIBLE="$w/fx/$fx/compat" DT_MODEL="$w/fx/$fx/model" MEMINFO="$w/fx/$fx/meminfo" NR_HUGEPAGES="$w/fx/$fx/hp"
    "$@" ) > "$w/out" 2>&1
  code=$?
  out=$(cat "$w/out")
}
want() { # name, label, expected, got
  [ "$3" = "$4" ] || { echo "FAIL $1: $2"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'; rc=1; }
}
count() { printf '%s\n' "$out" | grep -c "$1"; }

# The shared helpers.
for case in "0-3|0 1 2 3" "0,1,4-7|0 1 4 5 6 7" "0-3,2-5|0 1 2 3 4 5" "007|7"; do
  on x86 x86_64 expand_cpus "${case%|*}"
  want "expand_cpus ${case%|*}" exit 0 "$code"
  want "expand_cpus ${case%|*}" numbers "${case#*|}" "$(printf '%s' "$out" | tr '\n' ' ' | awk '{ $1 = $1; print }')"
done
for bad in 9-4 00000-7 a 1-2-3 '' '1,' '4;7' '$(x)'; do
  on x86 x86_64 expand_cpus "$bad"
  want "expand_cpus '$bad'" exit 1 "$code"
  want "expand_cpus '$bad'" output "" "$out"
done
on rk3588s x86_64 board_compatible; want "board_compatible" strings "xunlong,orangepi-5-plus
rockchip,rk3588s" "$out"
on x86 x86_64 board_compatible; want "board_compatible none" output "" "$out"

# The clone: the data file and the templates, with a .git directory.
clone="$w/base/Monero-miner-setup"
fresh() { # [data file to use instead of the clone's own]
  rm -rf "$w/base"; mkdir -p "$clone/templates" "$clone/scripts" "$clone/.git"
  cp "$root"/templates/*.template "$clone/templates/"
  cp "${1:-$root/scripts/board_profiles.conf}" "$clone/scripts/board_profiles.conf"
}
# data <key> <value>: the data file with one line replaced, to $w/data.conf.
data() { awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 { print k "=" v; next } { print }' "$root/scripts/board_profiles.conf" > "$w/data.conf"; }
# gen <fixture> <arch> <share> [assignments]: the config generator, as a run of the installer calls it.
gen() {
  on "$1" "$2" eval "BASE_DIR='$w/base' REPO_NAME=Monero-miner-setup POOL_URL=gulf.moneroocean.stream PORT=10128 PASS=rig1 DEFAULT_PASS=x \
    WALLET=$wallet MAX_THREADS=$3 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false $4; generate_config_files"
}
rxs() { grep '"rx": \[' "$clone/configs/$1" | awk '{ $1 = $1; print }'; }
bline() { printf '%s\n' "$out" | grep '^\[INFO\] Board:'; }
a8="[ERROR] --mode needs a board profile, and this host has none: profiles cover bcm2712 (Raspberry Pi 5) and rk3588 (RK3588 and RK3588S boards such as the Orange Pi 5 Plus and 5 Max). Pass --threads PERCENT instead."

# Arguments.
perr1="[ERROR] --mode must be max or eco."
perr2="[ERROR] --mode and --threads both say which CPUs mine: pass one of them."
on x86 x86_64 eval "parse_arguments -w $wallet --mode eco && printf '%s' \"\$MODE\""; want "parse eco" exit 0 "$code"; want "parse eco" MODE eco "$out"
on x86 x86_64 eval "parse_arguments -w $wallet --mode max && printf '%s' \"\$MODE\""; want "parse max" MODE max "$out"
for args in "--mode fast" "--mode" "--mode ECO"; do
  # shellcheck disable=SC2086
  on x86 x86_64 parse_arguments -w "$wallet" $args; want "parse $args" exit 1 "$code"; want "parse $args" output "$perr1" "$out"
done
for args in "--mode eco -t 50" "-t 50 --mode eco"; do
  # shellcheck disable=SC2086
  on x86 x86_64 parse_arguments -w "$wallet" $args; want "parse $args" exit 1 "$code"; want "parse $args" output "$perr2" "$out"
done
on x86 x86_64 eval "parse_arguments -w $wallet -t 50 && printf '%s/%s' \"\$MAX_THREADS\" \"\$MODE\""; want "parse -t" values "50/" "$out"

# A1 to A5: the profile's lists under every algorithm, and the board line.
for case in "pi5 eco [0,1,2,3]" "pi5 max [0,1,2,3]" "opi5plus eco [4,5,6,7]" "opi5plus max [0,1,2,3,4,5,6,7]" "rk3588s eco [4,5,6,7]"; do
  read -r fx mode list <<< "$case"
  fresh; gen "$fx" aarch64 75 "MODE=$mode"; want "generate $case" exit 0 "$code"
  for name in config.json config_background.json; do
    want "$name $case" "rx list" "\"rx\": ${list//,/, }," "$(rxs "$name")"
    want "$name $case" "ghostrider" "$(jq -c 'map([8, .])' <<< "$list" 2>/dev/null)" "$(jq -c .cpu.ghostrider "$clone/configs/$name" 2>/dev/null)"
  done
done
fresh; gen opi5plus aarch64 75 MODE=eco
want "board line" line "[INFO] Board: Xunlong Orange Pi 5 Plus, profile rk3588, mode eco, untested." "$(bline)"
# A3: measured is a whole model, one of a ;-separated list.
data rk3588.measured "Other Board;Xunlong Orange Pi 5 Plus"; fresh "$w/data.conf"; gen opi5plus aarch64 75 MODE=eco
want "measured" line "[INFO] Board: Xunlong Orange Pi 5 Plus, profile rk3588, mode eco, measured on Xunlong Orange Pi 5 Plus." "$(bline)"
data rk3588.measured "Xunlong Orange Pi 5"; fresh "$w/data.conf"; gen opi5plus aarch64 75 MODE=eco
want "measured prefix" line "[INFO] Board: Xunlong Orange Pi 5 Plus, profile rk3588, mode eco, untested." "$(bline)"

# A6: no --mode, v0.1.1's lists and configs; the board line says the share.
fresh; gen opi5plus aarch64 75
want "no mode" list '"rx": [0, 1, 4, 5, 6, 7],' "$(rxs config.json)"
want "no mode" line "[INFO] Board: Xunlong Orange Pi 5 Plus, profile rk3588, mode 75 %, untested." "$(bline)"
cp "$clone/configs/config.json" "$w/with.json"
fresh; gen opi5plus aarch64 75 'BOARD_RESOLVED=yes BOARD_PROFILE=""'
cmp -s "$w/with.json" "$clone/configs/config.json" || fail "no mode: the config differs from the one without a board"
want "no board" line "" "$(bline)"

# A8: --mode with no profile stops before any config.
for case in "other aarch64 MODE=eco" "x86 x86_64 MODE=max"; do
  read -r fx arch assign <<< "$case"
  fresh; gen "$fx" "$arch" 75 "$assign"
  want "A8 $case" exit 1 "$code"; want "A8 $case" "error lines" "$a8" "$(printf '%s\n' "$out" | grep '^\[ERROR\]')"
  [ ! -e "$clone/configs/config.json" ] || fail "A8 $case: a config was written"
done
rm -rf "$w/base"; mkdir -p "$w/base"
on x86 x86_64 eval "BASE_DIR='$w/base' REPO_NAME=Monero-miner-setup MODE=max; check_board"
want "check_board x86 max, no clone" exit 1 "$code"; want "check_board x86 max, no clone" output "$a8" "$out"
on x86 x86_64 eval "BASE_DIR='$w/base' REPO_NAME=Monero-miner-setup; check_board"
want "check_board x86, no mode" exit 0 "$code"; want "check_board x86, no mode" output "" "$out"
fresh; rm "$clone/scripts/board_profiles.conf"; gen pi5 aarch64 75 MODE=eco
want "no data file" exit 1 "$code"; want "no data file" "error lines" 1 "$(count '^\[ERROR\]')"
case $out in *"git -C"*"pull"*) ;; *) fail "no data file: the line names no 'git -C ... pull': $out" ;; esac
fresh; rm "$clone/scripts/board_profiles.conf"; gen pi5 aarch64 75
want "no data file, no mode" exit 0 "$code"; want "no data file, no mode" "board line" "" "$(bline)"

# x86 with no --mode: no board line.
fresh; gen x86 x86_64 75; want "x86" exit 0 "$code"; want "x86" "board line" "" "$(bline)"

# A device tree model holds nothing but printable characters in the line.
fresh; gen evil-model aarch64 75 MODE=eco
want "evil model" "esc bytes" 0 "$(bline | LC_ALL=C grep -c $'\033')"
want "evil model" line "[INFO] Board: Evil[31m Board, profile bcm2712, mode eco, untested." "$(bline)"

# Hostile data: nothing runs, the profile is unusable.
for bad in "4-7; touch $w/pwned" "\$(touch $w/pwned)" 9-4 00000-7; do
  data rk3588.eco "$bad"; fresh "$w/data.conf"; gen opi5plus aarch64 75 MODE=eco
  [ ! -e "$w/pwned" ] || { fail "hostile eco '$bad': the file ran"; rm -f "$w/pwned"; }
  want "hostile eco '$bad'" exit 1 "$code"
  want "hostile eco '$bad'" warnings 1 "$(count '^\[WARNING\]')"
  want "hostile eco '$bad'" "last line" "$a8" "$(printf '%s\n' "$out" | tail -n 1)"
  [ ! -e "$clone/configs/config.json" ] || fail "hostile eco '$bad': a config was written"
done
data rk3588.compatible "rockchip,rk3588 *"; fresh "$w/data.conf"
gen opi5plus aarch64 75 MODE=eco; want "hostile compatible" exit 1 "$code"; want "hostile compatible" warnings 1 "$(count '^\[WARNING\]')"
# A compatible word matches a whole device tree string, not a prefix of one or a part of it.
for case in "rockchip,rk3588 rk3588s" "rockchip,rk3588s opi5plus" "rockchip,rk3588s,x opi5plus"; do
  read -r word fx <<< "$case"
  data rk3588.compatible "$word"; fresh "$w/data.conf"
  gen "$fx" aarch64 75 MODE=eco; want "compatible '$word' on $fx" exit 1 "$code"
  want "compatible '$word' on $fx" "error lines" "$a8" "$(printf '%s\n' "$out" | grep '^\[ERROR\]')"
done
data rk3588.compatible "rockchip,rk3588 *"; fresh "$w/data.conf"
gen other aarch64 75; want "star compatible, other" exit 0 "$code"; want "star compatible, other" board "" "$(bline)"
want "star compatible, other" warnings 0 "$(count '^\[WARNING\]')"

# The board is resolved once: the main step, then the config generator.
fresh
on opi5plus aarch64 eval "BASE_DIR='$w/base' REPO_NAME=Monero-miner-setup POOL_URL=gulf.moneroocean.stream PORT=10128 PASS=rig1 DEFAULT_PASS=x \
  WALLET=$wallet MAX_THREADS=75 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false MODE=eco; check_board; generate_config_files"
want "resolve once" exit 0 "$code"; want "resolve once" "board lines" 1 "$(count '^\[INFO\] Board:')"
[ "$rc" -eq 0 ] && echo "PASS board-profiles"
exit "$rc"
