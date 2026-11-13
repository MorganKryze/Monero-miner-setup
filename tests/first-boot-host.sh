#!/bin/bash
# The first-boot setup's host steps (scripts/first_boot.sh): the board's name (short model name and
# the first wired interface's MAC tail, lower case), the refusal of a board outside the profiles,
# the hostname files, SSH closed without a key (every unit systemd knows disabled, masked and found
# inactive) or opened to the key alone with password logins off, and avahi-daemon only when mdns is
# on; each step that fails exits 1 with its error on stderr. Every function runs under env -i
# against fixture trees, with stub systemctl, hostname, apt-get and dpkg-query that record their
# arguments, or fail on request; systemctl also keeps the units' states. Run from the repository
# root.
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
real_grep=$(command -v grep) || { echo "FAIL no grep on this host"; exit 1; }
# systemctl keeps unit state in files of unit names: systemd knows the units in known; enabled,
# masked and active hold their states. alias holds "<alias> <unit>" lines: as on Debian's OpenSSH,
# the alias is a link that exists while its unit is enabled, is listed with the state alias, reads
# its unit's activity, and cannot be disabled or masked on its own. list-unit-files fails while
# list-fails exists; is-active prints active or inactive, an active unit's state is the one in
# active-says when it exists, and it prints nothing and fails while bus-fails does. disable --now
# and mask fail while disable-fails or mask-fails exists, restart while restart-fails does; a unit
# in sticky stays active.
cat > "$w/stubs/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$w/calls.log"
has() { "$real_grep" -qx "\$1" "$w/\$2" 2>/dev/null; }
add() { has "\$1" "\$2" || echo "\$1" >> "$w/\$2"; }
del() { "$real_grep" -vx "\$1" "$w/\$2" > "$w/\$2.new"; mv "$w/\$2.new" "$w/\$2"; }
target() { local a t; while read -r a t; do [ "\$a" != "\$1" ] || { echo "\$t"; return; }; done < "$w/alias"; }
u=\${*: -1}
t=\$(target "\$u")
case "\$1" in
  list-unit-files)
    [ ! -e "$w/list-fails" ] || { echo "Failed to connect to bus" >&2; exit 1; }
    [[ \$u == --* ]] && u=
    while read -r k; do [ -n "\$u" ] && [ "\$k" != "\$u" ] || echo "\$k enabled enabled"; done < "$w/known"
    while read -r a k; do has "\$k" enabled && { [ -z "\$u" ] || [ "\$a" = "\$u" ]; } && echo "\$a alias -"; done < "$w/alias"
    exit 0 ;;
  is-enabled)
    if has "\$u" masked; then echo masked; exit 1; fi
    if has "\$u" enabled; then echo enabled; else echo disabled; exit 1; fi ;;
  is-active)
    [ ! -e "$w/bus-fails" ] || { echo "Failed to connect to bus" >&2; exit 1; }
    s=inactive; has "\${t:-\$u}" active && s=active && [ -e "$w/active-says" ] && s=\$(cat "$w/active-says")
    [ "\$2" = --quiet ] || echo "\$s"
    [ "\$s" = active ] || exit 3 ;;
  disable) [ ! -e "$w/disable-fails" ] && [ -z "\$t" ] || exit 1; del "\$u" enabled; has "\$u" sticky || del "\$u" active ;;
  mask) [ ! -e "$w/mask-fails" ] && [ -z "\$t" ] || exit 1; add "\$u" masked ;;
  unmask) del "\$u" masked ;;
  enable) add "\$u" enabled ;;
  restart) [ ! -e "$w/restart-fails" ] || exit 1; add "\${t:-\$u}" active ;;
esac
EOF
printf '#!/bin/bash\necho "hostname $*" >> "%s/calls.log"\n' "$w" > "$w/stubs/hostname"
# apt-get fails while apt-fails exists.
printf '#!/bin/bash\necho "apt-get $*" >> "%s/calls.log"\n[ -e "%s/mdns-installed-seen" ] || [ ! -e "$STATE/mdns-installed" ] || : > "%s/mdns-installed-seen"\n[ ! -e "%s/apt-fails" ]\n' "$w" "$w" "$w" "$w" > "$w/stubs/apt-get"
# dpkg-query reports avahi-daemon installed when the avahi file exists.
printf '#!/bin/bash\necho "dpkg-query $*" >> "%s/calls.log"\nif [ -e "%s/avahi" ]; then printf "installed"; else exit 1; fi\n' "$w" "$w" > "$w/stubs/dpkg-query"
chmod +x "$w/stubs/"*

cat > "$w/drive.sh" <<'EOF'
# shellcheck source=/dev/null
source "$SCRIPT"
STATE_DIR="$FX/state" LEDS_DIR="$FX/leds" DT_COMPATIBLE="$FX/compatible" NET_DIR="$FX/net"
HOSTNAME_FILE="$FX/etc/hostname" HOSTS_FILE="$FX/etc/hosts" ROOT_SSH_DIR="$FX/ssh"
SSHD_DROPIN="$FX/etc/ssh/sshd_config.d/00-xmrig-first-boot.conf" DROPBEAR_DEFAULTS="$FX/etc/default/dropbear"
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
# split <fixture> <function> [args]: like run, stdout lines as "out", stderr lines as "err".
split() {
  local fx="$w/$1" code; shift
  env -i PATH="$w/stubs:$w/tools" SCRIPT="$script" FX="$fx" STATE="$fx/state" KEY="${KEY-}" MDNS="${MDNS-off}" \
    "$BASH" --norc --noprofile "$w/drive.sh" "$@" > "$w/run.out" 2> "$w/run.err"
  code=$?
  while IFS= read -r l; do echo "out $l"; done < "$w/run.out"
  while IFS= read -r l; do echo "err $l"; done < "$w/run.err"
  echo "exit $code"
}
calls() { cat "$w/calls.log" 2>/dev/null; }
# iface <fixture> <name> <mac> [wireless|phy80211|nodevice|loopback|can]
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
    can) printf '280\n' > "$d/type" ;;
  esac
  ln -s "$w/$1/devices/$2" "$d/device"
}
# board <fixture> <compatible...>: a device tree list, eth0 wired and wlan0 wireless.
board() {
  local fx="$w/$1" c; shift
  rm -rf -- "$fx" "$w/calls.log" "$w/avahi" "$w/mdns-installed-seen" "$w/disable-fails" "$w/apt-fails" \
    "$w/mask-fails" "$w/restart-fails" "$w/list-fails" "$w/bus-fails" "$w/active-says"
  for f in known enabled masked active sticky alias; do : > "$w/$f"; done
  mkdir -p "$fx/state" "$fx/etc"
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
board ctype raspberrypi,5-model-b brcm,bcm2712
iface ctype can0 aa:aa:aa:aa:aa:01 can
same "another type first by name" "rpi5-3fa2
exit 0" "$(run ctype board_name)"
board badmac raspberrypi,5-model-b brcm,bcm2712
iface badmac end0 aa:aa:aa:aa:aa
same "malformed address first by name" "rpi5-3fa2
exit 0" "$(run badmac board_name)"
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
board hostdir raspberrypi,5-model-b; mkdir "$w/hostdir/etc/hostname"
same "hostname file not writable" "err [  ERROR  ] Failed to set the host name to rpi5-3fa2. The setup runs again at the next boot; see journalctl -u xmrig-first-boot.service.
exit 1" "$(split hostdir set_hostname rpi5-3fa2)"
same "hostname file not writable: not applied" "" "$(calls)"

# ---- SSH ----
# units <state file> <unit...>: sets a unit state file.
units() { local f=$1; shift; printf '%s\n' "$@" > "$w/$f"; }
state() {
  local f u
  for f in known enabled masked active; do
    printf '%s:' "$f"; while read -r u; do printf ' %s' "$u"; done < <(sort "$w/$f"); echo
  done
}
error_tail="The setup runs again at the next boot; see journalctl -u xmrig-first-boot.service."
off_line="[  INFO   ] No ssh_key in the settings: the SSH server is disabled and masked."
key_line="[  INFO   ] The ssh_key from the settings is added to root's authorized_keys; password logins are off."
# dropbear <fixture>: DietPi's Dropbear, its service enabled and running, its socket known.
dropbear() { units known dropbear.service dropbear.socket; units enabled dropbear.service; units active dropbear.service; }
board nokey raspberrypi,5-model-b; dropbear
same "no key" "$off_line
exit 0" "$(run nokey ssh_policy)"
same "no key: every known unit off" "known: dropbear.service dropbear.socket
enabled:
masked: dropbear.service dropbear.socket
active:" "$(state)"
same "no key: calls" "systemctl list-unit-files --no-legend --no-pager
systemctl disable --now dropbear.service
systemctl mask dropbear.service
systemctl disable --now dropbear.socket
systemctl mask dropbear.socket
systemctl is-active dropbear.service
systemctl is-active dropbear.socket
systemctl is-active ssh.service
systemctl is-active ssh.socket
systemctl is-active sshd.service" "$(calls)"
same "no key, run again" "$off_line
exit 0" "$(run nokey ssh_policy)"
[ -e "$w/nokey/ssh" ] && fail "no key: an ssh folder is written"
board openssh raspberrypi,5-model-b
units known ssh.service ssh.socket sshd.service; units enabled ssh.service; units active ssh.service
same "no key, OpenSSH" "$off_line
exit 0" "$(run openssh ssh_policy)"
same "no key, OpenSSH: every known unit off" "known: ssh.service ssh.socket sshd.service
enabled:
masked: ssh.service ssh.socket sshd.service
active:" "$(state)"
grep -q '^systemctl \(disable\|mask\).* dropbear' "$w/calls.log" && fail "no key, OpenSSH: an unknown unit is turned off"
# Debian's OpenSSH: sshd.service is an alias of ssh.service, gone once ssh.service is disabled.
debian() { units known ssh.service ssh.socket; units enabled ssh.service; units active ssh.service; units alias "sshd.service ssh.service"; }
board debian raspberrypi,5-model-b; debian
same "no key, Debian's OpenSSH" "$off_line
exit 0" "$(run debian ssh_policy)"
same "no key, Debian's OpenSSH: every unit off" "known: ssh.service ssh.socket
enabled:
masked: ssh.service ssh.socket
active:" "$(state)"
grep -q '^systemctl \(disable\|mask\).* sshd[.]service$' "$w/calls.log" && fail "no key, Debian's OpenSSH: the alias is turned off on its own"
board offfails raspberrypi,5-model-b; dropbear; : > "$w/disable-fails"
same "no key, the server not disabled" "err [  ERROR  ] Failed to turn off dropbear.service. $error_tail
exit 1" "$(split offfails ssh_policy)"
board maskfails raspberrypi,5-model-b; dropbear; : > "$w/mask-fails"
same "no key, the server not masked" "err [  ERROR  ] Failed to turn off dropbear.service. $error_tail
exit 1" "$(split maskfails ssh_policy)"
board stuck raspberrypi,5-model-b; dropbear; units sticky dropbear.service
same "no key, the server still active" "err [  ERROR  ] dropbear.service is still active after it was disabled and masked, so SSH stays open. $error_tail
exit 1" "$(split stuck ssh_policy)"
# Fails closed: a unit list systemd cannot give, an active unit it does not list, a state other
# than inactive or failed, or no state at all.
board listfails raspberrypi,5-model-b; dropbear; : > "$w/list-fails"
same "no key, no unit list" "err Failed to connect to bus
err [  ERROR  ] Failed to list the SSH units systemd knows. $error_tail
exit 1" "$(split listfails ssh_policy)"
board unlisted raspberrypi,5-model-b; units active dropbear.service
same "no key, an active unit not listed" "err [  ERROR  ] dropbear.service is still active after it was disabled and masked, so SSH stays open. $error_tail
exit 1" "$(split unlisted ssh_policy)"
board activating raspberrypi,5-model-b; dropbear; units sticky dropbear.service; echo activating > "$w/active-says"
same "no key, the server activating" "err [  ERROR  ] dropbear.service is still activating after it was disabled and masked, so SSH stays open. $error_tail
exit 1" "$(split activating ssh_policy)"
board busfails raspberrypi,5-model-b; dropbear; : > "$w/bus-fails"
same "no key, no state" "err Failed to connect to bus
err [  ERROR  ] dropbear.service is still in an unknown state after it was disabled and masked, so SSH stays open. $error_tail
exit 1" "$(split busfails ssh_policy)"

key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOv8 you@laptop"
board key raspberrypi,5-model-b
mkdir -p "$w/key/ssh"; chmod 0755 "$w/key/ssh"; printf 'ssh-rsa AAAAB3 old@host\n' > "$w/key/ssh/authorized_keys"
out=$(KEY=$key run key ssh_policy)
same "key" "$key_line
exit 0" "$out"
KEY=$key run key ssh_policy > /dev/null
same "key: added once" "ssh-rsa AAAAB3 old@host
$key" "$(cat "$w/key/ssh/authorized_keys")"
same "key: folder mode" "700" "$(mode "$w/key/ssh")"
same "key: file mode" "600" "$(mode "$w/key/ssh/authorized_keys")"
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
board sshfile raspberrypi,5-model-b; : > "$w/sshfile/ssh"
out=$(KEY=$key split sshfile ssh_policy)
same "key, ssh folder not writable: exit" "exit 1" "$(tail -n 1 <<<"$out")"
same "key, ssh folder not writable: stdout" "" "$(grep '^out ' <<<"$out")"
same "key, ssh folder not writable: last error" "err [  ERROR  ] Failed to add the ssh_key to $w/sshfile/ssh/authorized_keys. $error_tail" \
  "$(grep '^err ' <<<"$out" | tail -n 1)"

# With a key, password logins are turned off in the server's own config and the server restarted.
board kdrop raspberrypi,5-model-b; dropbear; mkdir -p "$w/kdrop/etc/default"
printf '# Dropbear\nDROPBEAR_PORT=22\nDROPBEAR_EXTRA_ARGS="-w"\n' > "$w/kdrop/etc/default/dropbear"
chmod 0640 "$w/kdrop/etc/default/dropbear"
same "key, Dropbear" "$key_line
exit 0" "$(KEY=$key run kdrop ssh_policy)"
KEY=$key run kdrop ssh_policy > /dev/null
same "key, Dropbear: password logins off" "# Dropbear
DROPBEAR_PORT=22
DROPBEAR_EXTRA_ARGS=\"-w -s -g\"" "$(cat "$w/kdrop/etc/default/dropbear")"
same "key, Dropbear: file mode kept" "640" "$(mode "$w/kdrop/etc/default/dropbear")"
same "key, Dropbear: restarted" "2" "$(grep -cx 'systemctl restart dropbear.service' "$w/calls.log")"
same "key, Dropbear: state" "known: dropbear.service dropbear.socket
enabled: dropbear.service
masked:
active: dropbear.service" "$(state)"
[ -e "$w/kdrop/etc/ssh" ] && fail "key, Dropbear: an sshd drop-in is written"
board kdropnew raspberrypi,5-model-b; dropbear
KEY=$key run kdropnew ssh_policy > /dev/null
same "key, Dropbear without defaults" "DROPBEAR_EXTRA_ARGS=\"-s -g\"" "$(cat "$w/kdropnew/etc/default/dropbear" 2>/dev/null)"
board kssh raspberrypi,5-model-b
units known ssh.service ssh.socket sshd.service; units enabled ssh.service; units active ssh.service
same "key, OpenSSH" "$key_line
exit 0" "$(KEY=$key run kssh ssh_policy)"
same "key, OpenSSH: drop-in" "PasswordAuthentication no
PermitRootLogin prohibit-password" "$(cat "$w/kssh/etc/ssh/sshd_config.d/00-xmrig-first-boot.conf" 2>/dev/null)"
grep -qx 'systemctl restart ssh.service' "$w/calls.log" || fail "key, OpenSSH: not restarted"
[ -e "$w/kssh/etc/default/dropbear" ] && fail "key, OpenSSH: Dropbear defaults written"
board kdebian raspberrypi,5-model-b; debian
same "key, Debian's OpenSSH" "$key_line
exit 0" "$(KEY=$key run kdebian ssh_policy)"
same "key, Debian's OpenSSH: drop-in" "PasswordAuthentication no
PermitRootLogin prohibit-password" "$(cat "$w/kdebian/etc/ssh/sshd_config.d/00-xmrig-first-boot.conf" 2>/dev/null)"
same "key, Debian's OpenSSH: restarted once" "systemctl restart ssh.service" "$(grep '^systemctl restart' "$w/calls.log")"
# An earlier boot without a key masked the server: the key brings it back.
board kback raspberrypi,5-model-b; units known dropbear.service dropbear.socket; units masked dropbear.service dropbear.socket
same "key after SSH was turned off" "$key_line
exit 0" "$(KEY=$key run kback ssh_policy)"
same "key after SSH was turned off: state" "known: dropbear.service dropbear.socket
enabled: dropbear.service
masked:
active: dropbear.service" "$(state)"
board krestart raspberrypi,5-model-b; dropbear; : > "$w/restart-fails"
same "key, the server not restarted" "err [  ERROR  ] Failed to restart dropbear.service with password logins off. $error_tail
exit 1" "$(KEY=$key split krestart ssh_policy)"
board klistfails raspberrypi,5-model-b; dropbear; : > "$w/list-fails"
out=$(KEY=$key split klistfails ssh_policy)
same "key, no unit list: first error" "err [  ERROR  ] Failed to list the SSH units systemd knows. $error_tail" \
  "$(grep '^err \[' <<<"$out" | head -n 1)"
same "key, no unit list: exit" "exit 1" "$(tail -n 1 <<<"$out")"
board kdropin raspberrypi,5-model-b; units known ssh.service; mkdir -p "$w/kdropin/etc"; : > "$w/kdropin/etc/ssh"
out=$(KEY=$key split kdropin ssh_policy)
same "key, the drop-in not written: last error" "err [  ERROR  ] Failed to turn off password logins for SSH. $error_tail" \
  "$(grep '^err ' <<<"$out" | tail -n 1)"
same "key, the drop-in not written: exit" "exit 1" "$(tail -n 1 <<<"$out")"
grep -q 'restart' "$w/calls.log" && fail "key, the drop-in not written: the server restarted"

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
board mfail raspberrypi,5-model-b; : > "$w/apt-fails"
same "mdns on, the install fails" "out [  INFO   ] Installing avahi-daemon to announce this board as its host name .local.
err [  ERROR  ] Failed to install avahi-daemon for mdns = on. The setup runs again at the next boot; see journalctl -u xmrig-first-boot.service.
exit 1" "$(MDNS=on split mfail mdns_setup)"

# ---- the SoC table ----
same "SOCS equal to the board profiles" "$(grep '^[a-z0-9]*\.compatible=' "$root/scripts/board_profiles.conf")" \
  "$(env -i SCRIPT="$script" "$BASH" --norc --noprofile -c 'source "$SCRIPT"; printf "%s\n" "$SOCS"')"

[ "$rc" -eq 0 ] && echo "PASS first-boot-host"
exit "$rc"
