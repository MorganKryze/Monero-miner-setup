#!/bin/bash
# make bench-layouts benches each CPU layout of the board profile offline: one XMRig run per layout,
# pinned to its CPUs with taskset, from a throwaway folder holding a config that never saves, with
# no pool and no submit; one result line per layout (CPUs, H/s, huge pages, cpufreq maxima). It
# refuses, with one line and nothing run, when a miner runs, the miner is not built, MODE or BENCH
# is invalid, the host is not arm64 Linux, or taskset or pgrep is missing. The clone's configs and
# logs stay byte for byte as found and the throwaway folders are gone. A stub XMRig that keeps
# running after its result, as the real one does, must not hang the bench. The board functions are
# the installer's, byte for byte. Stubs only; nothing is read from this host's /proc or /sys.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT

for f in board_compatible board_model profile_value find_profile expand_cpus profile_ok profile_status total_mem_mib is_arm64 ranked_cpus; do
  a=$(sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/bench_layouts.sh")
  b=$(sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/install.sh")
  { [ -n "$b" ] && [ "$a" = "$b" ]; } || fail "$f differs between bench_layouts.sh and install.sh"
done

make -n bench-layouts 2>&1 | grep -qxF 'bash ./scripts/bench_layouts.sh' || fail "make -n bench-layouts does not run the script"
[ -f "$root/scripts/bench_layouts.sh" ] || { echo "FAIL no scripts/bench_layouts.sh"; exit 1; }

# Real commands the script needs, linked into the stubs' folder.
mkdir -p "$w/tools"
for c in awk cat cut getconf grep kill mktemp rm sed sleep sort tr uname head tail wc; do
  p=$(command -v "$c") && ln -s "$p" "$w/tools/$c"
done
cat > "$w/tools/xmrig" <<'STUB'
#!/bin/bash
w=${STUB_W:?}
printf '%s\n' "$*" >> "$w/calls"
log=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in -l) log=$2; shift ;; --config=*) cfg=${1#--config=} ;; esac
  shift
done
cat "$cfg" >> "$w/configs.log"
[ -f "$w/noresult" ] && exit 0
{
  echo "[t]  cpu      READY threads 4/4 (4) huge pages 100% 4/4 memory 8192 KB (1 ms)"
  echo "[t]  bench    benchmark finished in 12.500 seconds (321.0 h/s) hash sum = 0"
} > "$log"
[ -f "$w/linger" ] && { echo $$ >> "$w/pids"; exec sleep 300; }
exit 0
STUB
cat > "$w/tools/taskset" <<'STUB'
#!/bin/bash
echo "$1 $2" >> "${STUB_W:?}/calls"
shift 2
exec "$@"
STUB
cat > "$w/tools/pgrep" <<'STUB'
#!/bin/bash
[ -f "${STUB_W:?}/running" ]
STUB
chmod +x "$w/tools/xmrig" "$w/tools/taskset" "$w/tools/pgrep"

# Fake clone with the files the bench must not touch.
mkclone() {
  rm -rf "$w/clone" "$w/before"
  mkdir -p "$w/clone/scripts" "$w/clone/configs" "$w/clone/logs" "$w/before"
  cp "$root/scripts/bench_layouts.sh" "$root/scripts/board_profiles.conf" "$w/clone/scripts/"
  printf '{"autosave": true}\n' > "$w/clone/configs/config.json"
  ln -s configs/config.json "$w/clone/config.json"
  echo "old log" > "$w/clone/logs/xmrig.log"
  ln -s "$w/tools/xmrig" "$w/clone/xmrig"
  cp "$w/clone/scripts/bench_layouts.sh" "$w/clone/scripts/board_profiles.conf" "$w/clone/configs/config.json" "$w/clone/logs/xmrig.log" "$w/before/"
  rm -f "$w/calls" "$w/configs.log" "$w/running" "$w/noresult" "$w/linger" "$w/pids"
}
# fx <name> <MemTotal kB> <compatible> <capacities...>; capacities per cpu, one fixture per board.
fx() {
  local d=$w/$1 i=0 c; mkdir -p "$d/sys" "$d/cpufreq"
  printf 'MemTotal:       %s kB\n' "$2" > "$d/meminfo"
  printf '%s\0' "$3" > "$d/compatible"
  printf 'Model\0' > "$d/model"
  printf 'Cpus_allowed_list:\t0-%s\n' "$(($# - 4))" > "$d/status"
  shift 3
  for c in "$@"; do
    mkdir -p "$d/sys/cpu$i"; echo "$c" > "$d/sys/cpu$i/cpu_capacity"; i=$((i + 1))
  done
}
fx opi5plus 16272000 rockchip,rk3588 1024 1024 1024 1024 1024 1024 1024 1024
fx pi5 2030592 brcm,bcm2712 1024 1024 1024 1024
fx other 16272000 vendor,thing 530 530 530 530 1024 1024 1024 1024
fx same 16272000 vendor,thing 1024 1024 1024 1024
for p in 0:1800000 4:2400000 6:2400000; do
  for b in opi5plus pi5 other same; do
    mkdir -p "$w/$b/cpufreq/policy${p%:*}"; echo "${p#*:}" > "$w/$b/cpufreq/policy${p%:*}/scaling_max_freq"
  done
done
for b in pi5 other same; do rm -rf "$w/$b/cpufreq/policy4" "$w/$b/cpufreq/policy6"; done

# bench <fixture> [VAR=value ...]: runs main; output in $out, status in $code.
bench() {
  local b=$1 d; shift; d=$w/$b
  out=$(env -i PATH="$w/tools" HOME="$w" STUB_W="$w" "$@" "$BASH" --norc --noprofile -c '
    source "$1/scripts/bench_layouts.sh" || exit 1
    OS=${OS_T:-Linux}; HOST_ARCH=${ARCH_T:-aarch64}
    CPU_SYS_DIR=$2/sys PROC_STATUS=$2/status DT_COMPATIBLE=$2/compatible DT_MODEL=$2/model
    MEMINFO=$2/meminfo CPUFREQ_DIR=$2/cpufreq
    main' _ "$w/clone" "$d" 2>&1)
  code=$?
}
has() { printf '%s\n' "$2" | grep -qxF -- "$3" || fail "$1: no line '$3'"; }
hasnt() { ! printf '%s\n' "$2" | grep -qF -- "$3" || fail "$1: unexpected '$3'"; }
# After every case: the clone is as found and no folder named in a --config= argument is left.
after() {
  local f g
  for f in scripts/bench_layouts.sh scripts/board_profiles.conf configs/config.json logs/xmrig.log; do
    cmp -s "$w/clone/$f" "$w/before/${f##*/}" || fail "$1: $f changed"
  done
  [ -L "$w/clone/xmrig" ] || [ "$NOX" = 1 ] || fail "$1: xmrig link gone"
  if [ -f "$w/calls" ]; then
    for g in $(grep -o -- '--config=[^ ]*' "$w/calls" | sed 's/^--config=//; s|/[^/]*$||'); do
      [ ! -e "$g" ] || fail "$1: folder $g left"
    done
    ! grep -qE -- ' -o |--url|--submit|--config=.*clone|-l .*clone' "$w/calls" || fail "$1: pool, submit or clone path in a call"
  fi
  [ "$(printf '%s\n' "$out" | grep -c 'H/s')" -ge 0 ] || true
}
refuse() { # <name> <needle> ; one line, miner never called
  [ "$code" -ne 0 ] || fail "$1: exit 0"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "$1: not one line: $out"
  printf '%s\n' "$out" | grep -qF -- "$2" || fail "$1: no '$2' in: $out"
  [ ! -e "$w/calls" ] || fail "$1: the miner was called"
}

# opi5plus, default mode.
mkclone; bench opi5plus
tail="policy0 1800 MHz, policy4 2400 MHz, policy6 2400 MHz"
n=$(printf '%s\n' "$out" | grep -c 'H/s')
[ "$n" -eq 3 ] || fail "opi5plus: $n result lines"
[ "$(printf '%s\n' "$out" | grep 'H/s' | sed -n 1p)" = "CPUs 0-7: 321.0 H/s, huge pages 100%, $tail" ] || fail "opi5plus: line 1: $out"
[ "$(printf '%s\n' "$out" | grep 'H/s' | sed -n 2p)" = "CPUs 4-7: 321.0 H/s, huge pages 100%, $tail" ] || fail "opi5plus: line 2"
[ "$(printf '%s\n' "$out" | grep 'H/s' | sed -n 3p)" = "CPUs 0,1,4-7: 321.0 H/s, huge pages 100%, $tail" ] || fail "opi5plus: line 3"
[ "$(grep -- '^-c ' "$w/calls" | tr '\n' '|')" = "-c 0-7|-c 4-7|-c 0,1,4-7|" ] || fail "opi5plus: taskset lists"
grep -qF '"autosave": false' "$w/configs.log" || fail "opi5plus: autosave"
grep -qF '"rx": [0, 1, 2, 3, 4, 5, 6, 7]' "$w/configs.log" || fail "opi5plus: rx 0-7"
grep -qF '"rx": [0, 1, 4, 5, 6, 7]' "$w/configs.log" || fail "opi5plus: rx 0,1,4-7"
[ "$(grep -c -- '--bench=250K' "$w/calls")" -eq 3 ] || fail "opi5plus: bench size"
after opi5plus

# eco and BENCH.
mkclone; bench opi5plus MODE=eco BENCH=1M
[ "$(printf '%s\n' "$out" | grep -c 'H/s')" -eq 1 ] || fail "eco: not one line"
printf '%s\n' "$out" | grep -q '^CPUs 4-7: ' || fail "eco: not CPUs 4-7"
grep -qF -- '--bench=1M' "$w/calls" || fail "eco: --bench=1M"
after eco

# Under the floor: light mode, said once.
mkclone; bench pi5
[ "$(printf '%s\n' "$out" | grep -c 'H/s')" -eq 1 ] || fail "pi5: not one line"
printf '%s\n' "$out" | grep -q '^CPUs 0-3: ' || fail "pi5: not CPUs 0-3"
grep -qF -- '--randomx-mode=light' "$w/calls" || fail "pi5: no light mode"
[ "$(printf '%s\n' "$out" | grep -c 'light mode under the 2560 MiB floor')" -eq 1 ] || fail "pi5: light mode note"
printf '%s\n' "$out" | grep 'light mode' | grep -q '^\[  INFO   \]' || fail "pi5: note is not an INFO line"
after pi5
mkclone; bench opi5plus
hasnt big "$(cat "$w/calls")" "light"
after big

# No profile: every usable CPU, then the highest capacity ones.
mkclone; bench other
[ "$(printf '%s\n' "$out" | grep 'H/s' | sed -n 1p | cut -d: -f1)" = "CPUs 0,1,2,3,4,5,6,7" ] || fail "other: line 1: $out"
[ "$(printf '%s\n' "$out" | grep 'H/s' | sed -n 2p | cut -d: -f1)" = "CPUs 4,5,6,7" ] || fail "other: line 2"
[ "$(printf '%s\n' "$out" | grep -c 'H/s')" -eq 2 ] || fail "other: not two lines"
after other
mkclone; bench same
[ "$(printf '%s\n' "$out" | grep -c 'H/s')" -eq 1 ] || fail "same: not one line"
after same

# Refusals.
mkclone; touch "$w/running"; bench opi5plus; refuse running "make stop"; after running
mkclone; rm "$w/clone/xmrig"; NOX=1; bench opi5plus; refuse unbuilt "make build"; after unbuilt; NOX=
mkclone; bench opi5plus MODE=fast; refuse mode "MODE=max|eco"; after mode
mkclone; bench opi5plus ARCH_T=x86_64; refuse arch "make benchmark"; after arch
mkclone; bench opi5plus OS_T=Darwin; refuse darwin "make benchmark"; after darwin
mkclone; bench opi5plus BENCH=3K; refuse size "250K"; after size
mkclone; mv "$w/tools/taskset" "$w/taskset.off"; bench opi5plus; refuse taskset "util-linux"; after taskset; mv "$w/taskset.off" "$w/tools/taskset"
mkclone; mv "$w/tools/pgrep" "$w/pgrep.off"; bench opi5plus; refuse pgrep "procps"; after pgrep; mv "$w/pgrep.off" "$w/tools/pgrep"

# No result line: an error for that layout, the others still run, exit 1.
mkclone; touch "$w/noresult"; bench opi5plus
[ "$code" -eq 1 ] || fail "noresult: exit $code"
[ "$(printf '%s\n' "$out" | grep -c '^\[  ERROR  \]')" -eq 3 ] || fail "noresult: not one error per layout"
[ "$(grep -c -- '^-c ' "$w/calls")" -eq 3 ] || fail "noresult: not every layout ran"
after noresult

# A miner that keeps running after its result must not hang the bench.
mkclone; touch "$w/linger"
env -i PATH="$w/tools" HOME="$w" STUB_W="$w" "$BASH" --norc --noprofile -c '
  source "$1/scripts/bench_layouts.sh" || exit 1
  CPU_SYS_DIR=$2/sys PROC_STATUS=$2/status DT_COMPATIBLE=$2/compatible DT_MODEL=$2/model
  MEMINFO=$2/meminfo CPUFREQ_DIR=$2/cpufreq OS=Linux HOST_ARCH=aarch64
  main' _ "$w/clone" "$w/opi5plus" > "$w/linger.out" 2>&1 &
bp=$!
for _ in $(seq 1 60); do kill -0 "$bp" 2>/dev/null || break; sleep 1; done
if kill -0 "$bp" 2>/dev/null; then
  fail "linger: not finished within 60 s"; pkill -P "$bp" 2>/dev/null; kill "$bp" 2>/dev/null
fi
wait "$bp" 2>/dev/null
out=$(cat "$w/linger.out")
[ "$(printf '%s\n' "$out" | grep -c 'H/s')" -eq 3 ] || fail "linger: not three result lines"
sleep 1
if [ -f "$w/pids" ]; then
  while read -r p; do kill -0 "$p" 2>/dev/null && { fail "linger: stub $p left"; kill "$p"; }; done < "$w/pids"
fi
after linger

[ "$rc" -eq 0 ] && echo "PASS bench-layouts"
exit "$rc"
