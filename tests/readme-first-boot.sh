#!/bin/bash
# The README's "DietPi first boot" names what the DietPi files do: every settings key with its
# default, as the block at the top of scripts/first_boot.sh writes it, the paths the setup installs,
# each dietpi.txt key the project changes, the LED states, the zip checks and the board notes. A
# new key, path or changed dietpi.txt key without its README line fails here.
# Reads the repository root, or the directory given as $1.
set -u

cd -- "${1:-.}" || { echo "FAIL readme-first-boot: no directory ${1:-.}"; exit 1; }

README=README.md
SCRIPT=scripts/first_boot.sh
DIETPI_TEST=tests/dietpi-files.sh
failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

for f in "$README" "$SCRIPT" "$DIETPI_TEST"; do
    [ -f "$f" ] || { echo "FAIL readme-first-boot: no $f"; exit 1; }
done
section=$(sed -n '/^### DietPi first boot$/,/^### /p' "$README" | sed '1d;$d')
[ -n "$section" ] || { echo "FAIL readme-first-boot: $README has no DietPi first boot section"; exit 1; }

# True when the section holds $1 as text.
function says() {
    case $section in *"$1"*) return 0 ;; esac
    return 1
}

# The settings block: each `key = value` line, commented or not, is named as a code span.
block=$(sed -n "/^: <<'END_OF_MINER_SETTINGS'\$/,/^END_OF_MINER_SETTINGS\$/p" "$SCRIPT" | sed '1d;$d')
[ -n "$block" ] || fail "readme-first-boot: $SCRIPT has no settings block"
n=0
while IFS= read -r line; do
    line=${line#\# }
    [[ $line =~ ^[a-z_]+\ =( |$) ]] || continue
    n=$((n + 1))
    line=${line% }
    says "\`$line\`" || fail "readme-first-boot: the section does not show the setting \`$line\`"
done <<<"$block"
[ "$n" -ge 8 ] || fail "readme-first-boot: read $n settings from $SCRIPT, expected 8"

# The paths the setup installs, read from the script's constants.
for name in SETUP_BIN SETUP_UNIT STATE_DIR; do
    value=$(sed -n "s/^$name=\"\(.*\)\"\$/\1/p" "$SCRIPT")
    [ -n "$value" ] || { fail "readme-first-boot: $SCRIPT has no $name"; continue; }
    says "\`$value\`" || fail "readme-first-boot: the section does not name $name \`$value\`"
done

# Each dietpi.txt key the project changes, with its value, as tests/dietpi-files.sh lists them.
changed=$(sed -n "/^CHANGED='/,/'\$/p" "$DIETPI_TEST" | tr -d "'" | sed 's/^CHANGED=//')
[ -n "$changed" ] || fail "readme-first-boot: $DIETPI_TEST has no CHANGED list"
while read -r key ours theirs; do
    [ -n "$key" ] || continue
    says "\`$key=$ours\`" || fail "readme-first-boot: the section does not name the dietpi.txt change \`$key=$ours\`"
done <<<"$changed"

for text in dietpi-first-boot.zip SHA256SUMS "sha256sum -c SHA256SUMS" "gh attestation verify dietpi-first-boot.zip" \
    "make service-disable" 127.0.1.1 authorized_keys avahi-daemon MaskROM END_OF_MINER_SETTINGS \
    Automation_Custom_Script.sh dietpi.txt DIETPISETUP GPL-2.0 LGPL-2.1 \
    blinks heartbeat "steady on" "journalctl -u xmrig-first-boot.service"; do
    says "$text" || fail "readme-first-boot: the section does not name $text"
done

[ "$failed" -eq 0 ] && echo "PASS readme-first-boot"
exit "$failed"
