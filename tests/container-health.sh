#!/bin/bash
# The container's miner logs only to its output, and its healthcheck reads the miner process: no
# miner process is unhealthy; a first check, or one after the miner restarted under another PID,
# is healthy and saves the reading; CPU time that grew since the last check is healthy; no new CPU
# time is healthy when a pause flag lets the miner pause or when it holds no established TCP
# connection (IPv4 or IPv6), and unhealthy only when it is connected, not paused and idle. The
# healthcheck is sourced and run against a fixture /proc tree and config, with a stub pgrep; PATH
# holds only the stub and tool-link directories. The miner's config names no log file, and
# neither the image nor the compose file has a log directory; compose rotates the miner's output
# (json-file, 3 x 10 MB) and keeps the config directory in a named volume, not a bind mount.
# Nothing runs but the healthcheck.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/bin" "$w/tools"
for t in jq readlink; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
# The stub pgrep: the oldest process named exactly xmrig is FIX_PID, or none without it.
cat > "$w/bin/pgrep" <<STUB
#!/bin/bash
PATH="$w/bin:$w/tools"
[ "\$*" = "-xo xmrig" ] || { echo "pgrep stub: unexpected arguments \$*" >&2; exit 2; }
[ -n "\${FIX_PID:-}" ] || exit 1
echo "\$FIX_PID"
STUB
chmod +x "$w/bin/pgrep"

# proc <pid> <utime> <stime> <tcp state|-> <tcp6 state|->: a fixture process. Its name holds a
# space and a ')' as a comm may; one socket (inode 4242) is matched in the tcp table given a state,
# another (4343) in the tcp6 one; other entries are sockets or files of no interest.
proc() {
  local d="$w/proc/$1"
  rm -rf "$d"; mkdir -p "$d/fd" "$d/net"
  echo "$1 (xm rig) x) S 1 $1 $1 0 -1 4194560 100 0 0 0 $2 $3 0 0 20 0 9 0 50 1000 200 18446744073709551615" > "$d/stat"
  ln -s /dev/null "$d/fd/0"
  ln -s 'socket:[4242]' "$d/fd/7"
  ln -s 'socket:[4343]' "$d/fd/8"
  ln -s 'pipe:[4242]' "$d/fd/9"
  {
    echo '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
    echo '   0: 0100007F:0CEA 00000000:0000 0A 00000000:00000000 00:00000000 00000000   999        0 4141 1 0000000000000000 100 0 0 10 0'
    [ "$4" = - ] || echo "   1: 0100007F:9C40 0100007F:0D05 $4 00000000:00000000 00:00000000 00000000   999        0 4242 1 0000000000000000 20 4 30 10 -1"
    echo '   2: 0100007F:9C41 0100007F:0D05 01 00000000:00000000 00:00000000 00000000   999        0 9999 1 0000000000000000 20 4 30 10 -1'
  } > "$d/net/tcp"
  {
    echo '  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
    [ "$5" = - ] || echo '   0: 00000000000000000000000001000000:9C42 00000000000000000000000001000000:0D05 '"$5"' 00000000:00000000 00:00000000 00000000   999        0 4343 1 0000000000000000 20 4 30 10 -1'
  } > "$d/net/tcp6"
}
config() { # pause-on-battery, pause-on-active
  jq -n --argjson b "$1" --argjson a "$2" '{"log-file": null, "pause-on-battery": $b, "pause-on-active": $a}' > "$w/config.json"
}
# check <name> <want exit> <want line> [VAR=value...]: one healthcheck run with that environment.
check() {
  local name=$1 code_want=$2 line_want=$3 out code; shift 3
  out=$(env -i PATH="$w/bin:$w/tools" "$@" "$BASH" --norc --noprofile -c '
    source "$1/docker/healthcheck.sh"
    PROC_DIR=$2/proc CONFIG=$2/config.json STATE=$2/state
    main' healthcheck "$root" "$w" 2>&1)
  code=$?
  [ "$out" = "$line_want" ] || fail "$name: printed '$out', not '$line_want'"
  [ "$code" -eq "$code_want" ] || fail "$name: exit $code, not $code_want"
}
state() { # name, the whole state file wanted
  local got; got=$(cat "$w/state" 2>/dev/null)
  [ "$got" = "$2" ] || fail "$1: state file '$got', not '$2'"
}
first='Healthy: first check since the miner started.'
mining='Healthy: mining.'
paused='Healthy: idle, and its pause flags let it pause.'
nopool='Healthy: waiting for its pool.'
stuck='Unhealthy: connected to its pool, not paused, and no CPU time since the last check.'

config false false
# No miner process.
rm -f "$w/state"
check gone 1 'Unhealthy: the miner process is gone.'
[ ! -e "$w/state" ] || fail "gone: wrote a state file"
# Two consecutive checks of a connected miner: the first one saves its reading, the second sees
# the CPU time grow (utime 300 + stime 45 = 345, then 360).
proc 321 300 45 01 -
check first 0 "$first" FIX_PID=321
state first '321 345'
proc 321 310 50 01 -
check mining 0 "$mining" FIX_PID=321
state mining '321 360'
# No new CPU time, connected over IPv4, not paused.
check stuck 1 "$stuck" FIX_PID=321
state stuck '321 360'
# The same over IPv6 only.
proc 321 310 50 - 01
check stuck-tcp6 1 "$stuck" FIX_PID=321
# A pause flag lets it pause.
config true false
check paused-battery 0 "$paused" FIX_PID=321
config false true
check paused-active 0 "$paused" FIX_PID=321
config false false
# Its sockets are not established (SYN_SENT, TIME_WAIT), or it has none in either table.
proc 321 310 50 02 06
check no-pool 0 "$nopool" FIX_PID=321
proc 321 310 50 - -
check no-pool-none 0 "$nopool" FIX_PID=321
# Another PID: the miner restarted, so the old reading is no measure, even with fewer ticks.
proc 654 10 5 01 -
check restarted 0 "$first" FIX_PID=654
state restarted '654 15'
# A state file holding something else is no reading.
echo 'garbage' > "$w/state"
check bad-state 0 "$first" FIX_PID=654
state bad-state '654 15'

# The miner's log goes to the container's output only.
entry=docker/entrypoint.sh
got=$(env -i PATH="$w/tools" "$BASH" --norc --noprofile -c 'source "$1"; jq -n --arg url u --arg user u --arg pass p --argjson donate 0 --argjson hint 75 --argjson threads 1 --arg mode auto --argjson battery false --argjson active false "$CONFIG_TEMPLATE" | jq -c "[has(\"log-file\"), .\"log-file\"]"' entry "$root/$entry" 2>&1)
[ "$got" = '[true,null]' ] || fail "$entry: log-file is $got, not [true,null]"
for f in docker/compose.yml docker/compose.vpn.yml docker/Dockerfile "$entry"; do
  [ "$(grep -c '/app/logs' "$f")" -eq 0 ] || fail "$f: names /app/logs"
done
# compose keeps the config directory in its named volume, and binds nothing onto /app.
c=docker/compose.yml
got=$(sed -n '/^    volumes:$/,/^$/p' "$c")
[ "$got" = "$(printf '%s\n' '    volumes:' '      - xmrig-configs:/app/configs' '')" ] \
  || fail "$c: the service's volumes are '$got'"
got=$(sed -n '/^volumes:$/,$p' "$c")
[ "$got" = "$(printf '%s\n' 'volumes:' '  xmrig-configs:')" ] || fail "$c: the top-level volumes are '$got'"
# compose rotates the miner's output, the only bound on its log: three files of 10 MB.
got=$(sed -n '/^    logging:$/,/^$/p' "$c")
[ "$got" = "$(printf '%s\n' '    logging:' '      driver: json-file' '      options:' \
  '        max-size: "10m"' '        max-file: "3"' '')" ] || fail "$c: the service's logging is '$got'"
for f in docker/compose.yml docker/compose.vpn.yml; do
  bad=$(grep -nE '^[[:space:]]*-[[:space:]]*["'\'']?[.~/$][^:]*:/app' "$f")
  [ -z "$bad" ] || fail "$f: a bind mount onto /app: $bad"
done
[ "$rc" -eq 0 ] && echo "PASS container-health"
exit "$rc"
