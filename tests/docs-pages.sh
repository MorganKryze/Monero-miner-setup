#!/bin/bash
# Every relative link of README.md, CHANGELOG.md and docs/*.md lands: the file it names exists,
# relative to the page, and its #anchor is the GitHub anchor of a heading of the target. Links in
# fenced blocks, and http, https and mailto links, are skipped. Each page under docs/ starts with a
# "# " title line, and its prose, and README.md's, holds no em dash and none of the stock phrases
# the project avoids. The nine pages under docs/ exist; README.md links each of them and the
# docs/README.md index, which links each exactly once; README.md stays at 170 lines or fewer; and
# docs/earnings.md gives the live-values command as one whole line. The lines the docs must keep
# hold as fixed strings, docs/development.md names every tests/docs-*.sh, and the first-boot stops
# the docs quote match scripts/first_boot.sh's own strings.
# Reads the repository root, or the directory given as $1.
set -u

cd -- "${1:-.}" || { echo "FAIL docs-pages: no directory ${1:-.}"; exit 1; }

failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

# GitHub's anchor for a heading: lower case, punctuation other than - and _ dropped, spaces to -.
function slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -e 's/[^a-z0-9 _-]//g' -e 's/ /-/g'
}

# The file's text with its fenced blocks dropped.
function prose() {
    awk '/^[[:space:]]*```/ { f = !f; next } !f' "$1"
}

# The anchors of the file's headings, one per line.
function anchors() {
    local h
    prose "$1" | sed -n 's/^##* //p' | while IFS= read -r h; do
        slug "$h"
        echo
    done
}

pages=(README.md CHANGELOG.md)
for f in docs/*.md; do
    [ -f "$f" ] && pages+=("$f")
done

links=0
for page in "${pages[@]}"; do
    [ -f "$page" ] || { fail "$page: missing"; continue; }
    dir=$(dirname -- "$page")
    text=$(prose "$page")
    targets=$(grep -oE '\]\([^)[:space:]]+\)' <<<"$text" | sed -e 's/^](//' -e 's/)$//')
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        case $t in http://* | https://* | mailto:*) continue ;; esac
        links=$((links + 1))
        file=${t%%#*}
        anchor=
        case $t in *'#'*) anchor=${t#*#} ;; esac
        if [ -z "$file" ]; then
            target=$page
        else
            target=$dir/$file
        fi
        if [ ! -e "$target" ]; then
            fail "$page: the link $t names $target, which does not exist"
            continue
        fi
        if [ -n "$anchor" ]; then
            if [ ! -f "$target" ] || ! grep -qxF -- "$anchor" <<<"$(anchors "$target")"; then
                fail "$page: the link $t names an anchor no heading of $target gives"
            fi
        fi
    done <<<"$targets"
done

stock='seamless|robust|leverage|delve|comprehensive|game-changer|elevate|streamline|it.s worth noting'
for page in README.md docs/*.md; do
    [ -f "$page" ] || continue
    if [ "$page" != README.md ]; then
        [ "$(sed -n 1p "$page" | cut -c1-2)" = "# " ] || fail "$page: the first line is not a '# ' title"
    fi
    text=$(prose "$page" | sed 's/`[^`]*`//g')
    if grep -qF -- $'\xe2\x80\x94' <<<"$text"; then
        fail "$page: an em dash in the prose"
    fi
    found=$(grep -oiE -- "$stock" <<<"$text" | sed -n 1p)
    [ -z "$found" ] || fail "$page: the stock phrase '$found' in the prose"
done

# The links of a file to the pages of docs/, one per line, as written.
function page_links() {
    grep -oE '\]\([^)#[:space:]]+' <<<"$(prose "$1")" | sed 's/^](//'
}

PAGES=(boards native-install docker security earnings operating upgrading troubleshooting development)
readme_links=
[ -f README.md ] && readme_links=$(page_links README.md)
index_links=
[ -f docs/README.md ] && index_links=$(page_links docs/README.md)
[ -f docs/README.md ] || fail "docs/README.md: missing"
grep -qxF -- docs/README.md <<<"$readme_links" || fail "README.md: no link to docs/README.md"
for p in "${PAGES[@]}"; do
    [ -f "docs/$p.md" ] || fail "docs/$p.md: missing"
    grep -qxF -- "docs/$p.md" <<<"$readme_links" || fail "README.md: no link to docs/$p.md"
    n=$(grep -cxF -- "$p.md" <<<"$index_links")
    [ "$n" -eq 1 ] || fail "docs/README.md: links $p.md $n times, not once"
done

if [ -f README.md ]; then
    lines=$(($(wc -l <README.md)))
    [ "$lines" -le 170 ] || fail "README.md: $lines lines, more than 170"
fi

LIVE="curl -fsSL https://api.moneroocean.stream/network/stats | jq '.\"18081\" | {difficulty, reward_xmr: (.value / 1e12)}'"
if [ -f docs/earnings.md ]; then
    grep -qxF -- "$LIVE" docs/earnings.md || fail "docs/earnings.md: the live-values command is not one whole line"
fi

# The lines the docs must keep, as fixed strings: the README's banner, pitch, risk warning and
# "What you get" list, the no-VPN sentence, the measured cooling figures and the dated earnings
# figures. Rewording one means rewording it here too.
function keeps() {
    local page=$1 text=$2
    [ -f "$page" ] || return 0
    grep -qF -- "$text" "$page" || fail "$page: no longer says '$text'"
}
keeps README.md '![Monero Miner Setup banner](assets/banner.png)'
keeps README.md 'Turn a Raspberry Pi, a spare PC or any Docker host into a quiet Monero miner: one command, TLS to the pool.'
keeps README.md '> **⚠️ Before you run this.** Mining consumes power, heats hardware, and can violate your cloud provider'"'"'s ToS. Expect antivirus tools to flag XMRig. This project is not endorsed by Monero or MoneroOcean. You run it at your own risk.'
for text in '## What you get' '- **TLS to the pool.**' '- **An eco mode for boards.**' '- **A prebuilt arm64 binary.**' \
    '- **A card that mines on first boot.**' '- **Docker, with an optional VPN.**'; do
    keeps README.md "$text"
done
keeps docs/security.md 'No VPN ships for the native install or the boards'
for text in '391 to 398 H/s' '402 H/s' '372 H/s' '73-74 °C'; do
    keeps docs/boards.md "$text"
done
for text in '858 690 000 000' '0.0015 XMR' '0.72 EUR' '479 EUR'; do
    keeps docs/earnings.md "$text"
done
for text in '0.0015 XMR' '0.72 EUR' '479 EUR/XMR'; do
    keeps README.md "$text"
done

# docs/development.md names every tests/docs-*.sh.
[ -f docs/development.md ] || fail "docs/development.md: missing"
for t in tests/docs-*.sh; do
    [ -f "$t" ] || continue
    [ -f docs/development.md ] || continue
    grep -qF -- "\`$t\`" docs/development.md || fail "docs/development.md: does not name $t"
done

# The first-boot stops the docs quote are scripts/first_boot.sh's own strings: the settings remedy
# on both pages (its first letter in either case, its closing full stop optional), the Wi-Fi stop
# line on troubleshooting.md. Code spans are read as plain text.
FIRST_BOOT=scripts/first_boot.sh
if [ -f "$FIRST_BOOT" ]; then
    remedy=$(sed -n 's/^SETTINGS_REMEDY="\(.*\)"$/\1/p' "$FIRST_BOOT")
    wifi=$(sed -n 's/^ *error "\(Wi-Fi was asked for (wifi_ssid)[^"]*\)"$/\1/p' "$FIRST_BOOT")
    [ -n "$remedy" ] || fail "$FIRST_BOOT: no SETTINGS_REMEDY"
    [ -n "$wifi" ] || fail "$FIRST_BOOT: no Wi-Fi stop line"
    remedy=${remedy%.}
    lower=$(tr '[:upper:]' '[:lower:]' <<<"${remedy:0:1}")${remedy:1}
    for page in docs/troubleshooting.md docs/boards.md; do
        [ -f "$page" ] && [ -n "$remedy" ] || continue
        text=$(tr -d '`' <"$page")
        grep -qF -- "$remedy" <<<"$text" || grep -qF -- "$lower" <<<"$text" ||
            fail "$page: does not quote the settings remedy of $FIRST_BOOT"
    done
    if [ -f docs/troubleshooting.md ] && [ -n "$wifi" ]; then
        grep -qF -- "$wifi" <<<"$(tr -d '`' <docs/troubleshooting.md)" ||
            fail "docs/troubleshooting.md: does not quote the Wi-Fi stop line of $FIRST_BOOT"
    fi
else
    fail "$FIRST_BOOT: missing"
fi

[ "$failed" -eq 0 ] || exit 1
echo "PASS docs-pages ($links links in ${#pages[@]} files)"
