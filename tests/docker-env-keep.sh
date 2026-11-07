#!/bin/bash
# A re-run of the Docker installer keeps docker/.env and docker/.env.vpn byte for byte, mode and
# all, with one line each naming --overwrite-env, and asks for no VPN secret it does not need; a
# kept file others can read gets a warning and stays as it is. --overwrite-env rewrites the files
# this run writes, and only those. A new file is mode 600 from its first byte and replaces the old
# one whole: a failed write leaves the old one, or none, and one error line. The installer runs from
# a fixture checkout with a stub docker; PATH holds only the stub and tool-link directories.
# Nothing is pulled, built or started.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/bin" "$w/tools" "$w/repo/docker"
: > "$w/repo/docker/compose.yml"
: > "$w/repo/docker/Dockerfile"
for t in cat chmod cut date dirname head ls mktemp mv rm tr; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
real_mv=$(command -v mv)
# The stub docker answers the two availability checks and records every call.
cat > "$w/bin/docker" <<STUB
#!/bin/bash
PATH="$w/bin:$w/tools"
echo "\$*" >> "$w/docker.log"
case "\$*" in "compose version") exit 0 ;; --version) echo "Docker version stub" ;; *) exit 0 ;; esac
STUB
chmod +x "$w/bin/docker"
wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge
env="$w/repo/docker/.env" vpn="$w/repo/docker/.env.vpn"

# run <name> <args...>: the installer in the fixture checkout. Sets out, err, code.
run() {
  local name=$1; shift
  rm -f "$w/docker.log"
  (cd "$w/repo" && env -i HOME="$w" PATH="$w/bin:$w/tools" ${KEY:+WIREGUARD_PRIVATE_KEY=$KEY} \
    ${ADDR:+WIREGUARD_ADDRESSES=$ADDR} "$BASH" "$root/scripts/docker_setup.sh" "$@") > "$w/out" 2> "$w/err"
  code=$?
  out=$(sed 's/\x1b\[[0-9;]*m//g' "$w/out") err=$(sed 's/\x1b\[[0-9;]*m//g' "$w/err")
  # Only the two availability checks may reach docker, or nothing when the run stops before them.
  case "$(cat "$w/docker.log" 2>/dev/null)" in "" | "compose version"$'\n'"--version") ;; *) fail "$name: docker calls: $(tr '\n' ' ' < "$w/docker.log")" ;; esac
}
want() { # name, label, expected, got
  [ "$3" = "$4" ] || { echo "FAIL $1: $2"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'; rc=1; }
}
has() { # name, stream text, whole line
  printf '%s\n' "$2" | grep -qxF -- "$3" || fail "$1: no line '$3'"
}
mode() { ls -l "$1" | cut -c1-10; }
leftovers() { (cd "$w/repo/docker" && ls -A | grep -vxE 'compose.yml|Dockerfile|\.env|\.env\.vpn' | tr '\n' ' '); }
keep_line() { echo "[  INFO   ] Keeping $1: this run's flags are not applied to it. To rewrite it from them, run again with --overwrite-env."; }

# A first run writes .env, mode 600.
run fresh -w "$wallet" -y --worker-name first
want fresh exit 0 "$code"
want fresh mode "-rw-------" "$(mode "$env")"
has fresh "$out" "[ SUCCESS ] Wrote $env (mode 0600)."
grep -qx 'WORKER_NAME=first' "$env" || fail "fresh: WORKER_NAME=first not written"
cp -p "$env" "$w/env.first"

# A re-run keeps it, whatever its flags say, with one line.
run rerun -w "$wallet" -y --worker-name second
want rerun exit 0 "$code"
cmp -s "$env" "$w/env.first" || fail "rerun: .env changed"
want rerun mode "-rw-------" "$(mode "$env")"
has rerun "$out" "$(keep_line "$env")"
want rerun "keep lines" 1 "$(printf '%s\n' "$out" | grep -c 'Keeping ')"
want rerun stderr "" "$err"

# The wallet is still required and checked on a re-run that keeps the file.
run rerun-no-wallet -y
want rerun-no-wallet exit 1 "$code"
cmp -s "$env" "$w/env.first" || fail "rerun-no-wallet: .env changed"

# A kept file the group or others can read or write: one warning, mode unchanged.
for m in 644:-rw-r--r-- 604:-rw----r-- 606:-rw----rw- 640:-rw-r----- 620:-rw--w----; do
  chmod "${m%%:*}" "$env"
  run "loose-${m%%:*}" -w "$wallet" -y
  want "loose-${m%%:*}" exit 0 "$code"
  want "loose-${m%%:*}" mode "${m#*:}" "$(mode "$env")"
  want "loose-${m%%:*}" stderr "[ WARNING ] $env can be read or changed by other users. Restrict it with: chmod 600 $env" "$err"
  cmp -s "$env" "$w/env.first" || fail "loose-${m%%:*}: .env changed"
done
chmod 600 "$env"

# --overwrite-env rewrites it from this run's flags, with one line naming it.
run overwrite -w "$wallet" -y --worker-name second --overwrite-env
want overwrite exit 0 "$code"
grep -qx 'WORKER_NAME=second' "$env" || fail "overwrite: WORKER_NAME=second not written"
want overwrite mode "-rw-------" "$(mode "$env")"
has overwrite "$out" "[ SUCCESS ] Replaced $env with this run's flags (mode 0600)."
want overwrite leftovers "" "$(leftovers)"

# With a VPN provider: every secret is resolved before the first write, so a missing one leaves
# nothing written; then both files, mode 600.
rm -f "$env"
run vpn-missing -w "$wallet" -y --vpn mullvad
want vpn-missing exit 1 "$code"
[ ! -e "$env" ] && [ ! -e "$vpn" ] || fail "vpn-missing: a file was written before the secrets were in hand"
KEY=wgkey-first ADDR=10.64.0.1/32 run vpn -w "$wallet" -y --vpn mullvad
want vpn exit 0 "$code"
want vpn "mode .env.vpn" "-rw-------" "$(mode "$vpn")"
grep -qx 'WIREGUARD_PRIVATE_KEY=wgkey-first' "$vpn" || fail "vpn: key not written"
cp -p "$vpn" "$w/vpn.first"
cp -p "$env" "$w/env.vpnrun"

# A re-run with the provider keeps .env.vpn and needs no secret at all.
run vpn-rerun -w "$wallet" -y --vpn mullvad
want vpn-rerun exit 0 "$code"
cmp -s "$vpn" "$w/vpn.first" || fail "vpn-rerun: .env.vpn changed"
cmp -s "$env" "$w/env.vpnrun" || fail "vpn-rerun: .env changed"
has vpn-rerun "$out" "$(keep_line "$vpn")"
has vpn-rerun "$out" "$(keep_line "$env")"
want vpn-rerun stderr "" "$err"

# A kept .env.vpn others can read gets the same warning, and only it.
chmod 604 "$vpn"
run vpn-loose -w "$wallet" -y --vpn mullvad
want vpn-loose exit 0 "$code"
want vpn-loose mode "-rw----r--" "$(mode "$vpn")"
want vpn-loose stderr "[ WARNING ] $vpn can be read or changed by other users. Restrict it with: chmod 600 $vpn" "$err"
cmp -s "$vpn" "$w/vpn.first" || fail "vpn-loose: .env.vpn changed"
chmod 600 "$vpn"

# --overwrite-env without a provider leaves .env.vpn as it is.
run overwrite-novpn -w "$wallet" -y --overwrite-env --worker-name third
want overwrite-novpn exit 0 "$code"
cmp -s "$vpn" "$w/vpn.first" || fail "overwrite-novpn: .env.vpn changed"
grep -qx 'WORKER_NAME=third' "$env" || fail "overwrite-novpn: .env not rewritten"
printf '%s\n' "$out" | grep -q "Replaced $vpn" && fail "overwrite-novpn: .env.vpn reported replaced"

# --overwrite-env with the provider rewrites both.
KEY=wgkey-second ADDR=10.64.0.2/32 run overwrite-vpn -w "$wallet" -y --vpn mullvad --overwrite-env
want overwrite-vpn exit 0 "$code"
grep -qx 'WIREGUARD_PRIVATE_KEY=wgkey-second' "$vpn" || fail "overwrite-vpn: key not rewritten"
has overwrite-vpn "$out" "[ SUCCESS ] Replaced $vpn with this run's flags (mode 0600)."
cp -p "$vpn" "$w/vpn.second"
cp -p "$env" "$w/env.second"

# While the secrets file is written it is already mode 600: a stub mv records the new file's mode
# and content just before the rename, under a umask that would give 666.
cat > "$w/bin/mv" <<STUB
#!/bin/bash
PATH="$w/bin:$w/tools"
for a in "\$@"; do case \$a in -*) ;; *) ls -l "\$a" | cut -c1-10 >> "$w/mv.log"; cat "\$a" >> "$w/mv.log"; break ;; esac; done
exec "$real_mv" "\$@"
STUB
chmod +x "$w/bin/mv"
rm -f "$w/mv.log"
(umask 000; KEY=wgkey-third ADDR=10.64.0.3/32 run umask -w "$wallet" -y --vpn mullvad --overwrite-env)
grep -c '^-rw-------$' "$w/mv.log" | grep -qx 2 || fail "umask: a new file was not mode 600 while written: $(grep '^-' "$w/mv.log" | tr '\n' ' ')"
grep -qx 'WIREGUARD_PRIVATE_KEY=wgkey-third' "$w/mv.log" || fail "umask: the stub saw no key"
want umask "mode .env" "-rw-------" "$(mode "$env")"
want umask "mode .env.vpn" "-rw-------" "$(mode "$vpn")"
cp -p "$vpn" "$w/vpn.second"
cp -p "$env" "$w/env.second"

# Only the .env.vpn rename fails: the run still stops, and the old .env.vpn stays byte for byte.
cat > "$w/bin/mv" <<STUB
#!/bin/bash
PATH="$w/bin:$w/tools"
case "\${!#}" in */.env.vpn) exit 1 ;; esac
exec "$real_mv" "\$@"
STUB
chmod +x "$w/bin/mv"
KEY=wgkey-fourth ADDR=10.64.0.4/32 run vpn-mv-fails -w "$wallet" -y --vpn mullvad --overwrite-env
want vpn-mv-fails exit 1 "$code"
cmp -s "$vpn" "$w/vpn.second" || fail "vpn-mv-fails: .env.vpn changed"
want vpn-mv-fails stderr "[  ERROR  ] Could not write $vpn: it is left as it was." "$err"
want vpn-mv-fails leftovers "" "$(leftovers)"
cp -p "$env" "$w/env.second"

# A failed write: the rename fails, the old file stays byte for byte, no temporary file is left,
# one error line, exit 1. Then the same on a fresh host: no file at all.
printf '#!/bin/bash\nexit 1\n' > "$w/bin/mv"
chmod +x "$w/bin/mv"
KEY=wgkey-fourth ADDR=10.64.0.4/32 run mv-fails -w "$wallet" -y --vpn mullvad --overwrite-env --worker-name fourth
want mv-fails exit 1 "$code"
cmp -s "$env" "$w/env.second" || fail "mv-fails: .env changed"
cmp -s "$vpn" "$w/vpn.second" || fail "mv-fails: .env.vpn changed"
want mv-fails stderr "[  ERROR  ] Could not write $env: it is left as it was." "$err"
want mv-fails leftovers "" "$(leftovers)"
rm -f "$env" "$vpn"
run mv-fails-fresh -w "$wallet" -y
want mv-fails-fresh exit 1 "$code"
[ ! -e "$env" ] || fail "mv-fails-fresh: .env exists"
want mv-fails-fresh leftovers "" "$(leftovers)"
rm -f "$w/bin/mv"
printf '#!/bin/bash\nexit 1\n' > "$w/bin/mktemp"
chmod +x "$w/bin/mktemp"
run mktemp-fails -w "$wallet" -y
want mktemp-fails exit 1 "$code"
want mktemp-fails stderr "[  ERROR  ] Could not write $env: it is left as it was." "$err"
[ ! -e "$env" ] || fail "mktemp-fails: .env exists"
rm -f "$w/bin/mktemp"
[ "$rc" -eq 0 ] && echo "PASS docker-env-keep"
exit "$rc"
