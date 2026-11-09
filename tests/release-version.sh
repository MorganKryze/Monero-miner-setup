#!/bin/bash
# The version both installers print is the latest release in CHANGELOG.md, whose heading, link and
# README anchors follow Keep a Changelog: a release whose scripts and notes disagree fails here
# before its tag is pushed.
set -u

failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

# The value of the VERSION="X.Y.Z" line, the only one a script may hold.
function script_version() {
    local lines
    lines=$(grep -E '^VERSION=' "$1")
    if [ "$(printf '%s\n' "$lines" | grep -c .)" -ne 1 ]; then
        fail "$1: expected one VERSION= line, got: $lines"
        return
    fi
    if ! [[ $lines =~ ^VERSION=\"([0-9]+\.[0-9]+\.[0-9]+)\"$ ]]; then
        fail "$1: not VERSION=\"X.Y.Z\": $lines"
        return
    fi
    printf '%s' "${BASH_REMATCH[1]}"
}

# GitHub's anchor for a heading: lower case, punctuation other than - and _ dropped, spaces to -.
function slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -e 's/[^a-z0-9 _-]//g' -e 's/ /-/g'
}

native=$(script_version scripts/install.sh)
docker=$(script_version scripts/docker_setup.sh)
[ -n "$native" ] && [ "$native" = "$docker" ] ||
    fail "scripts/install.sh says ${native:-nothing}, scripts/docker_setup.sh says ${docker:-nothing}"

if [ ! -f CHANGELOG.md ]; then
    fail "no CHANGELOG.md"
else
    [ "$(sed -n 1p CHANGELOG.md)" = "# Changelog" ] || fail "CHANGELOG.md: first line is not '# Changelog'"
    top=$(grep -E '^## \[' CHANGELOG.md | grep -v '^## \[Unreleased\]$' | sed -n 1p)
    if ! [[ $top =~ ^##\ \[([0-9]+\.[0-9]+\.[0-9]+)\]\ -\ [0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        fail "CHANGELOG.md: the latest release heading is not '## [X.Y.Z] - YYYY-MM-DD': ${top:-none}"
    else
        released=${BASH_REMATCH[1]}
        [ "$released" = "$native" ] || fail "CHANGELOG.md's latest release is $released, the scripts say ${native:-nothing}"
        grep -qxF "git clone --branch v$released --recurse-submodules https://github.com/MorganKryze/Monero-miner-setup.git" README.md ||
            fail "README.md: the pin to $released does not clone tag v$released"
        grep -qxF "./scripts/install.sh --docker --image ghcr.io/morgankryze/monero-miner-setup:$released -w YOUR_MONERO_WALLET --autostart" README.md ||
            fail "README.md: the pin to $released does not pass the image :$released"
        grep -qxF "[$released]: https://github.com/MorganKryze/Monero-miner-setup/releases/tag/v$released" CHANGELOG.md ||
            fail "CHANGELOG.md: no link line for [$released] to its v$released tag"
    fi
    anchors=$(grep -oE '\(README\.md#[^)]*\)' CHANGELOG.md | sed -e 's/^(README\.md#//' -e 's/)$//')
    headings=$(sed -n 's/^##* //p' README.md | while IFS= read -r h; do slug "$h"; echo; done)
    for a in $anchors; do
        printf '%s\n' "$headings" | grep -qxF -- "$a" || fail "CHANGELOG.md links README.md#$a, which no README heading gives"
    done
fi

# The security notes claim only what the scripts do. The root refusal of a directory others can
# change runs in the native installer on Linux alone (the gate below); the Docker installer uses
# only its own clone or one in its base directory, never a folder found above the current one.
gate='    if [ "$(id -u)" == "0" ] && [ "$(uname -s)" == "Linux" ]; then'
grep -qxF -- "$gate" scripts/install.sh || fail "scripts/install.sh: the root directory check is no longer gated on Linux alone"
for line in \
    '- The native installer reuses the `Monero-miner-setup` clone in its base directory only when it is a git clone in which every file and folder belongs to you or root (as root, also to the user who ran `sudo`) and none can be changed by another user; otherwise it stops with one error line before it clones, builds or sets up anything. It checks a fresh clone the same way.' \
    '- The native installer loads bash-toolbox from its own clone'"'"'s submodule, when only you can write to that clone, or from the commit it pins, with `curl -fsSL`; a failed or empty fetch stops the install. It never loads the toolbox from the current directory.' \
    '- As root on Linux, the native installer refuses a base directory, a clone or a directory above them that a user other than root or the one who ran sudo can change, and the service setup refuses to run, as another account, a binary anyone but root can change.' \
    '- The Docker installer uses only the clone it runs from or the `Monero-miner-setup` clone in its base directory, cloned there when missing, and only a git clone owned by you or root (as root, also by the user who ran `sudo`) that no other user can write to, nor to its `docker/` folder. It no longer adopts a folder above the current directory because it holds the project'"'"'s Docker files: it stops with an error line instead.'; do
    grep -qxF -- "$line" CHANGELOG.md 2>/dev/null || fail "CHANGELOG.md: no security line: $line"
done

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "PASS release-version ($native)"
