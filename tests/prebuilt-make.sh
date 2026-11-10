#!/bin/bash
# A clone that runs a release binary keeps it: make update refuses (one error line, exit
# non-zero, nothing run, the binary and its record kept), a clone without a record updates as
# before, clean-build removes the binary and its record but not config.json, and build replaces
# the record with a link to the compiled binary. The Makefile is a copy in a scratch clone, run
# under env -i with stub git and cmake; PATH holds only the stub and tool-link directories.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d "${TMPDIR:-/tmp}/prebuilt-make.XXXXXX") && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'chmod -R u+rwx -- "$w" 2>/dev/null; rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/bin" "$w/tools" "$w/home"
chmod 755 "$w" "$w/bin" "$w/tools" "$w/home"
for t in awk cat getconf ln make mkdir rm touch; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
cat > "$w/bin/git" <<'STUB'
#!/bin/bash
echo "$*" >> "$CLONE_DIR/git.log"
exit 0
STUB
cat > "$w/bin/cmake" <<'STUB'
#!/bin/bash
printf 'all:\n\ttouch xmrig\n' > Makefile
exit 0
STUB
chmod 755 "$w/bin/git" "$w/bin/cmake"

# fresh_clone: an empty clone folder holding the Makefile.
fresh_clone() {
  rm -rf -- "$w/clone"
  mkdir -p "$w/clone/dependencies/xmrig"
  cp "$root/Makefile" "$w/clone/Makefile"
  chmod 755 "$w/clone" "$w/clone/dependencies" "$w/clone/dependencies/xmrig"
  chmod 644 "$w/clone/Makefile"
}
run() {
  env -i HOME="$w/home" PATH="$w/bin:$w/tools" CLONE_DIR="$w/clone" make -C "$w/clone" "$@" 2>&1
  return $?
}

msg='This clone runs a release binary (xmrig.release) that make update would delete and compile again. To install another release run as root in this clone: git fetch --tags; git checkout --recurse-submodules vX.Y.Z; scripts/install.sh --prebuilt -w YOUR_MONERO_WALLET -y; make restart'

fresh_clone
touch "$w/clone/xmrig.release" "$w/clone/xmrig"
out=$(run update); st=$?
[ "$st" -ne 0 ] || fail "update-refused: exit 0"
[ "$(grep -cF -- "$msg" <<<"$out")" -eq 1 ] || fail "update-refused: error text missing or repeated: $out"
[ ! -e "$w/clone/git.log" ] || fail "update-refused: git ran"
[ -e "$w/clone/xmrig.release" ] && [ -e "$w/clone/xmrig" ] || fail "update-refused: a file was removed"

fresh_clone
out=$(run update); st=$?
[ "$(head -n1 "$w/clone/git.log" 2>/dev/null)" = "pull" ] || fail "update-allowed: first git call not pull (exit $st): $out"

fresh_clone
touch "$w/clone/xmrig" "$w/clone/xmrig.release" "$w/clone/config.json"
mkdir "$w/clone/build-xmrig"; chmod 755 "$w/clone/build-xmrig"
out=$(run clean-build); st=$?
[ "$st" -eq 0 ] || fail "clean-build: exit $st: $out"
for f in xmrig xmrig.release build-xmrig; do
  [ ! -e "$w/clone/$f" ] && [ ! -L "$w/clone/$f" ] || fail "clean-build: $f kept"
done
[ -e "$w/clone/config.json" ] || fail "clean-build: config.json removed"

fresh_clone
touch "$w/clone/xmrig.release"
out=$(run build); st=$?
[ "$st" -eq 0 ] || fail "build: exit $st: $out"
[ -L "$w/clone/xmrig" ] && [ "$(readlink "$w/clone/xmrig")" = "build-xmrig/xmrig" ] || fail "build: xmrig is not a link to build-xmrig/xmrig"
[ ! -e "$w/clone/xmrig.release" ] || fail "build: record kept"

exit "$rc"
