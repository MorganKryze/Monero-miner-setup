#!/bin/bash
# The first-boot setup's host steps (scripts/first_boot.sh): the board's name (short model name and
# the first wired interface's MAC tail, lower case), the refusal of a board outside the profiles,
# the hostname files, SSH closed without a key or opened to the key alone, and avahi-daemon only
# when mdns is on. Every function runs under env -i against fixture trees, with stub systemctl,
# hostname, apt-get and dpkg-query that only record their arguments. Run from the repository root.
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
mkdir -p "$w/tools" "$w/stubs"
for t in chmod cp mkdir mktemp mv rm cat; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
# systemctl: is-enabled answers yes for the units listed in the enabled file.
cat > "$w/stubs/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$w/calls.log"
if [ "\$1" = is-enabled ]; then
  u=\${*: -1}
  while read -r e; do [ "\$e" = "\$u" ] && exit 0; done < "$w/enabled"
  exit 1
fi
exit 0
EOF
printf '#!/bin/bash\necho "hostname $*" >> "%s/calls.log"\n' "$w" > "$w/stubs/hostname"
printf '#!/bin/bash\necho "apt-get $*" >> "%s/calls.log"\n[ -e "%s/mdns-installed-seen" ] || [ ! -e "$STATE/mdns-installed" ] || : > "%s/mdns-installed-seen"\n' "$w" "$w" "$w" > "$w/stubs/apt-get"
# dpkg-query reports avahi-daemon installed when the avahi file exists.
printf '#!/bin/bash\necho "dpkg-query $*" >> "%s/calls.log"\nif [ -e "%s/avahi" ]; then printf "installed"; else exit 1; fi\n' "$w" "$w" > "$w/stubs/dpkg-query"
chmod +x "$w/stubs/"*

cat > "$w/drive.sh" <<'EOF'
# shellcheck source=/dev/null
source "$SCRIPT"
STATE_DIR="$FX/state" LEDS_DIR="$FX/leds" DT_COMPATIBLE="$FX/compatible" NET_DIR="$FX/net"
HOSTNAME_FILE="$FX/etc/hostname" HOSTS_FILE="$FX/etc/hosts" ROOT_SSH_DIR="$FX/ssh"
S_SSH_KEY="$KEY" S_MDNS="$MDNS"
"$@"
EOF
script="$root/scripts/first_boot.sh"
# run <fixture> <function> [args]: the function's output and exit code.
run() {
  local fx="$w/$1" code; shift
  env -i PATH="$w/stubs:$w/tools" SCRIPT="$script" FX="$fx" STATE="$fx/state" KEY="${KEY-}" MDNS="${MDNS-off}" \
    "$BASH" --norc --noprofile "$w/drive.sh" "$@" > "$w/run.out" 2>&1
  code=$?
  cat "$w/run.out"; echo "exit $code"
}
calls() { cat "$w/calls.log" 2>/dev/null; }
# iface <fixture> <name> <mac> [wireless|phy80211|nodevice|loopback]
iface() {
  local d="$w/$1/net/$2"
  mkdir -p "$d" "$w/$1/devices/$2"
  printf '%s\n' "$3" > "$d/address"
  printf '1\n' > "$d/type"
  case "${4-}" in
    wireless) mkdir "$d/wireless" ;;
    phy80211) ln -s "$w/$1/devices/$2" "$d/phy80211" ;;
    loopback) printf '772\n' > "$d/type"; return ;;
    nodevice) return ;;
  esac
  ln -s "$w/$1/devices/$2" "$d/device"
}
# board <fixture> <compatible...>: a device tree list, eth0 wired and wlan0 wireless.
board() {
  local fx="$w/$1" c; shift
  rm -rf -- "$fx" "$w/calls.log" "$w/avahi" "$w/mdns-installed-seen"
  mkdir -p "$fx/state" "$fx/etc"
  : > "$w/enabled"
  : > "$fx/compatible"
  for c in "$@"; do printf '%s\0' "$c" >> "$fx/compatible"; done
  iface "${fx##*/}" lo 00:00:00:00:00:00 loopback
  iface "${fx##*/}" eth0 D8:3A:DD:41:3F:A2
  iface "${fx##*/}" wlan0 d8:3a:dd:41:77:01 wireless
}

# ---- the board's name ----
board pi raspberrypi,5-model-b brcm,bcm2712
same "Pi 5 name" "rpi5-3fa2
exit 0" "$(run pi board_name)"
board plus xunlong,orangepi-5-plus rockchip,rk3588
same "Orange Pi 5 Plus name" "opi5plus-3fa2
exit 0" "$(run plus board_name)"
board max xunlong,orangepi-5-max rockchip,rk3588
same "Orange Pi 5 Max name" "opi5max-3fa2
exit 0" "$(run max board_name)"
board other radxa,rock-5b rockchip,rk3588
same "unknown RK3588 model" "rk3588-3fa2
exit 0" "$(run other board_name)"
board rk3588s friendlyarm,nanopi-r6s rockchip,rk3588s
same "RK3588S model" "rk3588-3fa2
exit 0" "$(run rk3588s board_name)"
board soc raspberrypi,4-model-b brcm,bcm2711
same "another SoC" "[  ERROR  ] This board has no profile: the first boot covers the Raspberry Pi 5 and RK3588 boards. Install with the script instead, as the README says.
exit 1" "$(run soc board_name)"
board wfirst raspberrypi,5-model-b brcm,bcm2712
rm -rf "$w/wfirst/net/eth0"
iface wfirst eth0 aa:aa:aa:aa:aa:aa phy80211
iface wfirst eth1 d8:3a:dd:41:3f:a2
iface wfirst end0 bb:bb:bb:bb:bb:bb nodevice
same "wireless interface first by name" "rpi5-3fa2
exit 0" "$(run wfirst board_name)"
board nowired raspberrypi,5-model-b brcm,bcm2712
rm -rf "$w/nowired/net/eth0"
same "no wired interface" "[  ERROR  ] This board has no wired network interface to name it after: the first boot needs Ethernet. Install with the script instead, as the README says.
exit 1" "$(run nowired board_name)"

# ---- the hostname ----
board host raspberrypi,5-model-b
printf 'dietpi\n' > "$w/host/etc/hostname"; chmod 0644 "$w/host/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 DietPi\n::1 localhost ip6-localhost\n127.0.1.1 old\n' > "$w/host/etc/hosts"
chmod 0640 "$w/host/etc/hosts"
same "hostname set" "exit 0" "$(run host set_hostname rpi5-3fa2)"
same "hostname set again" "exit 0" "$(run host set_hostname rpi5-3fa2)"
same "hostname file" "rpi5-3fa2" "$(cat "$w/host/etc/hostname")"
same "hosts file" "127.0.0.1 localhost
127.0.1.1 rpi5-3fa2
::1 localhost ip6-localhost" "$(cat "$w/host/etc/hosts")"
same "hostname applied" "hostname rpi5-3fa2
hostname rpi5-3fa2" "$(calls)"
mode() { if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
same "hostname file mode kept" "644" "$(mode "$w/host/etc/hostname")"
same "hosts file mode kept" "640" "$(mode "$w/host/etc/hosts")"
board nohosts raspberrypi,5-model-b
printf '127.0.0.1 localhost\n' > "$w/nohosts/etc/hosts"
run nohosts set_hostname rpi5-3fa2 > /dev/null
same "hosts line added" "127.0.0.1 localhost
127.0.1.1 rpi5-3fa2" "$(cat "$w/nohosts/etc/hosts")"

# ---- SSH ----
board nokey raspberrypi,5-model-b; echo dropbear.service > "$w/enabled"
same "no key" "[  INFO   ] No ssh_key in the settings: SSH is turned off.
exit 0" "$(run nokey ssh_policy)"
same "no key: the enabled server is stopped" "systemctl is-enabled --quiet dropbear.service
systemctl disable --now dropbear.service
systemctl is-enabled --quiet ssh.service" "$(calls)"
[ -e "$w/nokey/ssh" ] && fail "no key: an ssh folder is written"
key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOv8 you@laptop"
board key raspberrypi,5-model-b; echo dropbear.service > "$w/enabled"
mkdir -p "$w/key/ssh"; chmod 0755 "$w/key/ssh"; printf 'ssh-rsa AAAAB3 old@host\n' > "$w/key/ssh/authorized_keys"
out=$(KEY=$key run key ssh_policy)
same "key" "[  INFO   ] SSH takes the key from the settings only.
exit 0" "$out"
KEY=$key run key ssh_policy > /dev/null
same "key: added once" "ssh-rsa AAAAB3 old@host
$key" "$(cat "$w/key/ssh/authorized_keys")"
same "key: folder mode" "700" "$(mode "$w/key/ssh")"
same "key: file mode" "600" "$(mode "$w/key/ssh/authorized_keys")"
same "key: no disable" "" "$(calls)"
grep -q AAAAC3 <<<"$out" && fail "key: the key is printed"
board newkey raspberrypi,5-model-b
KEY=$key run newkey ssh_policy > /dev/null
same "key, no folder" "$key" "$(cat "$w/newkey/ssh/authorized_keys" 2>/dev/null)"
same "key, no folder: file mode" "600" "$(mode "$w/newkey/ssh/authorized_keys")"
board nonl raspberrypi,5-model-b
mkdir -p "$w/nonl/ssh"; printf 'ssh-rsa AAAAB3 old@host' > "$w/nonl/ssh/authorized_keys"
KEY=$key run nonl ssh_policy > /dev/null
same "key after a last line without a newline" "ssh-rsa AAAAB3 old@host
$key" "$(cat "$w/nonl/ssh/authorized_keys")"
board emptykeys raspberrypi,5-model-b
mkdir -p "$w/emptykeys/ssh"; : > "$w/emptykeys/ssh/authorized_keys"
KEY=$key run emptykeys ssh_policy > /dev/null
same "key in an empty file" "$key" "$(cat "$w/emptykeys/ssh/authorized_keys")"

# ---- mDNS ----
board moff raspberrypi,5-model-b
same "mdns off" "exit 0" "$(MDNS=off run moff mdns_setup)"
same "mdns off: no call" "" "$(calls)"
board mon raspberrypi,5-model-b
same "mdns on, avahi absent" "[  INFO   ] Installing avahi-daemon to announce this board as its host name .local.
exit 0" "$(MDNS=on run mon mdns_setup)"
same "mdns on: install" "dpkg-query -W -f=\${db:Status-Status} avahi-daemon
apt-get install -y --no-install-recommends avahi-daemon" "$(calls)"
[ -e "$w/mon/state/mdns-installed" ] || fail "mdns on: no record"
[ -e "$w/mdns-installed-seen" ] || fail "mdns on: no record before the install"
board mhas raspberrypi,5-model-b; : > "$w/avahi"
same "mdns on, avahi present" "exit 0" "$(MDNS=on run mhas mdns_setup)"
same "mdns on, present: no install" "dpkg-query -W -f=\${db:Status-Status} avahi-daemon" "$(calls)"
[ -e "$w/mhas/state/mdns-installed" ] && fail "mdns on, present: a record is written"

# ---- the SoC table ----
same "SOCS equal to the board profiles" "$(grep '^[a-z0-9]*\.compatible=' "$root/scripts/board_profiles.conf")" \
  "$(env -i SCRIPT="$script" "$BASH" --norc --noprofile -c 'source "$SCRIPT"; printf "%s\n" "$SOCS"')"

[ "$rc" -eq 0 ] && echo "PASS first-boot-host"
exit "$rc"
