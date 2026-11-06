#!/bin/bash
# The native install (build_project in scripts/install.sh) and `make update` check out the
# submodule commits this repository pins, even when upstream has moved past them; over a local
# change in a submodule they stop with an error line and a non-zero exit, keep the change and
# never reach the build. Runs both paths against a throwaway superproject whose submodules are
# local repositories: no network, the build replaced by markers.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
# A hook or a linked worktree exports GIT_DIR, GIT_INDEX_FILE and the like: left set, the fixture
# commands below would act on the developer's own repository instead of the ones under $w.
# shellcheck disable=SC2046 # the names are git's, one word each
unset $(git rev-parse --local-env-vars)
# Only these settings: the developer's own git config must not change the answer.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=4
export GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=check
export GIT_CONFIG_KEY_2=user.email GIT_CONFIG_VALUE_2=check@localhost
export GIT_CONFIG_KEY_3=init.defaultBranch GIT_CONFIG_VALUE_3=master

# Upstreams: xmrig gets a commit past the pin, after the superproject records the pin.
for u in xmrig bash-toolbox; do
  git init -q "$w/$u"
  echo pinned > "$w/$u/README.md"
  git -C "$w/$u" add README.md
  git -C "$w/$u" commit -q -m pin
done
pin=$(git -C "$w/xmrig" rev-parse HEAD)
btpin=$(git -C "$w/bash-toolbox" rev-parse HEAD)
git init -q "$w/super"
mkdir -p "$w/super/scripts"
cp "$root/Makefile" "$w/super/Makefile"
cp "$root/scripts/install.sh" "$w/super/scripts/install.sh"
git -C "$w/super" add Makefile scripts/install.sh
git -C "$w/super" submodule add -q "$w/xmrig" dependencies/xmrig
git -C "$w/super" submodule add -q "$w/bash-toolbox" dependencies/bash-toolbox
git -C "$w/super" commit -q -m super
echo upstream > "$w/xmrig/README.md"
git -C "$w/xmrig" commit -q -am drift

# The Makefile path: its definitions and the update recipe, each sub-make replaced by a marker.
mk="$w/update.mk"
{ sed -n '1,/^help:/p' "$root/Makefile" | sed '$d'
  awk '/^update:/ {on = 1; print; next} on && /^[^[:space:]#]/ {exit} on' "$root/Makefile" \
    | sed 's/^\t@\$(MAKE) \(.*\)$/\t@echo "BUILD REACHED: \1"/'; } > "$mk"
grep -q '\$(MAKE)' "$mk" && { echo "FAIL harness: a sub-make is left in the update recipe"; exit 1; }
grep -q '^update:' "$mk" || { echo "FAIL harness: no update target in the Makefile"; exit 1; }

host() { # name: a clone of the superproject whose xmrig was moved to upstream's tip
  git clone -q "$w/super" "$w/$1"
  git -C "$w/$1" submodule update -q --init dependencies/xmrig
  git -C "$w/$1/dependencies/xmrig" checkout -q origin/master
}
run_install() {
  ( cd "$1" || exit 99
    info() { echo "[INFO] $*"; }
    success() { echo "[SUCCESS] $*"; }
    warning() { echo "[WARNING] $*"; }
    error() { echo "[ERROR] $*"; }
    make() { echo "BUILD REACHED: make $*"; }
    # shellcheck disable=SC2034 # read by build_project, taken from install.sh below
    BASE_DIR=${1%/*} REPO_NAME=${1##*/} OS_TYPE=macos OS_NAME=Darwin
    eval "$(sed -n '/^function build_project() {$/,/^}$/p' "$root/scripts/install.sh")"
    build_project )
}
run_make() { ( cd "$1" && TERM=dumb make -s -f "$mk" update ); }

for p in install make; do
  # Upstream moved past the pin: the pin is checked out, bash-toolbox initialised, the build reached.
  host "$p-ok"
  out=$("run_$p" "$w/$p-ok" 2>&1); code=$?
  [ "$code" -eq 0 ] || { echo "FAIL $p: exit $code with upstream past the pin"; rc=1; }
  [ "$(git -C "$w/$p-ok/dependencies/xmrig" rev-parse HEAD)" = "$pin" ] || { echo "FAIL $p: xmrig not on the pinned commit"; rc=1; }
  [ "$(git -C "$w/$p-ok/dependencies/bash-toolbox" rev-parse HEAD 2>/dev/null)" = "$btpin" ] || { echo "FAIL $p: bash-toolbox not initialised at its pin"; rc=1; }
  printf '%s\n' "$out" | grep -q '^BUILD REACHED: ' || { echo "FAIL $p: the build was not reached"; rc=1; }
  # A local change the checkout would overwrite: stop, say so, keep it, build nothing.
  host "$p-local"
  echo local > "$w/$p-local/dependencies/xmrig/README.md"
  out=$("run_$p" "$w/$p-local" 2>&1); code=$?
  [ "$code" -ne 0 ] || { echo "FAIL $p: exit 0 over a local change"; rc=1; }
  case $p in
    install) want='[ERROR] Failed to check out the pinned submodules.' ;;
    make) want='[  ERROR  ] Failed to check out the pinned submodules' ;;
  esac
  printf '%s\n' "$out" | grep -qxF -- "$want" || { echo "FAIL $p: no line '$want'"; rc=1; }
  printf '%s\n' "$out" | grep -q '^BUILD REACHED: ' && { echo "FAIL $p: the build was reached after a failed checkout"; rc=1; }
  [ "$(cat "$w/$p-local/dependencies/xmrig/README.md")" = local ] || { echo "FAIL $p: the local change was lost"; rc=1; }
done
[ "$rc" -eq 0 ] && echo "PASS submodule-pin"
exit "$rc"
