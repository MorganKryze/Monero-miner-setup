#!/bin/bash
# The DietPi custom script (scripts/first_boot.sh) carries the miner's settings in an inert quoted
# block at its top. Its parser reads them as data: key = value lines, optional quotes, comments,
# a trailing CR; an unknown, repeated or missing key and a value of the wrong form are refused with
# one line naming the key, and no value is ever run (a value holding $(...), backticks or ; creates
# no file). The handoff DietPi runs once copies the settings to a 0600 file in a 0700 folder, the
# code without the settings to a 0755 copy, writes the setup's unit and enables and starts it. The
# status LED blinks during the setup, stays on after a refusal and beats once set up.
# Every function runs under env -i on fixtures, with stub id, systemctl and sleep; PATH holds only
# the stub and tool-link directories. Nothing is installed or started. Run from the repository
# root. Prints FAIL lines, exits 1 on any miss.
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
# touch is there for the hostile values: a value that ran would leave a file.
for t in chmod mkdir mktemp mv rm cat touch; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
real_sleep=$(command -v sleep) || { echo "FAIL no sleep on this host"; exit 1; }
# id answers as root unless the fixture says otherwise; systemctl records its arguments; sleep
# waits a twentieth of a second whatever it is asked, so the blink loop turns fast.
printf '#!/bin/sh\nif [ -e "%s/not-root" ]; then echo 1000; else echo 0; fi\n' "$w" > "$w/stubs/id"
printf '#!/bin/sh\necho "$*" >> "%s/systemctl.log"\n[ ! -e "%s/systemctl-fails" ]\n' "$w" "$w" > "$w/stubs/systemctl"
printf '#!/bin/sh\nexec "%s" 0.05\n' "$real_sleep" > "$w/stubs/sleep"
chmod +x "$w/stubs/"*

# The driver sources the script (which runs nothing), points every host path at the fixture, then
# runs the function it is given.
cat > "$w/drive.sh" <<'EOF'
# shellcheck source=/dev/null
source "$SCRIPT"
STATE_DIR="$FX/state"
SETUP_BIN="$FX/sbin/xmrig-first-boot"
SETUP_UNIT="$FX/unit/xmrig-first-boot.service"
LEDS_DIR="$FX/leds"
DT_COMPATIBLE="$FX/compatible"
NET_DIR="$FX/net" MEMINFO="$FX/meminfo" HOSTNAME_FILE="$FX/hostname" HOSTS_FILE="$FX/hosts"
ROOT_SSH_DIR="$FX/ssh" CLONE_DIR="$FX/clone"
function show() {
    read_settings "$1" || return 1
    printf '%s\n' "wallet=$S_WALLET" "mode=$S_MODE" "pool=$S_POOL" "name=$S_NAME" "donate=$S_DONATE" \
        "light=$S_LIGHT" "mdns=$S_MDNS" "ssh_key=$S_SSH_KEY"
}
# shellcheck source=/dev/null
source "$EXTRA"
"$@"
EOF
: > "$w/extra.sh"
# run <script> <fixture> <function> <args...>: prints stdout and stderr, then the exit code. The
# output goes through a file, not a pipe: a blink loop left running must not hold the check up.
run() {
  local script=$1 fx=$2 code; shift 2
  env -i PATH="$w/stubs:$w/tools" SCRIPT="$script" FX="$fx" EXTRA="$w/extra.sh" "$BASH" --norc --noprofile "$w/drive.sh" "$@" > "$w/run.out" 2>&1
  code=$?
  cat "$w/run.out"; echo "exit $code"
}
script="$root/scripts/first_boot.sh"
[ -f "$script" ] || { echo "FAIL no scripts/first_boot.sh"; exit 1; }
remedy="Fix it in the settings at the top of Automation_Custom_Script.sh and flash the card again, or edit /var/lib/xmrig-first-boot/settings as root on the board and reboot."
W=44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A

# ---- the parser ----
mkdir -p "$w/p"
settings() { printf "$2" > "$w/p/$1"; } # name, printf format (\r, \t and \n spelled out)
check() { same "$1" "$2" "$(run "$script" "$w/p" show "$w/p/$3")"; }

settings every "# a comment\n\n   # an indented comment\nwallet = $W\nmode=max\npool = 'pool.example.org:10128'\nname = \"rpi5-3fa2\"  \ndonate = 1 # a tail\nlight=yes\nmdns =   on   \nssh_key = \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB+7v/x0= me@host\"\n"
check "every form" "wallet=$W
mode=max
pool=pool.example.org:10128
name=rpi5-3fa2
donate=1
light=yes
mdns=on
ssh_key=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB+7v/x0= me@host
exit 0" every
settings crlf "wallet = $W\r\nmode = eco\r\n# c\r\n\r\n"
check "CRLF and defaults" "wallet=$W
mode=eco
pool=
name=
donate=
light=no
mdns=off
ssh_key=
exit 0" crlf
settings empty-optional "wallet = $W\nmode = eco\npool =\nname = \"\"\n"
check "empty optional values" "wallet=$W
mode=eco
pool=
name=
donate=
light=no
mdns=off
ssh_key=
exit 0" empty-optional
settings unknown "wallet = $W\nwalet = $W\nmode = eco\n"
check "unknown key" "[  ERROR  ] Setting 'walet' is not one this script knows: wallet, mode, pool, name, donate, light, mdns, ssh_key. $remedy
exit 1" unknown
settings repeated "wallet = $W\nmode = eco\nmode = max\n"
check "repeated key" "[  ERROR  ] Setting 'mode' is given twice. $remedy
exit 1" repeated
settings no-wallet "mode = eco\n"
check "missing wallet" "[  ERROR  ] Setting 'wallet' is missing. $remedy
exit 1" no-wallet
settings blank-wallet "wallet =\nmode = eco\n"
check "blank wallet" "[  ERROR  ] Setting 'wallet' is missing. $remedy
exit 1" blank-wallet
settings no-mode "wallet = $W\n"
check "missing mode" "[  ERROR  ] Setting 'mode' is missing. $remedy
exit 1" no-mode
settings not-kv "wallet = $W\nmode eco\n"
check "not key = value" "[  ERROR  ] Line 2 of the settings is not key = value.
exit 1" not-kv
settings bad-key "wallet = $W\n\$(id) = x\n"
check "key of another form" "[  ERROR  ] Line 2 of the settings is not key = value.
exit 1" bad-key
# Each form rule, on a value it refuses.
form() { # key, value, rule
  settings "form-$1" "wallet = $W\nmode = eco\n$1 = $2\n"
  [ "$1" = wallet ] && settings "form-$1" "wallet = $2\nmode = eco\n"
  [ "$1" = mode ] && settings "form-$1" "wallet = $W\nmode = $2\n"
  check "form of $1 ($2)" "[  ERROR  ] Setting '$1' $3. $remedy
exit 1" "form-$1"
}
form wallet "44AF0q" "must be 1 to 128 base58 characters"
form wallet "$W$W" "must be 1 to 128 base58 characters"
form mode turbo "must be max or eco"
form pool "pool.example.org:10128?x" "must be 1 to 255 letters, digits or . + : / _ - characters"
form name "my board" "must be 1 to 64 letters, digits or . _ - @ : + characters"
form donate 6 "must be a whole number from 0 to 5"
form donate 01 "must be a whole number from 0 to 5"
form light true "must be yes or no"
form mdns yes "must be on or off"
form ssh_key "ssh-dss AAAAB3NzaC1kc3M=" "must be one ssh-ed25519, ecdsa-sha2-nistp256, ecdsa-sha2-nistp384, ecdsa-sha2-nistp521 or ssh-rsa public key, then optionally a comment of letters, digits or @ . _ - characters"
form ssh_key "ssh-ed25519 AAAA me host" "must be one ssh-ed25519, ecdsa-sha2-nistp256, ecdsa-sha2-nistp384, ecdsa-sha2-nistp521 or ssh-rsa public key, then optionally a comment of letters, digits or @ . _ - characters"
form name "\"rpi5\" # x" "must be 1 to 64 letters, digits or . _ - @ : + characters"
form name "\"rpi5'" "must be 1 to 64 letters, digits or . _ - @ : + characters"
# Hostile values: refused by their form, and nothing they hold runs.
form name "\$(touch $w/pwned1)" "must be 1 to 64 letters, digits or . _ - @ : + characters"
form pool "\`touch $w/pwned2\`" "must be 1 to 255 letters, digits or . + : / _ - characters"
form wallet "$W; touch $w/pwned3" "must be 1 to 128 base58 characters"
form ssh_key "\"ssh-ed25519 AAAA \$(touch $w/pwned4)\"" "must be one ssh-ed25519, ecdsa-sha2-nistp256, ecdsa-sha2-nistp384, ecdsa-sha2-nistp521 or ssh-rsa public key, then optionally a comment of letters, digits or @ . _ - characters"
form wallet END_OF_MINER_SETTINGS "must be 1 to 128 base58 characters"
settings hostile-key "wallet = $W\n\$(touch $w/pwned5) = 1\n"
check "hostile key" "[  ERROR  ] Line 2 of the settings is not key = value.
exit 1" hostile-key
for f in "$w"/pwned*; do [ -e "$f" ] && fail "a settings value ran: $f exists"; done

# The block: the lines between the opening line and the first line that is exactly the terminator.
# A line that only starts with the terminator is a settings line, as bash's here-document reads it.
mkdir -p "$w/blk"
printf '%s\n' '#!/bin/bash' 'echo before' ": <<'END_OF_MINER_SETTINGS'" 'wallet = x' 'END_OF_MINER_SETTINGS2' \
  ' END_OF_MINER_SETTINGS' 'END_OF_MINER_SETTINGS' 'echo after' > "$w/blk/script"
same "settings region" 'wallet = x
END_OF_MINER_SETTINGS2
 END_OF_MINER_SETTINGS
exit 0' "$(run "$script" "$w/blk" settings_region "$w/blk/script")"
same "terminator prefix read as a settings line" "[  ERROR  ] Line 2 of the settings is not key = value.
exit 1" "$(run "$script" "$w/blk" settings_region "$w/blk/script" > "$w/blk/region"; run "$script" "$w/blk" read_settings "$w/blk/region")"
printf '%s\n' '#!/bin/bash' ": <<'END_OF_MINER_SETTINGS'" 'wallet = x' > "$w/blk/open"
same "unterminated block" 'exit 1' "$(run "$script" "$w/blk" settings_region "$w/blk/open")"
# The shipped block holds every key, commented with its default, and only wallet and mode live.
same "shipped block" "wallet =
mode = eco" "$(run "$script" "$w/blk" settings_region "$script" | grep -v '^#' | grep -v '^exit 0$' | grep -v '^$')"
for k in pool name donate light mdns ssh_key; do
  run "$script" "$w/blk" settings_region "$script" | grep -q "^# $k = " || fail "shipped block: no commented $k"
done
bash --norc --noprofile -n "$script" || fail "the script does not parse"
grep -qx 'RELEASE_TAG=""' "$script" || fail 'no RELEASE_TAG="" line'
grep -qx 'INSTALLER_SHA256=""' "$script" || fail 'no INSTALLER_SHA256="" line'
grep -qx 'RX_FLOOR_MIB=2560' "$script" || fail 'no RX_FLOOR_MIB=2560 line'
same "floor equal to the installer's" "$(grep -x 'RX_FLOOR_MIB=[0-9]*' "$root/scripts/install.sh")" "$(grep -x 'RX_FLOOR_MIB=[0-9]*' "$script")"

# ---- the handoff ----
# A copy of the script with filled settings, run from its own folder as DietPi would.
mode_of() { stat -c '%a %u' "$1" 2>/dev/null || stat -f '%Lp %u' "$1"; }
me=$(id -u)
started="[  INFO   ] The first-boot setup is installed and starts now: the status LED blinks while it runs."
h="$w/h"; mkdir -p "$h/sbin" "$h/unit" "$h/boot"
{ sed -n '1,/^: <<.END_OF_MINER_SETTINGS.$/p' "$script"
  printf '%s\n' "wallet = $W" 'mode = max' '# pool = x'
  sed -n '/^END_OF_MINER_SETTINGS$/,$p' "$script"; } > "$h/boot/Automation_Custom_Script.sh"
same "handoff" "$started
exit 0" "$(run "$h/boot/Automation_Custom_Script.sh" "$h" handoff)"
same "state folder mode" "700 $me" "$(mode_of "$h/state")"
same "settings copy mode" "600 $me" "$(mode_of "$h/state/settings")"
same "settings copy" "wallet = $W
mode = max
# pool = x" "$(cat "$h/state/settings")"
same "code copy mode" "755 $me" "$(mode_of "$h/sbin/xmrig-first-boot")"
same "code copy without settings" "$(grep -v -x -e "wallet = $W" -e 'mode = max' -e '# pool = x' "$h/boot/Automation_Custom_Script.sh")" "$(cat "$h/sbin/xmrig-first-boot")"
grep -q "$W" "$h/sbin/xmrig-first-boot" && fail "the code copy holds the wallet"
same "unit mode" "644 $me" "$(mode_of "$h/unit/xmrig-first-boot.service")"
same "unit" "[Unit]
Description=Monero miner first-boot setup
After=network.target

[Service]
Type=exec
ExecStart=$h/sbin/xmrig-first-boot setup

[Install]
WantedBy=multi-user.target" "$(cat "$h/unit/xmrig-first-boot.service")"
same "systemctl calls" "daemon-reload
enable xmrig-first-boot.service
start --no-block xmrig-first-boot.service" "$(cat "$w/systemctl.log")"
ls -A "$h/state" "$h/sbin" "$h/unit" | grep -q '^\.' && fail "the handoff left a temp file"
# A second run replaces the copies in place.
rm -f "$w/systemctl.log"
same "handoff again" "$started
exit 0" "$(run "$h/boot/Automation_Custom_Script.sh" "$h" handoff)"
same "settings copy mode again" "600 $me" "$(mode_of "$h/state/settings")"

: > "$w/not-root"
same "handoff not as root" "[  ERROR  ] The first-boot setup must run as root.
exit 1" "$(run "$h/boot/Automation_Custom_Script.sh" "$w/h2" handoff)"
[ -e "$w/h2" ] && fail "the handoff wrote as non-root"
rm -f "$w/not-root"
# A directory in place of a file fails its step.
h3="$w/h3"; mkdir -p "$h3/sbin/xmrig-first-boot/x" "$h3/unit"; rm -f "$w/systemctl.log"
same "handoff code copy fails" "[  ERROR  ] Failed to install the first-boot setup: the setup script.
exit 1" "$(run "$h/boot/Automation_Custom_Script.sh" "$h3" handoff)"
[ -e "$w/systemctl.log" ] && fail "systemctl ran after a failed step"
h4="$w/h4"; mkdir -p "$h4/sbin" "$h4/unit" "$h4/state/settings/x"
same "handoff settings copy fails" "[  ERROR  ] Failed to install the first-boot setup: the settings copy.
exit 1" "$(run "$h/boot/Automation_Custom_Script.sh" "$h4" handoff)"
h5="$w/h5"; mkdir -p "$h5/sbin" "$h5/unit"; : > "$w/systemctl-fails"
same "handoff systemctl fails" "[  ERROR  ] Failed to install the first-boot setup: systemctl daemon-reload.
exit 1" "$(run "$h/boot/Automation_Custom_Script.sh" "$h5" handoff)"
rm -f "$w/systemctl-fails"

# ---- the LED ----
led() { # fixture, compatible, LED name or -
  mkdir -p "$w/$1/leds"
  printf '%s\0' "$2" > "$w/$1/compatible"
  [ "$3" = - ] && return
  mkdir -p "$w/$1/leds/$3"
  printf 'mmc0\n' > "$w/$1/leds/$3/trigger"; printf '0\n' > "$w/$1/leds/$3/brightness"
  printf '255\n' > "$w/$1/leds/$3/max_brightness"
}
led pi raspberrypi,5-model-b ACT
same "LED of a Pi 5" "ACT
exit 0" "$(run "$script" "$w/pi" led_find)"
led opi xunlong,orangepi-5-plus green:indicator-2
same "LED of a 5 Plus" "green:indicator-2
exit 0" "$(run "$script" "$w/opi" led_find)"
led max xunlong,orangepi-5-max -
same "no LED known" "[ WARNING ] No status LED is known for this board: the setup goes on without LEDs.
exit 0" "$(run "$script" "$w/max" led_find)"
led gone raspberrypi,5-model-b -
same "LED absent" "[ WARNING ] No status LED ACT on this board: the setup goes on without LEDs.
exit 0" "$(run "$script" "$w/gone" led_find)"
led odd 'raspberrypi,4-model-b' -
same "unknown board" "[ WARNING ] No status LED is known for this board: the setup goes on without LEDs.
exit 0" "$(run "$script" "$w/odd" led_find)"
cat >> "$w/extra.sh" <<'EOF'
function blink_then() {
    STATUS_LED=$(led_find)
    led_blink_start
    sleep 1; sleep 1; sleep 1; sleep 1; sleep 1; sleep 1
    printf 'pid %s\n' "$BLINK_PID" > "$FX/pid"
    led_state "$1"
}
EOF
leds() { printf '%s %s\n' "$(cat "$w/$1/leds/$2/trigger")" "$(cat "$w/$1/leds/$2/brightness")"; }
same "blink then error" "exit 0" "$(run "$script" "$w/pi" blink_then error)"
same "error LED" "none 255" "$(leds pi ACT)"
# loop_gone <fixture>: the blink loop the last run started has ended (else it is stopped here).
loop_gone() {
  local pid
  pid=$(cut -d" " -f2 "$w/$1/pid")
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { fail "$1: the blink loop still runs"; kill "$pid"; }
}
loop_gone pi
# The loop wrote both levels: tracing its writes shows on and off.
cat >> "$w/extra.sh" <<'EOF'
function blink_trace() {
    STATUS_LED=$(led_find)
    led_blink_start
    local seen="" b
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        sleep 1; read -r b < "$LEDS_DIR/$STATUS_LED/brightness"; seen="$seen $b"
    done
    printf "pid %s\n" "$BLINK_PID" > "$FX/pid"
    led_blink_stop
    [[ $seen == *" 255"* && $seen == *" 0"* ]] && echo "on and off"
    read -r b < "$LEDS_DIR/$STATUS_LED/trigger"; echo "trigger $b"
}
EOF
same "blink writes" "on and off
trigger none
exit 0" "$(run "$script" "$w/opi" blink_trace)"
loop_gone opi
same "blink then heartbeat" "exit 0" "$(run "$script" "$w/opi" blink_then heartbeat)"
loop_gone opi
same "heartbeat LED" "heartbeat" "$(cat "$w/opi/leds/green:indicator-2/trigger")"
same "no LED, one warning" "[ WARNING ] No status LED ACT on this board: the setup goes on without LEDs.
exit 0" "$(run "$script" "$w/gone" blink_then error)"
same "no LED written" "" "$(ls -A "$w/gone/leds")"

[ "$rc" -eq 0 ] && echo "PASS first-boot-settings"
exit "$rc"
