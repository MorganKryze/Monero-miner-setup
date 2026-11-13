#!/bin/bash
# `make service-disable` and `make wipe` remove the logrotate file the systemd setup installed,
# besides the unit or the plist, and no other path; `make start`, `stop`, `status` and
# `service-disable` know systemd and launchd only (no FreeBSD rc.d branch left). On systemd,
# `service-disable` stops and disables the unit, resets a failed state, has systemd remove the
# service's own configuration, state and log directories while the unit still exists (a failed
# clean stops it there, non-zero; a unit from an older release declares none and skips the clean),
# then removes the unit; `status` tails the
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
# sudo fails `systemctl clean` while the file fail-clean exists in the fixture, as it does on a
# systemd without the clean verb or on a unit still active; while the file failed exists, as
# systemd refuses to clean a unit in the failed state, until `systemctl reset-failed` removes it;
# while old-unit exists, as on a unit that declares none of the directories; and `test` while
# fail-sudo-test exists, as sudo does without a password or a terminal.
cat > "$w/bin/sudo" <<EOS
#!/bin/sh
echo "sudo \$*" >> "$w/calls"
[ "\$1 \$2" = "systemctl reset-failed" ] && /bin/rm -f "$w/failed"
[ "\$*" = "systemctl stop xmrig-host-tuning.service" ] && [ -f "$w/fail-tuning-stop" ] && exit 1
[ "\$1" = test ] && [ -f "$w/fail-sudo-test" ] && { echo "sudo: a password is required" >&2; exit 1; }
[ "\$1" = test ] && { shift; exec test "\$@"; }
[ "\$1 \$2" = "apt-get remove" ] && [ -f "$w/fail-apt" ] && exit 100
if [ "\$1 \$2" = "systemctl clean" ]; then
  [ -f "$w/fail-clean" ] && exit 1
  [ -f "$w/failed" ] && { echo "Failed to clean unit xmrig.service: Unit is not inactive or has pending job." >&2; exit 2; }
  [ -f "$w/old-unit" ] && { echo "Failed to clean unit xmrig.service: No matching resources found." >&2; exit 2; }
fi
exit 0
EOS
# systemctl show answers the unit's User= with a fixture account name and its StateDirectory=
# with the directory the setup declares, or nothing for a unit from an older release.
cat > "$w/bin/systemctl" <<EOS
#!/bin/sh
echo "systemctl \$*" >> "$w/calls"
[ "\$1 \$3" = "show User" ] && echo fixture-miner
[ "\$1" = show ] && [ -f "$w/no-bus" ] && exit 1
[ "\$1 \$3" = "show StateDirectory" ] && [ ! -f "$w/old-unit" ] && echo xmrig/fixture-miner
[ "\$1 \$3" = "show FragmentPath" ] && [ -f "$w/etc/xmrig-host-tuning.service" ] && echo /etc/systemd/system/xmrig-host-tuning.service
if [ "\$1 \$3" = "show Result" ]; then
  if [ -f "$w/result" ]; then cat "$w/result"; elif [ -f "$w/tuning-stop-failed" ]; then echo exit-code; else echo success; fi
fi
exit 0
EOS
chmod +x "$w/bin/"*
paths=(SYSTEMD_UNIT="$w/etc/xmrig.service" LAUNCHD_PLIST="$w/agents/com.moneroocean.xmrig.plist" LOGROTATE_CONF="$w/etc/logrotate-xmrig"
  TUNING_UNIT="$w/etc/xmrig-host-tuning.service" TUNING_BIN="$w/etc/xmrig-host-tuning" TUNING_CONF="$w/etc/xmrig-host-tuning.conf"
  FIRSTBOOT_UNIT="$w/etc/xmrig-first-boot.service" FIRSTBOOT_BIN="$w/etc/xmrig-first-boot" FIRSTBOOT_STATE="$w/etc/first-boot"
  BOARD_STATUS="$w/board-status")
printf 'echo "BOARD READOUT"\n' > "$w/board-status"
# The targets must reach the service only through these variables: with them set, no recipe
# may name another path under /etc, /usr/local/etc or a LaunchAgents directory. Otherwise not run.
for t in start stop status service-disable; do
  TERM=dumb make -s -n -f "$root/Makefile" "${paths[@]}" "$t" | grep -nE '/etc/|/usr/local/etc|LaunchAgents' | grep -v "$w/" \
    && { echo "FAIL $t names a service path the check cannot redirect; not run"; exit 1; }
done
make=$(command -v make)
target() { # target: runs it in the fixture, sets out (stdout), code, calls, files; stub_path=<dir> narrows PATH
  rm -f "$w/calls"
  out=$(cd "$w/run" && TERM=dumb PATH="${stub_path:-$w/bin:$PATH}" "$make" -s -f "$root/Makefile" "${paths[@]}" "$1" 2>/dev/null); code=$?
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
sudo systemctl reset-failed xmrig.service
systemctl show -p StateDirectory --value xmrig.service
sudo systemctl clean --what=configuration --what=state --what=logs xmrig.service
sudo rm -f $w/etc/xmrig.service
sudo systemctl daemon-reload
sudo rm -f $w/etc/logrotate-xmrig" "$calls"
printf '%s\n' "$out" | grep -qxF '[ SUCCESS ] XMRig logrotate config removed.' || fail "systemd: no line saying the logrotate config was removed"
# A board set up with --mode: after the miner's unit, the host tuning is stopped (its stop gives
# the CPU settings back), disabled and its unit, script and values removed, with one line; the
# logrotate file after it. A failed stop keeps the tuning and the logrotate file, non-zero.
tuned() { setup etc/xmrig.service etc/xmrig-host-tuning.service etc/logrotate-xmrig run/keep; mkdir -p "$w/run/scripts"; cp "$root/scripts/setup_service_tuning.sh" "$w/run/scripts/"; }
tuned
target service-disable
[ "$code" -eq 0 ] || fail "tuned: exit $code"
same "tuned: calls" "sudo systemctl stop xmrig.service
sudo systemctl disable xmrig.service
sudo systemctl reset-failed xmrig.service
systemctl show -p StateDirectory --value xmrig.service
sudo systemctl clean --what=configuration --what=state --what=logs xmrig.service
sudo rm -f $w/etc/xmrig.service
sudo systemctl daemon-reload
systemctl show -p FragmentPath --value xmrig-host-tuning.service
sudo systemctl stop xmrig-host-tuning.service
sudo systemctl disable xmrig-host-tuning.service
systemctl show -p Result --value xmrig-host-tuning.service
sudo rm -f -- /etc/systemd/system/xmrig-host-tuning.service /usr/local/sbin/xmrig-host-tuning /etc/xmrig-host-tuning.conf
sudo rm -rf -- /run/xmrig-host-tuning
sudo systemctl daemon-reload
sudo rm -f $w/etc/logrotate-xmrig" "$calls"
printf '%s\n' "$out" | grep -qxF 'Host tuning removed: CPU settings given back; the huge pages are freed at the next boot.' || fail "tuned: no line saying the tuning was removed"
tuned
: > "$w/fail-tuning-stop"
target service-disable
rm -f "$w/fail-tuning-stop"
[ "$code" -ne 0 ] || fail "tuning stop fails: exit 0"
printf '%s\n' "$calls" | grep -q 'logrotate-xmrig' && fail "tuning stop fails: the logrotate file was removed"
printf '%s\n' "$calls" | grep -q 'rm -f -- /etc/systemd/system/xmrig-host-tuning.service' && fail "tuning stop fails: the tuning was removed"
printf '%s\n' "$out" | grep -qxF "ERROR: Failed to stop xmrig-host-tuning.service, so the host tuning is kept. Fix the error, then run 'make service-disable' again." \
  || fail "tuning stop fails: no line saying the tuning is kept"
printf '%s\n' "$calls" | grep -q 'rm -rf -- /run/xmrig-host-tuning' && fail "tuning stop fails: the record of what apply found was removed"
# The stop ran, but the tuning's own stop step failed: the files go, and the line says the CPU
# settings come back at the next boot rather than that they were given back.
tuned
: > "$w/tuning-stop-failed"
target service-disable
rm -f "$w/tuning-stop-failed"
[ "$code" -eq 0 ] || fail "tuning stop step fails: exit $code"
same "tuning stop step fails: line" "Host tuning removed, but its stop step reported exit-code: the CPU settings and the huge pages come back at the next boot." \
  "$(printf '%s\n' "$out" | grep '^Host tuning')"
# A Result that is not one plain word (a second line, a control character) is said as unknown,
# never printed as systemd gave it.
tuned
printf 'exit-code\nsuccess \033[2J\n' > "$w/result"
target service-disable
rm -f "$w/result"
[ "$code" -eq 0 ] || fail "odd stop result: exit $code"
same "odd stop result: line" "Host tuning removed, but its stop step reported unknown: the CPU settings and the huge pages come back at the next boot." \
  "$(printf '%s\n' "$out" | grep '^Host tuning')"
printf '%s\n' "$out" | grep -q "$(printf '\033')" && fail "odd stop result: a control character reached the output"
# A partial install (the values file and the boot script, no unit systemd knows): nothing to
# stop, the files are removed all the same.
setup etc/xmrig-host-tuning etc/xmrig-host-tuning.conf run/keep; mkdir -p "$w/run/scripts"; cp "$root/scripts/setup_service_tuning.sh" "$w/run/scripts/"
target service-disable
[ "$code" -eq 0 ] || fail "partial tuning: exit $code"
same "partial tuning: calls" "pgrep -x xmrig
systemctl show -p FragmentPath --value xmrig-host-tuning.service
sudo rm -f -- /etc/systemd/system/xmrig-host-tuning.service /usr/local/sbin/xmrig-host-tuning /etc/xmrig-host-tuning.conf
sudo rm -rf -- /run/xmrig-host-tuning
sudo systemctl daemon-reload" "$calls"
same "partial tuning: line" "Host tuning removed: systemd did not know its unit, so nothing was stopped; the huge pages are freed at the next boot." \
  "$(printf '%s\n' "$out" | grep '^Host tuning')"
# Any one of the three files is enough to run the removal: the values file alone is what a setup
# leaves when it fails after installing it first, the boot script alone what a removed unit leaves.
for only in xmrig-host-tuning.conf xmrig-host-tuning; do
  setup "etc/$only" run/keep; mkdir -p "$w/run/scripts"; cp "$root/scripts/setup_service_tuning.sh" "$w/run/scripts/"
  target service-disable
  [ "$code" -eq 0 ] || fail "only $only: exit $code"
  printf '%s\n' "$calls" | grep -qxF 'sudo rm -f -- /etc/systemd/system/xmrig-host-tuning.service /usr/local/sbin/xmrig-host-tuning /etc/xmrig-host-tuning.conf' \
    || fail "only $only: the tuning was not removed"
done
# systemctl show fails (no system bus) on a tuning with no miner unit: an empty answer would read
# as a unit systemd does not know, and the restore script would go with the CPU settings still
# changed. The tuning and the logrotate file are kept, non-zero.
setup etc/xmrig-host-tuning.service etc/xmrig-host-tuning etc/xmrig-host-tuning.conf etc/logrotate-xmrig run/keep
mkdir -p "$w/run/scripts"; cp "$root/scripts/setup_service_tuning.sh" "$w/run/scripts/"
: > "$w/no-bus"
target service-disable
rm -f "$w/no-bus"
[ "$code" -ne 0 ] || fail "tuning show fails: exit 0"
same "tuning show fails: calls" "pgrep -x xmrig
systemctl show -p FragmentPath --value xmrig-host-tuning.service" "$calls"
same "tuning show fails: line" "ERROR: systemctl show failed for xmrig-host-tuning.service, so the host tuning is kept. Fix the error, then run 'make service-disable' again." \
  "$(printf '%s\n' "$out" | grep '^ERROR')"
# systemd host where clean fails: the target stops there with an error and a non-zero exit,
# before the unit is removed, so a second run can retry; the logrotate file is not touched.
setup etc/xmrig.service etc/logrotate-xmrig run/keep
: > "$w/fail-clean"
target service-disable
rm -f "$w/fail-clean"
[ "$code" -ne 0 ] || fail "systemd clean fails: exit 0"
same "systemd clean fails: calls" "sudo systemctl stop xmrig.service
sudo systemctl disable xmrig.service
sudo systemctl reset-failed xmrig.service
systemctl show -p StateDirectory --value xmrig.service
sudo systemctl clean --what=configuration --what=state --what=logs xmrig.service" "$calls"
same "systemd clean fails: output" "[  INFO   ] Disabling and removing XMRig service...
[  ERROR  ] systemctl clean failed. The unit is kept so make service-disable can retry once the error is fixed" "$out"
same "systemd clean fails: files left" "etc/logrotate-xmrig
etc/xmrig.service
run/keep" "$files"
# A unit an older release installed declares none of the directories, so systemd has nothing to
# clean and refuses the verb: the target skips it and removes the unit. The stubs are the whole PATH.
setup etc/xmrig.service etc/logrotate-xmrig run/keep
: > "$w/old-unit"
stub_path="$w/bin" target service-disable
rm -f "$w/old-unit"
[ "$code" -eq 0 ] || fail "older unit: exit $code"
same "older unit: calls" "sudo systemctl stop xmrig.service
sudo systemctl disable xmrig.service
sudo systemctl reset-failed xmrig.service
systemctl show -p StateDirectory --value xmrig.service
sudo rm -f $w/etc/xmrig.service
sudo systemctl daemon-reload
sudo rm -f $w/etc/logrotate-xmrig" "$calls"
# A unit in the failed state (the miner exited non-zero) is reset first, as systemd refuses to
# clean it otherwise; then cleaned and removed. The stubs are the whole PATH.
setup etc/xmrig.service etc/logrotate-xmrig run/keep
: > "$w/failed"
stub_path="$w/bin" target service-disable
[ ! -f "$w/failed" ] || { fail "failed unit: never reset"; rm -f "$w/failed"; }
[ "$code" -eq 0 ] || fail "failed unit: exit $code"
same "failed unit: calls" "sudo systemctl stop xmrig.service
sudo systemctl disable xmrig.service
sudo systemctl reset-failed xmrig.service
systemctl show -p StateDirectory --value xmrig.service
sudo systemctl clean --what=configuration --what=state --what=logs xmrig.service
sudo rm -f $w/etc/xmrig.service
sudo systemctl daemon-reload
sudo rm -f $w/etc/logrotate-xmrig" "$calls"
# systemctl show fails (no system bus): an empty answer would read as an older unit, so the
# target stops there, non-zero, and keeps the unit and the logrotate file.
setup etc/xmrig.service etc/logrotate-xmrig run/keep
: > "$w/no-bus"
stub_path="$w/bin" target service-disable
rm -f "$w/no-bus"
[ "$code" -ne 0 ] || fail "show fails: exit 0"
same "show fails: output" "[  INFO   ] Disabling and removing XMRig service...
[  ERROR  ] systemctl show failed. The unit is kept so make service-disable can retry once the error is fixed" "$out"
same "show fails: files left" "etc/logrotate-xmrig
etc/xmrig.service
run/keep" "$files"
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
sudo systemctl reset-failed xmrig.service
systemctl show -p StateDirectory --value xmrig.service
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
same "status: the board readout comes last" "BOARD READOUT" "$(printf '%s\n' "$out" | tail -n 1)"
same "status with no service: calls" "pgrep -x xmrig" "$calls"
# status on systemd: the unit's status, then the service's own log, read as the service account
# (never as root inside the account's log directory), control characters shown with cat -v.
setup etc/xmrig.service run/keep run/logs/xmrig_stdout.log run/logs/xmrig_stderr.log
target status
same "systemd status: calls" "sudo systemctl status xmrig.service
systemctl show -p User --value xmrig.service
sudo -u fixture-miner test -f /var/log/xmrig/fixture-miner/xmrig.log
sudo -u fixture-miner tail -n 5 -- /var/log/xmrig/fixture-miner/xmrig.log" "$calls"
# A board set up by the DietPi first boot: its unit is disabled and stopped, its unit, script and
# state folder (settings, records, the fetched installer) removed, one line; the hostname is left
# as set. avahi-daemon is removed only when the setup's record says the setup installed it, and a
# failed removal keeps every first-boot file, non-zero.
firstboot() { setup etc/xmrig-first-boot.service etc/xmrig-first-boot etc/first-boot/settings etc/first-boot/done "$@"; }
firstboot
target service-disable
[ "$code" -eq 0 ] || fail "first boot: exit $code"
same "first boot: calls" "pgrep -x xmrig
sudo test -f $w/etc/first-boot/mdns-installed
sudo test ! -f $w/etc/first-boot/mdns-installed
sudo systemctl disable --now xmrig-first-boot.service
sudo rm -f -- $w/etc/xmrig-first-boot.service $w/etc/xmrig-first-boot
sudo rm -rf -- $w/etc/first-boot
sudo systemctl daemon-reload" "$calls"
printf '%s\n' "$out" | grep -qxF '[ SUCCESS ] First-boot setup removed: its unit and script and settings and records. The hostname stays as set.' \
  || fail "first boot: no line saying the setup was removed"
printf '%s\n' "$calls" | grep -qE 'hostname|/etc/hosts' && fail "first boot: the hostname was touched"
firstboot etc/first-boot/mdns-installed
target service-disable
[ "$code" -eq 0 ] || fail "first boot with mdns: exit $code"
same "first boot with mdns: calls" "pgrep -x xmrig
sudo test -f $w/etc/first-boot/mdns-installed
sudo systemctl disable --now xmrig-first-boot.service
sudo apt-get remove --purge -y avahi-daemon
sudo rm -f -- $w/etc/xmrig-first-boot.service $w/etc/xmrig-first-boot
sudo rm -rf -- $w/etc/first-boot
sudo systemctl daemon-reload" "$calls"
firstboot etc/first-boot/mdns-installed etc/logrotate-xmrig
: > "$w/fail-apt"
target service-disable
rm -f "$w/fail-apt"
[ "$code" -ne 0 ] || fail "mdns removal fails: exit 0"
printf '%s\n' "$calls" | grep -qF -e "rm -rf -- $w/etc/first-boot" -e 'rm -f -- ' && fail "mdns removal fails: first-boot files removed"
printf '%s\n' "$calls" | grep -q 'logrotate-xmrig' && fail "mdns removal fails: the logrotate file was removed"
printf '%s\n' "$out" | grep -qxF '[  ERROR  ] Failed to remove avahi-daemon. The first-boot files are kept so make service-disable can retry once apt is fixed' \
  || fail "mdns removal fails: no line saying the files are kept"
# sudo cannot look for the record: nothing is removed, so avahi-daemon is not left behind unrecorded.
firstboot etc/first-boot/mdns-installed
: > "$w/fail-sudo-test"
target service-disable
rm -f "$w/fail-sudo-test"
[ "$code" -ne 0 ] || fail "record unreadable: exit 0"
printf '%s\n' "$calls" | grep -qE 'disable --now xmrig-first-boot|apt-get|rm -' && fail "record unreadable: the setup was touched"
printf '%s\n' "$out" | grep -qxF '[  ERROR  ] Failed to look for the first-boot record of avahi-daemon with sudo. Nothing is removed so make service-disable can retry' \
  || fail "record unreadable: no line saying nothing is removed"
# Only the state folder left (a setup cut before its unit was written): still removed.
setup etc/first-boot/settings
target service-disable
printf '%s\n' "$calls" | grep -qxF "sudo rm -rf -- $w/etc/first-boot" || fail "state folder alone: not removed"
# No first boot here: no first-boot call at all.
setup etc/xmrig.service
target service-disable
printf '%s\n' "$calls" | grep -q 'first-boot\|avahi' && fail "no first boot: a first-boot call was made"
[ "$rc" -eq 0 ] && echo "PASS service-disable"
exit "$rc"
