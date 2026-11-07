#!/bin/bash
# The value rules are one set: the native installer, the Docker installer and the container hold
# the same wallet, worker name and pool rules, function for function, and each accepts and refuses
# the same values, run here from each script in a UTF-8 locale where one exists.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
fail() { echo "FAIL $*"; rc=1; }
scripts="scripts/install.sh scripts/docker_setup.sh docker/entrypoint.sh"
utf8=$(locale -a 2>/dev/null | grep -iE '^(c|en_us)\.utf-?8$' | head -1)
fn() { sed -n "/^function $2() {\$/,/^}\$/p" "$1"; }
for f in is_wallet is_worker_name is_pool; do
  first=$(fn scripts/install.sh "$f")
  [ -n "$first" ] || fail "scripts/install.sh has no $f"
  for s in scripts/docker_setup.sh docker/entrypoint.sh; do
    [ "$(fn "$s" "$f")" = "$first" ] || fail "$s: $f differs from scripts/install.sh's"
  done
done
[ -n "$(fn docker/entrypoint.sh is_whole_number)" ] \
  && [ "$(fn scripts/docker_setup.sh is_whole_number)" = "$(fn docker/entrypoint.sh is_whole_number)" ] \
  || fail "is_whole_number differs between the Docker installer and the container"

wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge
long=8$(printf 'B%.0s' {1..105})
a64=$(printf 'a%.0s' {1..64}) a65=$(printf 'a%.0s' {1..65})
host253=$(printf 'h%.0s' {1..253}) host254=$(printf 'h%.0s' {1..254})
# rule, verdict (yes|no), value
table() {
  cat <<TABLE
is_wallet yes $wallet
is_wallet yes $long
is_wallet yes $wallet.Rig42
is_wallet yes $wallet.$a64
is_wallet no $wallet.$a65
is_wallet no $wallet.
is_wallet no $wallet.a.b
is_wallet no $wallet.a-b
is_wallet no ${wallet}0
is_wallet no ${wallet:0:94}
is_wallet no 3${wallet:1}
is_wallet no 4${wallet:2}O
is_worker_name yes docker_miner
is_worker_name yes rig@home:1+a.b-c_d
is_worker_name yes $a64
is_worker_name no $a65
is_worker_name no a#b
is_worker_name no rigé
is_worker_name no a"b
is_worker_name no a\\b
is_pool yes gulf.moneroocean.stream
is_pool yes gulf.moneroocean.stream:10128
is_pool yes stratum+tcp://10.0.0.2:3333
is_pool yes stratum+ssl://pool.example.com:65535
is_pool yes a
is_pool yes $host253
is_pool no $host254
is_pool no pool:0
is_pool no pool:65536
is_pool no pool:
is_pool no -pool
is_pool no pool.
is_pool no http://pool
is_pool no stratum+tcp://
is_pool no stratum+tcp://stratum+tcp://pool
is_pool no pool:80:80
is_pool no pool;b
is_pool no pool#e
TABLE
}
for s in $scripts; do
  defs=$(for f in is_wallet is_worker_name is_pool; do fn "$s" "$f"; done)
  while read -r rule verdict value; do
    if env -i ${utf8:+LC_ALL=$utf8} "$BASH" -c "$defs"$'\n''"$1" "$2"' rules "$rule" "$value"; then got=yes; else got=no; fi
    [ "$got" = "$verdict" ] || fail "$s: $rule '$value' gave $got"
  done < <(table)
  # Values no table line can hold: empty, and with a space or a newline.
  for rule in is_wallet is_worker_name is_pool; do
    for value in '' 'a b' $'a\nb'; do
      env -i "$BASH" -c "$defs"$'\n''"$1" "$2"' rules "$rule" "$value" && fail "$s: $rule accepts '$value'"
    done
  done
done
[ "$rc" -eq 0 ] && echo "PASS value-rules"
exit "$rc"
