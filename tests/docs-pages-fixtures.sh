#!/bin/bash
# tests/docs-pages.sh fails when it should: it runs against a copy of README.md, CHANGELOG.md,
# docs/, assets/, scripts/first_boot.sh and tests/docs-*.sh, first as they are (it passes), then with one change planted in the copy (it
# fails with the line that names it).
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
set -u

failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

w=$(mktemp -d "${TMPDIR:-/tmp}/docs-pages-fixtures.XXXXXX") && [ -d "$w" ] || {
    echo "FAIL mktemp -d"
    exit 1
}
w=$(cd "$w" && pwd -P)
trap 'rm -rf -- "$w"' EXIT

check="$PWD/tests/docs-pages.sh"

# A fresh copy of what the check reads, in $w/repo.
function fresh() {
    rm -rf -- "$w/repo"
    mkdir "$w/repo"
    cp -R README.md CHANGELOG.md LICENSE docs assets "$w/repo/"
    mkdir "$w/repo/scripts" "$w/repo/tests"
    cp scripts/first_boot.sh "$w/repo/scripts/"
    cp tests/docs-*.sh "$w/repo/tests/"
}

# Runs the check on the copy; $1 is the case, $2 the exit code expected, $3 a pattern one whole
# line of the output must match.
function expect() {
    local out code
    out=$(bash --norc --noprofile "$check" "$w/repo" 2>&1)
    code=$?
    [ "$code" -eq "$2" ] || fail "$1: exit $code, expected $2"
    grep -qxE -- "$3" <<<"$out" || fail "$1: no line matching $3 in: $out"
}

# Runs sed expression $2 on the copy's file $1, in place.
function plant() {
    sed "$2" "$w/repo/$1" > "$w/r" && mv "$w/r" "$w/repo/$1"
}

fresh
expect "the copy as it is" 0 'PASS docs-pages \([0-9]+ links in [0-9]+ files\)'

# A link to a directory that exists is not broken, so a link to a missing file must be.
fresh
printf '\n%s\n' 'See [the missing page](no-such-page.md).' >> "$w/repo/docs/boards.md"
expect "a broken link" 1 'FAIL docs/boards\.md: the link no-such-page\.md names docs/no-such-page\.md, which does not exist'

fresh
printf '\n%s\n' 'See [a missing heading](boards.md#no-such-heading).' >> "$w/repo/docs/operating.md"
expect "a broken anchor" 1 'FAIL docs/operating\.md: the link boards\.md#no-such-heading names an anchor no heading of docs/boards\.md gives'

# An en dash is fine; an em dash is not.
fresh
printf '\n%s\n' $'Runs 5\xe2\x80\x9315% faster.' >> "$w/repo/docs/boards.md"
expect "an en dash" 0 'PASS docs-pages \([0-9]+ links in [0-9]+ files\)'

fresh
printf '\n%s\n' $'It mines \xe2\x80\x94 quietly.' >> "$w/repo/docs/boards.md"
expect "an em dash in a page" 1 'FAIL docs/boards\.md: an em dash in the prose'

fresh
printf '\n%s\n' $'It mines \xe2\x80\x94 quietly.' >> "$w/repo/README.md"
expect "an em dash in the readme" 1 'FAIL README\.md: an em dash in the prose'

fresh
printf '\n%s\n' 'A seamless setup.' >> "$w/repo/README.md"
expect "a stock phrase" 1 "FAIL README\\.md: the stock phrase 'seamless' in the prose"

# 170 lines is the limit: one more line fails.
fresh
while [ "$(($(wc -l <"$w/repo/README.md")))" -lt 170 ]; do echo >> "$w/repo/README.md"; done
expect "a 170-line readme" 0 'PASS docs-pages \([0-9]+ links in [0-9]+ files\)'
echo >> "$w/repo/README.md"
expect "a 171-line readme" 1 'FAIL README\.md: 171 lines, more than 170'

fresh
grep -vF '(docs/README.md)' "$w/repo/README.md" > "$w/r" && mv "$w/r" "$w/repo/README.md"
expect "the index dropped from the readme" 1 'FAIL README\.md: no link to docs/README\.md'

fresh
grep -vF '(docs/earnings.md)' "$w/repo/README.md" > "$w/r" && mv "$w/r" "$w/repo/README.md"
expect "a page dropped from the readme" 1 'FAIL README\.md: no link to docs/earnings\.md'

fresh
grep -vF '(earnings.md)' "$w/repo/docs/README.md" > "$w/r" && mv "$w/r" "$w/repo/docs/README.md"
expect "a page dropped from the index" 1 'FAIL docs/README\.md: links earnings\.md 0 times, not once'

fresh
printf '\n%s\n' '- [Again](boards.md)' >> "$w/repo/docs/README.md"
expect "a page twice in the index" 1 'FAIL docs/README\.md: links boards\.md 2 times, not once'

fresh
rm "$w/repo/docs/upgrading.md"
expect "a page missing" 1 'FAIL docs/upgrading\.md: missing'

fresh
sed 's/^curl -fsSL https:\/\/api/curl -s https:\/\/api/' "$w/repo/docs/earnings.md" > "$w/r" && mv "$w/r" "$w/repo/docs/earnings.md"
expect "curl -s in the live-values command" 1 'FAIL docs/earnings\.md: the live-values command is not one whole line'

fresh
plant README.md '/assets\/banner\.png/d'
expect "the banner dropped" 1 "FAIL README\\.md: no longer says '!\\[Monero Miner Setup banner\\]\\(assets/banner\\.png\\)'"

fresh
plant README.md 's/into a quiet Monero miner/into a Monero miner/'
expect "the pitch reworded" 1 "FAIL README\\.md: no longer says 'Turn a Raspberry Pi, .*TLS to the pool\\.'"

fresh
plant README.md 's/ You run it at your own risk\.//'
expect "the own-risk warning cut" 1 "FAIL README\\.md: no longer says '> .*at your own risk\\.'"

fresh
plant README.md '/A prebuilt arm64 binary/d'
expect "a what-you-get item dropped" 1 "FAIL README\\.md: no longer says '- \\*\\*A prebuilt arm64 binary\\.\\*\\*'"

fresh
plant docs/security.md 's/No VPN ships for the native install or the boards/No VPN ships for the native install/'
expect "the no-VPN sentence cut" 1 "FAIL docs/security\\.md: no longer says 'No VPN ships for the native install or the boards'"

fresh
plant docs/boards.md 's/73-74 °C/75 °C/'
expect "a cooling figure changed" 1 "FAIL docs/boards\\.md: no longer says '73-74 °C'"

fresh
plant docs/earnings.md 's/858 690 000 000/858 000 000 000/g'
expect "the example's difficulty changed" 1 "FAIL docs/earnings\\.md: no longer says '858 690 000 000'"

fresh
: > "$w/repo/tests/docs-new.sh"
expect "a docs check the development page does not name" 1 'FAIL docs/development\.md: does not name tests/docs-new\.sh'

fresh
plant scripts/first_boot.sh 's/^SETTINGS_REMEDY="Flash the card again,/SETTINGS_REMEDY="Flash the SD card again,/'
expect "the settings remedy reworded in the script" 1 'FAIL docs/boards\.md: does not quote the settings remedy of scripts/first_boot\.sh'

fresh
plant docs/troubleshooting.md 's/copy the files from `dietpi-first-boot.zip` onto it, then fix/then fix/'
expect "the settings remedy reworded on a page" 1 'FAIL docs/troubleshooting\.md: does not quote the settings remedy of scripts/first_boot\.sh'

fresh
plant scripts/first_boot.sh 's/the Wi-Fi step never set it up: flash/the Wi-Fi step never ran: flash/'
expect "the Wi-Fi stop line reworded in the script" 1 'FAIL docs/troubleshooting\.md: does not quote the Wi-Fi stop line of scripts/first_boot\.sh'

[ "$failed" -eq 0 ] || exit 1
echo "PASS docs-pages-fixtures"
