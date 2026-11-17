#!/bin/bash
# docs/boards.md's "Board profiles" table is the data file's: each profile of scripts/board_profiles.conf
# has one row whose cells hold, whole, its compatible strings, max and eco CPU lists and eco caps
# (each in backticks), and its status: untested while the profile names no measured model, the
# measured models otherwise. `install.sh --help` names --mode and `make help` names bench-layouts.
# A value changed in the data file without its row on the page fails here. Fixture-free: reads the
# repository's files. Run from the repository root.
set -u

PAGE=docs/boards.md
CONF=scripts/board_profiles.conf
failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

[ -f "$PAGE" ] && [ -f "$CONF" ] || { echo "FAIL docs-board-profiles: no $PAGE or $CONF"; exit 1; }

# The value of <profile>.<key> in the data file, as written.
function value() {
    local line
    line=$(grep -F -- "$1.$2=" "$CONF" | sed -n 1p)
    printf '%s' "${line#*=}"
}

# Backtick each word of $1, joined by ", ".
function ticked() {
    local out="" word
    for word in $1; do
        out+="${out:+, }\`$word\`"
    done
    printf '%s' "$out"
}

# cell <row> <n>: the n-th cell of a table row, without its surrounding spaces.
function cell() {
    local c
    c=$(printf '%s' "$1" | awk -F'|' -v n="$(($2 + 1))" '{ print $n }')
    c=${c#"${c%%[![:space:]]*}"}
    printf '%s' "${c%"${c##*[![:space:]]}"}"
}

profiles=$(sed -n 's/^\([a-z0-9]*\)\.compatible=.*/\1/p' "$CONF")
[ -n "$profiles" ] || fail "$CONF: no profile"

for p in $profiles; do
    if [ "$(grep -cF -- "| \`$p\` |" "$PAGE")" -ne 1 ]; then
        fail "$PAGE: expected one board profile row for $p"
        continue
    fi
    row=$(grep -F -- "| \`$p\` |" "$PAGE")
    want_cell() { [ "$(cell "$row" "$1")" = "$2" ] || fail "$PAGE: row $p, $3: expected '$2', found '$(cell "$row" "$1")'"; }
    want_cell 2 "$(ticked "$(value "$p" compatible)")" "compatible"
    want_cell 3 "$(ticked "$(value "$p" max)")" "max CPUs"
    want_cell 4 "$(ticked "$(value "$p" eco)")" "eco CPUs"
    want_cell 5 "$(ticked "$(value "$p" eco-cap)")" "eco cap"
    measured=$(value "$p" measured)
    status=$(cell "$row" 6)
    if [ -z "$measured" ]; then
        [ "$status" = "untested" ] || fail "$PAGE: row $p, status: expected 'untested', found '$status'"
    else
        case $status in *untested*) fail "$PAGE: row $p names measured models but says untested" ;; esac
        IFS=';' read -ra models <<<"$measured"
        for model in "${models[@]}"; do
            model=${model#"${model%%[![:space:]]*}"}
            model=${model%"${model##*[![:space:]]}"}
            case $status in
                *"$model"*) ;;
                *) fail "$PAGE: row $p, status does not name the measured model '$model'" ;;
            esac
        done
    fi
done

# Every table row names a profile of the data file.
rows=$(sed -n '/^### Board profiles$/,/^##* /p' "$PAGE" | sed '1d' | grep -c '^| `')
[ "$rows" -eq "$(printf '%s\n' "$profiles" | grep -c .)" ] ||
    fail "$PAGE: $rows profile rows for $(printf '%s\n' "$profiles" | grep -c .) profiles in $CONF"

# The entry points the section sends the reader to.
# The help text is read from usage() itself: running install.sh would load bash-toolbox, over the
# network when the submodule is not checked out.
if ! sed -n '/^function usage() {$/,/^}$/p' scripts/install.sh | grep -qF -- '--mode max|eco'; then
    fail "scripts/install.sh --help does not name --mode"
fi
# Captured first: a producer piped into grep -q can die of SIGPIPE when grep stops reading.
help=$(make -s help 2>&1)
grep -qF 'bench-layouts' <<<"$help" || fail "make help does not name bench-layouts"
grep -qF 'make bench-layouts' "$PAGE" || fail "$PAGE: does not name make bench-layouts"
grep -qF -- '--mode max|eco' "$PAGE" || fail "$PAGE: does not name --mode max|eco"

[ "$failed" -eq 0 ] || exit 1
echo "PASS docs-board-profiles"
