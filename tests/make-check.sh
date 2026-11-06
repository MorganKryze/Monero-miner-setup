#!/bin/bash
# `make check` runs every script in tests/, all of them even after one fails, and exits non-zero
# when any of them failed. Runs this Makefile's check target in a throwaway copy whose tests/
# holds two stubs: one that fails, sorted first, and one that passes.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
mkdir "$w/tests"
cp Makefile "$w/Makefile"
printf '%s\n' 'echo "RAN a-fails"' 'exit 1' > "$w/tests/a-fails.sh"
printf '%s\n' 'echo "RAN b-passes"' > "$w/tests/b-passes.sh"
out=$(cd "$w" && TERM=dumb make -s check 2>&1); code=$?
[ "$code" -ne 0 ] || { echo "FAIL exit 0 with a failing check"; rc=1; }
printf '%s\n' "$out" | grep -qx 'RAN a-fails' || { echo "FAIL the failing check did not run"; rc=1; }
printf '%s\n' "$out" | grep -qx 'RAN b-passes' || { echo "FAIL a check after a failure did not run"; rc=1; }
rm "$w/tests/a-fails.sh"
out=$(cd "$w" && TERM=dumb make -s check 2>&1); code=$?
[ "$code" -eq 0 ] || { echo "FAIL exit $code with every check passing"; rc=1; }
printf '%s\n' "$out" | grep -qx 'RAN b-passes' || { echo "FAIL the passing check did not run"; rc=1; }
[ "$rc" -eq 0 ] && echo "PASS make-check"
exit "$rc"
