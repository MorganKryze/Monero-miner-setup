#!/bin/bash
# How the systemd setup reaches /etc: the unit and the logrotate file are staged in files mktemp
# creates (TMPDIR points at a fixture here, holding files planted at the old fixed names), installed
# by root in one step owned by root with mode 644, the staged files gone afterwards, and nothing
# installed when a staging file cannot be created or an install fails. Runs a fixture clone's copy
# of scripts/setup_service_debian.sh with stubs first on PATH: sudo records its arguments and keeps
# a copy of what it was asked to install, never running anything; systemctl and logrotate exist.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
script=scripts/setup_service_debian.sh
# A copy that still stages under /tmp would write there: refuse to run it.
grep -n '/tmp/' "$root/$script" && { echo "FAIL $script names a fixed path under /tmp; not run"; exit 1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
c="$w/clone"
mkdir -p "$w/bin" "$w/failtmp" "$c/scripts" "$c/templates"
cp "$root/$script" "$c/$script"
cp "$root/templates/xmrig.service.template" "$root/templates/logrotate.xmrig.template" "$c/templates/"
cat > "$w/bin/sudo" <<STUB
#!/bin/bash
echo "sudo \$*" >> "$w/sudo.log"
[ "\$1" = install ] || exit 0
[ "\${SUDO_FAIL:-}" = install ] && exit 1
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
chmod +x "$w/bin/"* "$w/failtmp/mktemp"
me=$(whoami)
mygroup=$(id -gn)

setup() { # extra PATH dir: runs the copy, sets out, code, calls
  rm -rf "$w/tmp" "$w/installed" "$w/sudo.log" "$w/mktemp.n"
  mkdir "$w/tmp"
  printf 'PLANTED\n' > "$w/tmp/xmrig.service"
  printf 'PLANTED\n' > "$w/tmp/xmrig.logrotate"
  out=$(cd "$w" && TMPDIR="$w/tmp" PATH="${1:+$1:}$w/bin:$PATH" bash "$c/$script" 2>&1); code=$?
  calls=$(sed -E "s#$w/tmp/[^ /]+#STAGED#g" "$w/sudo.log" 2>/dev/null)
}
left() { # what is left in the fixture TMPDIR besides the planted files
  (cd "$w/tmp" && ls -A | grep -vx -e xmrig.service -e xmrig.logrotate)
}

setup ""
[ "$code" -eq 0 ] || { echo "FAIL setup: exit $code"; printf '%s\n' "$out" | sed 's/^/    /'; rc=1; }
want='sudo install -o root -g root -m 644 STAGED /etc/systemd/system/xmrig.service
sudo systemctl daemon-reload
sudo systemctl enable xmrig.service
sudo install -o root -g root -m 644 STAGED /etc/logrotate.d/xmrig'
[ "$calls" = "$want" ] || { echo "FAIL setup: sudo calls"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$calls") | sed 's/^/    /'; rc=1; }
want_unit="[Unit]
Description=XMRig Monero Miner
After=network.target

[Service]
Type=simple
User=$me
WorkingDirectory=$c
ExecStart=$c/xmrig --config=$c/config_background.json
Restart=on-failure
RestartSec=15
Nice=10

[Install]
WantedBy=multi-user.target"
got=$(cat "$w/installed/xmrig.service" 2>/dev/null)
[ "$got" = "$want_unit" ] || { echo "FAIL setup: the unit root installed"; diff <(printf '%s\n' "$want_unit") <(printf '%s\n' "$got") | sed 's/^/    /'; rc=1; }
want_lr="$c/logs/*.log {
    su $me $mygroup
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0644 $me $me
}"
got=$(cat "$w/installed/xmrig" 2>/dev/null)
[ "$got" = "$want_lr" ] || { echo "FAIL setup: the logrotate file root installed"; diff <(printf '%s\n' "$want_lr") <(printf '%s\n' "$got") | sed 's/^/    /'; rc=1; }
[ "$(cat "$w/tmp/xmrig.service" "$w/tmp/xmrig.logrotate")" = "PLANTED"$'\n'"PLANTED" ] || { echo "FAIL setup: a planted file changed"; rc=1; }
[ -z "$(left)" ] || { echo "FAIL setup: staged files left behind: $(left | tr '\n' ' ')"; rc=1; }

# No staging file for the unit, then none for logrotate: an error line, a non-zero exit, nothing
# installed, nothing left.
for at in 1 2; do
  FAIL_AT=$at setup "$w/failtmp"
  [ "$code" -ne 0 ] || { echo "FAIL mktemp fails on call $at: exit 0"; rc=1; }
  [ "$out" = "ERROR: Failed to create a temporary file." ] || { echo "FAIL mktemp fails on call $at: output '$out'"; rc=1; }
  [ -z "$calls" ] || { echo "FAIL mktemp fails on call $at: sudo ran: $calls"; rc=1; }
  [ -z "$(left)" ] || { echo "FAIL mktemp fails on call $at: staged files left behind"; rc=1; }
done
# The unit install fails: an error line, a non-zero exit, nothing enabled, nothing left.
SUDO_FAIL=install setup ""
[ "$code" -ne 0 ] || { echo "FAIL install fails: exit 0"; rc=1; }
[ "${out##*$'\n'}" = "ERROR: Failed to install /etc/systemd/system/xmrig.service." ] || { echo "FAIL install fails: last line '${out##*$'\n'}'"; rc=1; }
[ "$calls" = "sudo install -o root -g root -m 644 STAGED /etc/systemd/system/xmrig.service" ] || { echo "FAIL install fails: sudo calls '$calls'"; rc=1; }
[ -z "$(left)" ] || { echo "FAIL install fails: staged files left behind"; rc=1; }
# No logrotate file to stage, with LOGROTATE_STAGED inherited from the caller's environment: the
# cleanup on exit must not remove the file it names.
mv "$c/templates/logrotate.xmrig.template" "$w/logrotate.xmrig.template"
printf 'KEEP\n' > "$w/victim"
LOGROTATE_STAGED="$w/victim" setup ""
[ "$code" -eq 0 ] || { echo "FAIL inherited LOGROTATE_STAGED: exit $code"; rc=1; }
[ "$(cat "$w/victim" 2>/dev/null)" = "KEEP" ] || { echo "FAIL inherited LOGROTATE_STAGED: the file it names was removed"; rc=1; }
[ -z "$(left)" ] || { echo "FAIL inherited LOGROTATE_STAGED: staged files left behind"; rc=1; }
mv "$w/logrotate.xmrig.template" "$c/templates/logrotate.xmrig.template"
[ "$rc" -eq 0 ] && echo "PASS service-staging"
exit "$rc"
