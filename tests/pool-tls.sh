#!/bin/bash
# The native installer mines to MoneroOcean over TLS by default, with MoneroOcean's certificate
# pinned: a MoneroOcean host with no port gets the TLS port (20000 + the power of two the CPUs give),
# stratum+tcp:// or a typed plain port opts out with a warning line, any other URL is written as
# given, and a fingerprint the user passes pins any TLS pool and is refused without TLS. A config
# kept from before says it mines in clear. The functions are taken from scripts/install.sh and run
# on the real templates; PATH holds only the tool-link directory. Nothing is cloned, built,
# installed or reached over the network.
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
fns="usage is_arm64 ranked_cpus arm_cpu_list pick_cpu_list board_compatible board_model profile_value find_profile expand_cpus profile_ok profile_status total_mem_mib mode_cpu_list configs_exist huge_page_line resolve_board validate_wallet is_wallet is_worker_name is_pool is_fingerprint is_moneroocean pool_settings parse_arguments write_miner_config generate_config_files"
{
  sed -n '/^# ===== Constants =====$/,/^DOCKER_SCRIPT_URL=/p' "$root/scripts/install.sh"
  for f in $fns; do sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/install.sh"; done
} > "$w/functions.sh"
for f in $fns; do grep -qx "function $f() {" "$w/functions.sh" || fail "no function $f in scripts/install.sh"; done
wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge
pin=239daadd5c7d0ac097376c7871f787738826eef1c024729eff870e473b970855
mine=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff

# on <function> <args...>: one function from install.sh, in a subshell. Sets out, code.
on() {
  ( PATH="$w/tools"
    info() { echo "[INFO] $1"; }; success() { echo "[SUCCESS] $1"; }; warning() { echo "[WARNING] $1"; }
    error() { echo "[ERROR] $1"; return 1; }; txt() { echo "$1"; }
    # shellcheck source=/dev/null
    source "$w/functions.sh"
    DT_COMPATIBLE=/nonexistent DT_MODEL=/nonexistent MEMINFO=/nonexistent NR_HUGEPAGES=/nonexistent
    "$@" ) > "$w/out" 2>&1
  code=$?
  out=$(cat "$w/out")
}
want() { # name, label, expected, got
  [ "$3" = "$4" ] || { echo "FAIL $1: $2"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'; rc=1; }
}
settings() { pool_settings "$1" 10128 && echo "$POOL_WRITTEN $POOL_TLS ${POOL_PIN:-none}"; }
parsed() { parse_arguments "$@" && echo "${TLS_FINGERPRINT:-none}"; }

# The pool written for each pool given, its TLS flag and its pin (port computed as 10128 today).
while read -r given fp expected; do
  [ "$fp" != - ] || fp=""
  TLS_FINGERPRINT=$fp on settings "$given"
  want "pool $given ${fp:+pinned}" written "$expected" "$out"
done <<ROWS
gulf.moneroocean.stream - stratum+ssl://gulf.moneroocean.stream:20128 true $pin
GULF.MoneroOcean.Stream - stratum+ssl://GULF.MoneroOcean.Stream:20128 true $pin
de.moneroocean.stream - stratum+ssl://de.moneroocean.stream:20128 true $pin
moneroocean.stream - stratum+ssl://moneroocean.stream:20128 true $pin
stratum+ssl://gulf.moneroocean.stream - stratum+ssl://gulf.moneroocean.stream:20128 true $pin
stratum+ssl://gulf.moneroocean.stream:20064 - stratum+ssl://gulf.moneroocean.stream:20064 true $pin
stratum+tcp://gulf.moneroocean.stream - stratum+tcp://gulf.moneroocean.stream:10128 false none
gulf.moneroocean.stream:10128 - gulf.moneroocean.stream:10128 false none
moneroocean.example.com - moneroocean.example.com false none
stratum+ssl://moneroocean.stream.example.com:443 - stratum+ssl://moneroocean.stream.example.com:443 true none
stratum+ssl://xmoneroocean.stream:443 - stratum+ssl://xmoneroocean.stream:443 true none
pool.example.com - pool.example.com false none
stratum+ssl://pool.example.com:443 - stratum+ssl://pool.example.com:443 true none
stratum+ssl://pool.example.com:443 $mine stratum+ssl://pool.example.com:443 true $mine
gulf.moneroocean.stream $mine stratum+ssl://gulf.moneroocean.stream:20128 true $mine
ROWS
# A fingerprint on a pool written without TLS is refused.
tline="[ERROR] --tls-fingerprint needs a TLS pool: give it after stratum+ssl://, or a MoneroOcean host with no port."
for given in pool.example.com:3333 stratum+tcp://gulf.moneroocean.stream gulf.moneroocean.stream:10128 pool.example.com; do
  on parse_arguments -w "$wallet" --pool "$given" --tls-fingerprint "$mine"
  want "pin without tls $given" exit 1 "$code"
  want "pin without tls $given" output "$tline" "$out"
done

# --tls-fingerprint takes 64 hex digits or openssl's colon form, written lower case without colons.
on parsed -w "$wallet" --tls-fingerprint 23:9D:AA:DD:5C:7D:0A:C0:97:37:6C:78:71:F7:87:73:88:26:EE:F1:C0:24:72:9E:FF:87:0E:47:3B:97:08:55
want "colon form" fingerprint "$pin" "$out"
on parsed -w "$wallet" --tls-fingerprint "$(printf %s "$mine" | tr a-f A-F)"
want "upper case" fingerprint "$mine" "$out"
on parsed -w "$wallet"
want "no flag" fingerprint none "$out"
fline="[ERROR] --tls-fingerprint must be a sha256 of 64 hex digits, with or without a colon between each pair."
for bad in "${mine:1}" "${mine}0" "g${mine:1}" "${pin:0:2}:${pin:2}" '"},"url":"evil' "$mine;id" ''; do
  on parse_arguments -w "$wallet" --tls-fingerprint "$bad"
  want "fingerprint $bad" exit 1 "$code"
  want "fingerprint $bad" output "$fline" "$out"
done

# gen <label> <pool> [fingerprint]: both configs generated into a fresh clone at $w/<label>.
gen() {
  mkdir -p "$w/$1/Monero-miner-setup/templates"
  cp "$root"/templates/config*.template "$w/$1/Monero-miner-setup/templates/"
  ( BASE_DIR="$w/$1" REPO_NAME=Monero-miner-setup POOL_URL=$2 TLS_FINGERPRINT=${3:-} PORT=10128 PASS=rig1 DEFAULT_PASS=x \
      WALLET=$wallet MAX_THREADS=75 DONATE_LEVEL=0 PAUSE_ON_BATTERY=false PAUSE_ON_ACTIVE=false
    on generate_config_files
    [ "$code" -eq 0 ] || echo "FAIL generate $1: exit $code: $out"
    printf '%s\n' "$out" ) > "$w/$1.out"
  grep '^FAIL' "$w/$1.out" && rc=1
}
pool0() { jq -c '.pools[0] | [.url, .tls, ."tls-fingerprint"]' "$w/$1/Monero-miner-setup/configs/$2" 2>&1; }
gen default gulf.moneroocean.stream
gen clear stratum+tcp://gulf.moneroocean.stream
gen own stratum+ssl://pool.example.com:443 "$mine"
gen port gulf.moneroocean.stream:10128
gen other pool.example.com:3333
for name in config.json config_background.json; do
  want "default $name" pool "[\"stratum+ssl://gulf.moneroocean.stream:20128\",true,\"$pin\"]" "$(pool0 default "$name")"
  want "clear $name" pool '["stratum+tcp://gulf.moneroocean.stream:10128",false,null]' "$(pool0 clear "$name")"
  want "own $name" pool "[\"stratum+ssl://pool.example.com:443\",true,\"$mine\"]" "$(pool0 own "$name")"
  # Nothing but the pool's url, tls and fingerprint differs between TLS and clear text (the log
  # path names each fixture's own clone).
  rest() { jq -S 'del(.pools[0].url, .pools[0].tls, .pools[0]."tls-fingerprint", ."log-file")' "$w/$1/Monero-miner-setup/configs/$name" 2>&1; }
  want "only the pool differs $name" config "$(rest clear)" "$(rest default)"
  want "one pool $name" count 1 "$(jq '.pools | length' "$w/default/Monero-miner-setup/configs/$name" 2>&1)"
done
want "default line" log "[INFO] Using pool stratum+ssl://gulf.moneroocean.stream:20128 over TLS, certificate pinned." \
  "$(grep -F 'Using pool' "$w/default.out")"
# MoneroOcean in clear warns, with the flags that move the same worker to TLS; another pool does not.
while read -r label form; do
  want "clear line $form" log "[WARNING] Using pool $form on MoneroOcean without TLS. To switch to TLS, run 'make clean-configs', the installer again with '--pool gulf.moneroocean.stream --name rig1' and the other flags you gave it, then 'make service-setup' and 'make restart'." \
    "$(grep -F 'Using pool' "$w/$label.out")"
done <<ROWS
clear stratum+tcp://gulf.moneroocean.stream:10128
port gulf.moneroocean.stream:10128
ROWS
want "other clear line" log "[INFO] Using pool pool.example.com:3333 without TLS." "$(grep -F 'Using pool' "$w/other.out")"

# A config kept from before that mines on MoneroOcean in clear says so, with the flags that keep its
# pool and worker name (a worker name of "x" has no flag: the installer would draw a new one); a
# TLS one does not.
for url in gulf.moneroocean.stream:10128 stratum+tcp://gulf.moneroocean.stream:10128 stratum+ssl://gulf.moneroocean.stream:20128; do
  rm -rf "$w/kept"; mkdir -p "$w/kept/Monero-miner-setup/configs"
  for kept in config.json:my_rig config_background.json:x; do
    printf '{\n  "pools": [\n    {\n      "url": "%s",\n      "pass": "%s",\n      "tls": false\n    }\n  ]\n}\n' "$url" "${kept#*:}" > "$w/kept/Monero-miner-setup/configs/${kept%%:*}"
  done
  gen kept gulf.moneroocean.stream
  got=$(grep -F 'without TLS' "$w/kept.out")
  case $url in
    stratum+ssl://*) want "kept $url" warning "" "$got" ;;
    *) want "kept $url" warning "[WARNING] $w/kept/Monero-miner-setup/configs/config.json mines on MoneroOcean without TLS. To switch to TLS, run 'make clean-configs', the installer again with '--pool gulf.moneroocean.stream --name my_rig' and the other flags you gave it, then 'make service-setup' and 'make restart'.
[WARNING] $w/kept/Monero-miner-setup/configs/config_background.json mines on MoneroOcean without TLS. To switch to TLS, run 'make clean-configs', the installer again with '--pool gulf.moneroocean.stream' and the other flags you gave it, then 'make service-setup' and 'make restart'." "$got" ;;
  esac
done
# An edit that replaced the clone root's link with a file is the config the miner reads: it warns too.
rm -rf "$w/root"; mkdir -p "$w/root/Monero-miner-setup"
printf '{\n  "pools": [\n    {\n      "url": "stratum+tcp://gulf.moneroocean.stream:10128",\n      "pass": "my_rig",\n      "tls": false\n    }\n  ]\n}\n' > "$w/root/Monero-miner-setup/config.json"
gen root gulf.moneroocean.stream
want "kept clone root config.json" warning "[WARNING] $w/root/Monero-miner-setup/config.json mines on MoneroOcean without TLS. To switch to TLS, run 'make clean-configs', the installer again with '--pool gulf.moneroocean.stream --name my_rig' and the other flags you gave it, then 'make service-setup' and 'make restart'." \
  "$(grep -F 'without TLS' "$w/root.out")"

# One pin everywhere: the installer's constant and both templates.
want constant pin "MONEROOCEAN_FINGERPRINT=\"$pin\"" "$(grep '^MONEROOCEAN_FINGERPRINT=' "$root/scripts/install.sh")"
for name in config.json config_background.json; do
  want "template $name" pin "[\"stratum+ssl://gulf.moneroocean.stream:20128\",true,\"$pin\"]" \
    "$(jq -c '.pools[0] | [.url, .tls, ."tls-fingerprint"]' "$root/templates/$name.template" 2>&1)"
done
[ "$rc" -eq 0 ] && echo "PASS pool-tls"
exit "$rc"
