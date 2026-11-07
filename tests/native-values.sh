#!/bin/bash
# The native installer accepts a pool, a worker name and a wallet suffix only by the value rules,
# with one error line and exit 1 otherwise, and writes each setting into the miner's configs as one
# JSON value holding exactly what was passed: never a command built from it (a pool that made GNU
# sed run `touch` through its `e` flag is refused, and written as plain text when it reaches the
# writer). The functions are taken from scripts/install.sh and run on the real templates; PATH
# holds only the tool-link directory. Nothing is cloned, built or installed.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/tools"
for t in awk cat cp cut ln mkdir mv rm; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
command -v jq >/dev/null || { echo "FAIL no jq on this host"; exit 1; }
fns="usage validate_wallet is_wallet is_worker_name is_pool parse_arguments write_miner_config generate_config_files"
{
  sed -n '/^# ===== Constants =====$/,/^DOCKER_SCRIPT_URL=/p' "$root/scripts/install.sh"
  for f in $fns; do sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/install.sh"; done
} > "$w/functions.sh"
for f in $fns; do grep -qx "function $f() {" "$w/functions.sh" || fail "no function $f in scripts/install.sh"; done
wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge
exploit='x";touch${IFS}'"$w"'/pwned;#e;s#x#'

# on <function> <args...>: one function from install.sh, in a subshell. Sets out, code.
on() {
  ( PATH="$w/tools"
    info() { echo "[INFO] $1"; }; success() { echo "[SUCCESS] $1"; }; warning() { echo "[WARNING] $1"; }
    error() { echo "[ERROR] $1"; return 1; }; txt() { echo "$1"; }
    # shellcheck source=/dev/null
    source "$w/functions.sh"
    "$@" ) > "$w/out" 2>&1
  code=$?
  out=$(cat "$w/out")
}
want() { # name, label, expected, got
  [ "$3" = "$4" ] || { echo "FAIL $1: $2"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'; rc=1; }
}

# --pool and --name, refused by their rules before anything else runs.
pline="[ERROR] --pool must be a host name or IPv4 address, optionally after stratum+tcp:// or stratum+ssl:// and before a :port from 1 to 65535."
for bad in "$exploit" 'a;b' 'pool:0' 'pool:65536' 'http://pool' 'po ol' '-pool'; do
  on parse_arguments -w "$wallet" --pool "$bad"
  want "pool $bad" exit 1 "$code"
  want "pool $bad" output "$pline" "$out"
done
nline="[ERROR] --name must be 1 to 64 letters, digits or . _ - @ : + characters."
for bad in 'a b' 'x","url":"evil' 'a#b' 'a/b' 'rig&1' "$(printf 'a%.0s' {1..65})"; do
  for flag in --name --pass; do
    on parse_arguments -w "$wallet" "$flag" "$bad"
    want "$flag $bad" exit 1 "$code"
    want "$flag $bad" output "$nline" "$out"
  done
done
for good in gulf.moneroocean.stream stratum+ssl://pool.example.com:443 10.0.0.2:3333; do
  on parse_arguments -w "$wallet" --pool "$good" --name "rig@home:1+a.b-c_d"
  want "pool $good" exit 0 "$code"
done
[ ! -e "$w/pwned" ] || fail "a value ran as a command"

# The wallet's suffix: nothing, or one '.' and 1 to 64 letters and digits.
wline="[ERROR] Invalid wallet: 95 or 106 base58 characters starting with 4 or 8, then optionally one '.' and 1 to 64 letters or digits."
for bad in "$wallet." "$wallet.a.b" "$wallet.a\"b" "$wallet.a-b" "$wallet.$(printf 'a%.0s' {1..65})"; do
  on validate_wallet "$bad"
  want "wallet $bad" exit 1 "$code"
  want "wallet $bad" "last line" "$wline" "$(printf '%s\n' "$out" | tail -1)"
done
on validate_wallet "$wallet.Rig42"
want "wallet suffix" exit 0 "$code"

# The writer: the eight settings, exactly, as JSON values, every other line of the template as it
# was. A log path holding a quote, a backslash and an ampersand stays one JSON string. The last
# key of the template has no comma and is filled in too.
log="$w/we\"ird\\&dir/logs/xmrig.log"
for name in config.json config_background.json; do
  ( WALLET="$wallet.Rig42" MAX_THREADS=42 DONATE_LEVEL=3 PAUSE_ON_BATTERY=true PAUSE_ON_ACTIVE=true
    on write_miner_config "$root/templates/$name.template" "$w/$name" "$log" "stratum+ssl://pool.example.com:443" "rig@home:1+a.b-c_d"
    [ "$code" -eq 0 ] || echo "FAIL $name: writer exit $code: $out" ) | grep . && rc=1
  got=$(jq -c '[.cpu."max-threads-hint", ."donate-level", ."log-file", .pools[0].url, .pools[0].user, .pools[0].pass, ."pause-on-battery", ."pause-on-active"]' "$w/$name" 2>&1)
  want "$name" values "[42,3,$(printf '%s' "$log" | jq -Rc .),\"stratum+ssl://pool.example.com:443\",\"$wallet.Rig42\",\"rig@home:1+a.b-c_d\",true,true]" "$got"
  rest() { jq -S 'del(.cpu."max-threads-hint", ."donate-level", ."log-file", .pools[0].url, .pools[0].user, .pools[0].pass, ."pause-on-battery", ."pause-on-active")' "$1"; }
  want "$name" "other settings" "$(rest "$root/templates/$name.template")" "$(rest "$w/$name")"
  want "$name" "lines" "$(wc -l < "$root/templates/$name.template")" "$(wc -l < "$w/$name")"
done
# The exploit, handed to the writer directly: plain text in the config, nothing run.
( WALLET="$wallet" MAX_THREADS=75 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false
  on write_miner_config "$root/templates/config.json.template" "$w/exploit.json" "$w/logs/xmrig.log" "$exploit" "$exploit" )
want exploit url "$(printf '%s' "$exploit" | jq -Rc .)" "$(jq -c '.pools[0].url' "$w/exploit.json" 2>&1)"
want exploit pass "$(printf '%s' "$exploit" | jq -Rc .)" "$(jq -c '.pools[0].pass' "$w/exploit.json" 2>&1)"
[ ! -e "$w/pwned" ] || fail "exploit: the value ran as a command"
# A MoneroOcean pool given with no scheme or stratum+tcp:// and no port gets the computed port.
for pool in gulf.moneroocean.stream stratum+tcp://gulf.moneroocean.stream; do
  rm -rf "$w/home"; mkdir -p "$w/home/Monero-miner-setup/templates"
  cp "$root"/templates/config*.template "$w/home/Monero-miner-setup/templates/"
  ( BASE_DIR="$w/home" REPO_NAME=Monero-miner-setup POOL_URL=$pool PORT=10128 PASS=x DEFAULT_PASS=x \
      WALLET=$wallet MAX_THREADS=75 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false
    on generate_config_files
    [ "$code" -eq 0 ] || echo "FAIL generate $pool: exit $code: $out" ) | grep . && rc=1
  want "generate $pool" url "\"$pool:10128\"" "$(jq -c '.pools[0].url' "$w/home/Monero-miner-setup/configs/config.json" 2>&1)"
done
# A TLS MoneroOcean URL with no port is kept as given: the computed port is a plain TCP one.
rm -rf "$w/home"; mkdir -p "$w/home/Monero-miner-setup/templates"
cp "$root"/templates/config*.template "$w/home/Monero-miner-setup/templates/"
( BASE_DIR="$w/home" REPO_NAME=Monero-miner-setup POOL_URL=stratum+ssl://gulf.moneroocean.stream PORT=10128 PASS=x DEFAULT_PASS=x \
    WALLET=$wallet MAX_THREADS=75 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false
  on generate_config_files
  [ "$code" -eq 0 ] || echo "FAIL generate tls: exit $code: $out" ) | grep . && rc=1
want "generate tls" url '"stratum+ssl://gulf.moneroocean.stream"' "$(jq -c '.pools[0].url' "$w/home/Monero-miner-setup/configs/config.json" 2>&1)"
# A config that cannot be written stops the generator with one error line.
rm -rf "$w/home"; mkdir -p "$w/home/Monero-miner-setup/templates" "$w/home/Monero-miner-setup/configs"
cp "$root"/templates/config*.template "$w/home/Monero-miner-setup/templates/"
chmod 555 "$w/home/Monero-miner-setup/configs"
( BASE_DIR="$w/home" REPO_NAME=Monero-miner-setup POOL_URL=gulf.moneroocean.stream PORT=10128 PASS=x DEFAULT_PASS=x \
    WALLET=$wallet MAX_THREADS=75 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false
  on generate_config_files
  [ "$code" -eq 1 ] || echo "FAIL unwritable: exit $code"
  printf '%s\n' "$out" | grep -qxF "[ERROR] Failed to write $w/home/Monero-miner-setup/configs/config.json." \
    || echo "FAIL unwritable: no error line: $out" ) | grep . && rc=1
chmod 755 "$w/home/Monero-miner-setup/configs"
# A config whose write fails leaves nothing behind, so the next run does not keep it as written.
rm -rf "$w/home"; mkdir -p "$w/home/Monero-miner-setup/templates"
cp "$root"/templates/config.json.template "$w/home/Monero-miner-setup/templates/"
( BASE_DIR="$w/home" REPO_NAME=Monero-miner-setup POOL_URL=gulf.moneroocean.stream PORT=10128 PASS=x DEFAULT_PASS=x \
    WALLET=$wallet MAX_THREADS=75 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false
  on generate_config_files
  [ "$code" -eq 1 ] || echo "FAIL failed write: exit $code" ) | grep . && rc=1
want "failed write" "configs left" "config.json" "$(cd "$w/home/Monero-miner-setup/configs" && ls -A)"
[ "$rc" -eq 0 ] && echo "PASS native-values"
exit "$rc"
