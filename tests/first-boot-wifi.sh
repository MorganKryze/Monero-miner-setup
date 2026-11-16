#!/bin/bash
# The Wi-Fi mode of the DietPi custom script (scripts/first_boot.sh wifi) runs before DietPi's
# network step. From the wifi_ssid, wifi_key and wifi_country settings it writes dietpi-wifi.txt
# (0600, each value single-quoted so bash reading it gets the value and runs nothing), turns Wi-Fi
# on in dietpi.txt with exactly two lines changed, records the country in a 0600 file of a 0700
# folder, and empties every wifi_key line of the script's settings whatever happened. It reads only
# the Wi-Fi keys, refuses a value of the wrong form or a key without its pair with one line, and
# never prints the key.
# Every function runs under env -i on fixtures from a scratch folder, with a stub id; PATH holds
# only the stub and tool-link directories. Run from the repository root. Prints FAIL lines, exits 1
# on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
same() { # label, expected, got
  [ "$2" = "$3" ] || { fail "$1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/    /'; }
}
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/tools" "$w/stubs" "$w/cwd"
# touch is there for the hostile values: a value that ran would leave a file in the scratch folder.
for t in chmod mkdir mktemp mv rm cat cp touch; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
printf '#!/bin/sh\necho 0\n' > "$w/stubs/id"
chmod +x "$w/stubs/"*

# The driver sources the fixture's copy of the script, points the host paths at the fixture, then
# runs the function it is given. With FAIL_DIETPI set, writing a file named dietpi.txt fails.
cat > "$w/drive.sh" <<'EOF'
# shellcheck source=/dev/null
source "$SCRIPT"
BOOT_DIR="$FX/boot" STATE_DIR="$FX/state" NET_DIR="$FX/net"
if [ -n "${FAIL_DIETPI:-}" ]; then
    eval "real_$(declare -f put_file)"
    function put_file() {
        if [[ $1 == */dietpi.txt ]]; then cat >/dev/null; return 1; fi
        real_put_file "$@"
    }
fi
"$@"
EOF
script="$root/scripts/first_boot.sh"
[ -f "$script" ] || { echo "FAIL no scripts/first_boot.sh"; exit 1; }
[ -f "$root/templates/dietpi.txt" ] || { echo "FAIL no templates/dietpi.txt"; exit 1; }
mode_of() { stat -c '%a %u' "$1" 2>/dev/null || stat -f '%Lp %u' "$1"; }
me=$(id -u)
remedy="Fix it in the settings at the top of Automation_Custom_Script.sh on your computer and flash the card again."
W=44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A
# A made-up key, never a real network's.
KEY='not-a-real-key-42'

# fixture <name> <settings lines...>: boot/ with the template's dietpi.txt and a copy of the script
# whose settings block holds the lines; expected.sh is that copy with each wifi_key line emptied,
# a commented one, one in another case or one set apart by a Unicode space included.
fixture() {
  local LC_ALL=C fx="$w/$1" line; shift
  rm -rf -- "$fx"; mkdir -p "$fx/boot"
  cp "$root/templates/dietpi.txt" "$fx/boot/dietpi.txt"
  { sed -n '1,/^: <<.END_OF_MINER_SETTINGS.$/p' "$script"
    printf '%s\n' '# the owner'"'"'s settings' "$@"
    sed -n '/^END_OF_MINER_SETTINGS$/,$p' "$script"
  } > "$fx/boot/Automation_Custom_Script.sh"
  { sed -n '1,/^: <<.END_OF_MINER_SETTINGS.$/p' "$script"
    printf '%s\n' '# the owner'"'"'s settings'
    for line in "$@"; do
      if [[ ${line,,} =~ ^([^[:alnum:]_=]*)wifi_key[^[:alnum:]_=]*= ]]; then
        if [[ ${BASH_REMATCH[1]} == *#* ]]; then echo '# wifi_key ='; else echo 'wifi_key ='; fi
      else printf '%s\n' "$line"; fi
    done
    sed -n '/^END_OF_MINER_SETTINGS$/,$p' "$script"
  } > "$fx/expected.sh"
  cp "$fx/boot/dietpi.txt" "$fx/dietpi.before"
}
# step <name> [key]: runs the Wi-Fi mode on the fixture from the scratch folder, in the locale
# RUN_LANG names when set; prints its output and exit code. Checks the key is in no output line and
# the script kept all but its key's value.
step() {
  local fx="$w/$1" key=${2:-$KEY} code
  (cd "$w/cwd" && env -i ${RUN_LANG:+"LANG=$RUN_LANG"} PATH="$w/stubs:$w/tools" SCRIPT="$fx/boot/Automation_Custom_Script.sh" FX="$fx" \
    FAIL_DIETPI="${FAIL_DIETPI:-}" "$BASH" --norc --noprofile "$w/drive.sh" main wifi) > "$w/run.out" 2>&1
  code=$?
  grep -F -- "$key" "$w/run.out" >/dev/null && fail "$1: the output holds the key"
  cmp -s "$fx/expected.sh" "$fx/boot/Automation_Custom_Script.sh" || fail "$1: the script is not its copy with wifi_key emptied"
  grep -F -- "$key" "$fx/boot/Automation_Custom_Script.sh" >/dev/null && fail "$1: the script holds the key"
  cat "$w/run.out"; echo "exit $code"
}
# readback <name>: the network bash reads from dietpi-wifi.txt as DietPi does, from the scratch folder.
readback() {
  (cd "$w/cwd" && env -i PATH="$w/tools" "$BASH" --norc --noprofile -c \
    '. "$1"; printf "%s\n" "${aWIFI_SSID[0]}" "${aWIFI_KEY[0]}" "${aWIFI_KEYMGR[0]}"' _ "$w/$1/boot/dietpi-wifi.txt")
}
untouched() { # name: neither DietPi file written, no record
  [ -e "$w/$1/boot/dietpi-wifi.txt" ] && fail "$1: dietpi-wifi.txt written"
  cmp -s "$w/$1/dietpi.before" "$w/$1/boot/dietpi.txt" || fail "$1: dietpi.txt changed"
  [ -e "$w/$1/state/wifi" ] && fail "$1: a record was written"
}
set_line() { printf 'Wi-Fi set for the network %s, country %s: DietPi brings it up next.' "$1" "$2"; }
ok() { # name, ssid, key, country written: the happy path's files
  same "$1: network" "$2
$3
WPA-PSK" "$(readback "$1")"
  same "$1: dietpi-wifi.txt mode" "600 $me" "$(mode_of "$w/$1/boot/dietpi-wifi.txt")"
  same "$1: record" "country=$4" "$(cat "$w/$1/state/wifi")"
}

# ---- the happy path ----
fixture happy "wallet = $W" 'mode = eco' 'wifi_ssid = Home' "wifi_key = $KEY" 'wifi_country = FR'
same "happy path" "[  INFO   ] $(set_line Home FR)
exit 0" "$(step happy)"
ok happy Home "$KEY" FR
same "dietpi.txt diff" "< AUTO_SETUP_NET_WIFI_ENABLED=0
---
> AUTO_SETUP_NET_WIFI_ENABLED=1
< AUTO_SETUP_NET_WIFI_COUNTRY_CODE=GB
---
> AUTO_SETUP_NET_WIFI_COUNTRY_CODE=FR" "$(diff "$w/happy/dietpi.before" "$w/happy/boot/dietpi.txt" | grep -v '^[0-9]')"
grep -x 'AUTO_SETUP_NET_ETHERNET_ENABLED=1' "$w/happy/boot/dietpi.txt" >/dev/null || fail "happy path: Ethernet is not enabled"
same "record mode" "600 $me" "$(mode_of "$w/happy/state/wifi")"
same "state folder mode" "700 $me" "$(mode_of "$w/happy/state")"
ls -A "$w/happy/boot" "$w/happy/state" | grep '^\.' >/dev/null && fail "happy path: a temp file was left"

fixture lower 'wifi_ssid = Home' "wifi_key = $KEY" 'wifi_country = fr'
same "lower-case country" "[  INFO   ] $(set_line Home FR)
exit 0" "$(step lower)"
grep -x 'AUTO_SETUP_NET_WIFI_COUNTRY_CODE=FR' "$w/lower/boot/dietpi.txt" >/dev/null || fail "lower-case country: not written FR"

# ---- hostile values: read back unchanged, nothing runs ----
n=0
for v in "a'b" '$(touch x)' '`touch x`' "x'; touch y; '"; do
  n=$((n + 1))
  fixture "hostile$n" "wifi_ssid = $v" "wifi_key = $KEY" 'wifi_country = FR'
  same "hostile SSID $v" "[  INFO   ] $(set_line "$v" FR)
exit 0" "$(step "hostile$n")"
  ok "hostile$n" "$v" "$KEY" FR
done
for v in '$(touch k1)' '`touch k2`' "k'; touch k3; '" "it's a key"; do
  n=$((n + 1))
  fixture "hostile$n" 'wifi_ssid = Home' "wifi_key = $v" 'wifi_country = FR'
  same "hostile key $n" "[  INFO   ] $(set_line Home FR)
exit 0" "$(step "hostile$n" "$v")"
  ok "hostile$n" Home "$v" FR
done
same "nothing ran" "" "$(ls -A "$w/cwd")"

# ---- forms ----
refused() { # name, expected error, then the settings lines
  local name=$1 want=$2; shift 2
  fixture "$name" "$@"
  same "$name" "[  ERROR  ] $want
exit 1" "$(step "$name")"
  untouched "$name"
}
s29=$(printf 'n%.0s' {1..29})
fixture ssid32 "wifi_ssid = ${s29}’" "wifi_key = $KEY" 'wifi_country = FR'
same "SSID of 32 bytes" "[  INFO   ] $(set_line "${s29}’" FR)
exit 0" "$(step ssid32)"
ok ssid32 "${s29}’" "$KEY" FR
ssid_rule='must be 1 to 32 bytes with no control character, no " and no \: rename the network if it holds one'
refused ssid33 "Setting 'wifi_ssid' $ssid_rule. $remedy" "wifi_ssid = n${s29}’" "wifi_key = $KEY" 'wifi_country = FR'
refused ssid-tab "Setting 'wifi_ssid' $ssid_rule. $remedy" "wifi_ssid = a$(printf '\t')b" "wifi_key = $KEY" 'wifi_country = FR'
refused ssid-dq "Setting 'wifi_ssid' $ssid_rule. $remedy" 'wifi_ssid = a"b' "wifi_key = $KEY" 'wifi_country = FR'
refused ssid-bs "Setting 'wifi_ssid' $ssid_rule. $remedy" 'wifi_ssid = a\b' "wifi_key = $KEY" 'wifi_country = FR'
key_rule="must be 8 to 63 printable ASCII characters, or the 64 hex digits of its PSK"
refused key7 "Setting 'wifi_key' $key_rule. $remedy" 'wifi_ssid = Home' 'wifi_key = abcdefg' 'wifi_country = FR'
p64=$(printf 'p%.0s' {1..64})
refused key64 "Setting 'wifi_key' $key_rule. $remedy" 'wifi_ssid = Home' "wifi_key = $p64" 'wifi_country = FR'
# WPA takes 8 to 63 printable ASCII characters: both ends pass, a non-ASCII or control byte does not.
fixture key8 'wifi_ssid = Home' 'wifi_key = made-up8' 'wifi_country = FR'
same "key of 8 characters" "[  INFO   ] $(set_line Home FR)
exit 0" "$(step key8 made-up8)"
ok key8 Home made-up8 FR
p63=${p64%p}
fixture key63 'wifi_ssid = Home' "wifi_key = $p63" 'wifi_country = FR'
same "key of 63 characters" "[  INFO   ] $(set_line Home FR)
exit 0" "$(step key63 "$p63")"
ok key63 Home "$p63" FR
refused key-accent "Setting 'wifi_key' $key_rule. $remedy" 'wifi_ssid = Home' 'wifi_key = made-up-clé-1' 'wifi_country = FR'
refused key-del "Setting 'wifi_key' $key_rule. $remedy" 'wifi_ssid = Home' "wifi_key = made-up$(printf '\177')key-2" 'wifi_country = FR'
h64=$(printf '0123456789abcdef%.0s' 1 2 3 4)
fixture hex64 'wifi_ssid = Home' "wifi_key = $h64" 'wifi_country = FR'
same "64 hex key" "[  INFO   ] $(set_line Home FR)
exit 0" "$(step hex64 "$h64")"
ok hex64 Home "$h64" FR
fixture hash 'wifi_ssid = Home' 'wifi_key = pa ss #word' 'wifi_country = FR'
same "key with a space and #" "[  INFO   ] $(set_line Home FR)
exit 0" "$(step hash 'pa ss #word')"
ok hash Home 'pa ss #word' FR
refused country "Setting 'wifi_country' must be your country's two-letter code, such as FR. $remedy" \
  'wifi_ssid = Home' "wifi_key = $KEY" 'wifi_country = FRA'
refused country-digit "Setting 'wifi_country' must be your country's two-letter code, such as FR. $remedy" \
  'wifi_ssid = Home' "wifi_key = $KEY" 'wifi_country = F1'

# ---- pairs and repeats ----
refused key-alone "Settings 'wifi_ssid' and 'wifi_key' go together. $remedy" "wifi_key = $KEY" 'wifi_country = FR'
refused country-alone "Settings 'wifi_ssid' and 'wifi_country' go together. $remedy" 'wifi_country = FR'
refused no-country "Settings 'wifi_ssid' and 'wifi_country' go together. $remedy" 'wifi_ssid = Home' "wifi_key = $KEY"
refused no-key "Settings 'wifi_ssid' and 'wifi_key' go together. $remedy" 'wifi_ssid = Home' 'wifi_country = FR'
# A key filled in on a line left commented, or with its name in capitals, leaves the card too.
fixture commented 'wifi_ssid = Home' "#wifi_key = $KEY" 'wifi_country = FR'
same "key on a commented line" "[  ERROR  ] Settings 'wifi_ssid' and 'wifi_key' go together. $remedy
exit 1" "$(step commented)"
untouched commented
fixture all-commented '# wifi_ssid = Home' "  # wifi_key = $KEY" '## wifi_country = FR'
same "all three commented" "exit 0" "$(step all-commented)"
untouched all-commented
fixture capitals 'wifi_ssid = Home' "WiFi_Key = $KEY" 'wifi_country = FR'
same "key named in capitals" "[  ERROR  ] Settings 'wifi_ssid' and 'wifi_key' go together. $remedy
exit 1" "$(step capitals)"
untouched capitals
# DietPi runs the step in C.UTF-8, where bash's [[:space:]] also takes Unicode spaces such as
# U+3000 and U+2003: the key on a line set apart by one is read, so it leaves the card too.
u3000=$'\xe3\x80\x80' u2003=$'\xe2\x80\x83'
env -i LANG=C.UTF-8 "$BASH" --norc --noprofile -c '[[ $1 =~ ^[[:space:]]$ ]]' _ "$u3000" ||
  fail "no C.UTF-8 locale here that reads U+3000 as a space"
fixture wide-before 'wifi_ssid = Home' "${u3000}wifi_key = $KEY" 'wifi_country = FR'
same "key after a Unicode space, UTF-8 locale" "[  INFO   ] $(set_line Home FR)
exit 0" "$(RUN_LANG=C.UTF-8 step wide-before)"
fixture wide-after 'wifi_ssid = Home' "wifi_key${u2003}= $KEY" 'wifi_country = FR'
same "key name then a Unicode space, UTF-8 locale" "[  INFO   ] $(set_line Home FR)
exit 0" "$(RUN_LANG=C.UTF-8 step wide-after)"
fixture wide-commented 'wifi_ssid = Home' "#${u3000}wifi_key = $KEY" 'wifi_country = FR'
same "key commented with a Unicode space, UTF-8 locale" "[  ERROR  ] Settings 'wifi_ssid' and 'wifi_key' go together. $remedy
exit 1" "$(RUN_LANG=C.UTF-8 step wide-commented)"
untouched wide-commented
# A name that only holds wifi_key, or goes on past it, is not the key's line.
fixture key-in-name 'wifi_ssid = my_wifi_key=net' "wifi_key = $KEY" 'wifi_country = FR'
same "network named after the key" "[  INFO   ] $(set_line my_wifi_key=net FR)
exit 0" "$(step key-in-name)"
grep -x 'wifi_ssid = my_wifi_key=net' "$w/key-in-name/boot/Automation_Custom_Script.sh" >/dev/null ||
  fail "network named after the key: its line was emptied"
refused key-twice "Setting 'wifi_key' is given twice. $remedy" 'wifi_ssid = Home' "wifi_key = $KEY" "  wifi_key = $KEY" 'wifi_country = FR'

# ---- only the Wi-Fi keys count ----
fixture other-keys 'mode = x' 'not a setting' 'wifi_ssid = Home' "wifi_key = $KEY" 'wifi_country = FR'
same "missing wallet and a bad mode" "[  INFO   ] $(set_line Home FR)
exit 0" "$(step other-keys)"
ok other-keys Home "$KEY" FR
fixture none "wallet = $W" 'mode = eco' '# wifi_ssid =' '# wifi_key =' '# wifi_country = FR'
same "no wifi_ssid" "exit 0" "$(step none)"
untouched none

# ---- dietpi.txt it cannot edit ----
dietpi_error="[  ERROR  ] Failed to set up Wi-Fi: $w/%s/boot/dietpi.txt needs exactly one AUTO_SETUP_NET_WIFI_ENABLED= line and one AUTO_SETUP_NET_WIFI_COUNTRY_CODE= line at the start of a line. Copy dietpi.txt from dietpi-first-boot.zip to the card again.
exit 1"
for case in no-enable country-twice enable-twice indented; do
  fixture "$case" 'wifi_ssid = Home' "wifi_key = $KEY" 'wifi_country = FR'
  f="$w/$case/boot/dietpi.txt"
  case $case in
    no-enable) grep -v '^AUTO_SETUP_NET_WIFI_ENABLED=' "$root/templates/dietpi.txt" > "$f" ;;
    country-twice) printf 'AUTO_SETUP_NET_WIFI_COUNTRY_CODE=GB\n' >> "$f" ;;
    enable-twice) printf 'AUTO_SETUP_NET_WIFI_ENABLED=0\n' >> "$f" ;;
    indented) sed 's/^AUTO_SETUP_NET_WIFI_ENABLED=/  &/' "$root/templates/dietpi.txt" > "$f" ;;
  esac
  cp "$f" "$w/$case/dietpi.before"
  # shellcheck disable=SC2059
  same "dietpi.txt $case" "$(printf "$dietpi_error" "$case")" "$(step "$case")"
  untouched "$case"
done
fixture write-fails 'wifi_ssid = Home' "wifi_key = $KEY" 'wifi_country = FR'
same "dietpi.txt write fails" "[  ERROR  ] Failed to set up Wi-Fi: writing $w/write-fails/boot/dietpi.txt failed. Copy the files from dietpi-first-boot.zip to the card again.
exit 1" "$(FAIL_DIETPI=1 step write-fails)"
untouched write-fails

[ "$rc" -eq 0 ] && echo "PASS first-boot-wifi"
exit "$rc"
