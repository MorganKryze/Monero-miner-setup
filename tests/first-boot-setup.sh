#!/bin/bash
# The first-boot setup (scripts/first_boot.sh setup) installs the release its custom script came
# with: it waits for apt and the network, fetches that tag's installer over HTTPS, refuses it
# unless its sha256 is the one the script carries, and runs it with --prebuilt. The setup is
# recorded done only once the installer exits 0 and xmrig.service is enabled and running; every
# refusal leaves it undone, exits 1 and lights the error LED, and a done board only sets the
# heartbeat. SSH is turned off first, before any check that can refuse but the one for a copy without
# a release, and once more after the apt wait; SSH left on or the host name not set stops the setup before the installer. A clone a
# power cut left at the wrong commit is removed before the next run.
# DietPi's minimal image has no git, make or bc: the setup installs the missing ones through apt
# before the installer, and stops when that install fails.
# Every run is under env -i with stub curl, git, make, bc, apt-get, pgrep, systemctl, hostname and sleep, and a stub
# installer served by the stub curl; nothing reaches the network. Run from the repository root.
# Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
same() { # label, expected, got
  [ "$2" = "$3" ] || { fail "$1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/    /'; }
}
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/tools" "$w/stubs" "$w/srv"
for t in chmod cp mkdir mktemp mv rm cat sha256sum bash; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
real_sleep=$(command -v sleep) || { echo "FAIL no sleep on this host"; exit 1; }
# count <file>: exit 0 and decrement while the file holds a number above 0.
cat > "$w/count.sh" <<'EOF'
n=0; [ -f "$1" ] && read -r n < "$1"
[ "$n" -gt 0 ] || exit 1
echo $((n - 1)) > "$1"
EOF
# curl serves srv/install.sh and answers the SHA256SUMS HEAD; it fails with curl's own error line while
# curl-fails counts down, and on the download alone while fetch-fails does.
cat > "$w/stubs/curl" <<EOF
#!/bin/bash
echo "curl \$*" >> "$w/calls.log"
bash "$w/count.sh" "$w/curl-fails" && { echo "curl: (7) Failed to connect to github.com port 443" >&2; exit 7; }
out=- url=
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out=\$2; shift ;; https://*) url=\$1 ;; esac
  shift
done
case "\$url" in
  */scripts/install.sh) bash "$w/count.sh" "$w/fetch-fails" && { echo "curl: (56) Recv failure: Connection reset by peer" >&2; exit 56; }
    if [ "\$out" = - ]; then cat "$w/srv/install.sh"; else cat "$w/srv/install.sh" > "\$out"; fi ;;
  */SHA256SUMS) ;;
  *) exit 22 ;;
esac
EOF
# pgrep finds apt busy while apt-busy counts down.
printf '#!/bin/bash\necho "pgrep $*" >> "%s/calls.log"\nbash "%s/count.sh" "%s/apt-busy"\n' "$w" "$w" "$w" > "$w/stubs/pgrep"
# systemctl: xmrig.service is enabled and running unless no-service exists; of the SSH units, systemd
# knows dropbear.service alone, which stays active after it is turned off while ssh-on exists; the
# others are inactive.
cat > "$w/stubs/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$w/calls.log"
case "\$1 \${*: -1}" in
  "is-"*" xmrig.service") [ ! -e "$w/no-service" ] ;;
  "list-unit-files "*) echo "dropbear.service enabled enabled" ;;
  "is-active dropbear.service") if [ -e "$w/ssh-on" ]; then echo active; else echo inactive; exit 3; fi ;;
  "is-active "*) echo inactive; exit 3 ;;
  is-*) exit 1 ;;
esac
EOF
# git describe answers the tag clone-tag holds, or fails as on an untagged commit; git submodule
# status prints sub-status, else both submodules checked out at their pinned commits, in git's order.
cat > "$w/stubs/git" <<EOF
#!/bin/bash
echo "git \$*" >> "$w/calls.log"
case "\$*" in
  *" describe "*) [ -f "$w/clone-tag" ] || exit 128; cat "$w/clone-tag" ;;
  *" submodule status") if [ -f "$w/sub-status" ]; then cat "$w/sub-status"; else printf ' %s\n' "5e4d3c2 dependencies/bash-toolbox (v1.4.0)" "3f2a1b0 dependencies/xmrig (v6.22.2)"; fi ;;
esac
EOF
printf '#!/bin/bash\necho "hostname $*" >> "%s/calls.log"\n' "$w" > "$w/stubs/hostname"
# sleep: the blink loop's half seconds pass fast and unlogged; the retry waits are logged, not slept,
# and each records the LED's brightness, sampled until it has been seen both on and off or for up to
# 40 samples (twelve blink periods, more on a loaded host). Past 20 waits a loop runs away: sleep-cap
# is written and the setup gets SIGTERM, so the case FAILs instead of hanging.
cat > "$w/stubs/sleep" <<EOF
#!/bin/bash
if [ "\$1" = 0.5 ]; then exec "$real_sleep" 0.05; fi
echo "sleep \$*" >> "$w/calls.log"
n=0; [ -f "$w/sleeps" ] && read -r n < "$w/sleeps"
echo \$((n + 1)) > "$w/sleeps"
[ "\$n" -lt 20 ] || { : > "$w/sleep-cap"; kill "\$PPID"; exit 1; }
s=; for ((i = 0; i < 40; i++)); do b=; read -r b < "\$FX/leds/ACT/brightness"; s="\$s \$b"
  [[ \$s =~ \ 0( |\$) && \$s =~ \ 255( |\$) ]] && break; "$real_sleep" 0.03; done
echo "\$s" >> "$w/led-samples"
EOF
# apt-get records its arguments and DEBIAN_FRONTEND, and fails while apt-fails exists.
cat > "$w/stubs/apt-get" <<EOF
#!/bin/bash
echo "apt-get \$* (\$DEBIAN_FRONTEND)" >> "$w/calls.log"
[ ! -e "$w/apt-fails" ] || { echo "E: Unable to locate package bc" >&2; exit 100; }
[ ! -e "$w/apt-fails-once" ] || { rm -f "$w/apt-fails-once"; echo "E: Unable to locate package bc" >&2; exit 100; }
EOF
chmod +x "$w/stubs/"*
# The installer records its arguments, its umask and whether the installing marker is there while it
# runs, and exits with the code in installer-exit.
cat > "$w/srv/install.sh" <<EOF
echo "installer \$*" >> "$w/calls.log"
umask > "$w/installer-umask"
[ -e "\$FX/state/installing" ] && : > "$w/installing-seen"
code=0; [ -f "$w/installer-exit" ] && read -r code < "$w/installer-exit"
[ "\$code" -eq 0 ] || echo "[  ERROR  ] Invalid wallet address format." >&2
exit "\$code"
EOF
sum=$(sha256sum "$w/srv/install.sh") && sum=${sum%% *}

cat > "$w/drive.sh" <<'EOF'
# shellcheck source=/dev/null
source "$SCRIPT"
# A runaway loop ended by the sleep stub stops its blink loop too.
trap 'led_blink_stop; exit 143' TERM
RELEASE_TAG="$TAG" INSTALLER_SHA256="$SUM"
STATE_DIR="$FX/state" SETUP_BIN="$FX/sbin/xmrig-first-boot" SETUP_UNIT="$FX/unit/xmrig-first-boot.service"
LEDS_DIR="$FX/leds" DT_COMPATIBLE="$FX/compatible" NET_DIR="$FX/net" MEMINFO="$FX/meminfo"
HOSTNAME_FILE="$FX/etc/hostname" HOSTS_FILE="$FX/etc/hosts" ROOT_SSH_DIR="$FX/ssh" CLONE_DIR="$FX/clone"
SSHD_DROPIN="$FX/etc/ssh/sshd_config.d/00-xmrig-first-boot.conf" DROPBEAR_DEFAULTS="$FX/etc/default/dropbear"
setup
code=$?
printf 'pid %s\n' "$BLINK_PID" > "$FX/pid"
exit "$code"
EOF
script="$root/scripts/first_boot.sh"
W=44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A
# board <fixture> [settings lines...]: a Pi 5 with 8 GiB, its LED off, the settings given.
board() {
  local fx="$w/$1"; shift
  rm -rf -- "$fx" "$w/calls.log" "$w/curl-fails" "$w/fetch-fails" "$w/apt-busy" "$w/no-service" "$w/clone-tag" "$w/sub-status" "$w/installer-exit" "$w/ssh-on" \
    "$w/sleeps" "$w/sleep-cap" "$w/led-samples" "$w/installing-seen" "$w/apt-fails" "$w/apt-fails-once"
  # git (the stub above), make and bc are on the board unless a case removes them.
  printf '#!/bin/bash\n' > "$w/stubs/make"; printf '#!/bin/bash\n' > "$w/stubs/bc"; chmod +x "$w/stubs/make" "$w/stubs/bc"
  mkdir -p "$fx/state" "$fx/leds/ACT" "$fx/net/eth0" "$fx/dev" "$fx/etc"
  printf 'raspberrypi,5-model-b\0brcm,bcm2712\0' > "$fx/compatible"
  ln -s "$fx/dev" "$fx/net/eth0/device"; printf '1\n' > "$fx/net/eth0/type"
  printf 'd8:3a:dd:41:3f:a2\n' > "$fx/net/eth0/address"
  printf 'DietPi\n' > "$fx/etc/hostname"; printf '127.0.0.1 localhost\n127.0.1.1 DietPi\n' > "$fx/etc/hosts"
  printf 'none\n' > "$fx/leds/ACT/trigger"; printf '0\n' > "$fx/leds/ACT/brightness"
  printf '255\n' > "$fx/leds/ACT/max_brightness"
  printf 'MemTotal:        8156396 kB\nMemFree:  100 kB\n' > "$fx/meminfo"
  printf '%s\n' "wallet = $W" "mode = eco" "$@" > "$fx/state/settings"
}
# after <fixture>: FAILs a blink loop left running or a loop the sleep cap ended.
after() {
  local pid; pid=$(cut -d" " -f2 "$w/$1/pid" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { fail "$1: the blink loop still runs"; kill "$pid"; }
  [ -e "$w/sleep-cap" ] && fail "$1: a loop ran away, ended after 20 waits"
}
# run <fixture> [tag] [sum]: the setup's output and exit code.
run() {
  local code
  env -i PATH="$w/stubs:$w/tools" SCRIPT="$script" FX="$w/$1" TAG="${2-v9.9.9}" SUM="${3-$sum}" \
    "$BASH" --norc --noprofile "$w/drive.sh" > "$w/run.out" 2>&1
  code=$?
  cat "$w/run.out"; echo "exit $code"
  after "$1"
}
# split <fixture> [tag] [sum]: like run, stdout lines as "out", stderr lines as "err".
split() {
  local code l
  env -i PATH="$w/stubs:$w/tools" SCRIPT="$script" FX="$w/$1" TAG="${2-v9.9.9}" SUM="${3-$sum}" \
    "$BASH" --norc --noprofile "$w/drive.sh" > "$w/run.out" 2> "$w/run.err"
  code=$?
  while IFS= read -r l; do echo "out $l"; done < "$w/run.out"
  while IFS= read -r l; do echo "err $l"; done < "$w/run.err"
  echo "exit $code"
  after "$1"
}
led() { printf '%s %s\n' "$(cat "$w/$1/leds/ACT/trigger")" "$(cat "$w/$1/leds/ACT/brightness")"; }
calls() { grep -v '^pgrep ' "$w/calls.log" 2>/dev/null; }
no_done() { [ -e "$w/$1/state/done" ] && fail "$1: done written"; }
raw="https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/v9.9.9/scripts/install.sh"
sums="https://github.com/MorganKryze/Monero-miner-setup/releases/download/v9.9.9/SHA256SUMS"
fetch="curl -fsSL --proto =https --proto-redir =https -o $w/%s/state/install.sh $raw"
head="curl -fsSL --proto =https --proto-redir =https -I -o /dev/null $sums"
# The SSH policy's calls without a key: every unit systemd knows is disabled, masked, then checked.
ssh_run="systemctl list-unit-files --no-legend --no-pager
systemctl disable --now dropbear.service
systemctl mask dropbear.service
systemctl is-active dropbear.service
systemctl is-active dropbear.socket
systemctl is-active ssh.service
systemctl is-active ssh.socket
systemctl is-active sshd.service"
ssh_off="$ssh_run
hostname rpi5-3fa2"
ok_calls() { # fixture: the calls of a clean run, installer arguments included
  printf '%s\n' "$head" "$(printf "$fetch" "$1")" \
    "installer -w $W --mode eco --prebuilt --autostart -y --name ${2:-rpi5-3fa2}${3:+ $3}" \
    "systemctl is-enabled --quiet xmrig.service" "systemctl is-active --quiet xmrig.service"
}
ssh_line="[  INFO   ] No ssh_key in the settings: the SSH server is disabled and masked."
done_line="[ SUCCESS ] First-boot setup done: rpi5-3fa2 mines as worker"

# ---- the release ----
board unbundled
same "unbundled script" "[  ERROR  ] This script carries no release: take Automation_Custom_Script.sh from a release's dietpi-first-boot.zip, not from the repository.
exit 1" "$(run unbundled "" "")"
same "unbundled: error LED" "none 255" "$(led unbundled)"
# The repository's copy, run by hand on any host, leaves its SSH alone.
same "unbundled: SSH untouched" "" "$(calls)"
no_done unbundled

board mismatch
bad=0000000000000000000000000000000000000000000000000000000000000000
same "fingerprint mismatch" "out $ssh_line
err [  ERROR  ] The installer of v9.9.9 has sha256 $sum where this script expects $bad, so nothing is installed. Download dietpi-first-boot.zip of v9.9.9 again from the release page and check it against SHA256SUMS.
exit 1" "$(split mismatch v9.9.9 "$bad")"
grep -q '^installer' "$w/calls.log" && fail "mismatch: the installer ran"
[ -e "$w/mismatch/state/install.sh" ] && fail "mismatch: the refused installer is kept"
same "mismatch: error LED" "none 255" "$(led mismatch)"
no_done mismatch

# ---- waits ----
board net; echo 3 > "$w/curl-fails"
same "network down three tries" "$ssh_line
[  INFO   ] Waiting for the network to fetch the installer of v9.9.9...
$done_line rpi5-3fa2.
exit 0" "$(run net)"
same "network waits" "$ssh_off
$ssh_run
$head
sleep 10
$head
sleep 10
$head
sleep 10
$(ok_calls net)" "$(calls)"
grep -E ' 0( |$)' "$w/led-samples" 2>/dev/null | grep -qE ' 255( |$)' || fail "network wait: the LED does not blink"
board dl; echo 1 > "$w/fetch-fails"
same "download cut once" "$ssh_line
[  INFO   ] Waiting for the network to fetch the installer of v9.9.9...
$done_line rpi5-3fa2.
exit 0" "$(run dl)"
board apt; echo 2 > "$w/apt-busy"
same "apt busy then idle" "$ssh_line
[  INFO   ] Waiting for apt to finish: the installer installs packages.
$done_line rpi5-3fa2.
exit 0" "$(run apt)"
same "apt waits" "$ssh_off
sleep 10
sleep 10
$ssh_run
$(ok_calls apt)" "$(calls)"
for p in apt apt-get dpkg dietpi-software dietpi-update; do
  grep -qx "pgrep -u 0 -x $p" "$w/calls.log" || fail "apt wait: no pgrep -u 0 -x $p"
done

# ---- memory ----
board small
printf 'MemTotal:        2014000 kB\n' > "$w/small/meminfo"
same "memory under the floor" "$ssh_line
[  ERROR  ] This board has 1966 MiB of memory, under the 2560 MiB RandomX's fast mode needs. Add light = yes to the settings to mine in the slower light mode, and flash the card again.
exit 1" "$(run small)"
same "small: SSH off first" "$ssh_run" "$(calls)"
same "small: error LED" "none 255" "$(led small)"
no_done small
board light "light = yes"
printf 'MemTotal:        2014000 kB\n' > "$w/light/meminfo"
same "memory under the floor, light" "$ssh_line
$done_line rpi5-3fa2.
exit 0" "$(run light)"

# ---- the board ----
board pi4; printf 'raspberrypi,4-model-b\0brcm,bcm2711\0' > "$w/pi4/compatible"
same "board outside the profiles" "[ WARNING ] No status LED is known for this board: the setup goes on without LEDs.
$ssh_line
[  ERROR  ] This board has no profile: the first boot covers the Raspberry Pi 5 and RK3588 boards. Install with the script instead, as the README says.
exit 1" "$(run pi4)"
same "pi4: SSH off first" "$ssh_run" "$(calls)"
same "pi4: host name kept" "DietPi" "$(cat "$w/pi4/etc/hostname")"
no_done pi4

# ---- the host steps ----
board sshon; : > "$w/ssh-on"
same "SSH still active" "[  ERROR  ] dropbear.service is still active after it was disabled and masked, so SSH stays open. The setup runs again at the next boot; see journalctl -u xmrig-first-boot.service.
exit 1" "$(run sshon)"
grep -q '^installer' "$w/calls.log" && fail "SSH still active: the installer ran"
same "SSH still active: error LED" "none 255" "$(led sshon)"
no_done sshon
# A refused settings file still turns SSH off.
board badset; printf 'wallet = %s\nmode = turbo\n' "$W" > "$w/badset/state/settings"
same "bad settings: SSH off" "[  ERROR  ] Setting 'mode' must be max or eco. Fix it in the settings at the top of Automation_Custom_Script.sh and flash the card again, or edit /var/lib/xmrig-first-boot/settings as root on the board and reboot.
$ssh_line
exit 1" "$(run badset)"
same "bad settings: calls" "$ssh_run" "$(calls)"
no_done badset
board hostdir; rm -f "$w/hostdir/etc/hostname"; mkdir "$w/hostdir/etc/hostname"
same "host name not set" "$ssh_line
[  ERROR  ] Failed to set the host name to rpi5-3fa2. The setup runs again at the next boot; see journalctl -u xmrig-first-boot.service.
exit 1" "$(run hostdir)"
grep -q '^installer' "$w/calls.log" && fail "host name not set: the installer ran"
same "host name not set: error LED" "none 255" "$(led hostdir)"
no_done hostdir

# ---- the installer ----
board refused; echo 1 > "$w/installer-exit"
same "installer refusal" "$ssh_line
[  ERROR  ] Invalid wallet address format.
exit 1" "$(run refused)"
same "refusal: error LED" "none 255" "$(led refused)"
[ -e "$w/refused/state/installing" ] || fail "refusal: installing removed"
grep -q 'xmrig[.]service' "$w/calls.log" && fail "refusal: the service was checked"
no_done refused
board noservice; : > "$w/no-service"
same "installer exit 0 without a service" "$ssh_line
[  ERROR  ] The installer finished, but xmrig.service is not running, so the setup is not marked done. It runs again at the next boot; see journalctl -u xmrig.service.
exit 1" "$(run noservice)"
same "no service: error LED" "none 255" "$(led noservice)"
no_done noservice

board ok "pool = pool.example.org:10128" "donate = 1" "name = shelf-2"
out=$(run ok)
same "success" "$ssh_line
[ SUCCESS ] First-boot setup done: rpi5-3fa2 mines as worker shelf-2.
exit 0" "$out"
same "success calls" "$ssh_off
$ssh_run
$(ok_calls ok shelf-2 "-p pool.example.org:10128 --donate 1")" "$(calls)"
[ -e "$w/ok/state/done" ] || fail "success: no done"
[ -e "$w/ok/state/installing" ] && fail "success: installing left"
[ -e "$w/installing-seen" ] || fail "success: no installing while the installer runs"
same "success: heartbeat" "heartbeat" "$(cat "$w/ok/leds/ACT/trigger")"
grep -q "$W" <<<"$out" && fail "success: the wallet is printed"
# The setup writes under umask 077, but the installer's clone and folders must stay readable by
# the xmrig account the service runs as.
same "success: installer umask" "0022" "$(cat "$w/installer-umask" 2>/dev/null)"

# A done board only beats, at each later boot.
rm -f "$w/calls.log"; printf 'none\n' > "$w/ok/leds/ACT/trigger"
same "done boot" "exit 0" "$(run ok)"
same "done boot: no call" "" "$(cat "$w/calls.log" 2>/dev/null)"
same "done boot: heartbeat" "heartbeat" "$(cat "$w/ok/leds/ACT/trigger")"

# ---- the installer's tools ----
board need; rm -f "$w/stubs/make" "$w/stubs/bc"
same "tools missing" "$ssh_line
[  INFO   ] Installing make bc: the installer needs them.
$done_line rpi5-3fa2.
exit 0" "$(run need)"
same "tools missing: calls" "$ssh_off
$ssh_run
$head
$(printf "$fetch" need)
apt-get install -y --no-install-recommends make bc (noninteractive)
$(ok_calls need | tail -n +3)" "$(calls)"
board needfail; rm -f "$w/stubs/bc"; : > "$w/apt-fails"
same "tools install fails" "out $ssh_line
out [  INFO   ] Installing bc: the installer needs them.
err E: Unable to locate package bc
err E: Unable to locate package bc
err [  ERROR  ] Failed to install bc, which the installer needs. The setup runs again at the next boot; see journalctl -u xmrig-first-boot.service.
exit 1" "$(split needfail)"
grep -q '^installer' "$w/calls.log" && fail "tools install fails: the installer ran"
same "tools install fails: error LED" "none 255" "$(led needfail)"
no_done needfail
# Stale package lists: the first install fails, one update and a retry succeed.
board needupd; rm -f "$w/stubs/bc"; : > "$w/apt-fails-once"
run needupd >/dev/null
same "tools after an update: apt calls" "apt-get install -y --no-install-recommends bc (noninteractive)
apt-get update ()
apt-get install -y --no-install-recommends bc (noninteractive)" "$(grep '^apt-get' "$w/calls.log")"
[ -e "$w/needupd/state/done" ] || fail "tools after an update: no done"

# ---- a power cut during the clone ----
board cut; : > "$w/cut/state/installing"; mkdir -p "$w/cut/clone/.git"
same "cut clone off the tag" "$ssh_line
$done_line rpi5-3fa2.
exit 0" "$(run cut)"
[ -e "$w/cut/clone" ] && fail "cut: a clone off the tag is kept"
grep -qx "git -C $w/cut/clone describe --exact-match --tags" "$w/calls.log" || fail "cut: no git describe"
# kept <fixture>: a cut run's clone at the tag, its submodule checked out.
kept() {
  board "$1"; : > "$w/$1/state/installing"; mkdir -p "$w/$1/clone/.git" "$w/$1/clone/dependencies/xmrig"
  : > "$w/$1/clone/dependencies/xmrig/.git"; echo v9.9.9 > "$w/clone-tag"
}
kept kept
same "cut clone at the tag" "$ssh_line
$done_line rpi5-3fa2.
exit 0" "$(run kept)"
[ -d "$w/kept/clone/.git" ] || fail "cut: the clone at the tag is removed"
grep -qx "git -C $w/kept/clone submodule status" "$w/calls.log" || fail "cut: no git submodule status"
kept subnone; printf '%s\n' " 5e4d3c2 dependencies/bash-toolbox (v1.4.0)" "-3f2a1b0 dependencies/xmrig" > "$w/sub-status"
run subnone > /dev/null
[ -e "$w/subnone/clone" ] && fail "cut: a clone at the tag without its submodule is kept"
kept subplus; printf '%s\n' " 5e4d3c2 dependencies/bash-toolbox (v1.4.0)" "+9c8d7e6 dependencies/xmrig (v6.21.0)" > "$w/sub-status"
run subplus > /dev/null
[ -e "$w/subplus/clone" ] && fail "cut: a clone at the tag with its submodule off the pin is kept"
kept subempty; rm -f "$w/subempty/clone/dependencies/xmrig/.git"
run subempty > /dev/null
[ -e "$w/subempty/clone" ] && fail "cut: a clone at the tag without dependencies/xmrig checked out is kept"
board fresh; mkdir -p "$w/fresh/clone/.git"
run fresh > /dev/null
[ -d "$w/fresh/clone/.git" ] || fail "a clone is removed without installing"

same "floor equal to the installer's" "$(grep -x 'RX_FLOOR_MIB=[0-9]*' "$root/scripts/install.sh")" "$(grep -x 'RX_FLOOR_MIB=[0-9]*' "$script")"

[ "$rc" -eq 0 ] && echo "PASS first-boot-setup"
exit "$rc"
