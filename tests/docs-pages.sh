#!/bin/bash
# Every relative link of README.md, CHANGELOG.md and docs/*.md lands: the file it names exists,
# relative to the page, and its #anchor is the GitHub anchor of a heading of the target. Links in
# fenced blocks, and http, https and mailto links, are skipped. Each page under docs/ starts with a
# "# " title line, and its prose holds no em dash and none of the stock phrases the project avoids.
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
    for t in $targets; do
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
    done
done

stock='seamless|robust|leverage|delve|comprehensive|game-changer|elevate|streamline|it.s worth noting'
for page in docs/*.md; do
    [ -f "$page" ] || continue
    [ "$(sed -n 1p "$page" | cut -c1-2)" = "# " ] || fail "$page: the first line is not a '# ' title"
    text=$(prose "$page" | sed 's/`[^`]*`//g')
    if grep -qF -- $'\xe2\x80\x94' <<<"$text"; then
        fail "$page: an em dash in the prose"
    fi
    found=$(grep -oiE -- "$stock" <<<"$text" | sed -n 1p)
    [ -z "$found" ] || fail "$page: the stock phrase '$found' in the prose"
done

[ "$failed" -eq 0 ] || exit 1
echo "PASS docs-pages ($links links in ${#pages[@]} files)"
