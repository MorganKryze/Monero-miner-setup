#!/bin/bash
# docs/boards.md, from "Set up a card that mines on first boot" to the next "## " heading, names
# what the DietPi files do: every settings key with its
# default, as the block at the top of scripts/first_boot.sh writes it, the paths the setup installs,
# each dietpi.txt key the project changes, the LED states, the zip checks and the board notes. A
# new key, path or changed dietpi.txt key without its line on the page fails here.
# Reads the repository root, or the directory given as $1.
set -u

cd -- "${1:-.}" || { echo "FAIL docs-first-boot: no directory ${1:-.}"; exit 1; }

PAGE=docs/boards.md
SCRIPT=scripts/first_boot.sh
DIETPI_TEST=tests/dietpi-files.sh
failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

for f in "$PAGE" "$SCRIPT" "$DIETPI_TEST"; do
    [ -f "$f" ] || { echo "FAIL docs-first-boot: no $f"; exit 1; }
done
section=$(sed -n '/^## Set up a card that mines on first boot$/,/^## /p' "$PAGE" | sed '1d;$d')
[ -n "$section" ] || { echo "FAIL docs-first-boot: $PAGE has no '## Set up a card that mines on first boot' section"; exit 1; }

# True when the section holds $1 as text.
function says() {
    case $section in *"$1"*) return 0 ;; esac
    return 1
}

# The settings block: each `key = value` line, commented or not, is named as a code span.
block=$(sed -n "/^: <<'END_OF_MINER_SETTINGS'\$/,/^END_OF_MINER_SETTINGS\$/p" "$SCRIPT" | sed '1d;$d')
[ -n "$block" ] || fail "docs-first-boot: $SCRIPT has no settings block"
n=0
while IFS= read -r line; do
    line=${line#\# }
    [[ $line =~ ^[a-z_]+\ =( |$) ]] || continue
    n=$((n + 1))
    line=${line% }
    says "\`$line\`" || fail "docs-first-boot: the section does not show the setting \`$line\`"
done <<<"$block"
[ "$n" -ge 12 ] || fail "docs-first-boot: read $n settings from $SCRIPT, expected 12"

# The paths the setup installs, read from the script's constants.
for name in SETUP_BIN SETUP_UNIT STATE_DIR; do
    value=$(sed -n "s/^$name=\"\(.*\)\"\$/\1/p" "$SCRIPT")
    [ -n "$value" ] || { fail "docs-first-boot: $SCRIPT has no $name"; continue; }
    says "\`$value\`" || fail "docs-first-boot: the section does not name $name \`$value\`"
done

# Each dietpi.txt key the project changes, with its value, as tests/dietpi-files.sh lists them.
changed=$(sed -n "/^CHANGED='/,/'\$/p" "$DIETPI_TEST" | tr -d "'" | sed 's/^CHANGED=//')
[ -n "$changed" ] || fail "docs-first-boot: $DIETPI_TEST has no CHANGED list"
while read -r key ours theirs; do
    [ -n "$key" ] || continue
    says "\`$key=$ours\`" || fail "docs-first-boot: the section does not name the dietpi.txt change \`$key=$ours\`"
done <<<"$changed"

for text in dietpi-first-boot.zip SHA256SUMS "sha256sum -c SHA256SUMS" "gh attestation verify dietpi-first-boot.zip" \
    "make service-disable" 127.0.1.1 authorized_keys avahi-daemon MaskROM END_OF_MINER_SETTINGS \
    Automation_Custom_Script.sh dietpi.txt DIETPISETUP GPL-2.0 LGPL-2.1 \
    blinks heartbeat "steady on" "journalctl -u xmrig-first-boot.service"; do
    says "$text" || fail "docs-first-boot: the section does not name $text"
done

# The Wi-Fi step: the pre-script, the file it writes and the dietpi.txt line it turns on.
for text in Automation_Custom_PreScript.sh dietpi-wifi.txt AUTO_SETUP_NET_WIFI_ENABLED=1 wifi_country; do
    says "$text" || fail "docs-first-boot: the section does not name $text"
done
# A Wi-Fi key is read as it stands: quoting one that holds a quote keeps the outer quotes, so the
# page asks for quotes only to keep a space at either end, with the kind the key doesn't hold.
says 'quote a key holding a space, `#` or a quote' && fail "docs-first-boot: the section still says to quote a key holding a quote"
says "read as it stands" || fail "docs-first-boot: the section does not say a Wi-Fi key is read as it stands"
says "the kind of quote it doesn't hold" || fail "docs-first-boot: the section does not say which quote to wrap a Wi-Fi key in"
says "Wi-Fi isn't set up" && fail "docs-first-boot: the section still says Wi-Fi isn't set up"
# DietPi moves the files off the FAT at first boot: none of them stays on the card's FAT.
says "The files stay there" && fail "docs-first-boot: the section still says the files stay on the FAT"

[ "$failed" -eq 0 ] && echo "PASS docs-first-boot"
exit "$failed"
