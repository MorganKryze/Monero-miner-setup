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
fns="is_arm64 ranked_cpus arm_cpu_list pick_cpu_list $shared mode_cpu_list any_config_kept configs_exist huge_page_line resolve_board check_board usage validate_wallet is_wallet is_worker_name is_pool parse_arguments write_miner_config generate_config_files"
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
cp -R "$w/fx/pi5" "$w/fx/evil-text"
printf 'Evil\\033[2J\\e[1m\\x1b\\a Board\0' > "$w/fx/evil-text/model"
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
  local fx=$1 arch=$2 pid; shift 2
  ( PATH="$w/tools"
    info() { echo -e "[INFO] $1"; }; success() { echo "[SUCCESS] $1"; }; warning() { echo "[WARNING] $1"; }
    error() { echo "[ERROR] $1"; return 1; }
    # shellcheck source=/dev/null
    source "$w/functions.sh"
    HOST_ARCH=$arch CPU_SYS_DIR="$w/fx/$fx/sys" PROC_STATUS="$w/fx/$fx/status"
    DT_COMPATIBLE="$w/fx/$fx/compat" DT_MODEL="$w/fx/$fx/model" MEMINFO="$w/fx/$fx/meminfo" NR_HUGEPAGES="$w/fx/$fx/hp"
    "$@" ) > "$w/out" 2>&1 &
  pid=$!
  # Watchdog: a hung function is killed after 20 s (bounded loop, no timeout tool).
  ( for ((i = 0; i < 200; i++)); do kill -0 "$pid" 2>/dev/null || exit 0; sleep 0.1; done; kill -9 "$pid" 2>/dev/null ) &
  wait "$pid"
  code=$?
  [ "$code" -ne 137 ] || fail "hang: $*"
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
no_profile_line="[ERROR] --mode needs a board profile, and this host has none: profiles cover bcm2712 (Raspberry Pi 5) and rk3588 (RK3588 and RK3588S boards such as the Orange Pi 5 Plus and 5 Max). Pass --threads PERCENT instead."

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

# the profile's lists under every algorithm, and the board line.
for case in "pi5 eco [0,1,2,3]" "pi5 max [0,1,2,3]" "opi5plus eco [4,5,6,7]" "opi5plus max [0,1,2,3,4,5,6,7]" "rk3588s eco [4,5,6,7]"; do
  read -r fx mode list <<< "$case"
  fresh; gen "$fx" aarch64 75 "MODE=$mode"; want "generate $case" exit 0 "$code"
  for name in config.json config_background.json; do
    want "$name $case" "rx list" "\"rx\": ${list//,/, }," "$(rxs "$name")"
    want "$name $case" "ghostrider" "$(jq -c 'map([8, .])' <<< "$list" 2>/dev/null)" "$(jq -c .cpu.ghostrider "$clone/configs/$name" 2>/dev/null)"
  done
done
# One config kept, one missing, --mode eco: the missing one still gets the eco list.
fresh; mkdir -p "$clone/configs"; printf '{"x": 1}\n' > "$clone/configs/config.json"
gen opi5plus aarch64 75 MODE=eco; want "one kept, eco" exit 0 "$code"
want "one kept, eco" "rx list" '"rx": [4, 5, 6, 7],' "$(rxs config_background.json)"
fresh; gen opi5plus aarch64 75 MODE=eco
want "board line" line "[INFO] Board: Xunlong Orange Pi 5 Plus, profile rk3588, mode eco, untested." "$(bline)"
# measured is a whole model, one of a ;-separated list.
data rk3588.measured "Other Board;Xunlong Orange Pi 5 Plus"; fresh "$w/data.conf"; gen opi5plus aarch64 75 MODE=eco
want "measured" line "[INFO] Board: Xunlong Orange Pi 5 Plus, profile rk3588, mode eco, measured on Xunlong Orange Pi 5 Plus." "$(bline)"
data rk3588.measured "Xunlong Orange Pi 5"; fresh "$w/data.conf"; gen opi5plus aarch64 75 MODE=eco
want "measured prefix" line "[INFO] Board: Xunlong Orange Pi 5 Plus, profile rk3588, mode eco, untested." "$(bline)"

# no --mode, v0.1.1's lists and configs; the board line says the share.
fresh; gen opi5plus aarch64 75
want "no mode" list '"rx": [0, 1, 4, 5, 6, 7],' "$(rxs config.json)"
want "no mode" line "[INFO] Board: Xunlong Orange Pi 5 Plus, profile rk3588, mode 75 %, untested." "$(bline)"
cp "$clone/configs/config.json" "$w/with.json"
fresh; gen opi5plus aarch64 75 'BOARD_RESOLVED=yes BOARD_PROFILE=""'
cmp -s "$w/with.json" "$clone/configs/config.json" || fail "no mode: the config differs from the one without a board"
want "no board" line "" "$(bline)"

# --mode with no profile stops before any config.
for case in "other aarch64 MODE=eco" "x86 x86_64 MODE=max"; do
  read -r fx arch assign <<< "$case"
  fresh; gen "$fx" "$arch" 75 "$assign"
  want "no profile, $case" exit 1 "$code"; want "no profile, $case" "error lines" "$no_profile_line" "$(printf '%s\n' "$out" | grep '^\[ERROR\]')"
  [ ! -e "$clone/configs/config.json" ] || fail "no profile, $case: a config was written"
done
rm -rf "$w/base"; mkdir -p "$w/base"
on x86 x86_64 eval "BASE_DIR='$w/base' REPO_NAME=Monero-miner-setup MODE=max; check_board"
want "check_board x86 max, no clone" exit 1 "$code"; want "check_board x86 max, no clone" output "$no_profile_line" "$out"
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
# Escapes written as text: the toolbox prints with echo -e, which would turn them back into bytes.
fresh; gen evil-text aarch64 75 MODE=eco
want "evil text" "control bytes" 0 "$(bline | LC_ALL=C grep -c '[[:cntrl:]]')"
want "evil text" line "[INFO] Board: Evil033[2Je[1mx1ba Board, profile bcm2712, mode eco, untested." "$(bline)"

# Hostile data: nothing runs, the profile is unusable.
for bad in "4-7; touch $w/pwned" "\$(touch $w/pwned)" 9-4 00000-7; do
  data rk3588.eco "$bad"; fresh "$w/data.conf"; gen opi5plus aarch64 75 MODE=eco
  [ ! -e "$w/pwned" ] || { fail "hostile eco '$bad': the file ran"; rm -f "$w/pwned"; }
  want "hostile eco '$bad'" exit 1 "$code"
  want "hostile eco '$bad'" warnings 1 "$(count '^\[WARNING\]')"
  want "hostile eco '$bad'" "last line" "$no_profile_line" "$(printf '%s\n' "$out" | tail -n 1)"
  [ ! -e "$clone/configs/config.json" ] || fail "hostile eco '$bad': a config was written"
done
data rk3588.compatible "rockchip,rk3588 *"; fresh "$w/data.conf"
gen opi5plus aarch64 75 MODE=eco; want "hostile compatible" exit 1 "$code"; want "hostile compatible" warnings 1 "$(count '^\[WARNING\]')"
# A compatible word matches a whole device tree string, not a prefix of one or a part of it.
for case in "rockchip,rk3588 rk3588s" "rockchip,rk3588s opi5plus" "rockchip,rk3588s,x opi5plus"; do
  read -r word fx <<< "$case"
  data rk3588.compatible "$word"; fresh "$w/data.conf"
  gen "$fx" aarch64 75 MODE=eco; want "compatible '$word' on $fx" exit 1 "$code"
  want "compatible '$word' on $fx" "error lines" "$no_profile_line" "$(printf '%s\n' "$out" | grep '^\[ERROR\]')"
done
data rk3588.compatible "rockchip,rk3588 *"; fresh "$w/data.conf"
gen other aarch64 75; want "star compatible, other" exit 0 "$code"; want "star compatible, other" board "" "$(bline)"
want "star compatible, other" warnings 0 "$(count '^\[WARNING\]')"

# The board is resolved once: the main step, then the config generator.
fresh
on opi5plus aarch64 eval "BASE_DIR='$w/base' REPO_NAME=Monero-miner-setup POOL_URL=gulf.moneroocean.stream PORT=10128 PASS=rig1 DEFAULT_PASS=x \
  WALLET=$wallet MAX_THREADS=75 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false MODE=eco; check_board; generate_config_files"
want "resolve once" exit 0 "$code"; want "resolve once" "board lines" 1 "$(count '^\[INFO\] Board:')"
# the profile's CPUs are checked against the host.
allowed() { # new fixture, base fixture, allowed list
  cp -R "$w/fx/$2" "$w/fx/$1"
  printf 'Name:\tbash\nCpus_allowed_list:\t%s\n' "$3" > "$w/fx/$1/status"
}
allowed opi-2-5 opi5plus 2-5
allowed opi-0-3 opi5plus 0-3
for c in 0 1 2 3; do cpu vendor-numbering "$c" 1024 2400000; done
for c in 4 5 6 7; do cpu vendor-numbering "$c" 530 1800000; done
board vendor-numbering 0-7 'vendor,board\0rockchip,rk3588\0' 'Vendor Board\0'
for c in 0 1 2 3; do cpu rk3588-freq "$c" 0 1800000; rm "$w/fx/rk3588-freq/sys/cpu$c/cpu_capacity"; done
for c in 4 5 6 7; do cpu rk3588-freq "$c" 0 2400000; rm "$w/fx/rk3588-freq/sys/cpu$c/cpu_capacity"; done
board rk3588-freq 0-7 'vendor,board\0rockchip,rk3588\0' 'Vendor Board\0'
wl() { printf '%s\n' "$out" | grep '^\[WARNING\]'; }
fb="[WARNING] The eco list of profile rk3588 does not fit this host's CPUs: mining on 4 CPUs chosen by capacity instead."
fresh; gen opi-2-5 aarch64 75 MODE=eco; want "allowed 2-5 eco" exit 0 "$code"
want "allowed 2-5 eco" rx '"rx": [4, 5],' "$(rxs config.json)"
want "allowed 2-5 eco" warnings "[WARNING] CPUs 6, 7 of the eco list are not ones this installer may run on: left out." "$(wl)"
fresh; gen opi-0-3 aarch64 75 MODE=eco; want "allowed 0-3 eco" exit 0 "$code"
want "allowed 0-3 eco" rx '"rx": [0, 1, 2, 3],' "$(rxs config.json)"
want "allowed 0-3 eco" warnings "[WARNING] CPUs 4, 5, 6, 7 of the eco list are not ones this installer may run on: left out.
$fb" "$(wl)"
fresh; gen vendor-numbering aarch64 75 MODE=eco; want "vendor eco" exit 0 "$code"
want "vendor eco" rx '"rx": [0, 1, 2, 3],' "$(rxs config.json)"
want "vendor eco" warnings "$fb" "$(wl)"
fresh; gen vendor-numbering aarch64 75 MODE=max; want "vendor max" exit 0 "$code"
want "vendor max" rx '"rx": [0, 1, 2, 3, 4, 5, 6, 7],' "$(rxs config.json)"
want "vendor max" warnings "" "$(wl)"
fresh; gen rk3588-freq aarch64 75 MODE=eco; want "freq eco" exit 0 "$code"
want "freq eco" rx '"rx": [4, 5, 6, 7],' "$(rxs config.json)"
want "freq eco" warnings "" "$(wl)"

# The ranking check is for eco only: a max list that leaves out faster CPUs is used as it is.
data rk3588.max 4-7; fresh "$w/data.conf"; gen vendor-numbering aarch64 75 MODE=max; want "vendor max 4-7" exit 0 "$code"
want "vendor max 4-7" rx '"rx": [4, 5, 6, 7],' "$(rxs config.json)"
want "vendor max 4-7" warnings "" "$(wl)"

# a kept config says the mode does not apply; it is never edited.
kept_line="[WARNING] --mode does not apply to the kept configs. To apply it, run 'make clean-configs', the installer again with --mode, then 'make service-setup' and 'make restart'."
chk() { on opi5plus aarch64 eval "BASE_DIR='$w/base' REPO_NAME=Monero-miner-setup MODE=$1; check_board"; }
fresh; mkdir -p "$clone/configs"; printf '{"x": 1}\n' > "$clone/configs/config.json"; cp "$clone/configs/config.json" "$w/kept.json"
chk eco; want "kept" exit 0 "$code"; want "kept" warning "$kept_line" "$(wl)"
cmp -s "$w/kept.json" "$clone/configs/config.json" || fail "kept: the config changed"
on opi5plus aarch64 eval "BASE_DIR='$w/base' REPO_NAME=Monero-miner-setup POOL_URL=gulf.moneroocean.stream PORT=10128 PASS=rig1 DEFAULT_PASS=x \
  WALLET=$wallet MAX_THREADS=75 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false MODE=eco; check_board; generate_config_files"
want "kept, generate" exit 0 "$code"; want "kept, generate" "mode lines" 1 "$(count 'does not apply to the kept')"
want "kept, generate" "threads lines" 0 "$(count 'threads does not apply')"
cmp -s "$w/kept.json" "$clone/configs/config.json" || fail "kept, generate: the config changed"
fresh; printf '{}\n' > "$clone/config.json"; chk eco; want "kept-root" warning "$kept_line" "$(wl)"
fresh; ln -s "$clone/configs/nothing.json" "$clone/config.json"; chk eco; want "dangling root link" warnings "" "$(wl)"
fresh; mkdir -p "$clone/configs"; printf '{}\n' > "$clone/configs/config.json"; chk ""; want "installed" warnings "" "$(wl)"

# A malformed profile is dropped with one warning and nothing is written.
bad() { # label, key to replace (value) or "-key" to delete
  if [ "${2#-}" != "$2" ]; then grep -v "^rk3588.${2#-}=" "$root/scripts/board_profiles.conf" > "$w/data.conf"; else data "$2" "$3"; fi
  fresh "$w/data.conf"; gen opi5plus aarch64 75 MODE=eco
  want "$1" exit 1 "$code"; want "$1" warnings 1 "$(count '^\[WARNING\]')"
  [ ! -e "$clone/configs/config.json" ] || fail "$1: a config was written"
}
bad "no max" -max
bad "no eco" -eco
bad "bad layouts" rk3588.layouts "0-7 x"
bad "bad eco-cap" rk3588.eco-cap "policy4"
bad "bad measured" rk3588.measured "$(printf 'a%.0s' $(seq 1 1025))"
# A key outside the known ones makes the profile unusable.
{ cat "$root/scripts/board_profiles.conf"; echo "rk3588.eco =4-7"; } > "$w/data.conf"; fresh "$w/data.conf"; gen opi5plus aarch64 75 MODE=eco
want "spaced key" exit 1 "$code"; want "spaced key" warnings 1 "$(count '^\[WARNING\]')"
# An empty list for the mode refuses with one error and writes nothing.
sed 's/^rk3588.eco=.*/rk3588.eco=/' "$root/scripts/board_profiles.conf" > "$w/data.conf"; fresh "$w/data.conf"; gen opi5plus aarch64 75 MODE=eco
want "empty list" exit 1 "$code"; [ ! -e "$clone/configs/config.json" ] || fail "empty list: a config was written"
# The same list, reached past resolve_board: mode_cpu_list refuses and the refusal reaches the caller.
fresh "$w/data.conf"; gen opi5plus aarch64 75 "MODE=eco BOARD_RESOLVED=yes BOARD_PROFILE=rk3588 PROFILE_FILE='$clone/scripts/board_profiles.conf'"
want "empty list, past resolve" exit 1 "$code"
want "empty list, past resolve" "error lines" "[ERROR] The eco list of profile rk3588 is empty or not valid: nothing is written." "$(printf '%s\n' "$out" | grep '^\[ERROR\]')"
want "empty list, past resolve" success 0 "$(count 'SUCCESS')"
[ ! -e "$clone/configs/config.json" ] || fail "empty list, past resolve: a config was written"
# The model is cut to 64 characters.
cp -R "$w/fx/pi5" "$w/fx/long-model"; printf 'M%.0s' $(seq 1 100) > "$w/fx/long-model/model"
fresh; gen long-model aarch64 75 MODE=eco
want "long model" line "[INFO] Board: $(printf 'M%.0s' $(seq 1 64)), profile bcm2712, mode eco, untested." "$(bline)"
# The board is resolved afresh by parse_arguments, whatever the environment says.
fresh
BOARD_RESOLVED=yes on opi5plus aarch64 eval "parse_arguments -w $wallet --mode eco; BASE_DIR='$w/base' REPO_NAME=Monero-miner-setup POOL_URL=gulf.moneroocean.stream PORT=10128 PASS=rig1 DEFAULT_PASS=x \
  DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false; generate_config_files"
want "reset" "board lines" 1 "$(count '^\[INFO\] Board:')"
# A profile name is 1 to 16 lower case letters and digits.
for name in RK3588 abcdefghijklmnopq; do
  sed "s/^rk3588\./$name./" "$root/scripts/board_profiles.conf" > "$w/data.conf"; fresh "$w/data.conf"; gen opi5plus aarch64 75 MODE=eco
  want "name $name" exit 1 "$code"; want "name $name" "error lines" "$no_profile_line" "$(printf '%s\n' "$out" | grep '^\[ERROR\]')"
done
# under 2560 MiB of total memory a new config gets RandomX's light mode; the huge page line.
mem() { # new fixture, base fixture, MemTotal kB, optional Hugepagesize kB, optional nr_hugepages
  rm -rf "$w/fx/$1"; cp -R "$w/fx/$2" "$w/fx/$1"
  { printf 'MemTotal:       %s kB\n' "$3"; [ -z "$4" ] || printf 'Hugepagesize:   %s kB\n' "$4"; } > "$w/fx/$1/meminfo"
  [ -z "$5" ] || printf '%s\n' "$5" > "$w/fx/$1/hp"
}
# genb: the main step, then the config generator, as the installer runs them.
genb() { # fixture, arch, share, assignments
  on "$1" "$2" eval "BASE_DIR='$w/base' REPO_NAME=Monero-miner-setup POOL_URL=gulf.moneroocean.stream PORT=10128 PASS=rig1 DEFAULT_PASS=x \
    WALLET=$wallet MAX_THREADS=$3 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false $4; check_board; generate_config_files"
}
floor="[WARNING] This host has 1983 MiB of memory, under the 2560 MiB RandomX's fast mode needs: new configs use its light mode, slower but within memory."
modeof() { jq -r .randomx.mode "$clone/configs/$1" 2>/dev/null; }
for case in "pi5 aarch64" "opi5plus aarch64" "x86 x86_64"; do
  read -r fx arch <<< "$case"
  mem big "$fx" 16777216; mem small "$fx" 2030592
  fresh; genb big "$arch" 75; want "16 GiB $fx" exit 0 "$code"; want "16 GiB $fx" warnings "" "$(wl)"
  mkdir -p "$w/ref"; cp "$clone/configs/config.json" "$w/ref/a"; cp "$clone/configs/config_background.json" "$w/ref/b"
  want "16 GiB $fx" mode auto "$(modeof config.json)"
  fresh; genb small "$arch" 75; want "1983 MiB $fx" exit 0 "$code"
  want "1983 MiB $fx" warning "$floor" "$(wl)"
  for name in config.json config_background.json; do
    want "1983 MiB $fx $name" mode light "$(modeof "$name")"
    ref=a; [ "$name" = config.json ] || ref=b
    want "1983 MiB $fx $name" diff '<     "mode": "auto",
>     "mode": "light",' "$(diff "$w/ref/$ref" "$clone/configs/$name" | grep '^[<>]')"
  done
done
# The edge: 2560 MiB is fast mode, one kB less is light.
mem edge pi5 2621440; fresh; genb edge aarch64 75
want "2560 MiB" mode auto "$(modeof config.json)"; want "2560 MiB" warnings "" "$(wl)"
mem edge pi5 2621439; fresh; genb edge aarch64 75
want "2621439 kB" mode light "$(modeof config.json)"; want "2621439 kB" warning "[WARNING] This host has 2559 MiB of memory, under the 2560 MiB RandomX's fast mode needs: new configs use its light mode, slower but within memory." "$(wl)"
# A figure with a leading zero is a decimal number.
fresh; on pi5 aarch64 eval "total_mem_mib() { echo 02560; }; BASE_DIR='$w/base' REPO_NAME=Monero-miner-setup POOL_URL=gulf.moneroocean.stream PORT=10128 PASS=rig1 DEFAULT_PASS=x \
  WALLET=$wallet MAX_THREADS=75 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false; check_board; generate_config_files"
want "leading zero" mode auto "$(modeof config.json)"; want "leading zero" warnings "" "$(wl)"
# No meminfo: nothing is known, the config is v0.1.1's.
fresh; on pi5 aarch64 eval "MEMINFO=/nonexistent; BASE_DIR='$w/base' REPO_NAME=Monero-miner-setup POOL_URL=gulf.moneroocean.stream PORT=10128 PASS=rig1 DEFAULT_PASS=x \
  WALLET=$wallet MAX_THREADS=75 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false; check_board; generate_config_files"
want "no meminfo" mode auto "$(modeof config.json)"; want "no meminfo" warnings "" "$(wl)"
# x86 at 16 GiB: the config is byte for byte the one written with no memory figure.
fresh; gen x86 x86_64 75; cp "$clone/configs/config.json" "$w/ref/x86"
mem big x86 16777216; fresh; genb big x86_64 75
cmp -s "$w/ref/x86" "$clone/configs/config.json" || fail "x86 at 16 GiB: config.json differs"
# Only the "mode" line of "randomx" changes, not one of another object.
fresh; sed 's/^  "cpu": {$/  "cpu": {\n    "mode": "x",/' "$clone/templates/config.json.template" > "$w/t.json" && cp "$w/t.json" "$clone/templates/config.json.template"
mem small pi5 2030592; genb small aarch64 75
want "other mode line" "cpu mode" x "$(jq -r .cpu.mode "$clone/configs/config.json" 2>/dev/null)"
want "other mode line" "randomx mode" light "$(modeof config.json)"
# A kept config: the warning is printed, the file is not touched.
fresh; mkdir -p "$clone/configs"; printf '{"x": 1}\n' > "$clone/configs/config.json"; cp "$clone/configs/config.json" "$w/kept.json"
genb small aarch64 100; want "kept, small" exit 0 "$code"; want "kept, small" warning "$floor" "$(wl)"
cmp -s "$w/kept.json" "$clone/configs/config.json" || fail "kept, small: the config changed"
want "kept, small" "new config" light "$(modeof config_background.json)"

# the line, from Hugepagesize and nr_hugepages; nothing is written.
hp() { printf '%s\n' "$out" | grep '^\[INFO\] Huge pages'; }
mem hp pi5 16777216; fresh; genb hp aarch64 75
want "huge pages pi5" line "[INFO] Huge pages: none (kernel)." "$(hp)"
mem hp opi5plus 16777216 2048 0; printf '0\n' > "$w/fx/hp/hp"; cp "$w/fx/hp/hp" "$w/hp.before"
fresh; genb hp aarch64 75
want "huge pages 2 MB" line "[INFO] Huge pages: 0 of the 1280 2 MB pages RandomX needs are reserved." "$(hp)"
cmp -s "$w/hp.before" "$w/fx/hp/hp" || fail "huge pages 2 MB: nr_hugepages changed"
mem hp opi5plus 16777216 2048 1000; fresh; genb hp aarch64 75
want "huge pages 1000" line "[INFO] Huge pages: 1000 of the 1280 2 MB pages RandomX needs are reserved." "$(hp)"
mem hp opi5plus 16777216 2048 abc; fresh; genb hp aarch64 75
want "huge pages unreadable count" line "[INFO] Huge pages: 0 of the 1280 2 MB pages RandomX needs are reserved." "$(hp)"
mem hp opi5plus 16777216 2048; fresh; genb hp aarch64 75
want "huge pages no count file" line "[INFO] Huge pages: 0 of the 1280 2 MB pages RandomX needs are reserved." "$(hp)"
want "huge pages no count file" "shell error lines" "" "$(printf '%s\n' "$out" | grep -F "$w/fx/hp/hp")"
mem hp opi5plus 16777216 32768 0; fresh; genb hp aarch64 75
want "huge pages 32 MB" line "[INFO] Huge pages: 0 of the 80 32 MB pages RandomX needs are reserved." "$(hp)"
mem hp opi5plus 2030592 2048 0; fresh; genb hp aarch64 75
want "huge pages light" line "[INFO] Huge pages: 0 of the 128 2 MB pages RandomX needs are reserved." "$(hp)"
for case in "other aarch64" "x86 x86_64"; do
  read -r fx arch <<< "$case"
  mem hp "$fx" 16777216 2048 0; fresh; genb hp "$arch" 75
  want "huge pages $fx" line "" "$(hp)"
done

# A kept-config line with only the background config kept; every config kept under --mode prints the kept-config line and no CPU-fit line.
fresh; mkdir -p "$clone/configs"; printf '{}\n' > "$clone/configs/config_background.json"; chk eco
want "kept background only" warning "$kept_line" "$(wl)"
fresh; mkdir -p "$clone/configs"; printf '{}\n' > "$clone/configs/config.json"; printf '{}\n' > "$clone/configs/config_background.json"
gen vendor-numbering aarch64 75 MODE=eco; want "all kept, eco" exit 0 "$code"
want "all kept, eco" "CPU-fit lines" 0 "$(count 'CPUs\|does not fit')"
genb vendor-numbering aarch64 75 MODE=eco
want "all kept, eco, main step" warnings "$kept_line" "$(wl)"
# The fallback never names more CPUs than the host allows.
allowed opi-0-1 opi5plus 0-1
fresh; gen opi-0-1 aarch64 75 MODE=eco; want "two CPUs, eco" exit 0 "$code"
want "two CPUs, eco" rx '"rx": [0, 1],' "$(rxs config.json)"
want "two CPUs, eco" warnings "[WARNING] CPUs 4, 5, 6, 7 of the eco list are not ones this installer may run on: left out.
[WARNING] The eco list of profile rk3588 does not fit this host's CPUs: mining on 2 CPUs chosen by capacity instead." "$(wl)"
[ "$rc" -eq 0 ] && echo "PASS board-profiles"
exit "$rc"
