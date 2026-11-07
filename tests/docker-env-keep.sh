#!/bin/bash
# A re-run of the Docker installer keeps docker/.env and docker/.env.vpn byte for byte, mode and
# all, with one line each naming --overwrite-env, and asks for no VPN secret it does not need; a
# kept file others can read gets a warning and stays as it is, one another user owns or can change
# stops the run. --overwrite-env rewrites the files
# this run writes, and only those. A new file is mode 600 from its first byte and replaces the old
# one whole: a failed write leaves the old one, or none, and one error line. A copy of the installer
# runs from its own scratch clone with a stub docker; PATH holds only the stub and tool-link
# directories. Nothing is pulled, built or started, and the repository's docker/ stays as it was.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
: > "$w/stamp"
# The fixture clone holds a copy of this tree's installer: the installer uses only the clone it
# sits in, so a run of the repository's own copy would write into the repository's docker/.
mkdir -p "$w/bin" "$w/tools" "$w/repo/docker" "$w/repo/scripts" "$w/repo/.git"
: > "$w/repo/docker/compose.yml"
: > "$w/repo/docker/Dockerfile"
cp "$root/scripts/docker_setup.sh" "$w/repo/scripts/docker_setup.sh"
chmod 755 "$w/repo" "$w/repo/docker"
chmod 644 "$w/repo/docker/compose.yml" "$w/repo/docker/Dockerfile"
for t in cat chmod cut date dirname find head ls mktemp mv rm tr uname; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
real_mv=$(command -v mv) me=$(id -un) real_id=$(command -v id)
# The user's primary group is a shared one, unless ID_MODE=private says it is their own, as Ubuntu
# gives each user.
cat > "$w/bin/id" <<STUB
#!/bin/bash
case \$* in
  -gn) if [ "\${ID_MODE:-shared}" = private ]; then echo "$me"; else echo shared-group; fi ;;
  *) exec "$real_id" "\$@" ;;
esac
STUB
# OTHER_OWNS=<file>: find's owner test says another user owns that file (no chown needed).
real_find=$(command -v find)
cat > "$w/bin/find" <<STUB
#!/bin/bash
if [ -n "\${OTHER_OWNS:-}" ] && [ "\$2" = "\$OTHER_OWNS" ]; then
  for a in "\$@"; do [ "\$a" = -user ] && exit 0; done
fi
exec "$real_find" "\$@"
STUB
chmod +x "$w/bin/id" "$w/bin/find"
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
  (cd "$w/repo" && env -i HOME="$w" PATH="$w/bin:$w/tools" ${ID_MODE:+ID_MODE=$ID_MODE} ${OTHER_OWNS:+OTHER_OWNS=$OTHER_OWNS} ${KEY:+WIREGUARD_PRIVATE_KEY=$KEY} \
    ${ADDR:+WIREGUARD_ADDRESSES=$ADDR} "$BASH" "$w/repo/scripts/docker_setup.sh" "$@") > "$w/out" 2> "$w/err"
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
# The refusal offers first the remedy that keeps none of the file's values: a chmod alone would
# start the miner on values someone else may have written. --overwrite-env, which rewrites the
# other settings file too, is offered only for a file the user cannot chmod: another user's.
refuse_line() { echo "[  ERROR  ] $1 can be changed by a user other than you, so this run does not use it. Remove it and run again, or, if you wrote its values and have checked them, restrict it with: chmod 600 $1"; }
refuse_owner_line() { echo "[  ERROR  ] $1 belongs to another user, so this run does not use it. Remove it and run again, or run again with --overwrite-env, which rewrites docker/.env, and docker/.env.vpn with --vpn, from this run's flags."; }
keep_line() { echo "[  INFO   ] Keeping $1: this run's flags are not applied to it. To rewrite it from them, run again with --overwrite-env."; }

# A first run writes .env, mode 600.
run fresh -w "$wallet" -y --worker-name first
want fresh exit 0 "$code"
want fresh mode "-rw-------" "$(mode "$env")"
has fresh "$out" "[ SUCCESS ] Wrote $env (mode 0600)."
grep -qx 'WORKER_NAME="first"' "$env" || fail "fresh: WORKER_NAME=first not written"
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

# A kept file the group or others can only read: one warning, mode unchanged.
for m in 644:-rw-r--r-- 604:-rw----r-- 640:-rw-r-----; do
  chmod "${m%%:*}" "$env"
  run "loose-${m%%:*}" -w "$wallet" -y
  want "loose-${m%%:*}" exit 0 "$code"
  want "loose-${m%%:*}" mode "${m#*:}" "$(mode "$env")"
  want "loose-${m%%:*}" stderr "[ WARNING ] $env can be read or changed by other users. Restrict it with: chmod 600 $env" "$err"
  cmp -s "$env" "$w/env.first" || fail "loose-${m%%:*}: .env changed"
done
chmod 600 "$env"

# refused <name> <file> <expected mode>: one error line, exit 1, nothing written or started (the
# cases pass --autostart, so a refusal after the start step reaches docker), the
# file byte for byte and mode as it was.
refused() {
  want "$1" exit 1 "$code"
  want "$1" stderr "$(${LINE:-refuse_line} "$2")" "$err"
  want "$1" mode "$3" "$(mode "$2")"
  printf '%s\n' "$out" | grep -q 'Wrote \|Replaced ' && fail "$1: a file was written"
}
# A kept file another user owns or can change is refused: the run would start the miner on
# settings someone else chose. Group write passes only for the user's private group.
OTHER_OWNS=$env run env-other-owner -w "$wallet" -y --autostart
LINE=refuse_owner_line refused env-other-owner "$env" "-rw-------"
cmp -s "$env" "$w/env.first" || fail "env-other-owner: .env changed"
chmod 620 "$env"
run env-group -w "$wallet" -y --autostart
refused env-group "$env" "-rw--w----"
cmp -s "$env" "$w/env.first" || fail "env-group: .env changed"
ID_MODE=private run env-group-private -w "$wallet" -y
want env-group-private exit 0 "$code"
chmod 606 "$env"
ID_MODE=private run env-world -w "$wallet" -y --autostart
refused env-world "$env" "-rw----rw-"
cmp -s "$env" "$w/env.first" || fail "env-world: .env changed"
chmod 600 "$env"
if [ "$(uname -s)" = Darwin ]; then
  chmod +a "everyone allow write" "$env"
  run env-acl -w "$wallet" -y --autostart
  want env-acl exit 1 "$code"
  want env-acl stderr "$(refuse_line "$env")" "$err"
  cmp -s "$env" "$w/env.first" || fail "env-acl: .env changed"
  chmod -N "$env"
fi
# --overwrite-env replaces such a file whole, so it is not refused.
chmod 606 "$env"
run env-world-overwrite -w "$wallet" -y --overwrite-env --worker-name first
want env-world-overwrite exit 0 "$code"
want env-world-overwrite mode "-rw-------" "$(mode "$env")"
cp -p "$env" "$w/env.first"

# --overwrite-env rewrites it from this run's flags, with one line naming it.
run overwrite -w "$wallet" -y --worker-name second --overwrite-env
want overwrite exit 0 "$code"
grep -qx 'WORKER_NAME="second"' "$env" || fail "overwrite: WORKER_NAME=second not written"
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
grep -qx 'WIREGUARD_PRIVATE_KEY="wgkey-first"' "$vpn" || fail "vpn: key not written"
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
# A kept .env.vpn others can write to is refused, and .env with it stays as it was.
chmod 606 "$vpn"
run vpn-world -w "$wallet" -y --vpn mullvad --autostart
refused vpn-world "$vpn" "-rw----rw-"
cmp -s "$vpn" "$w/vpn.first" || fail "vpn-world: .env.vpn changed"
cmp -s "$env" "$w/env.vpnrun" || fail "vpn-world: .env changed"
# The remedy it gives touches only .env.vpn: removed and written again, .env stays as it was.
chmod 664 "$vpn"
run vpn-group -w "$wallet" -y --vpn mullvad --autostart
refused vpn-group "$vpn" "-rw-rw-r--"
rm "$vpn"
KEY=wgkey-first ADDR=10.64.0.1/32 run vpn-removed -w "$wallet" -y --vpn mullvad
want vpn-removed exit 0 "$code"
cmp -s "$env" "$w/env.vpnrun" || fail "vpn-removed: .env changed"
want vpn-removed "mode .env.vpn" "-rw-------" "$(mode "$vpn")"
cp -p "$vpn" "$w/vpn.first"
OTHER_OWNS=$vpn run vpn-other-owner -w "$wallet" -y --vpn mullvad --autostart
LINE=refuse_owner_line refused vpn-other-owner "$vpn" "-rw-------"
cmp -s "$vpn" "$w/vpn.first" || fail "vpn-other-owner: .env.vpn changed"

# --overwrite-env without a provider leaves .env.vpn as it is.
run overwrite-novpn -w "$wallet" -y --overwrite-env --worker-name third
want overwrite-novpn exit 0 "$code"
cmp -s "$vpn" "$w/vpn.first" || fail "overwrite-novpn: .env.vpn changed"
grep -qx 'WORKER_NAME="third"' "$env" || fail "overwrite-novpn: .env not rewritten"
printf '%s\n' "$out" | grep -q "Replaced $vpn" && fail "overwrite-novpn: .env.vpn reported replaced"

# --overwrite-env with the provider rewrites both.
KEY=wgkey-second ADDR=10.64.0.2/32 run overwrite-vpn -w "$wallet" -y --vpn mullvad --overwrite-env
want overwrite-vpn exit 0 "$code"
grep -qx 'WIREGUARD_PRIVATE_KEY="wgkey-second"' "$vpn" || fail "overwrite-vpn: key not rewritten"
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
grep -qx 'WIREGUARD_PRIVATE_KEY="wgkey-third"' "$w/mv.log" || fail "umask: the stub saw no key"
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

# A directory in a settings file's place, or a link to one, is refused even with --overwrite-env:
# nothing is moved into it and nothing is written outside docker/.
mkdir "$env"
run env-dir -w "$wallet" -y --overwrite-env
want env-dir exit 1 "$code"
want env-dir stderr "[  ERROR  ] Could not write $env: it is a directory." "$err"
want env-dir "directory content" "" "$(ls -A "$env")"
want env-dir leftovers "" "$(leftovers)"
rmdir "$env"
mkdir "$w/elsewhere"
ln -s "$w/elsewhere" "$vpn"
KEY=wgkey-fifth ADDR=10.64.0.5/32 run vpn-linkdir -w "$wallet" -y --vpn mullvad --overwrite-env
want vpn-linkdir exit 1 "$code"
want vpn-linkdir stderr "[  ERROR  ] Could not write $vpn: it is a directory." "$err"
want vpn-linkdir "link target content" "" "$(ls -A "$w/elsewhere")"
[ -L "$vpn" ] || fail "vpn-linkdir: the link was replaced"
want vpn-linkdir leftovers "" "$(leftovers)"
rm -f "$vpn" "$env"

# A link to a file, or to nothing, is refused too: a rename would put a new file in the link's
# place, and the file the link points to would keep the old wallet with nothing reading it.
printf 'WALLET_ADDRESS=old\n' > "$w/elsewhere/env.real"
cp -p "$w/elsewhere/env.real" "$w/env.real.first"
ln -s "$w/elsewhere/env.real" "$env"
run env-linkfile -w "$wallet" -y --overwrite-env
want env-linkfile exit 1 "$code"
want env-linkfile stderr "[  ERROR  ] Could not write $env: it is a link. Edit the file it points to, or remove the link and run again." "$err"
[ -L "$env" ] || fail "env-linkfile: the link was replaced"
cmp -s "$w/elsewhere/env.real" "$w/env.real.first" || fail "env-linkfile: the link's target changed"
want env-linkfile leftovers "" "$(leftovers)"
rm -f "$env"
ln -s "$w/elsewhere/vpn.none" "$vpn"
KEY=wgkey-sixth ADDR=10.64.0.6/32 run vpn-dangling -w "$wallet" -y --vpn mullvad --overwrite-env
want vpn-dangling exit 1 "$code"
want vpn-dangling stderr "[  ERROR  ] Could not write $vpn: it is a link. Edit the file it points to, or remove the link and run again." "$err"
[ -L "$vpn" ] || fail "vpn-dangling: the link was replaced"
[ ! -e "$w/elsewhere/vpn.none" ] || fail "vpn-dangling: a file was written where the link points"
want vpn-dangling leftovers "" "$(leftovers)"
rm -f "$vpn" "$env"
# A temp file an interrupted write leaves next to the settings holds the same secrets: git ignores
# it as it ignores .env and .env.vpn, and still tracks the two examples.
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  for f in docker/.env docker/.env.vpn docker/.env.Ab12Cd docker/.env.vpn.Ab12Cd; do
    git -C "$root" check-ignore -q "$f" || fail "gitignore: $f is not ignored"
  done
  for f in docker/.env.example docker/.env.vpn.example; do
    git -C "$root" check-ignore -q "$f" && fail "gitignore: $f is ignored"
  done
fi
# Nothing above ran in the repository itself.
changed=$(find "$root/docker" "$root/scripts" -newer "$w/stamp" 2>&1)
[ -z "$changed" ] || fail "real tree: changed in the repository: $(printf '%s' "$changed" | tr '\n' ' ')"
[ "$rc" -eq 0 ] && echo "PASS docker-env-keep"
exit "$rc"
