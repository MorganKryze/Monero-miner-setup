#!/bin/bash
# What a root install changes about who runs the miner. The installer's --service-as-root, whose
# help line names the x86 RandomX MSR boost, reaches the service setup as SERVICE_AS_ROOT=yes, and
# nothing else does; as root on Linux, with no -d and no earlier clone in HOME, the base directory
# is /opt, which the account running the miner can enter. Whatever chose the base directory (that
# default, HOME or -d), root goes on only while no user but root, or a non-root user who ran sudo,
# can change it, a clone already there or any directory above them: else the installer stops and
# names a directory only root can change. The launchd setup refuses to run as root
# or with SERVICE_AS_ROOT=yes, and then writes, changes and loads nothing. The installer's
# constants and functions are taken from scripts/install.sh and run with stub id, uname and stat; the
# launchd setup runs in a fixture clone with stub id and launchctl. PATH holds the stub dirs and a
# tools dir of links to the plain tools the code needs, no host directory: nothing run here can
# reach the host's sudo, chown or useradd (checked first).
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
same() { # label, expected, got
  [ "$2" = "$3" ] || { fail "$1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/    /'; }
}
unset SUDO_USER
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
fns="usage trusted_by_root validate_directory parse_arguments"
{
  sed -n '/^# ===== Constants =====$/,/^DOCKER_SCRIPT_URL=/p' "$root/scripts/install.sh"
  for f in $fns; do sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/install.sh"; done
} > "$w/functions.sh"
for f in $fns; do grep -qx "function $f() {" "$w/functions.sh" || fail "no function $f in scripts/install.sh"; done

t="$w/tools"
mkdir -p "$t"
for tool in bash sh cat sed grep cut sort find ls dirname readlink; do
  p=$(type -P "$tool") && ln -s "$p" "$t/$tool" || { echo "FAIL no $tool on this host"; exit 1; }
done
stubpath() { printf '%s' "$w/$1:$t:$w/bin"; } # the only PATH any code under test gets
# Hosts, as id and uname report them: root on Linux, a user on Linux, root on macOS.
for h in root:0:Linux user:1000:Linux macroot:0:Darwin; do
  d="$w/${h%%:*}"; uid=${h#*:}; uid=${uid%%:*}
  mkdir -p "$d"
  printf '#!/bin/sh\n[ "$*" = -u ] && echo %s\n' "$uid" > "$d/id"
  printf '#!/bin/sh\necho %s\n' "${h##*:}" > "$d/uname"
  chmod +x "$d/id" "$d/uname"
  reach=$(PATH=$(stubpath "${h%%:*}"); type -P sudo chown useradd)
  [ -z "$reach" ] || { echo "FAIL ${h%%:*}: the stub PATH reaches $reach"; exit 1; }
done
# on <host> <command...>: the installer's functions on that host, HOME and /opt as fixtures.
on() {
  local host=$1; shift
  ( info() { echo "[INFO] $1"; }
    error() { echo "[ERROR] $1"; return 1; }
    # shellcheck source=/dev/null
    source "$w/functions.sh"
    # shellcheck disable=SC2034 # read by the functions taken from install.sh
    ROOT_BASE_DIR="$w/opt" HOME="$w/home" PATH=$(stubpath "$host")
    "$@" )
}
refused() { # path, clone or "": the installer's error line for a path root cannot trust
  local remedy="Pass -d"
  [ -z "$2" ] || remedy="Remove $2, or pass -d"
  printf '[ERROR] %s can be changed by a user other than root or the one who ran sudo, and root would run what they put there. %s with a directory only root can change.' \
    "$1" "$remedy"
}
base() { # host, -d value: sets got (the directory), err (its info lines)
  got=$(on "$1" validate_directory "$2" 2> "$w/err"); err=$(cat "$w/err")
}
mkdir -p "$w/opt" "$w/home" "$w/given"
# stat: owner and mode from the fixture table (path, owner, mode), root 755 for any path it does
# not list.
mkdir -p "$w/bin"
: > "$w/stat"
printf '#!/bin/sh\n[ "$1" = -c ] && [ "$2" = "%%U %%a" ] || exit 1\nwhile read -r p o m; do [ "$p" = "$3" ] && { echo "$o $m"; exit 0; }; done < "%s/stat"\necho "root 755"\n' "$w" > "$w/bin/stat"
chmod +x "$w/bin/stat"
opt_line="[INFO] Running as root, no base directory provided: using $w/opt, which the account running the miner can enter."
given_line="[INFO] Using base directory: $w/given."
base root ""
same "root, no -d: directory" "$w/opt" "$got"
same "root, no -d: line" "$opt_line" "$err"
# /opt, or a clone in it, that a user other than root owns or can write: root would run that
# user's scripts. The directory chosen, an error naming the path and the remedy, no directory.
for bad in "$w/opt root 777" "$w/opt root 775" "$w/opt alice 755" "$w/opt root 7" "$w/opt/Monero-miner-setup alice 755"; do
  mkdir -p "$w/opt/Monero-miner-setup"
  printf '%s\n' "$bad" > "$w/stat"
  base root ""
  same "root, no -d, $bad: directory" "" "$got"
  same "root, no -d, $bad: line" "$opt_line
$(refused "${bad%% *}" "$w/opt/Monero-miner-setup")" "$err"
done
# A clone in /opt that only root can change: a re-run there goes on.
: > "$w/stat"
base root ""
same "root, no -d, root's clone in /opt: directory" "$w/opt" "$got"
rmdir "$w/opt/Monero-miner-setup"
base root "$w/given"
same "root, -d: directory" "$w/given" "$got"
# -d skips none of it: a clone there that another user owns or can write, or the directory itself,
# or one above it, is refused as /opt's would be; the sudoer's own clone is theirs to run.
mkdir -p "$w/given/Monero-miner-setup"
for bad in "$w/given/Monero-miner-setup alice 755" "$w/given/Monero-miner-setup root 775" "$w/given alice 755" "$w root 757"; do
  printf '%s\n' "$bad" > "$w/stat"
  base root "$w/given"
  same "root, -d, $bad: directory" "" "$got"
  same "root, -d, $bad: line" "$given_line
$(refused "${bad%% *}" "$w/given/Monero-miner-setup")" "$err"
done
# -d through a link: root goes on with the directory it checked, so retargeting the link later
# changes nothing.
: > "$w/stat"
ln -s "$w/given" "$w/link"
base root "$w/link"
same "root, -d through a link: directory" "$w/given" "$got"
same "root, -d through a link: line" "[INFO] Using base directory: $w/link.
[INFO] Resolved to $w/given." "$err"
# Every user, on every OS, goes on with the real path its clone checks read.
for h in user macroot; do
  base "$h" "$w/link"
  same "$h, -d through a link: directory" "$w/given" "$got"
  same "$h, -d through a link: line" "[INFO] Using base directory: $w/link.
[INFO] Resolved to $w/given." "$err"
done
rm "$w/link"
printf '%s\n' "$w/given/Monero-miner-setup alice 755" > "$w/stat"
SUDO_USER=alice base root "$w/given"
same "root by sudo, -d, the sudoer's clone: directory" "$w/given" "$got"
printf '%s\n' "$w/given/Monero-miner-setup alice 775" > "$w/stat"
SUDO_USER=alice base root "$w/given"
same "root by sudo, -d, the sudoer's group-writable clone: directory" "" "$got"
rmdir "$w/given/Monero-miner-setup"
printf '%s\n' "$w/given alice 755" > "$w/stat"
base root "$w/given"
same "root, -d, another user's directory, no clone: line" "$given_line
$(refused "$w/given" "")" "$err"
: > "$w/stat"
base user ""
same "user, no -d: directory" "$w/home" "$got"
base macroot ""
same "root on macOS, no -d: directory" "$w/home" "$got"
mkdir -p "$w/home/Monero-miner-setup"
base root ""
same "root, an earlier clone in HOME: directory" "$w/home" "$got"
rmdir "$w/home/Monero-miner-setup" "$w/opt"
base root ""
same "root, no /opt: directory" "$w/home" "$got"

# The flag: yes with it, no without it even when the caller's environment says yes, exported to
# what the installer runs.
wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge
show_flag() { parse_arguments "$@" && bash -c 'printf %s "$SERVICE_AS_ROOT"'; }
flag() { on user show_flag "$@"; }
same "--service-as-root" "yes" "$(flag -w "$wallet" --service-as-root)"
same "no flag" "no" "$(SERVICE_AS_ROOT=yes flag -w "$wallet")"
help=$(on user usage)
for line in \
  "  -d, --dir DIR         Base directory for installation (defaults to HOME; as root on Linux, /opt)" \
  "  --service-as-root    Run the systemd service as root. Only for the x86 RandomX MSR boost, which" \
  "                       needs root; without it, a root install runs the miner as the user who ran" \
  "                       sudo, or as the system account xmrig"; do
  printf '%s\n' "$help" | grep -qxF -- "$line" || fail "help: no line '$line'"
done

# The launchd setup, as root and with SERVICE_AS_ROOT=yes: an error line, a non-zero exit, and the
# clone, HOME and launchd untouched (xmrig left without its execute bit, which the setup would add).
c="$w/clone"
mkdir -p "$c/scripts" "$c/templates" "$c/configs" "$w/mhome" "$w/bin"
cp "$root/scripts/setup_service_macos.sh" "$root/scripts/setup_service_common.sh" "$c/scripts/"
cp "$root/templates/com.moneroocean.xmrig.plist.template" "$c/templates/"
: > "$c/xmrig"
printf '{\n  "background": true\n}\n' > "$c/configs/config_background.json"
ln -s "$c/configs/config_background.json" "$c/config_background.json"
printf '#!/bin/sh\necho "launchctl $*" >> "%s/launchctl.log"\n' "$w" > "$w/bin/launchctl"
chmod +x "$w/bin/launchctl"
snapshot() { (cd "$w" && find clone mhome | LC_ALL=C sort; ls -l clone/xmrig | cut -c1-10; cat clone/configs/config_background.json) }
before=$(snapshot)
for case in "macroot:" "user:yes"; do
  host=${case%%:*}
  out=$(cd "$w" && HOME="$w/mhome" SERVICE_AS_ROOT="${case#*:}" PATH=$(stubpath "$host") bash "$c/scripts/setup_service_macos.sh" 2>&1); code=$?
  [ "$code" -ne 0 ] || fail "launchd setup ($case): exit 0"
  case $host in
    macroot) same "launchd setup as root: output" "Error: Run the macOS service setup as your own user, not root: launchd would run the miner as root." "$out" ;;
    user) same "launchd setup with SERVICE_AS_ROOT=yes: output" "Error: SERVICE_AS_ROOT=yes applies to the systemd service only; the macOS service runs as your user." "$out" ;;
  esac
  same "launchd setup ($case): files" "$before" "$(snapshot)"
  [ ! -e "$w/launchctl.log" ] || fail "launchd setup ($case): ran $(cat "$w/launchctl.log")"
done
[ "$rc" -eq 0 ] && echo "PASS root-install"
exit "$rc"
