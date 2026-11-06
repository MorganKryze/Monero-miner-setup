#!/bin/bash
# The service runs the miner in the foreground: the service config's template has background mode
# off, and the service setup turns it off in a host's existing service config, that one line alone,
# saying so. It also reports the xmrig processes an earlier background-mode start left detached,
# with the command that stops them, and stops none. The helpers run against fixture configs; both
# setup scripts run in a fixture clone with stubs on PATH (sudo, systemctl, launchctl, pgrep,
# ps, kill, pkill record or answer from fixtures; nothing is installed, registered or signalled).
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
same() { # label, expected, got
  [ "$2" = "$3" ] || { fail "$1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/    /'; }
}

# The template and the service definitions.
grep -qxF '  "background": false,' templates/config_background.json.template || fail "template: background is not off"
cmp -s templates/config.json.template templates/config_background.json.template || fail "template: the two config templates differ"
grep -nE -- '--background|(^|[[:space:]>])-B([[:space:]<]|$)' templates/xmrig.service.template templates/com.moneroocean.xmrig.plist.template \
  && fail "a service definition passes the background flag"

w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)

# The helpers on fixture configs. On: the template with background on, two-space (as
# generated) and four-space (as xmrig's autosave writes it) indents, one without a final newline;
# reached through a link, as configs/ is. Each must end byte-identical to its off twin.
# shellcheck source=../scripts/setup_service_common.sh
source "$root/scripts/setup_service_common.sh"
mkdir -p "$w/cfg/configs"
sed 's/^  "background": false,$/  "background": true,/' templates/config_background.json.template > "$w/cfg/on2"
cp templates/config_background.json.template "$w/cfg/off2"
sed 's/^  /    /' "$w/cfg/on2" > "$w/cfg/on4"; sed 's/^  /    /' "$w/cfg/off2" > "$w/cfg/off4"
printf '{\n  "background": true,\n  "colors": true\n}' > "$w/cfg/onnl"; printf '{\n  "background": false,\n  "colors": true\n}' > "$w/cfg/offnl"
for v in 2 4 nl; do
  cp "$w/cfg/on$v" "$w/cfg/configs/c$v.json"
  chmod 640 "$w/cfg/configs/c$v.json"
  ln -s "$w/cfg/configs/c$v.json" "$w/cfg/link$v.json"
  out=$(turn_background_off "$w/cfg/link$v.json"); code=$?
  [ "$code" -eq 0 ] || fail "turn off ($v): exit $code"
  same "turn off ($v): output" "Turned off background mode in $w/cfg/link$v.json: the service now supervises the miner." "$out"
  cmp -s "$w/cfg/configs/c$v.json" "$w/cfg/off$v" || fail "turn off ($v): the file is not its off twin, byte for byte"
  [ -L "$w/cfg/link$v.json" ] || fail "turn off ($v): the link was replaced by a file"
  [ "$(ls -l "$w/cfg/configs/c$v.json" | cut -c1-10)" = "-rw-r-----" ] || fail "turn off ($v): mode changed"
  out=$(turn_background_off "$w/cfg/link$v.json")
  same "turn off again ($v): output" "" "$out"
  cmp -s "$w/cfg/configs/c$v.json" "$w/cfg/off$v" || fail "turn off again ($v): the file changed"
done
cp "$w/cfg/off2" "$w/cfg/already"
out=$(turn_background_off "$w/cfg/already")
same "already off: output" "" "$out"
cmp -s "$w/cfg/already" "$w/cfg/off2" || fail "already off: the file changed"
out=$(turn_background_off "$w/cfg/missing" 2>&1); code=$?
[ "$code" -eq 0 ] && [ -z "$out" ] && [ ! -e "$w/cfg/missing" ] || fail "missing config: exit $code, output '$out'"

# The process table, from fixtures, with process IDs past any kernel's limit (macOS 99998,
# Linux 4194304), so no real process can hold one. ...901 and ...902 run the service config
# detached (macOS and Linux show no terminal as ?? and ?), ...903 runs it in a terminal, ...904
# another config, ...905 is the service manager's own. pgrep must be asked for this user's xmrig
# processes by exact name. kill is a shell builtin a PATH stub cannot catch: a function stands in
# for it, exported to the setup scripts too, and records instead of signalling.
mkdir -p "$w/bin" "$w/procs" "$w/tools"
# PATH holds the stub dir and a tools dir of links to plain tools, no host directory (C9): nothing
# run here can reach the host's sudo, chown or useradd; checked once the stubs are written.
for tool in bash sh cat sed grep cut sort ls dirname readlink mktemp cmp mv cp rm ln id awk tr head tail mkdir chmod uname; do
  p=$(type -P "$tool") && ln -s "$p" "$w/tools/$tool" || { echo "FAIL no $tool on this host"; exit 1; }
done
stubpath="$w/bin:$w/tools"
cfg="$w/clone/config_background.json"
while read -r pid tty conf; do
  printf '%s %s/clone/xmrig --config=%s/clone/%s\n' "$tty" "$w" "$w" "$conf" > "$w/procs/$pid"
done <<PROCS
9999901 ?? config_background.json
9999902 ? config_background.json
9999903 ttys001 config_background.json
9999904 ?? config.json
9999905 ? config_background.json
PROCS
cat > "$w/bin/pgrep" <<STUB
#!/bin/bash
echo "pgrep \$*" >> "$w/pgrep.log"
[ "\$*" = "-u $(id -u) -x xmrig" ] || exit 2
[ -n "\${NO_MINERS:-}" ] && exit 1
ls "$w/procs"
STUB
cat > "$w/bin/ps" <<STUB
#!/bin/bash
[ "\$1 \$2 \$3 \$4 \$5" = "-o tty= -o args= -p" ] || exit 2
cat "$w/procs/\$6"
STUB
for k in kill pkill; do printf '#!/bin/sh\necho "%s $*" >> "%s/signals"\n' "$k" "$w" > "$w/bin/$k"; done
SIGNALS="$w/signals"
kill() { echo "kill $*" >> "$SIGNALS"; }
export SIGNALS
export -f kill
chmod +x "$w/bin/"*
want_report="Warning: xmrig is still running detached from an earlier background-mode start: PID 9999901 9999902.
Stop it with: kill 9999901 9999902"
out=$(PATH=$stubpath report_detached_miners "$cfg" 9999905)
same "report: output" "$want_report" "$out"
same "report: pgrep call" "pgrep -u $(id -u) -x xmrig" "$(cat "$w/pgrep.log")"
out=$(PATH=$stubpath report_detached_miners "$cfg" "")
same "report, no service process: output" "Warning: xmrig is still running detached from an earlier background-mode start: PID 9999901 9999902 9999905.
Stop it with: kill 9999901 9999902 9999905" "$out"
out=$(NO_MINERS=1 PATH=$stubpath report_detached_miners "$cfg" 9999905)
same "report, no miner: output" "" "$out"
[ ! -s "$w/signals" ] || fail "report: signalled a process: $(cat "$w/signals")"

# Both setup scripts, in a fixture clone whose service config still has background mode on.
c="$w/clone"
mkdir -p "$c/scripts" "$c/templates" "$c/configs" "$w/home"
cp "$root"/scripts/setup_service_*.sh "$c/scripts/"
cp "$root"/templates/*.template "$c/templates/"
: > "$c/xmrig"; chmod +x "$c/xmrig"
printf '#!/bin/sh\necho "sudo $*" >> "%s/sudo.log"\n' "$w" > "$w/bin/sudo"
cat > "$w/bin/systemctl" <<'STUB'
#!/bin/sh
[ "$*" = "show -p MainPID --value xmrig.service" ] && echo 9999905
exit 0
STUB
# stat: the Debian setup reads the binary's owner; this user owns it, so nothing else is asked.
printf '#!/bin/sh\necho "%s 755"\n' "$(id -un)" > "$w/bin/stat"
cat > "$w/bin/launchctl" <<STUB
#!/bin/sh
echo "launchctl \$*" >> "$w/launchctl.log"
[ "\$1" = list ] && printf 'PID\tStatus\tLabel\n9999905\t0\tcom.moneroocean.xmrig\n7\t0\tcom.example.other\n'
exit 0
STUB
chmod +x "$w/bin/"*
IFS=: read -ra dirs <<< "$stubpath"
for d in "${dirs[@]}"; do
  case $d in "$w"/*) ;; *) echo "FAIL the stub PATH holds a host directory: $d"; exit 1 ;; esac
done
for t in sudo chown useradd; do
  r=$(PATH=$stubpath; type -P "$t")
  case $r in "" | "$w/bin/$t") ;; *) echo "FAIL the stub PATH reaches $r"; exit 1 ;; esac
done
for os in debian macos; do
  cp "$w/cfg/on2" "$c/configs/config_background.json"
  ln -sf "$c/configs/config_background.json" "$c/config_background.json"
  rm -f "$w/signals"
  out=$(cd "$w" && HOME="$w/home" TMPDIR="$w" PATH=$stubpath bash "$c/scripts/setup_service_$os.sh" 2>&1); code=$?
  [ "$code" -eq 0 ] || fail "$os setup: exit $code"
  cmp -s "$c/configs/config_background.json" "$w/cfg/off2" || fail "$os setup: the service config is not the template with background off"
  printf '%s\n' "$out" | grep -qxF "Turned off background mode in $c/config_background.json: the service now supervises the miner." \
    || fail "$os setup: no line saying background mode was turned off"
  [ "$(printf '%s\n' "$out" | grep -A1 -xF "Warning: xmrig is still running detached from an earlier background-mode start: PID 9999901 9999902.")" = "$want_report" ] \
    || fail "$os setup: no report of the detached miners"
  [ ! -s "$w/signals" ] || fail "$os setup: signalled a process: $(cat "$w/signals")"
done
grep -qxF "        <string>--config=$c/config_background.json</string>" "$w/home/Library/LaunchAgents/com.moneroocean.xmrig.plist" \
  || fail "macos setup: the plist does not run the service config"
# A service config the setup cannot write (read-only, and this user is not root): the setup stops
# with one error line and exit 1, before anything is installed, registered or loaded.
for os in debian macos; do
  cp "$w/cfg/on2" "$c/configs/config_background.json"
  chmod 444 "$c/configs/config_background.json"
  rm -f "$w/sudo.log" "$w/launchctl.log" "$w/home/Library/LaunchAgents/com.moneroocean.xmrig.plist"
  out=$(cd "$w" && HOME="$w/home" TMPDIR="$w" PATH=$stubpath bash "$c/scripts/setup_service_$os.sh" 2>&1); code=$?
  [ "$code" -eq 1 ] || fail "$os setup, config not writable: exit $code"
  case $os in
    debian) want="ERROR: Failed to turn off background mode in $c/config_background.json." ;;
    macos) want="Error: Failed to turn off background mode in $c/config_background.json" ;;
  esac
  printf '%s\n' "$out" | grep -qxF "$want" || fail "$os setup, config not writable: no error line"
  cmp -s "$c/configs/config_background.json" "$w/cfg/on2" || fail "$os setup, config not writable: the config changed"
  [ ! -e "$w/sudo.log" ] && [ ! -e "$w/launchctl.log" ] && [ ! -e "$w/home/Library/LaunchAgents/com.moneroocean.xmrig.plist" ] \
    || fail "$os setup, config not writable: the setup went on past the error"
  chmod 644 "$c/configs/config_background.json"
done
[ "$rc" -eq 0 ] && echo "PASS service-background"
exit "$rc"
