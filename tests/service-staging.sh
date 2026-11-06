#!/bin/bash
# How the systemd setup reaches /etc and who the service runs the miner as. The account is the user
# running the setup, the user who ran sudo when that is root, else the system account xmrig
# (created once, then reused), or root when SERVICE_AS_ROOT=yes asks; the setup stops when that
# account cannot run the binary, or when it is root or not the binary's owner and a user other than
# root could change the binary, the link to it or a directory above them. The unit, the logrotate file and the service config are staged in
# files mktemp creates for this user alone (TMPDIR points at a fixture here, holding files planted
# at the old fixed names), each write checked, the config read as this user, then installed by
# root: the config under /etc/xmrig with the account's group, the logrotate file before the unit,
# the staged files gone afterwards, and nothing installed or enabled when a step fails. The unit
# keeps the miner's config and log in directories systemd creates for that account, and its
# start-up step copies the config there as the account, keeping the miner's own edits until the
# config changes. The setup changes no owner or mode and removes nothing but its staged files.
# Runs a fixture clone's copy of scripts/setup_service_debian.sh with PATH set to one fixture
# directory of stubs and links to plain tools: sudo records each call and the mode and owner of
# what it was asked to install, runs install into a fixture root and useradd into a fixture
# account list, never anything of the host's; id plays the caller and the accounts, stat the owners
# and modes of the clone.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
script=scripts/setup_service_debian.sh
fail() { echo "FAIL $*"; rc=1; }
same() { # label, expected, got
  [ "$2" = "$3" ] || { fail "$1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/    /'; }
}
# A copy that still stages under /tmp would write there: refuse to run it.
grep -n '/tmp/' "$root/$script" && { echo "FAIL $script names a fixed path under /tmp; not run"; exit 1; }
# Nothing in the setup changes an owner or a mode, searches a tree or removes a path, its exit
# cleanup of the staged files aside (a line it only prints may name them).
same "commands that change owners or modes, search or remove" \
  'trap '\''rm -f -- "$UNIT_STAGED" "${SEED_STAGED:-}" "${LOGROTATE_STAGED:-}"'\'' EXIT' \
  "$(grep -wE 'chown|chmod|find|rm' "$root/$script" | grep -vE '^ *echo ')"
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
c="$w/clone"
b="$w/bin"
SERVICE_ROOT="$w/root"
mkdir -p "$b" "$c/scripts" "$c/templates"
for t in bash sh sed cat mktemp dirname readlink rm ls cut awk cp mv mkdir basename grep tr cmp; do
  p=$(command -v "$t") && [ -x "$p" ] || { echo "FAIL no $t on PATH"; exit 1; }
  case $t in mktemp|sed|cat) ln -s "$p" "$b/$t.real" ;; *) ln -s "$p" "$b/$t" ;; esac
done
cp "$root/$script" "$root/scripts/setup_service_common.sh" "$c/scripts/"
cp "$root/templates/xmrig.service.template" "$root/templates/logrotate.xmrig.template" "$c/templates/"
# The binary sits in the build directory behind a link in the clone, as make build leaves it.
mkdir "$c/build-xmrig"
printf '#!/bin/sh\n' > "$c/build-xmrig/xmrig"
ln -s build-xmrig/xmrig "$c/xmrig"
printf '{"pool":"seed"}\n' > "$c/configs.json"
ln -s configs.json "$c/config_background.json"
me=$(id -un)
# sudo: SUDO_FAIL names the target of the one call that fails. Only install, useradd and a test
# run as another account do anything; every other command is recorded and does nothing.
cat > "$b/sudo" <<STUB
#!$b/bash
PATH="$b"
echo "sudo \$*" >> "$w/sudo.log"
[ -n "\${SUDO_FAIL:-}" ] && [ "\${SUDO_FAIL:-}" = "\${*: -1}" ] && exit 1
case \$1 in
  -u) shift 2; [ "\$1" = test ] && "\$@" ;;
  install)
    [ "\$2" = -d ] || echo "\$(ls -l "\${@: -2:1}" | cut -c1-10) \$(ls -l "\${@: -2:1}" | awk '{print \$3}') \${*: -1}" >> "$w/staged.log"
    shift; exec "$b/install" "\$@" ;;
  useradd) echo "\${*: -1} \${*: -1}" >> "$w/accounts" ;;
esac
STUB
# install: writes under the fixture root and records the owner, group and mode it was asked for.
cat > "$b/install" <<STUB
#!$b/bash
PATH="$b"
dir=no
while :; do
  case \$1 in -d) dir=yes; shift ;; -o) o=\$2; shift 2 ;; -g) g=\$2; shift 2 ;; -m) m=\$2; shift 2 ;; *) break ;; esac
done
echo "\$dir \$m \$o:\$g \${*: -1}" >> "$w/install.log"
if [ "\$dir" = yes ]; then mkdir -p "$SERVICE_ROOT\$1"; else mkdir -p "\$(dirname "$SERVICE_ROOT\$2")" && cp "\$1" "$SERVICE_ROOT\$2"; fi
STUB
# id: FAKE_UID and FAKE_USER play the caller; the fixture account list holds name and group.
cat > "$b/id" <<STUB
#!$b/bash
PATH="$b"
group() { awk -v n="\$1" '\$1 == n { print \$2; f = 1 } END { exit !f }' "$w/accounts"; }
case \$# in
  1) case \$1 in -u) echo "\${FAKE_UID:-1000}" ;; -un) echo "\${FAKE_USER:-alice}" ;; -gn) group "\${FAKE_USER:-alice}" ;; *) group "\$1" >/dev/null ;; esac ;;
  2) [ "\$1" = -gn ] && group "\$2" ;;
  *) exit 1 ;;
esac
STUB
# systemctl: OLD_USER is the User= of an already installed unit.
cat > "$b/systemctl" <<STUB
#!$b/bash
[ "\$1" = show ] && echo "\${OLD_USER:-}"
exit 0
STUB
# stat: owner and mode from the fixture table (path, owner, mode; owner - fails), root 755 for any
# path it does not list; each path asked is recorded.
cat > "$b/stat" <<STUB
#!$b/bash
PATH="$b"
[ "\$1" = -c ] && [ "\$2" = '%U %a' ] && [ \$# -eq 3 ] || exit 1
echo "\$3" >> "$w/stat.log"
line=\$(awk -v p="\$3" '\$1 == p { l = \$0 } END { print l }' "$w/stat")
set -- \${line:-\$3 root 755}
[ "\$2" = - ] && { echo "stat: cannot stat '\$1'" >&2; exit 1; }
echo "\$2 \$3"
STUB
printf '#!%s/bash\necho "useradd run without sudo" >> "%s/sudo.log"; exit 1\n' "$b" "$w" > "$b/useradd"
printf '#!%s/sh\nexit 0\n' "$b" > "$b/logrotate"
# pgrep: records whose processes were asked for; no xmrig runs, so the report stays silent.
printf '#!%s/sh\necho "pgrep $*" >> "%s/pgrep.log"\nexit 1\n' "$b" "$w" > "$b/pgrep"
# mktemp that fails on its Nth call only (FAIL_AT); sed and cat that write a cut line and fail when
# they read the file SED_FAIL or CAT_FAIL names; the plain tools otherwise.
cat > "$b/mktemp" <<STUB
#!$b/bash
PATH="$b"
n=\$(( \$(cat "$w/mktemp.n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$w/mktemp.n"
[ "\$n" -eq "\${FAIL_AT:-0}" ] && exit 1
exec "$b/mktemp.real" "\$@"
STUB
for t in sed cat; do
  v=$(echo "$t" | tr a-z A-Z)_FAIL
  printf '#!%s/bash\nPATH="%s"\nfor a; do [ "$a" = "${%s:-}" ] && { echo PARTIAL; exit 4; }; done\nexec "%s/%s.real" "$@"\n' \
    "$b" "$b" "$v" "$b" "$t" > "$b/$t"
done
chmod +x "$b/stat" "$b/sudo" "$b/install" "$b/id" "$b/systemctl" "$b/useradd" "$b/logrotate" "$b/pgrep" "$b/mktemp" "$b/sed" "$b/cat" "$c/xmrig"
[ "$(PATH="$b" command -v sudo)" = "$b/sudo" ] || { echo "FAIL sudo resolves outside the stub dir"; exit 1; }

setup() { # runs the copy, sets out, code, calls, staged, installs; keeps the fixture account list
  rm -rf "${w:?}/tmp" "${SERVICE_ROOT:?}" "${w:?}/sudo.log" "${w:?}/staged.log" "${w:?}/install.log" "${w:?}/mktemp.n" "${w:?}/stat.log" "${w:?}/pgrep.log"
  mkdir "$w/tmp"
  printf 'PLANTED\n' > "$w/tmp/xmrig.service"
  printf 'PLANTED\n' > "$w/tmp/xmrig.logrotate"
  out=$(cd "$w" && TMPDIR="$w/tmp" PATH="$b" "$b/bash" "$c/$script" 2>&1); code=$?
  calls=$(sed -E "s#$w/tmp/[^ /]+#STAGED#g" "$w/sudo.log" 2>/dev/null)
  staged=$(cat "$w/staged.log" 2>/dev/null)
  installs=$(cat "$w/install.log" 2>/dev/null)
}
accounts() { printf '%s\n' "alice alice" "bob staff" "root root" > "$w/accounts"; owners alice; }
owners() { # owner of the clone, its build directory and the binary, then extra table lines
  local o=$1; shift
  printf '%s\n' "$c $o 755" "$c/build-xmrig $o 755" "$c/build-xmrig/xmrig $o 755" "$@" > "$w/stat"
}
chain() { # the path and every directory above it
  local p=$1
  while echo "$p"; [ "$p" != / ]; do p=$(dirname "$p"); done
}
left() { # what is left in the fixture TMPDIR besides the planted files
  (cd "$w/tmp" && ls -A | grep -vx -e xmrig.service -e xmrig.logrotate)
}
reach() { echo "sudo -u $1 test -x $c/xmrig"; }
seed_install() { # group
  printf '%s\n' "sudo install -d -o root -g root -m 0755 /etc/xmrig" "sudo install -o root -g $1 -m 640 STAGED /etc/xmrig/config.json"
}
lr_install="sudo install -o root -g root -m 644 STAGED /etc/logrotate.d/xmrig"
unit_install="sudo install -o root -g root -m 644 STAGED /etc/systemd/system/xmrig.service"
calls_for() { # account, group: every sudo call of a setup that ends well
  reach "$1"; seed_install "$2"
  printf '%s\n' "$lr_install" "$unit_install" "sudo systemctl daemon-reload" "sudo systemctl enable xmrig.service"
}
staged_for() {
  printf '%s\n' "-rw------- $me /etc/xmrig/config.json" "-rw------- $me /etc/logrotate.d/xmrig" \
    "-rw------- $me /etc/systemd/system/xmrig.service"
}
installs_for() { # group
  printf '%s\n' "yes 0755 root:root /etc/xmrig" "no 640 root:$1 /etc/xmrig/config.json" \
    "no 644 root:root /etc/logrotate.d/xmrig" "no 644 root:root /etc/systemd/system/xmrig.service"
}
out_for() { # account, the line about an earlier account if any
  printf '%s\n' "Installed logrotate config at /etc/logrotate.d/xmrig (daily, 7 rotations)."
  [ -z "${2:-}" ] || printf '%s\n' "$2"
  printf '%s\n' "XMRig service has been setup and enabled, but not started." "Use 'make start' to start mining." \
    "The service runs the miner as $1."
}
want_unit() { # account, group
  printf '%s\n' "[Unit]" "Description=XMRig Monero Miner" "After=network.target" "" "[Service]" "Type=simple" \
    "User=$1" "Group=$2" "ConfigurationDirectory=xmrig" "StateDirectory=xmrig/$1" "StateDirectoryMode=0700" \
    "LogsDirectory=xmrig/$1" "LogsDirectoryMode=0750" "WorkingDirectory=/var/lib/xmrig/$1" \
    "ExecStartPre=/bin/sh -c 'cmp -s /etc/xmrig/config.json /var/lib/xmrig/$1/seed.json || { cp /etc/xmrig/config.json /var/lib/xmrig/$1/config.json.new && mv -f /var/lib/xmrig/$1/config.json.new /var/lib/xmrig/$1/config.json && cp /etc/xmrig/config.json /var/lib/xmrig/$1/seed.json; }'" \
    "ExecStart=$c/xmrig --config=/var/lib/xmrig/$1/config.json --log-file=/var/log/xmrig/$1/xmrig.log" \
    "Restart=on-failure" "RestartSec=15" "Nice=10" "" "[Install]" "WantedBy=multi-user.target"
}
want_lr() { # account, group
  printf '%s\n' "/var/log/xmrig/$1/*.log {" "    su $1 $2" "    daily" "    rotate 7" "    compress" \
    "    delaycompress" "    missingok" "    notifempty" "    create 0640 $1 $2" "    sharedscripts" "    postrotate" \
    "        /usr/bin/systemctl try-restart xmrig.service" "    endscript" "}"
}
ends_well() { # label, account, group, the line about an earlier account if any
  [ "$code" -eq 0 ] || fail "$1: exit $code"
  same "$1: output" "$(out_for "$2" "${4:-}")" "$out"
  same "$1: sudo calls" "$(calls_for "$2" "$3")" "$calls"
  same "$1: what root was given to install" "$(staged_for)" "$staged"
  same "$1: what install was asked for" "$(installs_for "$3")" "$installs"
  same "$1: the unit root installed" "$(want_unit "$2" "$3")" "$(cat "$SERVICE_ROOT/etc/systemd/system/xmrig.service" 2>/dev/null)"
  same "$1: the logrotate file root installed" "$(want_lr "$2" "$3")" "$(cat "$SERVICE_ROOT/etc/logrotate.d/xmrig" 2>/dev/null)"
  same "$1: the config root installed" '{"pool":"seed"}' "$(cat "$SERVICE_ROOT/etc/xmrig/config.json" 2>/dev/null)"
  [ "$(cat "$w/tmp/xmrig.service" "$w/tmp/xmrig.logrotate")" = "PLANTED"$'\n'"PLANTED" ] || fail "$1: a planted file changed"
  [ -z "$(left)" ] || fail "$1: staged files left behind: $(left | tr '\n' ' ')"
}
nothing() { # label: no file installed, nothing left
  [ ! -e "$SERVICE_ROOT/etc/systemd/system/xmrig.service" ] || fail "$1: a unit was installed"
  same "$1: what install was asked for" "" "$installs"
  [ -z "$(left)" ] || fail "$1: staged files left behind"
}

# The caller alice: the miner runs as alice, with her group. Every staged file is this user's alone
# (mode 600) when root installs it, the config first, the logrotate file before the unit.
accounts
setup
ends_well "caller alice" alice alice
same "caller alice: whose miners were looked for" "pgrep -u 1000 -x xmrig" "$(cat "$w/pgrep.log" 2>/dev/null)"
# Root through sudo by alice: the miner runs as alice.
accounts
SUDO_USER=alice FAKE_UID=0 FAKE_USER=root setup
ends_well "sudo by alice" alice alice
# Root with no sudo user: the system account xmrig, created on the first run, reused on the next.
# The clone is root's, and only root can change it.
accounts
owners root
FAKE_UID=0 FAKE_USER=root setup
[ "$code" -eq 0 ] || fail "root: exit $code"
same "root: output" "Created the system account xmrig to run the miner.
$(out_for xmrig)" "$out"
same "root: sudo calls" "sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin xmrig
$(calls_for xmrig xmrig)" "$calls"
same "root: the unit root installed" "$(want_unit xmrig xmrig)" "$(cat "$SERVICE_ROOT/etc/systemd/system/xmrig.service" 2>/dev/null)"
SUDO_USER=root FAKE_UID=0 FAKE_USER=root setup
ends_well "root again, sudo user root" xmrig xmrig
# SERVICE_AS_ROOT=yes: root, whoever runs the setup, on a clone only root can change: the binary,
# the clone and every directory above them were looked at.
accounts
owners root
SERVICE_AS_ROOT=yes SUDO_USER=alice FAKE_UID=0 FAKE_USER=root setup
ends_well "SERVICE_AS_ROOT=yes" root root
same "SERVICE_AS_ROOT=yes: paths looked at" "$( (chain "$c/build-xmrig/xmrig"; chain "$c") | sort -u)" \
  "$(sort -u "$w/stat.log" 2>/dev/null)"
# The installed unit runs the miner as bob: his directories are named with the command that
# removes them, and left alone. The same account again: no such line.
accounts
OLD_USER=bob setup
ends_well "after bob" alice alice "The miner ran as bob before: its files stay in /var/lib/xmrig/bob and /var/log/xmrig/bob; remove them with: sudo rm -r /var/lib/xmrig/bob /var/log/xmrig/bob"
# Miners an earlier background-mode start left detached ran as the account the old unit named.
same "after bob: whose miners were looked for" "pgrep -u bob -x xmrig" "$(cat "$w/pgrep.log" 2>/dev/null)"
OLD_USER=alice setup
ends_well "after alice" alice alice

# The account cannot run the binary: one error line naming it, the binary and /opt, nothing
# installed. The service config still has background mode turned off first, so the unit an earlier
# setup left runs a supervised miner.
printf '{\n  "background": true,\n  "colors": true\n}\n' > "$c/configs.json"
chmod -x "$c/xmrig"
setup
chmod +x "$c/xmrig"
[ "$code" -ne 0 ] || fail "unreachable binary: exit 0"
same "unreachable binary: output" "Turned off background mode in $c/config_background.json: the service now supervises the miner.
ERROR: The account alice cannot run $c/xmrig; move the clone where it can, such as /opt." "$out"
same "unreachable binary: the service config" '{
  "background": false,
  "colors": true
}' "$(cat "$c/configs.json")"
[ -L "$c/config_background.json" ] || fail "unreachable binary: the config link was replaced by a file"
printf '{"pool":"seed"}\n' > "$c/configs.json"
same "unreachable binary: sudo calls" "$(reach alice)" "$calls"
nothing "unreachable binary"

# An account other than the binary's owner, or root, would run what a user other than root can
# change: one error line naming the binary, the account and /opt, nothing installed.
refused() { # label, account, sudo calls, a line before the error if any
  [ "$code" -ne 0 ] || fail "$1: exit 0"
  same "$1: output" "${4:+$4
}ERROR: A user other than root can change $c/xmrig, which the service would run as $2; move the clone where only root can change it, such as /opt." "$out"
  same "$1: sudo calls" "$3" "$calls"
  nothing "$1"
}
accounts
FAKE_UID=0 FAKE_USER=root setup
refused "xmrig on alice's clone" xmrig "sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin xmrig
$(reach xmrig)" "Created the system account xmrig to run the miner."
accounts
SERVICE_AS_ROOT=yes SUDO_USER=alice FAKE_UID=0 FAKE_USER=root setup
refused "root on alice's clone" root "$(reach root)"
accounts
owners bob
setup
refused "alice on bob's binary" alice "$(reach alice)"
accounts
owners root "$c/build-xmrig/xmrig root 775"
SERVICE_AS_ROOT=yes setup
refused "binary writable by its group" root "$(reach root)"
accounts
owners root "$w root 1777"
SERVICE_AS_ROOT=yes setup
refused "a directory above writable by others" root "$(reach root)"
accounts
owners root "/ alice 755"
SERVICE_AS_ROOT=yes setup
refused "/ not root's" root "$(reach root)"
# The binary elsewhere, root's alone, behind a link in a clone others can write: the link can be
# replaced.
mkdir "$w/opt"
mv "$c/build-xmrig/xmrig" "$w/opt/xmrig"
ln -sf "$w/opt/xmrig" "$c/xmrig"
accounts
owners root "$c root 757"
SERVICE_AS_ROOT=yes setup
refused "link in a clone others can write" root "$(reach root)"
mv "$w/opt/xmrig" "$c/build-xmrig/xmrig"
ln -sf build-xmrig/xmrig "$c/xmrig"
# The binary's owner cannot be read: an error line, nothing installed.
accounts
owners root "$c/build-xmrig/xmrig - -"
SERVICE_AS_ROOT=yes setup
[ "$code" -ne 0 ] || fail "unreadable owner: exit 0"
same "unreadable owner: output" "stat: cannot stat '$c/build-xmrig/xmrig'
ERROR: Failed to read the owner of $c/xmrig." "$out"
same "unreadable owner: sudo calls" "$(reach root)" "$calls"
nothing "unreadable owner"
accounts

# No staging file for the unit, the config, then logrotate: an error line, a non-zero exit, nothing
# installed, nothing left.
for at in 1 2 3; do
  FAIL_AT=$at setup
  [ "$code" -ne 0 ] || fail "mktemp fails on call $at: exit 0"
  same "mktemp fails on call $at: output" "ERROR: Failed to create a temporary file." "$out"
  same "mktemp fails on call $at: sudo calls" "$(reach alice)" "$calls"
  nothing "mktemp fails on call $at"
done
# A write that fails half way: an error line naming its source, nothing installed.
SED_FAIL="$c/templates/xmrig.service.template" setup
[ "$code" -ne 0 ] || fail "unit write fails: exit 0"
same "unit write fails: output" "ERROR: Failed to write the unit from $c/templates/xmrig.service.template." "$out"
same "unit write fails: sudo calls" "$(reach alice)" "$calls"
nothing "unit write fails"
CAT_FAIL="$c/config_background.json" setup
[ "$code" -ne 0 ] || fail "config write fails: exit 0"
same "config write fails: output" "ERROR: Failed to write the service config from $c/config_background.json." "$out"
same "config write fails: sudo calls" "$(reach alice)" "$calls"
nothing "config write fails"
SED_FAIL="$c/templates/logrotate.xmrig.template" setup
[ "$code" -ne 0 ] || fail "logrotate write fails: exit 0"
same "logrotate write fails: output" "ERROR: Failed to write the logrotate config from $c/templates/logrotate.xmrig.template." "$out"
same "logrotate write fails: sudo calls" "$(reach alice)" "$calls"
nothing "logrotate write fails"
# Each install fails in turn: an error line, no unit, nothing enabled, so a re-run sets the service
# up again.
n=0
for target in /etc/xmrig /etc/xmrig/config.json /etc/logrotate.d/xmrig /etc/systemd/system/xmrig.service; do
  n=$((n + 1))
  SUDO_FAIL=$target setup
  [ "$code" -ne 0 ] || fail "$target install fails: exit 0"
  same "$target install fails: last line" "ERROR: Failed to install $target." "${out##*$'\n'}"
  same "$target install fails: sudo calls" "$(calls_for alice alice | head -n $((n + 1)))" "$calls"
  [ ! -e "$SERVICE_ROOT/etc/systemd/system/xmrig.service" ] || fail "$target install fails: a unit was installed"
  [ -z "$(left)" ] || fail "$target install fails: staged files left behind"
done
# No logrotate file to stage, with the staging variables inherited from the caller's environment:
# the cleanup on exit must not remove the files they name.
mv "$c/templates/logrotate.xmrig.template" "$w/logrotate.xmrig.template"
printf 'KEEP\n' > "$w/victim"
printf 'KEEP\n' > "$w/victim2"
LOGROTATE_STAGED="$w/victim" SEED_STAGED="$w/victim2" setup
[ "$code" -eq 0 ] || fail "inherited staging variables: exit $code"
same "inherited staging variables: the files they name" "KEEP
KEEP" "$(cat "$w/victim" "$w/victim2" 2>/dev/null)"
[ -z "$(left)" ] || fail "inherited staging variables: staged files left behind"
mv "$w/logrotate.xmrig.template" "$c/templates/logrotate.xmrig.template"

# The unit's start-up step, run as the account on a fixture copy of its directories: the first
# start copies the config in and remembers it, a later start keeps the miner's own edit, a changed
# config replaces it.
accounts
setup
pre=$(sed -n "s|^ExecStartPre=/bin/sh -c '\(.*\)'\$|\1|p" "$SERVICE_ROOT/etc/systemd/system/xmrig.service" 2>/dev/null \
  | sed -e "s|/etc/xmrig|$w/svc/etc/xmrig|g" -e "s|/var/lib/xmrig|$w/svc/var/lib/xmrig|g")
st="$w/svc/var/lib/xmrig/alice"
mkdir -p "$w/svc/etc/xmrig" "$st"
start() { [ -n "$pre" ] && (cd "$st" && PATH="$b" "$b/sh" -c "$pre"); }
printf 'SEED1\n' > "$w/svc/etc/xmrig/config.json"
start || fail "first start: exit non-zero"
same "first start: config, remembered copy" "SEED1
SEED1" "$(cat "$st/config.json" "$st/seed.json" 2>/dev/null)"
printf 'CALIBRATED\n' > "$st/config.json"
start || fail "start, config unchanged: exit non-zero"
same "start, config unchanged: the miner's edit" "CALIBRATED" "$(cat "$st/config.json" 2>/dev/null)"
printf 'SEED2\n' > "$w/svc/etc/xmrig/config.json"
start || fail "start, config changed: exit non-zero"
same "start, config changed: config, remembered copy" "SEED2
SEED2" "$(cat "$st/config.json" "$st/seed.json" 2>/dev/null)"
same "start: files in the state directory" "config.json
seed.json" "$(ls -A "$st")"

[ "$rc" -eq 0 ] && echo "PASS service-staging"
exit "$rc"
