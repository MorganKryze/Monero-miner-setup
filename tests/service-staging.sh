#!/bin/bash
# How the systemd setup reaches /etc and who the service runs the miner as. The account is the user
# running the setup, the user who ran sudo when that is root, else the system account xmrig
# (created once, then reused), or root when SERVICE_AS_ROOT=yes asks; the setup stops when that
# account cannot run the binary, or when it is root or not the binary's owner and a user other than
# root could change the binary, a link on the way to it or a directory above any of them. The unit,
# the logrotate file and the service config are staged in
# files mktemp creates for this user alone (TMPDIR points at a fixture here, holding files planted
# at the old fixed names), each write checked, the config read as this user (as the account when
# that is root, so a link in the clone gets only what the account can read), then installed by
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
# A copy that still stages under /tmp would write there: refuse to run it. The tuning file it
# sources stages too.
for f in "$script" scripts/setup_service_tuning.sh; do
  grep -n '/tmp/' "$root/$f" && { echo "FAIL $f names a fixed path under /tmp; not run"; exit 1; }
done
# Nothing in the setup changes an owner or a mode, searches a tree or removes a path, its exit
# cleanup of the staged files aside (a line it only prints may name them).
same "commands that change owners or modes, search or remove" \
  'trap '\''rm -f -- "$UNIT_STAGED" "${SEED_STAGED:-}" "${LOGROTATE_STAGED:-}" "${TUNING_STAGED[@]}"'\'' EXIT' \
  "$(grep -wE 'chown|chmod|find|rm' "$root/$script" | grep -vE '^ *echo ')"
# The tuning file removes, as root, its own three installed files and nothing else.
same "tuning: commands that change owners or modes, search or remove" \
  '    if ! sudo rm -f -- "$TUNING_UNIT" "$TUNING_BIN" "$TUNING_CONF" || ! sudo systemctl daemon-reload; then' \
  "$(grep -wE 'chown|chmod|find|rm' "$root/scripts/setup_service_tuning.sh" | grep -vE '^ *(echo|#)')"
same "tuning: the paths root removes" 'TUNING_BIN="/usr/local/sbin/xmrig-host-tuning"
TUNING_CONF="/etc/xmrig-host-tuning.conf"
TUNING_UNIT="/etc/systemd/system/xmrig-host-tuning.service"' \
  "$(grep -E '^TUNING_(BIN|CONF|UNIT)=' "$root/scripts/setup_service_tuning.sh")"
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
c="$w/clone"
b="$w/bin"
SERVICE_ROOT="$w/root"
mkdir -p "$b" "$c/scripts" "$c/templates"
for t in bash sh sed cat mktemp dirname readlink rm ls cut awk cp mv mkdir basename grep tr cmp head sort; do
  p=$(command -v "$t") && [ -x "$p" ] || { echo "FAIL no $t on PATH"; exit 1; }
  case $t in mktemp|sed|cat) ln -s "$p" "$b/$t.real" ;; *) ln -s "$p" "$b/$t" ;; esac
done
cp "$root/$script" "$root/scripts/setup_service_common.sh" "$c/scripts/"
# A setup without a mode looks for the tuning's three installed files: they sit in a fixture
# directory, absent unless a case creates them.
old="$w/old"
old_paths=(-e "s|^TUNING_UNIT=.*|TUNING_UNIT=\"$old/xmrig-host-tuning.service\"|"
  -e "s|^TUNING_BIN=.*|TUNING_BIN=\"$old/xmrig-host-tuning\"|" -e "s|^TUNING_CONF=.*|TUNING_CONF=\"$old/xmrig-host-tuning.conf\"|")
sed "${old_paths[@]}" "$root/scripts/setup_service_tuning.sh" > "$c/scripts/setup_service_tuning.sh"
cp "$root/templates/xmrig.service.template" "$root/templates/logrotate.xmrig.template" "$c/templates/"
# The binary sits in the build directory behind a link in the clone, as make build leaves it.
mkdir "$c/build-xmrig"
printf '#!/bin/sh\n' > "$c/build-xmrig/xmrig"
ln -s build-xmrig/xmrig "$c/xmrig"
printf '{"pool":"seed"}\n' > "$c/configs.json"
ln -s configs.json "$c/config_background.json"
me=$(id -un)
# sudo: SUDO_FAIL names the target of the one call that fails. Only install, useradd and a test or
# a cat run as another account do anything; every other command is recorded and does nothing.
cat > "$b/sudo" <<STUB
#!$b/bash
PATH="$b"
echo "sudo \$*" >> "$w/sudo.log"
[ -n "\${SUDO_FAIL:-}" ] && [ "\${SUDO_FAIL:-}" = "\${*: -1}" ] && exit 1
case \$1 in
  -u) shift 2; case \$1 in test|cat) "\$@" ;; esac ;;
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
# systemctl: OLD_USER is the User= of an already installed unit; TUNING_FRAGMENT the file of a
# tuning unit an earlier setup with a mode installed.
cat > "$b/systemctl" <<STUB
#!$b/bash
[ "\$1 \$3" = "show FragmentPath" ] && { echo "\${TUNING_FRAGMENT:-}"; exit 0; }
[ "\$1 \$3" = "show Result" ] && { echo success; exit 0; }
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
  caller_uid=${FAKE_UID:-1000}
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
read_seed() { echo "sudo -u $1 cat $c/config_background.json"; }
calls_for() { # account, group: every sudo call of a setup that ends well; root reads the seed as the account
  reach "$1"
  [ "$caller_uid" != 0 ] || read_seed "$1"
  seed_install "$2"
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
  local origin='h=$$(sha256sum < "$$1/xmrig" | cut -c1-64); d=$$(grep -o "donate-level.: *[0-9]*" "$$2" | grep -o "[0-9]*$$"); if [ ! -e "$$1/xmrig.release" ]; then o="compiled on this host"; elif r=$$(cat "$$1/xmrig.release") && [ -n "$$h" ] && [ "$${r#* }" = "$$h" ]; then o="release $$(echo "$$r" | cut -d" " -f1), sha256 $$h"; else o="unknown (sha256 $${h:-unreadable} matches no release record)"; fi; u=$$(grep -m1 -o "url.: *[^,]*" "$$2"); if [ -n "$$d" ]; then if echo "$$u" | grep -q "moneroocean.stream"; then d=0; elif [ "$$d" -lt 1 ] || [ "$$d" -gt 99 ]; then d=1; fi; d="$$d (as XMRig applies it)"; fi; echo "Miner binary: $$o; donate level $${d:-unknown}"'
  printf '%s\n' "[Unit]" "Description=XMRig Monero Miner" "After=network.target" "" "[Service]" "Type=simple" \
    "User=$1" "Group=$2" "ConfigurationDirectory=xmrig" "StateDirectory=xmrig/$1" "StateDirectoryMode=0700" \
    "LogsDirectory=xmrig/$1" "LogsDirectoryMode=0750" "WorkingDirectory=/var/lib/xmrig/$1" \
    "ExecStartPre=/bin/sh -c 'cmp -s /etc/xmrig/config.json /var/lib/xmrig/$1/seed.json || { cp /etc/xmrig/config.json /var/lib/xmrig/$1/config.json.new && mv -f /var/lib/xmrig/$1/config.json.new /var/lib/xmrig/$1/config.json && cp /etc/xmrig/config.json /var/lib/xmrig/$1/seed.json; }'" \
    "# Names where the binary comes from and the donate level it starts with; never blocks the start." \
    "ExecStartPre=-/bin/sh -c '$origin' miner-origin $c /var/lib/xmrig/$1/config.json" \
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
# SERVICE_AS_ROOT=yes: root, whoever runs the setup, on a clone only root can change: the link,
# the binary, the clone, the config and every directory above them were looked at.
accounts
owners root
SERVICE_AS_ROOT=yes SUDO_USER=alice FAKE_UID=0 FAKE_USER=root setup
ends_well "SERVICE_AS_ROOT=yes" root root
same "SERVICE_AS_ROOT=yes: paths looked at" "$( (chain "$c/xmrig"; chain "$c/build-xmrig/xmrig"; chain "$c/configs.json") | sort -u)" \
  "$(sort -u "$w/stat.log" 2>/dev/null)"
# SERVICE_AS_ROOT=no, which the installer passes unless asked otherwise: the caller, or the user who
# ran sudo, as with no value at all.
accounts
SERVICE_AS_ROOT=no setup
ends_well "SERVICE_AS_ROOT=no, caller alice" alice alice
accounts
SERVICE_AS_ROOT=no SUDO_USER=alice FAKE_UID=0 FAKE_USER=root setup
ends_well "SERVICE_AS_ROOT=no, sudo by alice" alice alice
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
# stat prints a mode without its leading zeros: 0007 comes out as 7, still writable by others.
accounts
owners root "$w root 7"
SERVICE_AS_ROOT=yes setup
refused "a directory above with mode 0007" root "$(reach root)"
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
accounts
owners root "$w root 775"
SERVICE_AS_ROOT=yes setup
refused "a directory above writable by its group" root "$(reach root)"
# The link reaches the binary through a second link outside the clone, relative and climbing out
# with .., then through a link to a directory. Root's alone, every link and directory on the way
# was looked at, the ones the links pass through included; each can be changed later, so another
# user owning one, or able to write the directory holding one, is refused.
mkdir "$w/hops"
ln -s ../clone/build-xmrig "$w/hops/dir"
ln -s dir/xmrig "$w/hops/hop"
ln -sf "$w/hops/hop" "$c/xmrig"
accounts
owners root
SERVICE_AS_ROOT=yes FAKE_UID=0 FAKE_USER=root setup
ends_well "a chain of links, root's" root root
same "a chain of links, root's: paths looked at" \
  "$( (chain "$c/xmrig"; chain "$w/hops/hop"; chain "$w/hops/dir"; chain "$c/build-xmrig/xmrig"; chain "$c/configs.json") | sort -u)" \
  "$(sort -u "$w/stat.log" 2>/dev/null)"
for line in "$w/hops alice 755" "$w/hops root 775" "$w/hops/hop alice 777" "$w/hops/dir alice 777"; do
  accounts
  owners root "$line"
  SERVICE_AS_ROOT=yes FAKE_UID=0 FAKE_USER=root setup
  refused "a chain of links, ${line#"$w/"}" root "$(reach root)"
done
ln -sf build-xmrig/xmrig "$c/xmrig"
rm -r "$w/hops"
# Root and a config with background mode on. On alice's clone root writes nothing there: alice
# could point the link at a file of root's. The refusal comes
# alone and the file stays as it was; through sudo by alice, root turns off only the copy it
# installs. On a clone only root can change, root turns the file off itself.
printf '{\n  "background": true,\n  "colors": true\n}\n' > "$c/configs.json"
on=$(cat "$c/configs.json")
off='{
  "background": false,
  "colors": true
}'
accounts
FAKE_UID=0 FAKE_USER=root setup
refused "xmrig on alice's clone, background on" xmrig "sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin xmrig
$(reach xmrig)" "Created the system account xmrig to run the miner."
same "xmrig on alice's clone, background on: the service config" "$on" "$(cat "$c/configs.json")"
accounts
SUDO_USER=alice FAKE_UID=0 FAKE_USER=root setup
[ "$code" -eq 0 ] || fail "sudo by alice, background on: exit $code"
same "sudo by alice, background on: output" "Turned off background mode in /etc/xmrig/config.json: the service now supervises the miner.
$(out_for alice)" "$out"
same "sudo by alice, background on: the service config" "$on" "$(cat "$c/configs.json")"
same "sudo by alice, background on: the config root installed" "$off" "$(cat "$SERVICE_ROOT/etc/xmrig/config.json" 2>/dev/null)"
accounts
owners root
FAKE_UID=0 FAKE_USER=root setup
[ "$code" -eq 0 ] || fail "root's clone, background on: exit $code"
same "root's clone, background on: output" "Turned off background mode in $c/config_background.json: the service now supervises the miner.
Created the system account xmrig to run the miner.
$(out_for xmrig)" "$out"
same "root's clone, background on: the service config" "$off" "$(cat "$c/configs.json")"
[ -L "$c/config_background.json" ] || fail "root's clone, background on: the config link was replaced by a file"
same "root's clone, background on: the config root installed" "$off" "$(cat "$SERVICE_ROOT/etc/xmrig/config.json" 2>/dev/null)"
printf '{"pool":"seed"}\n' > "$c/configs.json"
# The link points out of the clone, at a file only root can change: on alice's clone she chose
# where it points, and on root's the file is not the clone's. Root leaves that file as it is, and
# turns off only the copy it installs.
printf '%s\n' "$on" > "$w/outside.json"
ln -sf "$w/outside.json" "$c/config_background.json"
accounts
FAKE_UID=0 FAKE_USER=root setup
refused "xmrig on alice's clone, link out of it" xmrig "sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin xmrig
$(reach xmrig)" "Created the system account xmrig to run the miner."
same "xmrig on alice's clone, link out of it: the file it points at" "$on" "$(cat "$w/outside.json")"
accounts
owners root
FAKE_UID=0 FAKE_USER=root setup
[ "$code" -eq 0 ] || fail "root's clone, link out of it: exit $code"
same "root's clone, link out of it: output" "Created the system account xmrig to run the miner.
Turned off background mode in /etc/xmrig/config.json: the service now supervises the miner.
$(out_for xmrig)" "$out"
same "root's clone, link out of it: the file it points at" "$on" "$(cat "$w/outside.json")"
same "root's clone, link out of it: the config root installed" "$off" "$(cat "$SERVICE_ROOT/etc/xmrig/config.json" 2>/dev/null)"
ln -sf configs.json "$c/config_background.json"
rm -f "$w/outside.json"
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
# Root, and a seed the account cannot read (a link in the clone to a file of root's, say): the
# read fails as the account, and root reads nothing itself.
SUDO_FAIL="$c/config_background.json" SUDO_USER=alice FAKE_UID=0 FAKE_USER=root setup
[ "$code" -ne 0 ] || fail "seed the account cannot read: exit 0"
same "seed the account cannot read: output" "ERROR: Failed to write the service config from $c/config_background.json." "$out"
same "seed the account cannot read: sudo calls" "$(reach alice; read_seed alice)" "$calls"
nothing "seed the account cannot read"
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
printf 'KEEP\n' > "$w/victim3"
LOGROTATE_STAGED="$w/victim" SEED_STAGED="$w/victim2" TUNING_STAGED="$w/victim3" setup
[ "$code" -eq 0 ] || fail "inherited staging variables: exit $code"
same "inherited staging variables: the files they name" "KEEP
KEEP
KEEP" "$(cat "$w/victim" "$w/victim2" "$w/victim3" 2>/dev/null)"
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

# A board installed with --mode (configs/board-mode, which the installer writes): the tuning's
# values, script and unit are staged with the rest, read from the clone as the caller (as the
# account when that is root), installed by root before the miner unit, which then runs the miner
# at normal priority, restarts it after any exit and wants the tuning first; the tuning is enabled,
# and restarted when already active, and one closing line names each change. The tuning file's
# kernel paths point at a fixture Orange Pi 5 Plus.
mkdir -p "$c/configs" "$w/board/cpufreq/policy0" "$w/board/cpufreq/policy4" "$w/board/cpufreq/policy6"
cp "$root/scripts/host_tuning.sh" "$root/scripts/board_profiles.conf" "$c/scripts/"
cp "$root/templates/xmrig-host-tuning.service.template" "$c/templates/"
printf '0 1 2 3\n' > "$w/board/cpufreq/policy0/related_cpus"
printf '4 5\n' > "$w/board/cpufreq/policy4/related_cpus"
printf '6 7\n' > "$w/board/cpufreq/policy6/related_cpus"
printf 'MemTotal:       16184388 kB\nHugepagesize:       2048 kB\n' > "$w/board/meminfo"
printf '%s\0' xunlong,orangepi-5-plus rockchip,rk3588 > "$w/board/compatible"
sed -e "s|^TUNING_CPUFREQ_DIR=.*|TUNING_CPUFREQ_DIR=\"$w/board/cpufreq\"|" -e "s|^DT_COMPATIBLE=.*|DT_COMPATIBLE=\"$w/board/compatible\"|" \
  -e "s|^MEMINFO=.*|MEMINFO=\"$w/board/meminfo\"|" "$root/scripts/setup_service_tuning.sh" > "$c/scripts/setup_service_tuning.sh"
tuning_installs='sudo install -o root -g root -m 644 STAGED /etc/xmrig-host-tuning.conf
sudo install -o root -g root -m 755 STAGED /usr/local/sbin/xmrig-host-tuning
sudo install -o root -g root -m 644 STAGED /etc/systemd/system/xmrig-host-tuning.service'
tuned_calls() { # account, group, mode of the caller (1000 or 0)
  reach "$1"
  [ "$3" != 0 ] || printf '%s\n' "$(read_seed "$1")" "sudo -u $1 cat -- $c/configs/board-mode" \
    "sudo -u $1 cat -- $c/scripts/board_profiles.conf" "sudo -u $1 cat -- $c/scripts/host_tuning.sh" "sudo -u $1 cat -- $c/templates/xmrig-host-tuning.service.template"
  seed_install "$2"
  printf '%s\n' "$lr_install" "$tuning_installs" "$unit_install" "sudo systemctl daemon-reload" "sudo systemctl enable xmrig.service" \
    "sudo systemctl enable xmrig-host-tuning.service" "sudo systemctl try-restart xmrig-host-tuning.service"
}
tuned_unit() { # account, group: the plain unit with the three changes
  want_unit "$1" "$2" | awk '$0 == "Nice=10" { next } $0 == "Restart=on-failure" { print "Restart=always"; next } { print }
    $0 == "After=network.target" { print "Wants=xmrig-host-tuning.service" }'
}
eco_lines="Host tuning for --mode eco, applied by xmrig-host-tuning.service at each boot before the miner:
  policy0 (CPUs 0 1 2 3): powersave governor, no mining there.
  policy4 (CPUs 4 5): performance governor, at most 1800 MHz.
  policy6 (CPUs 6 7): performance governor, at most 1800 MHz.
  Huge pages: 1280 of 2 MB reserved at each boot.
  The miner runs at normal priority (no Nice) and restarts 15 s after any exit.
  Files: /etc/systemd/system/xmrig-host-tuning.service, /usr/local/sbin/xmrig-host-tuning, /etc/xmrig-host-tuning.conf; 'make service-disable' removes them and gives the CPU settings back."
tuned_ends_well() { # label, account, group, caller uid, mode
  [ "$code" -eq 0 ] || fail "$1: exit $code"
  same "$1: sudo calls" "$(tuned_calls "$2" "$3" "$4")" "$calls"
  same "$1: the unit root installed" "$(tuned_unit "$2" "$3")" "$(cat "$SERVICE_ROOT/etc/systemd/system/xmrig.service" 2>/dev/null)"
  cmp -s "$c/scripts/host_tuning.sh" "$SERVICE_ROOT/usr/local/sbin/xmrig-host-tuning" || fail "$1: the boot script root installed"
  cmp -s "$c/templates/xmrig-host-tuning.service.template" "$SERVICE_ROOT/etc/systemd/system/xmrig-host-tuning.service" || fail "$1: the tuning unit root installed"
  [ -z "$(left)" ] || fail "$1: staged files left behind: $(left | tr '\n' ' ')"
}
accounts
printf 'eco\n' > "$c/configs/board-mode"
setup
tuned_ends_well "tuned eco, caller alice" alice alice 1000
same "tuned eco: output" "$(out_for alice)
$eco_lines" "$out"
same "tuned eco: values root installed" "# Written by the miner's service setup; make service-disable removes it.
mode=eco
policy0=powersave
policy4=performance 1800000
policy6=performance 1800000
hugepages=1280" "$(cat "$SERVICE_ROOT/etc/xmrig-host-tuning.conf" 2>/dev/null)"
accounts
printf 'max\n' > "$c/configs/board-mode"
SUDO_USER=alice FAKE_UID=0 FAKE_USER=root setup
tuned_ends_well "tuned max, sudo by alice" alice alice 0
same "tuned max: values root installed" "# Written by the miner's service setup; make service-disable removes it.
mode=max
policy0=performance max
policy4=performance max
policy6=performance max
hugepages=1280" "$(cat "$SERVICE_ROOT/etc/xmrig-host-tuning.conf" 2>/dev/null)"
# A failed install of the tuning stops before the unit.
accounts
SUDO_FAIL=/etc/xmrig-host-tuning.conf setup
[ "$code" -ne 0 ] || fail "tuning install fails: exit 0"
[ ! -e "$SERVICE_ROOT/etc/systemd/system/xmrig.service" ] || fail "tuning install fails: the unit was installed"
[ -z "$(left)" ] || fail "tuning install fails: staged files left behind"
# A mode the board has no profile for: one error line, nothing installed.
printf '%s\0' acme,desktop > "$w/board/compatible"
accounts
setup
[ "$code" -eq 1 ] || fail "no profile: exit $code"
same "no profile: error" "ERROR: The service config was written for --mode max, and this board has no valid profile in $c/scripts/board_profiles.conf. Run the installer again without --mode, or update the clone: git -C $c pull" "$(printf '%s\n' "$out" | grep '^ERROR')"
nothing "no profile"
printf '%s\0' xunlong,orangepi-5-plus rockchip,rk3588 > "$w/board/compatible"
# From here on the setup runs without a mode, so it looks for the installed tuning: at the fixture
# paths.
sed -i.bak "${old_paths[@]}" "$c/scripts/setup_service_tuning.sh" && rm -f "$c/scripts/setup_service_tuning.sh.bak"
# A board-mode that is not max or eco: the plain unit, as without one.
for m in 'eco; rm -rf /' ECO; do
  printf '%s\n' "$m" > "$c/configs/board-mode"
  accounts
  setup
  ends_well "board-mode '$m'" alice alice
done
# No board-mode while an earlier setup's tuning is installed: the plain unit, then the tuning
# stopped (its stop gives the CPU settings back) and removed, with one line.
rm -f "$c/configs/board-mode"
old_rm="sudo rm -f -- $old/xmrig-host-tuning.service $old/xmrig-host-tuning $old/xmrig-host-tuning.conf"
mkdir -p "$old"
: > "$old/xmrig-host-tuning.service"; : > "$old/xmrig-host-tuning"; : > "$old/xmrig-host-tuning.conf"
accounts
TUNING_FRAGMENT=/etc/systemd/system/xmrig-host-tuning.service setup
[ "$code" -eq 0 ] || fail "untuned again: exit $code"
same "untuned again: sudo calls" "$(calls_for alice alice)
sudo systemctl stop xmrig-host-tuning.service
sudo systemctl disable xmrig-host-tuning.service
$old_rm
sudo systemctl daemon-reload" "$calls"
same "untuned again: output" "$(out_for alice | sed '/^XMRig service has been setup/i\
Host tuning removed: CPU settings given back; the huge pages are freed at the next boot.')" "$out"
same "untuned again: the unit root installed" "$(want_unit alice alice)" "$(cat "$SERVICE_ROOT/etc/systemd/system/xmrig.service" 2>/dev/null)"
# A partial install (the values file, the boot script or the unit alone, none systemd knows), as a setup that
# failed half way or a removed unit leaves: removed all the same, nothing to stop.
for only in xmrig-host-tuning.conf xmrig-host-tuning xmrig-host-tuning.service; do
  rm -f "$old/"*; : > "$old/$only"
  accounts
  setup
  [ "$code" -eq 0 ] || fail "only $only left: exit $code"
  same "only $only left: sudo calls" "$(calls_for alice alice)
$old_rm
sudo systemctl daemon-reload" "$calls"
  same "only $only left: output" "$(out_for alice | sed '/^XMRig service has been setup/i\
Host tuning removed: systemd did not know its unit, so nothing was stopped; the huge pages are freed at the next boot.')" "$out"
done

[ "$rc" -eq 0 ] && echo "PASS service-staging"
exit "$rc"
