#!/bin/bash
# `make service-disable` and `make wipe` remove the logrotate file the systemd setup installed,
# besides the unit or the plist, and no other path; `make start`, `stop`, `status` and
# `service-disable` know systemd and launchd only (no FreeBSD rc.d branch left). On systemd,
# `service-disable` stops and disables the unit, has systemd remove the service's own configuration,
# state and log directories while the unit still exists, then removes the unit; `status` tails the
# service's log under /var/log/xmrig/<its User=>, never a file in the clone. The targets run in
# a fixture directory with the service paths set to fixture files on the command line and stubs
# first on PATH: sudo, systemctl, launchctl, pgrep and pkill record their arguments and run nothing,
# so nothing is stopped, unregistered, removed as root or signalled.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
same() { # label, expected, got
  [ "$2" = "$3" ] || { fail "$1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/    /'; }
}
grep -nE 'rc\.d|service xmrig' "$root/Makefile" && fail "a FreeBSD rc.d branch is left in the Makefile"
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/bin" "$w/run" "$w/etc" "$w/agents"
for c in sudo systemctl launchctl pgrep pkill; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n[ "%s" != pgrep ]\n' "$c" "$w" "$c" > "$w/bin/$c"
done
printf '#!/bin/sh\nexit 0\n' > "$w/bin/sleep"
# systemctl show answers the unit's User= with a fixture account name.
printf '#!/bin/sh\necho "systemctl $*" >> "%s/calls"\n[ "$1" = show ] && echo fixture-miner\nexit 0\n' "$w" > "$w/bin/systemctl"
chmod +x "$w/bin/"*
paths=(SYSTEMD_UNIT="$w/etc/xmrig.service" LAUNCHD_PLIST="$w/agents/com.moneroocean.xmrig.plist" LOGROTATE_CONF="$w/etc/logrotate-xmrig")
# The targets must reach the service only through the three variables: with them set, no recipe
# may name another path under /etc, /usr/local/etc or a LaunchAgents directory. Otherwise not run.
for t in start stop status service-disable; do
  TERM=dumb make -s -n -f "$root/Makefile" "${paths[@]}" "$t" | grep -nE '/etc/|/usr/local/etc|LaunchAgents' | grep -v "$w/" \
    && { echo "FAIL $t names a service path the check cannot redirect; not run"; exit 1; }
done
target() { # target: runs it in the fixture, sets out (stdout), code, calls, files
  rm -f "$w/calls"
  out=$(cd "$w/run" && TERM=dumb PATH="$w/bin:$PATH" make -s -f "$root/Makefile" "${paths[@]}" "$1" 2>/dev/null); code=$?
  calls=$(cat "$w/calls" 2>/dev/null)
  files=$(cd "$w" && find etc agents run -type f | LC_ALL=C sort)
}
setup() { # files to create, relative to $w
  rm -rf "${w:?}/etc/"* "${w:?}/agents/"* "${w:?}/run/"*
  for f in "$@"; do mkdir -p "$(dirname "$w/$f")"; : > "$w/$f"; done
}

# systemd host: unit and logrotate file. The unit goes through sudo (recorded, not run), so both
# stay in the fixture; the calls are the whole record.
setup etc/xmrig.service etc/logrotate-xmrig etc/other agents/other.plist run/keep
target service-disable
[ "$code" -eq 0 ] || fail "systemd: exit $code"
same "systemd: calls" "sudo systemctl stop xmrig.service
sudo systemctl disable xmrig.service
sudo systemctl clean --what=configuration --what=state --what=logs xmrig.service
sudo rm -f $w/etc/xmrig.service
sudo systemctl daemon-reload
sudo rm -f $w/etc/logrotate-xmrig" "$calls"
printf '%s\n' "$out" | grep -qxF '[ SUCCESS ] XMRig logrotate config removed.' || fail "systemd: no line saying the logrotate config was removed"
# launchd host: the plist is the user's own file and goes for real; a logrotate file left by an
# earlier systemd setup goes too, through sudo; every other file stays.
setup agents/com.moneroocean.xmrig.plist agents/other.plist etc/logrotate-xmrig etc/other run/keep
target service-disable
[ "$code" -eq 0 ] || fail "launchd: exit $code"
same "launchd: calls" "launchctl stop com.moneroocean.xmrig
launchctl unload -w $w/agents/com.moneroocean.xmrig.plist
sudo rm -f $w/etc/logrotate-xmrig" "$calls"
same "launchd: files left" "agents/other.plist
etc/logrotate-xmrig
etc/other
run/keep" "$files"
# No service, no logrotate file: nothing removed, nothing signalled (pgrep finds no xmrig).
setup etc/other run/keep
target service-disable
[ "$code" -eq 0 ] || fail "none: exit $code"
same "none: calls" "pgrep -x xmrig" "$calls"
same "none: files left" "etc/other
run/keep" "$files"
# make wipe: the build and configs in its own directory, then the same removal.
setup etc/xmrig.service etc/logrotate-xmrig etc/other run/build-xmrig/obj run/configs/config.json run/keep
target wipe
[ "$code" -eq 0 ] || fail "wipe: exit $code"
same "wipe: calls" "sudo systemctl stop xmrig.service
sudo systemctl disable xmrig.service
sudo systemctl clean --what=configuration --what=state --what=logs xmrig.service
sudo rm -f $w/etc/xmrig.service
sudo systemctl daemon-reload
sudo rm -f $w/etc/logrotate-xmrig" "$calls"
same "wipe: files left" "etc/logrotate-xmrig
etc/other
etc/xmrig.service
run/keep" "$files"
# start, stop and status with no service: systemd and launchd only, so nothing found.
setup run/keep
target start
[ "$code" -ne 0 ] || fail "start with no service: exit 0"
same "start with no service: output" "[  INFO   ] Starting XMRig service...
[  ERROR  ] No service configuration found. Run make service-setup first" "$out"
same "start with no service: calls" "" "$calls"
target stop
same "stop with no service: calls" "pgrep -x xmrig" "$calls"
target status
same "status with no service: calls" "pgrep -x xmrig" "$calls"
# status on systemd: the unit's status, then the service's own log read through sudo.
setup etc/xmrig.service run/keep run/logs/xmrig_stdout.log run/logs/xmrig_stderr.log
target status
same "systemd status: calls" "sudo systemctl status xmrig.service
systemctl show -p User --value xmrig.service
sudo tail -n 5 /var/log/xmrig/fixture-miner/xmrig.log" "$calls"
[ "$rc" -eq 0 ] && echo "PASS service-disable"
exit "$rc"
