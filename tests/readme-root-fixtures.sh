#!/bin/bash
# tests/readme-root.sh fails when it should: it runs against a copy of the README, the Makefile and
# the scripts, first as they are (it passes), then with one change planted in the copy (it fails
# with the line that names it, or passes for a sudo that does not run as root).
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
set -u

failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

w=$(mktemp -d "${TMPDIR:-/tmp}/readme-root-fixtures.XXXXXX") && [ -d "$w" ] || {
    echo "FAIL mktemp -d"
    exit 1
}
w=$(cd "$w" && pwd -P)
trap 'rm -rf -- "$w"' EXIT

check="$PWD/tests/readme-root.sh"

# A fresh copy of what the check reads, in $w/repo.
function fresh() {
    rm -rf -- "$w/repo"
    mkdir "$w/repo"
    cp -R README.md Makefile scripts "$w/repo/"
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

pass='PASS readme-root \([0-9]+ sudo commands\)'

fresh
expect "the copy as it is" 0 "$pass"

fresh
printf '\n%s\n' '	sudo rm -f /etc/sysctl.d/99-xmrig.conf' >> "$w/repo/Makefile"
expect "an rm of another path" 1 \
    'FAIL README\.md does not name /etc/sysctl\.d/99-xmrig\.conf, which Makefile:[0-9]+ writes through sudo'

fresh
printf '%s\n' 'sudo systemctl mask xmrig.service' >> "$w/repo/scripts/setup_service_debian.sh"
expect "another systemctl verb" 1 \
    'FAIL README\.md does not name systemctl mask, which scripts/setup_service_debian\.sh:[0-9]+ runs through sudo'

fresh
printf '%s\n' 'sudo modprobe msr' >> "$w/repo/scripts/setup_service_debian.sh"
expect "another program" 1 \
    'FAIL README\.md does not name modprobe, which scripts/setup_service_debian\.sh:[0-9]+ runs through sudo'

fresh
grep -vF -- '- `rm -f` of ' README.md > "$w/repo/README.md"
expect "the README without its rm line" 1 \
    'FAIL README\.md does not name rm -f, which Makefile:[0-9]+ runs through sudo'

fresh
sed 's/^The service runs the miner as root only with `--service-as-root`\./The miner runs as root only with `--service-as-root`./' \
    README.md > "$w/repo/README.md"
expect "the miner line widened" 1 \
    'FAIL README\.md: What runs as root does not say the service runs the miner as root only with --service-as-root'

fresh
printf '%s\n' 'sudo -u "$ACCOUNT" cat /etc/hostname' 'echo "run: sudo modprobe msr"' >> "$w/repo/scripts/setup_service_debian.sh"
expect "a sudo -u and a printed hint" 0 "$pass"

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "PASS readme-root-fixtures"
