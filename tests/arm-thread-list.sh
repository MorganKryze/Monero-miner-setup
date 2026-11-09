#!/bin/bash
# On arm64 the miner puts one thread on every CPU whatever its thread hint, so the native installer
# writes the CPUs to mine on into each new config: ceil(N x share / 100) of the N CPUs the process
# may run on, at least 1, highest capacity first, then highest maximum frequency, then lowest
# number, listed in ascending order under every algorithm the miner generates threads for. On x86
# the configs stay as they were. A config an earlier run left is never rewritten: on arm64, one
# without a list gets one warning line naming the remedy. The CPU-choice functions are the same,
# byte for byte, in scripts/install.sh and docker/entrypoint.sh.
# The functions run against sysfs and status fixtures; PATH holds only the tool-link directory.
# Nothing is cloned, built or installed. Run from the repository root. Prints FAIL lines, exits 1
# on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/tools"
for t in awk cat cmp cp head ln mkdir mv rm sort; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
# getconf answers as a 4-CPU host: the count used when the allowed list cannot be read.
printf '#!/bin/sh\necho 4\n' > "$w/tools/getconf" && chmod +x "$w/tools/getconf"
command -v jq >/dev/null || { echo "FAIL no jq on this host"; exit 1; }

shared="is_arm64 ranked_cpus arm_cpu_list"
fns="$shared pick_cpu_list write_miner_config generate_config_files"
{
  sed -n '/^# ===== Constants =====$/,/^DOCKER_SCRIPT_URL=/p' "$root/scripts/install.sh"
  for f in $fns; do sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/install.sh"; done
} > "$w/functions.sh"
for f in $fns; do grep -qx "function $f() {" "$w/functions.sh" || fail "no function $f in scripts/install.sh"; done
# Each shared function the container's entrypoint holds is the installer's, byte for byte.
for f in $shared; do
  theirs=$(sed -n "/^function $f() {\$/,/^}\$/p" "$root/docker/entrypoint.sh")
  [ -z "$theirs" ] || [ "$theirs" = "$(sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/install.sh")" ] \
    || fail "$f differs between scripts/install.sh and docker/entrypoint.sh"
done

# Fixtures: <name>/sys/cpuN/{cpu_capacity,cpufreq/cpuinfo_max_freq} and <name>/status.
# cpu <fixture> <cpu> <capacity|-> <max freq|->
cpu() {
  mkdir -p "$w/fx/$1/sys/cpu$2/cpufreq"
  [ "$3" = - ] || printf '%s\n' "$3" > "$w/fx/$1/sys/cpu$2/cpu_capacity"
  [ "$4" = - ] || printf '%s\n' "$4" > "$w/fx/$1/sys/cpu$2/cpufreq/cpuinfo_max_freq"
}
allowed() { mkdir -p "$w/fx/$1"; printf 'Name:\tbash\nCpus_allowed:\tff\nCpus_allowed_list:\t%s\n' "$2" > "$w/fx/$1/status"; }
# An RK3588: four little cores, then two big ones binned at 2.4 GHz and two at 2.256 GHz.
for f in rk3588 rk3588-cpuset rk3588-freq; do
  for c in 0 1 2 3; do cpu "$f" "$c" 530 1800000; done
  for c in 4 5; do cpu "$f" "$c" 1024 2400000; done
  for c in 6 7; do cpu "$f" "$c" 1024 2256000; done
done
allowed rk3588 0-7
allowed rk3588-cpuset 2-5
rm -f "$w"/fx/rk3588-freq/sys/cpu*/cpu_capacity; allowed rk3588-freq 0-7
for c in 0 1 2 3; do cpu pi5 "$c" 1024 2400000; done; allowed pi5 0-3
mkdir -p "$w/fx/bare/sys"; allowed bare 0-3
mkdir -p "$w/fx/ranges/sys"; allowed ranges 0,2-3,6
cpu junk 0 x -; cpu junk 1 900 -; cpu junk 2 '' -; cpu junk 3 1e3 -; allowed junk 0-3
for c in 0 1 2 3 4 5; do cpu garbled "$c" - -; done; allowed garbled '0-5;x'
mkdir -p "$w/fx/nostatus/sys"

# on <fixture> <arch> <function> <args...>: one function from install.sh, in a subshell, on the
# fixture's sysfs and status file. Sets out, code.
on() {
  local fx=$1 arch=$2; shift 2
  ( PATH="$w/tools"
    info() { echo "[INFO] $1"; }; success() { echo "[SUCCESS] $1"; }; warning() { echo "[WARNING] $1"; }
    error() { echo "[ERROR] $1"; return 1; }
    # shellcheck source=/dev/null
    source "$w/functions.sh"
    HOST_ARCH=$arch CPU_SYS_DIR="$w/fx/$fx/sys" PROC_STATUS="$w/fx/$fx/status"
    "$@" ) > "$w/out" 2>&1
  code=$?
  out=$(cat "$w/out")
}
want() { # name, label, expected, got
  [ "$3" = "$4" ] || { echo "FAIL $1: $2"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'; rc=1; }
}

for arch in aarch64 arm64; do on bare "$arch" is_arm64; want "is_arm64 $arch" exit 0 "$code"; done
for arch in x86_64 armv7l ""; do on bare "$arch" is_arm64; want "is_arm64 '$arch'" exit 1 "$code"; done

# The ranking: capacity, then maximum frequency, then number, among the allowed CPUs.
rank() { on "$1" aarch64 ranked_cpus; want "ranked_cpus $1" exit 0 "$code"; want "ranked_cpus $1" order "$2" "$(printf '%s' "$out" | tr '\n' ' ')"; }
rank rk3588 "4 5 6 7 0 1 2 3"
rank rk3588-cpuset "4 5 2 3"
rank rk3588-freq "4 5 6 7 0 1 2 3"
rank pi5 "0 1 2 3"
rank bare "0 1 2 3"
rank ranges "0 2 3 6"
rank junk "1 0 2 3"
rank garbled "0 1 2 3"
rank nostatus "0 1 2 3"

# The list: that many of the best CPUs, in ascending order.
list() { on "$1" aarch64 arm_cpu_list "$2"; want "arm_cpu_list $1 $2" exit 0 "$code"; want "arm_cpu_list $1 $2" list "$3" "$out"; }
list rk3588 6 "[0, 1, 4, 5, 6, 7]"
list rk3588 4 "[4, 5, 6, 7]"
list rk3588 2 "[4, 5]"
list rk3588-cpuset 3 "[2, 4, 5]"
list pi5 3 "[0, 1, 2]"
list ranges 2 "[0, 2]"

# The share: ceil(N x share / 100), at least 1, a leading zero read as decimal; nothing on x86.
pick() { # fixture, arch, share, expected
  on "$1" "$2" eval "MAX_THREADS=$3; pick_cpu_list && printf '%s' \"\$CPU_LIST\""
  want "pick_cpu_list $1 $2 $3" exit 0 "$code"; want "pick_cpu_list $1 $2 $3" list "$4" "$out"
}
pick rk3588 aarch64 75 "[0, 1, 4, 5, 6, 7]"
pick rk3588 aarch64 075 "[0, 1, 4, 5, 6, 7]"
pick rk3588 aarch64 050 "[4, 5, 6, 7]"
pick rk3588 aarch64 1 "[4]"
pick rk3588 aarch64 30 "[4, 5, 6]"
pick pi5 aarch64 60 "[0, 1, 2]"
pick rk3588 aarch64 100 "[0, 1, 2, 3, 4, 5, 6, 7]"
pick rk3588-cpuset aarch64 75 "[2, 4, 5]"
pick pi5 aarch64 75 "[0, 1, 2]"
pick nostatus arm64 75 "[0, 1, 2]"
pick rk3588 x86_64 75 ""

wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge
clone="$w/home/Monero-miner-setup"
fresh() { rm -rf "$w/home"; mkdir -p "$clone/templates"; cp "$root"/templates/config*.template "$clone/templates/"; }
# gen <fixture> <arch> <share>: the config generator, as a run of the installer calls it.
gen() {
  on "$1" "$2" eval "BASE_DIR='$w/home' REPO_NAME=Monero-miner-setup POOL_URL=gulf.moneroocean.stream PORT=10128 PASS=rig1 DEFAULT_PASS=x \
    WALLET=$wallet MAX_THREADS=$3 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false; generate_config_files"
  want "generate $*" exit 0 "$code"
}
keys='["argon2","cn","cn-heavy","cn-lite","cn-pico","cn/2","cn/gpu","cn/upx2","flex","panthera","rx","rx/wow"]'
# lists <file>: every algorithm's list, one per line, ghostrider's as its CPU numbers.
lists() { jq -c --argjson k "$keys" '.cpu as $c | ($k[] | $c[.]), ($c.ghostrider | if type == "array" then map(.[1]) else . end)' "$1" 2>&1 | sort -u; }
# rest <file>: the config without the algorithms' lists.
rest() { jq -S --argjson k "$keys" '.cpu |= with_entries(.key as $x | select(($k + ["ghostrider"]) | index([$x]) | not))' "$1"; }
for case in "rk3588 aarch64 75 [0,1,4,5,6,7]" "rk3588 arm64 050 [4,5,6,7]" "rk3588 aarch64 1 [4]" "nostatus arm64 75 [0,1,2]"; do
  read -r fx arch share expected <<< "$case"
  fresh; gen "$fx" x86_64 "$share"
  for name in config.json config_background.json; do rest "$clone/configs/$name" > "$w/x86-$name"; done
  fresh; gen "$fx" "$arch" "$share"
  for name in config.json config_background.json; do
    want "$name $case" lists "$expected" "$(lists "$clone/configs/$name")"
    want "$name $case" ghostrider "$(jq -c 'map([8, .])' <<< "$expected")" "$(jq -c .cpu.ghostrider "$clone/configs/$name" 2>&1)"
    want "$name $case" "other settings" "$(cat "$w/x86-$name")" "$(rest "$clone/configs/$name")"
  done
done
# x86: the configs are what the writer gives with no list, whatever the fixtures say.
fresh; gen rk3588 x86_64 75
for name in config.json config_background.json; do
  want "$name x86_64" "cpu keys" "$(jq -c '.cpu | keys' "$root/templates/$name.template")" "$(jq -c '.cpu | keys' "$clone/configs/$name" 2>&1)"
  want "$name x86_64" lines "$(wc -l < "$root/templates/$name.template")" "$(wc -l < "$clone/configs/$name")"
done
want "generate x86_64" warnings "" "$(printf '%s\n' "$out" | grep '^\[WARNING\]')"

# A kept config is never rewritten. On arm64 one with no list gets one warning line.
kline="[WARNING] --threads does not apply to the kept configs: they hold no CPU list, so the miner runs on every CPU. To apply it, run 'make clean-configs', the installer again, then 'make service-setup'."
fresh; gen rk3588 x86_64 75
cp "$clone/configs/config.json" "$w/kept.json"
gen rk3588 aarch64 75
cmp -s "$w/kept.json" "$clone/configs/config.json" || fail "kept arm64: the config was rewritten"
want "kept arm64" warnings "$kline" "$(printf '%s\n' "$out" | grep '^\[WARNING\]')"
gen rk3588 x86_64 75
want "kept x86_64" warnings "" "$(printf '%s\n' "$out" | grep '^\[WARNING\]')"
fresh; gen rk3588 aarch64 75
cp "$clone/configs/config.json" "$w/kept.json"
gen rk3588 aarch64 50
cmp -s "$w/kept.json" "$clone/configs/config.json" || fail "kept arm64 with a list: the config was rewritten"
want "kept arm64 with a list" warnings "" "$(printf '%s\n' "$out" | grep '^\[WARNING\]')"
[ "$rc" -eq 0 ] && echo "PASS arm-thread-list"
exit "$rc"
