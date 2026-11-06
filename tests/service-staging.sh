#!/bin/bash
# How the systemd setup reaches /etc. The unit and the logrotate file are staged in files mktemp
# creates for this user alone (TMPDIR points at a fixture here, holding files planted at the old
# fixed names), each write checked, installed by root in one step owned by root with mode 644, the
# logrotate file before the unit, the staged files gone afterwards, and nothing installed or
# enabled when a step fails. Runs a fixture clone's copy of scripts/setup_service_debian.sh with
# stubs first on PATH: sudo records its arguments and the mode and owner of what it was asked to
# install, and keeps a copy, never running anything; systemctl and logrotate exist.
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
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
c="$w/clone"
mkdir -p "$w/bin" "$w/failtmp" "$w/failsed" "$c/scripts" "$c/templates"
cp "$root/$script" "$c/$script"
cp "$root/templates/xmrig.service.template" "$root/templates/logrotate.xmrig.template" "$c/templates/"
me=$(id -un)
mygroup=$(id -gn)
# SUDO_FAIL names the target of the one install that fails.
cat > "$w/bin/sudo" <<STUB
#!/bin/bash
echo "sudo \$*" >> "$w/sudo.log"
case \$1 in
  install)
    src=\${@: -2:1}
    echo "\$(ls -l "\$src" | cut -c1-10) \$(ls -l "\$src" | awk '{print \$3}') \${*: -1}" >> "$w/staged.log" ;;
esac
[ "\${SUDO_FAIL:-}" = "\${*: -1}" ] && exit 1
[ "\$1" = install ] || exit 0
mkdir -p "$w/installed"
cp "\${@: -2:1}" "$w/installed/\$(basename "\${*: -1}")"
STUB
printf '#!/bin/sh\nexit 0\n' > "$w/bin/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$w/bin/logrotate"
printf '#!/bin/sh\nexit 1\n' > "$w/bin/pgrep"
# mktemp that fails on its Nth call only (FAIL_AT), the real one otherwise.
cat > "$w/failtmp/mktemp" <<STUB
#!/bin/bash
n=\$(( \$(cat "$w/mktemp.n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$w/mktemp.n"
[ "\$n" -eq "\${FAIL_AT:-0}" ] && exit 1
PATH=/usr/bin:/bin exec mktemp "\$@"
STUB
# sed that writes a cut line and fails when it reads the template SED_FAIL names, the real one
# otherwise.
cat > "$w/failsed/sed" <<STUB
#!/bin/bash
for a; do [ "\$a" = "\${SED_FAIL:-}" ] && { echo PARTIAL; exit 4; }; done
PATH=/usr/bin:/bin exec sed "\$@"
STUB
chmod +x "$w/bin/"* "$w/failtmp/mktemp" "$w/failsed/sed"

setup() { # extra PATH dir: runs the copy, sets out, code, calls, staged
  rm -rf "${w:?}/tmp" "${w:?}/installed" "${w:?}/sudo.log" "${w:?}/staged.log" "${w:?}/mktemp.n" "${c:?}/logs"
  mkdir "$w/tmp"
  printf 'PLANTED\n' > "$w/tmp/xmrig.service"
  printf 'PLANTED\n' > "$w/tmp/xmrig.logrotate"
  out=$(cd "$w" && TMPDIR="$w/tmp" \
    PATH="${1:+$1:}$w/bin:$PATH" bash "$c/$script" 2>&1); code=$?
  calls=$(sed -E "s#$w/tmp/[^ /]+#STAGED#g" "$w/sudo.log" 2>/dev/null)
  staged=$(cat "$w/staged.log" 2>/dev/null)
}
left() { # what is left in the fixture TMPDIR besides the planted files
  (cd "$w/tmp" && ls -A | grep -vx -e xmrig.service -e xmrig.logrotate)
}
lr_install="sudo install -o root -g root -m 644 STAGED /etc/logrotate.d/xmrig"
unit_install="sudo install -o root -g root -m 644 STAGED /etc/systemd/system/xmrig.service"
installs="$lr_install
$unit_install
sudo systemctl daemon-reload
sudo systemctl enable xmrig.service"
want_unit() { # user
  printf '%s\n' "[Unit]" "Description=XMRig Monero Miner" "After=network.target" "" "[Service]" "Type=simple" \
    "User=$1" "WorkingDirectory=$c" "ExecStart=$c/xmrig --config=$c/config_background.json" "Restart=on-failure" \
    "RestartSec=15" "Nice=10" "" "[Install]" "WantedBy=multi-user.target"
}
want_lr() { # user, group
  printf '%s\n' "$c/logs/*.log {" "    su $1 $2" "    daily" "    rotate 7" "    compress" "    delaycompress" \
    "    missingok" "    notifempty" "    copytruncate" "    create 0644 $1 $1" "}"
}
installed() { # label, user, group: both files as root installed them, the planted ones untouched, nothing left
  same "$1: the unit root installed" "$(want_unit "$2")" "$(cat "$w/installed/xmrig.service" 2>/dev/null)"
  same "$1: the logrotate file root installed" "$(want_lr "$2" "$3")" "$(cat "$w/installed/xmrig" 2>/dev/null)"
  [ "$(cat "$w/tmp/xmrig.service" "$w/tmp/xmrig.logrotate")" = "PLANTED"$'\n'"PLANTED" ] || fail "$1: a planted file changed"
  [ -z "$(left)" ] || fail "$1: staged files left behind: $(left | tr '\n' ' ')"
}
nothing() { # label: no file installed, nothing left
  [ ! -e "$w/installed" ] || fail "$1: installed $(ls "$w/installed" | tr '\n' ' ')"
  [ -z "$(left)" ] || fail "$1: staged files left behind"
}

# As a user: the miner runs as that user. Both staged files are this user's alone (mode 600) when
# root installs them, the logrotate file first.
setup ""
[ "$code" -eq 0 ] || { fail "setup: exit $code"; printf '%s\n' "$out" | sed 's/^/    /'; }
same "setup: sudo calls" "$installs" "$calls"
same "setup: what root was given to install" "-rw------- $me /etc/logrotate.d/xmrig
-rw------- $me /etc/systemd/system/xmrig.service" "$staged"
installed setup "$me" "$mygroup"

# No staging file for the unit, then none for logrotate: an error line, a non-zero exit, nothing
# installed, nothing left.
for at in 1 2; do
  FAIL_AT=$at setup "$w/failtmp"
  [ "$code" -ne 0 ] || fail "mktemp fails on call $at: exit 0"
  same "mktemp fails on call $at: output" "ERROR: Failed to create a temporary file." "$out"
  same "mktemp fails on call $at: sudo calls" "" "$calls"
  nothing "mktemp fails on call $at"
done
# A write that fails half way: an error line naming the template, nothing installed.
SED_FAIL="$c/templates/xmrig.service.template" setup "$w/failsed"
[ "$code" -ne 0 ] || fail "unit write fails: exit 0"
same "unit write fails: output" "ERROR: Failed to write the unit from $c/templates/xmrig.service.template." "$out"
same "unit write fails: sudo calls" "" "$calls"
nothing "unit write fails"
SED_FAIL="$c/templates/logrotate.xmrig.template" setup "$w/failsed"
[ "$code" -ne 0 ] || fail "logrotate write fails: exit 0"
same "logrotate write fails: output" "ERROR: Failed to write the logrotate config from $c/templates/logrotate.xmrig.template." "$out"
same "logrotate write fails: sudo calls" "" "$calls"
nothing "logrotate write fails"
# The logrotate install fails: no unit, so a re-run sets the service up again; nothing enabled.
SUDO_FAIL=/etc/logrotate.d/xmrig setup ""
[ "$code" -ne 0 ] || fail "logrotate install fails: exit 0"
same "logrotate install fails: last line" "ERROR: Failed to install /etc/logrotate.d/xmrig." "${out##*$'\n'}"
same "logrotate install fails: sudo calls" "$lr_install" "$calls"
nothing "logrotate install fails"
# The unit install fails: an error line, a non-zero exit, nothing enabled, nothing left.
SUDO_FAIL=/etc/systemd/system/xmrig.service setup ""
[ "$code" -ne 0 ] || fail "unit install fails: exit 0"
same "unit install fails: last line" "ERROR: Failed to install /etc/systemd/system/xmrig.service." "${out##*$'\n'}"
same "unit install fails: sudo calls" "$lr_install
$unit_install" "$calls"
[ ! -e "$w/installed/xmrig.service" ] || fail "unit install fails: a unit was installed"
[ -z "$(left)" ] || fail "unit install fails: staged files left behind"
# No logrotate file to stage, with LOGROTATE_STAGED inherited from the caller's environment: the
# cleanup on exit must not remove the file it names.
mv "$c/templates/logrotate.xmrig.template" "$w/logrotate.xmrig.template"
printf 'KEEP\n' > "$w/victim"
LOGROTATE_STAGED="$w/victim" setup ""
[ "$code" -eq 0 ] || fail "inherited LOGROTATE_STAGED: exit $code"
same "inherited LOGROTATE_STAGED: the file it names" "KEEP" "$(cat "$w/victim" 2>/dev/null)"
[ -z "$(left)" ] || fail "inherited LOGROTATE_STAGED: staged files left behind"
mv "$w/logrotate.xmrig.template" "$c/templates/logrotate.xmrig.template"

[ "$rc" -eq 0 ] && echo "PASS service-staging"
exit "$rc"
