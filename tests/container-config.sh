#!/bin/bash
# The container checks the wallet (from its variable or the secret file), worker name, pool,
# donation level, threads percentage, forced thread count and pause flags before it writes the
# miner's config; a value that breaks its rule stops it with one error line and starts nothing. The
# config holds each accepted value exactly, as one JSON string, number or boolean, and replaces the
# old one whole: a failed write leaves no config and starts nothing. The entrypoint is sourced and
# run against a fixture config directory, with a stub xmrig that records its arguments and the
# config it was given; PATH holds only the stub and tool-link directories. Nothing mines.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/bin" "$w/tools"
for t in cat chmod cp jq mkdir mktemp mv rm; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
cat > "$w/bin/xmrig" <<STUB
#!/bin/bash
PATH="$w/bin:$w/tools"
echo "\$*" > "$w/xmrig.args"
cp "$w/configs/config.json" "$w/xmrig.config" 2>/dev/null
STUB
printf '#!/bin/bash\necho 2\n' > "$w/bin/nproc"
# The pool check is answered "unreachable" without a network.
printf '#!/bin/bash\nexit 1\n' > "$w/bin/timeout"
chmod +x "$w/bin/xmrig" "$w/bin/nproc" "$w/bin/timeout"
wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge
# The rules hold in a UTF-8 locale too, where a letter range may take in accented letters.
utf8=$(locale -a 2>/dev/null | grep -iE '^(c|en_us)\.utf-?8$' | head -1)

# run <name> [VAR=value...]: the entrypoint with that environment. Sets out, err, code, config.
run() {
  local name=$1; shift
  rm -rf "$w/configs" "$w/xmrig.args" "$w/xmrig.config"
  mkdir -p "$w/configs"
  [ -z "${OLD_CONFIG:-}" ] || printf '%s\n' "$OLD_CONFIG" > "$w/configs/config.json"
  env -i PATH="$w/bin:$w/tools" ${utf8:+LC_ALL=$utf8} "$@" "$BASH" -c '
    source "$1/docker/entrypoint.sh"
    XMRIG_BIN=$2/bin/xmrig CONFIG_DIR=$2/configs WALLET_SECRET=$2/secret
    main' entrypoint "$root" "$w" > "$w/out" 2> "$w/err"
  code=$?
  out=$(sed 's/\x1b\[[0-9;]*m//g' "$w/out") err=$(sed 's/\x1b\[[0-9;]*m//g' "$w/err")
  config=$(cat "$w/xmrig.config" 2>/dev/null)
}
want() { # name, label, expected, got
  [ "$3" = "$4" ] || { echo "FAIL $1: $2"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'; rc=1; }
}
picked() { # the values the config holds, one line
  printf '%s\n' "$config" | jq -c '{url: .pools[0].url, user: .pools[0].user, pass: .pools[0].pass,
    donate: ."donate-level", hint: .cpu."max-threads-hint", forced: .cpu."*",
    battery: ."pause-on-battery", active: ."pause-on-active", pools: (.pools | length)}'
}
refused() { # name, error line, VAR=value...
  local name=$1 line=$2; shift 2
  run "$name" WALLET_ADDRESS="$wallet" "$@"
  want "$name" exit 1 "$code"
  want "$name" stderr "[  ERROR  ] $line" "$err"
  [ ! -e "$w/xmrig.args" ] || fail "$name: the miner started"
  [ -z "$(ls -A "$w/configs")" ] || fail "$name: a config was written: $(ls -A "$w/configs" | tr '\n' ' ')"
}

# The defaults.
run defaults WALLET_ADDRESS="$wallet"
want defaults exit 0 "$code"
want defaults args "--config=$w/configs/config.json --verbose" "$(cat "$w/xmrig.args" 2>/dev/null)"
want defaults values "{\"url\":\"gulf.moneroocean.stream:10001\",\"user\":\"$wallet\",\"pass\":\"docker_miner\",\"donate\":0,\"hint\":75,\"forced\":null,\"battery\":false,\"active\":false,\"pools\":1}" "$(picked)"
want defaults mode "-rw-r--r--" "$(ls -l "$w/configs/config.json" | cut -c1-10)"
want defaults "config dir" "config.json" "$(ls -A "$w/configs")"

# Values at the edges of their rules arrive exactly, each as its own JSON type.
run edges WALLET_ADDRESS="$wallet.Rig42" WORKER_NAME="rig@home:1+a.b-c_d" POOL_URL="stratum+ssl://pool.example.com:443" \
  DONATE_LEVEL=5 MAX_THREADS_PERCENT=100 FORCE_THREAD_COUNT=3 PAUSE_ON_BATTERY=true PAUSE_ON_ACTIVE=true
want edges exit 0 "$code"
want edges values "{\"url\":\"stratum+ssl://pool.example.com:443\",\"user\":\"$wallet.Rig42\",\"pass\":\"rig@home:1+a.b-c_d\",\"donate\":5,\"hint\":100,\"forced\":{\"threads\":3,\"affinity\":-1},\"battery\":true,\"active\":true,\"pools\":1}" "$(picked)"
# A scheme before a pool without a port still gets the port.
run scheme WALLET_ADDRESS="$wallet" POOL_URL="stratum+tcp://gulf.moneroocean.stream"
want scheme url '"stratum+tcp://gulf.moneroocean.stream:10001"' "$(printf '%s\n' "$config" | jq -c '.pools[0].url')"
# The wallet from the secret file, its final newline dropped.
printf '%s\n' "$wallet" > "$w/secret"
run secret
want secret exit 0 "$code"
want secret user "\"$wallet\"" "$(printf '%s\n' "$config" | jq -c '.pools[0].user')"
rm -f "$w/secret"
run no-wallet
want no-wallet exit 1 "$code"
want no-wallet stderr "[  ERROR  ] WALLET_ADDRESS environment variable is required" "$err"

# Each rule, broken: one error line naming the variable, nothing written, nothing started.
wline="Invalid wallet: 95 or 106 base58 characters starting with 4 or 8, then optionally one '.' and 1 to 64 letters or digits."
for bad in "$wallet." "$wallet.a.b" "$wallet\",\"url\":\"evil" "${wallet}0" "${wallet:0:94}" "$wallet.$(printf 'a%.0s' {1..65})" "3${wallet:1}"; do
  refused "wallet $bad" "$wline" WALLET_ADDRESS="$bad"
done
wnline="WORKER_NAME must be 1 to 64 letters, digits or . _ - @ : + characters."
for bad in 'x","url":"evil' 'a b' 'a}' "rigé" "$(printf 'a%.0s' {1..65})" 'a$b' 'a/b'; do
  refused "worker $bad" "$wnline" WALLET_ADDRESS="$wallet" WORKER_NAME="$bad"
done
pline="POOL_URL must be a host name or IPv4 address, optionally after stratum+tcp:// or stratum+ssl:// and before a :port from 1 to 65535."
for bad in 'a;b' 'pool:0' 'pool:65536' 'pool:' '-pool' 'pool-' 'http://pool' 'stratum+tcp://' 'pool:80:80' 'po ol' 'pool","x":"y'; do
  refused "pool $bad" "$pline" WALLET_ADDRESS="$wallet" POOL_URL="$bad"
done
for bad in 6 -1 abc 1.5 05x; do refused "donate '$bad'" "DONATE_LEVEL must be a whole number from 0 to 5." DONATE_LEVEL="$bad"; done
for bad in 0 101 x 50%; do refused "percent $bad" "MAX_THREADS_PERCENT must be a whole number from 1 to 100." MAX_THREADS_PERCENT="$bad"; done
for bad in 0 1025 x ' 2'; do refused "forced '$bad'" "FORCE_THREAD_COUNT must be empty or a whole number from 1 to 1024." FORCE_THREAD_COUNT="$bad"; done
for bad in True 1 '}' 'false,'; do
  refused "battery $bad" "PAUSE_ON_BATTERY must be true or false." PAUSE_ON_BATTERY="$bad"
  refused "active $bad" "PAUSE_ON_ACTIVE must be true or false." PAUSE_ON_ACTIVE="$bad"
done
# An empty donation level is the default, not an error: the variable set to nothing.
run donate-unset WALLET_ADDRESS="$wallet" DONATE_LEVEL=
want donate-unset exit 0 "$code"

# A config from an earlier start is replaced whole.
OLD_CONFIG='{"old": true}' run replaced WALLET_ADDRESS="$wallet"
want replaced old null "$(printf '%s\n' "$config" | jq -c '.old')"
want replaced "config dir" "config.json" "$(ls -A "$w/configs")"
# A failed write: the jq run stops part way, or the rename fails. No config, no temporary file,
# the miner not started, one error line, exit 1; an earlier config stays as it was.
printf '#!/bin/bash\nprintf "{"\nexit 5\n' > "$w/bin/jq"
chmod +x "$w/bin/jq"
OLD_CONFIG='{"old": true}' run jq-fails WALLET_ADDRESS="$wallet"
want jq-fails exit 1 "$code"
want jq-fails stderr "[  ERROR  ] Could not write the miner's config in $w/configs." "$err"
want jq-fails "config dir" "config.json" "$(ls -A "$w/configs")"
want jq-fails "old config" '{"old": true}' "$(cat "$w/configs/config.json")"
[ ! -e "$w/xmrig.args" ] || fail "jq-fails: the miner started"
rm -f "$w/bin/jq"
printf '#!/bin/bash\nexit 1\n' > "$w/bin/mv"
chmod +x "$w/bin/mv"
run mv-fails WALLET_ADDRESS="$wallet"
want mv-fails exit 1 "$code"
want mv-fails "config dir" "" "$(ls -A "$w/configs")"
[ ! -e "$w/xmrig.args" ] || fail "mv-fails: the miner started"
rm -f "$w/bin/mv"
[ "$rc" -eq 0 ] && echo "PASS container-config"
exit "$rc"
