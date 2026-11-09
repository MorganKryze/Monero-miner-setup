#!/bin/bash
# The container sizes the miner to what it may use: without a forced count, the threads
# percentage of its CPU quota (cgroup v2 or v1; without one, its online CPUs), rounded up, at least
# 1, at most the quota rounded up and at most xmrig's own count, read from a start of xmrig that is
# stopped before it hashes; a forced count is used as is. It prints the count and how it was
# reached, and picks the MoneroOcean port from it. Under 2560 MiB of usable memory (the lower of
# its limit and the host's available memory, plus free huge pages) it mines in RandomX light mode
# and warns. The entrypoint is sourced and run against fixture cgroup and meminfo files, with a stub
# xmrig; PATH holds only the stub and tool-link directories. Nothing mines.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/bin" "$w/tools" "$w/tmp"
for t in awk cat chmod cp jq mkdir mktemp mv rm seq sleep; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
# The stub xmrig: started for its own count (an offline benchmark in light mode), it saves the
# profile FIX_OWN asks for into the config it was given, as xmrig does, and waits to be stopped;
# started to mine, it records its arguments and config.
cat > "$w/bin/xmrig" <<STUB
#!/bin/bash
PATH="$w/bin:$w/tools"
case " \$* " in
  *" --bench=1M "*)
    echo "\$*" >> "$w/probe.log"
    cfg=\${1#--config=}
    if [ -n "\${FIX_OWN:-}" ]; then
      jq --argjson n "\$FIX_OWN" '.cpu.rx = [range(\$n)]' "\$cfg" > "\$cfg.new" && mv "\$cfg.new" "\$cfg"
    fi
    echo \$\$ > "$w/probe.pid"
    exec sleep 30 ;;
esac
echo "\$*" > "$w/xmrig.args"
cp "$w/configs/config.json" "$w/xmrig.config"
STUB
printf '#!/bin/bash\necho "${FIX_NPROC:-8}"\n' > "$w/bin/nproc"
printf '#!/bin/bash\nexit 1\n' > "$w/bin/timeout"
chmod +x "$w/bin/xmrig" "$w/bin/nproc" "$w/bin/timeout"
wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge

# cgroup <v2|v1> <cpu> <memory>: the fixture cgroup files ("" leaves a file out).
cgroup() {
  rm -rf "$w/cgroup"; mkdir -p "$w/cgroup/cpu" "$w/cgroup/memory"
  case $1 in
    v2) [ -z "$2" ] || echo "$2" > "$w/cgroup/cpu.max"; [ -z "$3" ] || echo "$3" > "$w/cgroup/memory.max" ;;
    v1) [ -z "$2" ] || { echo "${2% *}" > "$w/cgroup/cpu/cpu.cfs_quota_us"; echo "${2#* }" > "$w/cgroup/cpu/cpu.cfs_period_us"; }
        [ -z "$3" ] || echo "$3" > "$w/cgroup/memory/memory.limit_in_bytes" ;;
  esac
}
meminfo() { # available kB, free huge pages, huge page kB ("" leaves the file out)
  rm -f "$w/meminfo"
  [ -z "$1" ] || printf 'MemTotal:       16000000 kB\nMemAvailable:   %s kB\nHugePages_Free:   %s\nHugepagesize:    %s kB\n' "$1" "${2:-0}" "${3:-2048}" > "$w/meminfo"
}
# run <name> [VAR=value...]: the entrypoint with that environment. Sets out, code, config.
run() {
  local name=$1 start; shift
  rm -rf "$w/configs" "$w/xmrig.args" "$w/xmrig.config" "$w/probe.log" "$w/probe.pid"
  mkdir -p "$w/configs"
  start=$SECONDS
  env -i PATH="$w/bin:$w/tools" TMPDIR="$w/tmp" WALLET_ADDRESS="$wallet" "$@" "$BASH" --norc --noprofile -c '
    source "$1/docker/entrypoint.sh"
    XMRIG_BIN=$2/bin/xmrig CONFIG_DIR=$2/configs CGROUP_DIR=$2/cgroup MEMINFO=$2/meminfo
    main' entrypoint "$root" "$w" > "$w/out" 2>&1
  code=$?
  out=$(sed 's/\x1b\[[0-9;]*m//g' "$w/out")
  config=$(cat "$w/xmrig.config" 2>/dev/null)
  [ "$code" -eq 0 ] || fail "$name: exit $code: $out"
  [ $((SECONDS - start)) -lt 10 ] || fail "$name: took $((SECONDS - start)) s"
  [ -z "$(ls -A "$w/tmp")" ] || fail "$name: left $(ls -A "$w/tmp")"
  if [ -s "$w/probe.pid" ] && kill -0 "$(cat "$w/probe.pid")" 2>/dev/null; then
    fail "$name: the xmrig started for its own count is still running"
    kill "$(cat "$w/probe.pid")"
  fi
}
want() { # name, label, expected, got
  [ "$3" = "$4" ] || { echo "FAIL $1: $2"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'; rc=1; }
}
threads() { printf '%s\n' "$config" | jq -c '[.cpu."*".threads, .pools[0].url]'; }
says() { printf '%s\n' "$out" | grep -qxF -- "$2" || fail "$1: no line '$2'"; }
mode() { printf '%s\n' "$config" | jq -r '.randomx.mode'; }

meminfo 8000000
# percentage, cpu line (v2), online CPUs, xmrig's own count: threads, port, the line saying how.
while IFS='|' read -r name pct cpu nproc own count port how; do
  cgroup v2 "$cpu" ""
  FIX_OWN=$own FIX_NPROC=$nproc run "$name" MAX_THREADS_PERCENT="$pct" FIX_OWN="$own" FIX_NPROC="$nproc"
  want "$name" threads "[$count,\"gulf.moneroocean.stream:$port\"]" "$(threads)"
  says "$name" "[  INFO   ] Mining with $count threads: $pct% of $how, rounded up, at most xmrig's own count of $own."
done <<'TABLE'
quota 2, 75%|75|200000 100000|8|8|2|10016|its CPU quota of 2.00 CPUs
no quota, 50% of 8|50|max 100000|8|8|4|10032|its 8 online CPUs
quota 2, 25%|25|200000 100000|8|8|1|10001|its CPU quota of 2.00 CPUs
xmrig's own count caps|75|max 100000|8|3|3|10032|its 8 online CPUs
quota 1.5, 75%|75|150000 100000|8|8|2|10016|its CPU quota of 1.50 CPUs
quota 0.5, 100%|100|50000 100000|8|8|1|10001|its CPU quota of 0.50 CPUs
quota 4, 100%|100|400000 100000|8|8|4|10032|its CPU quota of 4.00 CPUs
quota 3.3, 100%|100|330000 100000|8|8|4|10032|its CPU quota of 3.30 CPUs
TABLE
# The xmrig started for its own count: an offline benchmark in light mode, on a config of its own.
[ "$(grep -c . "$w/probe.log")" -eq 1 ] && grep -qxE -- "--config=$w/tmp/xmrig-count\.[A-Za-z0-9]+/config\.json --bench=1M --randomx-mode=light --no-color" "$w/probe.log" \
  || fail "probe arguments: $(cat "$w/probe.log")"
# A leading zero is a whole number in base ten, not an octal one.
cgroup v2 "200000 100000" ""
FIX_OWN=8 run leading-zero MAX_THREADS_PERCENT=075 FIX_OWN=8
want leading-zero threads '[2,"gulf.moneroocean.stream:10016"]' "$(threads)"
says leading-zero "[  INFO   ] Mining with 2 threads: 75% of its CPU quota of 2.00 CPUs, rounded up, at most xmrig's own count of 8."
# cgroup v1, and v1 without a quota.
cgroup v1 "300000 100000" ""
FIX_OWN=8 run v1 MAX_THREADS_PERCENT=50 FIX_OWN=8
want v1 threads '[2,"gulf.moneroocean.stream:10016"]' "$(threads)"
cgroup v1 "-1 100000" ""
FIX_OWN=8 run v1-none MAX_THREADS_PERCENT=50 FIX_NPROC=6 FIX_OWN=8
want v1-none threads '[3,"gulf.moneroocean.stream:10032"]' "$(threads)"
# A forced count is used as is, and xmrig is not started for its own count.
cgroup v2 "200000 100000" ""
run forced FORCE_THREAD_COUNT=5 FIX_OWN=2
want forced threads '[5,"gulf.moneroocean.stream:10064"]' "$(threads)"
says forced "[  INFO   ] Mining with 5 threads, forced by FORCE_THREAD_COUNT."
[ ! -e "$w/probe.log" ] || fail "forced: xmrig was started for its own count"
# xmrig's own count unreadable: the uncapped count, one warning.
run no-count MAX_THREADS_PERCENT=75
want no-count threads '[2,"gulf.moneroocean.stream:10016"]' "$(threads)"
says no-count "[ WARNING ] Could not read xmrig's own thread count: mining with 2 threads, 75% of its CPU quota of 2.00 CPUs, rounded up, without that cap."

# Memory: limit (v2 or v1), available kB, free huge pages: the mode, and the warning under 2560 MiB.
cgroup v2 "" ""
light="under the 2560 MiB RandomX's fast mode needs: mining in light mode, at a fraction of the hashrate. Give it more memory (MEMORY_LIMIT in docker/.env, or --memory), such as 3g."
while IFS='|' read -r name version limit avail pages want_mode mib; do
  cgroup "$version" "" "$limit"
  meminfo "$avail" "$pages"
  FIX_OWN=8 run "memory $name" FIX_OWN=8
  want "memory $name" mode "$want_mode" "$(mode)"
  if [ "$want_mode" = light ]; then
    says "memory $name" "[ WARNING ] This container can use $mib MiB, $light"
  else
    printf '%s\n' "$out" | grep -q 'light mode' && fail "memory $name: warned"
  fi
done <<'TABLE'
3g|v2|3221225472|8000000|0|auto|
1g|v2|1073741824|8000000|0|light|1024
2560 MiB|v2|2684354560|8000000|0|auto|
2559 MiB|v2|2683305984|8000000|0|light|2559
no limit, low host|v2|max|2000000|0|light|1953
1g plus huge pages|v2|1073741824|8000000|768|auto|
1g plus too few huge pages|v2|1073741824|8000000|767|light|2558
v1 1g|v1|1073741824|8000000|0|light|1024
v1 no limit|v1|9223372036854771712|4000000|0|auto|
nothing readable|v2|||0|auto|
TABLE
[ "$rc" -eq 0 ] && echo "PASS container-sizing"
exit "$rc"
