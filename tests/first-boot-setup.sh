#!/bin/bash
# The first-boot setup (scripts/first_boot.sh setup) installs the release its custom script came
# with: it waits for apt and the network, fetches that tag's installer over HTTPS, refuses it
# unless its sha256 is the one the script carries, and runs it with --prebuilt. The setup is
# recorded done only once the installer exits 0 and xmrig.service is enabled and running; every
# refusal leaves it undone, exits 1 and lights the error LED, and a done board only sets the
# heartbeat. SSH left on or the host name not set stops the setup before the installer. A clone a
# power cut left at the wrong commit is removed before the next run.
# Every run is under env -i with stub curl, git, pgrep, systemctl, hostname and sleep, and a stub
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
# curl serves srv/install.sh and answers the SHA256SUMS HEAD; it fails while curl-fails counts down.
cat > "$w/stubs/curl" <<EOF
#!/bin/bash
echo "curl \$*" >> "$w/calls.log"
bash "$w/count.sh" "$w/curl-fails" && exit 7
out=- url=
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out=\$2; shift ;; https://*) url=\$1 ;; esac
  shift
done
case "\$url" in
  */scripts/install.sh) if [ "\$out" = - ]; then cat "$w/srv/install.sh"; else cat "$w/srv/install.sh" > "\$out"; fi ;;
  */SHA256SUMS) ;;
  *) exit 22 ;;
esac
EOF
# pgrep finds apt busy while apt-busy counts down.
printf '#!/bin/bash\necho "pgrep $*" >> "%s/calls.log"\nbash "%s/count.sh" "%s/apt-busy"\n' "$w" "$w" "$w" > "$w/stubs/pgrep"
# systemctl: xmrig.service is enabled and running unless no-service exists; no SSH server is enabled
# unless ssh-on exists, and then its disable fails.
printf '#!/bin/bash\necho "systemctl $*" >> "%s/calls.log"\ncase "$1 ${*: -1}" in "is-"*" xmrig.service") [ ! -e "%s/no-service" ] ;; "is-enabled ssh.service") [ -e "%s/ssh-on" ] ;; is-*) exit 1 ;; disable*) exit 1 ;; esac\n' "$w" "$w" "$w" > "$w/stubs/systemctl"
# git describe answers the tag clone-tag holds, or fails as on an untagged commit.
printf '#!/bin/bash\necho "git $*" >> "%s/calls.log"\n[ -f "%s/clone-tag" ] || exit 128\ncat "%s/clone-tag"\n' "$w" "$w" "$w" > "$w/stubs/git"
printf '#!/bin/bash\necho "hostname $*" >> "%s/calls.log"\n' "$w" > "$w/stubs/hostname"
# sleep: the blink loop's half seconds pass fast and unlogged; the retry waits are logged, not slept.
printf '#!/bin/bash\nif [ "$1" = 0.5 ]; then exec "%s" 0.05; fi\necho "sleep $*" >> "%s/calls.log"\n' "$real_sleep" "$w" > "$w/stubs/sleep"
chmod +x "$w/stubs/"*
# The installer records its arguments and umask, and exits with the code in installer-exit.
cat > "$w/srv/install.sh" <<EOF
echo "installer \$*" >> "$w/calls.log"
umask > "$w/installer-umask"
code=0; [ -f "$w/installer-exit" ] && read -r code < "$w/installer-exit"
[ "\$code" -eq 0 ] || echo "[  ERROR  ] Invalid wallet address format." >&2
exit "\$code"
EOF
sum=$(sha256sum "$w/srv/install.sh") && sum=${sum%% *}

cat > "$w/drive.sh" <<'EOF'
# shellcheck source=/dev/null
source "$SCRIPT"
RELEASE_TAG="$TAG" INSTALLER_SHA256="$SUM"
STATE_DIR="$FX/state" SETUP_BIN="$FX/sbin/xmrig-first-boot" SETUP_UNIT="$FX/unit/xmrig-first-boot.service"
LEDS_DIR="$FX/leds" DT_COMPATIBLE="$FX/compatible" NET_DIR="$FX/net" MEMINFO="$FX/meminfo"
HOSTNAME_FILE="$FX/etc/hostname" HOSTS_FILE="$FX/etc/hosts" ROOT_SSH_DIR="$FX/ssh" CLONE_DIR="$FX/clone"
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
  rm -rf -- "$fx" "$w/calls.log" "$w/curl-fails" "$w/apt-busy" "$w/no-service" "$w/clone-tag" "$w/installer-exit" "$w/ssh-on"
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
# run <fixture> [tag] [sum]: the setup's output and exit code.
run() {
  local fx="$w/$1" code
  env -i PATH="$w/stubs:$w/tools" SCRIPT="$script" FX="$fx" TAG="${2-v9.9.9}" SUM="${3-$sum}" \
    "$BASH" --norc --noprofile "$w/drive.sh" > "$w/run.out" 2>&1
  code=$?
  cat "$w/run.out"; echo "exit $code"
  local pid; pid=$(cut -d" " -f2 "$fx/pid" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { fail "$1: the blink loop still runs"; kill "$pid"; }
}
led() { printf '%s %s\n' "$(cat "$w/$1/leds/ACT/trigger")" "$(cat "$w/$1/leds/ACT/brightness")"; }
calls() { grep -v '^pgrep ' "$w/calls.log" 2>/dev/null; }
no_done() { [ -e "$w/$1/state/done" ] && fail "$1: done written"; }
raw="https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/v9.9.9/scripts/install.sh"
sums="https://github.com/MorganKryze/Monero-miner-setup/releases/download/v9.9.9/SHA256SUMS"
fetch="curl -fsSL --proto =https --proto-redir =https -o $w/%s/state/install.sh $raw"
head="curl -fsSL --proto =https --proto-redir =https -I -o /dev/null $sums"
ssh_off="systemctl is-enabled --quiet dropbear.service
systemctl is-enabled --quiet ssh.service
hostname rpi5-3fa2"
ok_calls() { # fixture: the calls of a clean run, installer arguments included
  printf '%s\n' "$head" "$(printf "$fetch" "$1")" \
    "installer -w $W --mode eco --prebuilt --autostart -y --name ${2:-rpi5-3fa2}${3:+ $3}" \
    "systemctl is-enabled --quiet xmrig.service" "systemctl is-active --quiet xmrig.service"
}
ssh_line="[  INFO   ] No ssh_key in the settings: SSH is turned off."
done_line="[ SUCCESS ] First-boot setup done: rpi5-3fa2 mines as worker"

# ---- the release ----
board unbundled
same "unbundled script" "[  ERROR  ] This script carries no release: take Automation_Custom_Script.sh from a release's dietpi-first-boot.zip, not from the repository.
exit 1" "$(run unbundled "" "")"
same "unbundled: error LED" "none 255" "$(led unbundled)"
same "unbundled: no call" "" "$(calls)"
no_done unbundled

board mismatch
bad=0000000000000000000000000000000000000000000000000000000000000000
same "fingerprint mismatch" "$ssh_line
[  ERROR  ] The installer of v9.9.9 has sha256 $sum where this script expects $bad, so nothing is installed. Download dietpi-first-boot.zip of v9.9.9 again from the release page and check it against SHA256SUMS.
exit 1" "$(run mismatch v9.9.9 "$bad")"
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
$head
sleep 10
$head
sleep 10
$head
sleep 10
$(ok_calls net)" "$(calls)"
board apt; echo 2 > "$w/apt-busy"
same "apt busy then idle" "$ssh_line
[  INFO   ] Waiting for apt to finish: the installer installs packages.
$done_line rpi5-3fa2.
exit 0" "$(run apt)"
same "apt waits" "$ssh_off
sleep 10
sleep 10
$(ok_calls apt)" "$(calls)"
for p in apt apt-get dpkg dietpi-software dietpi-update; do
  grep -qx "pgrep -u 0 -x $p" "$w/calls.log" || fail "apt wait: no pgrep -u 0 -x $p"
done

# ---- memory ----
board small
printf 'MemTotal:        2014000 kB\n' > "$w/small/meminfo"
same "memory under the floor" "[  ERROR  ] This board has 1966 MiB of memory, under the 2560 MiB RandomX's fast mode needs. Add light = yes to the settings to mine in the slower light mode, and flash the card again.
exit 1" "$(run small)"
same "small: no call" "" "$(calls)"
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
[  ERROR  ] This board has no profile: the first boot covers the Raspberry Pi 5 and RK3588 boards. Install with the script instead, as the README says.
exit 1" "$(run pi4)"
same "pi4: no call" "" "$(calls)"
same "pi4: host name kept" "DietPi" "$(cat "$w/pi4/etc/hostname")"
no_done pi4

# ---- the host steps ----
board sshon; : > "$w/ssh-on"
same "SSH not turned off" "[  ERROR  ] Failed to turn off ssh.service. The setup runs again at the next boot; see journalctl -u xmrig-first-boot.service.
exit 1" "$(run sshon)"
grep -q '^installer' "$w/calls.log" && fail "SSH not turned off: the installer ran"
same "SSH not turned off: error LED" "none 255" "$(led sshon)"
no_done sshon
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
$(ok_calls ok shelf-2 "-p pool.example.org:10128 --donate 1")" "$(calls)"
[ -e "$w/ok/state/done" ] || fail "success: no done"
[ -e "$w/ok/state/installing" ] && fail "success: installing left"
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

# ---- a power cut during the clone ----
board cut; : > "$w/cut/state/installing"; mkdir -p "$w/cut/clone/.git"
same "cut clone off the tag" "$ssh_line
$done_line rpi5-3fa2.
exit 0" "$(run cut)"
[ -e "$w/cut/clone" ] && fail "cut: a clone off the tag is kept"
grep -qx "git -C $w/cut/clone describe --exact-match --tags" "$w/calls.log" || fail "cut: no git describe"
board kept; : > "$w/kept/state/installing"; mkdir -p "$w/kept/clone/.git"; echo v9.9.9 > "$w/clone-tag"
same "cut clone at the tag" "$ssh_line
$done_line rpi5-3fa2.
exit 0" "$(run kept)"
[ -d "$w/kept/clone/.git" ] || fail "cut: the clone at the tag is removed"
board fresh; mkdir -p "$w/fresh/clone/.git"
run fresh > /dev/null
[ -d "$w/fresh/clone/.git" ] || fail "a clone is removed without installing"

same "floor equal to the installer's" "$(grep -x 'RX_FLOOR_MIB=[0-9]*' "$root/scripts/install.sh")" "$(grep -x 'RX_FLOOR_MIB=[0-9]*' "$script")"

[ "$rc" -eq 0 ] && echo "PASS first-boot-setup"
exit "$rc"
