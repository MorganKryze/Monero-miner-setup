#!/bin/bash
# The defaults the README lists are the ones the installers use: each flag line of the README's
# "Common flags" lists holds, in backticks, the value of the constant behind it (or "none" for an
# empty one), and the minimal docker run uses the Docker defaults and the compose file's
# no-new-privileges. A default changed in a script without its README line fails here.
set -u

README=README.md
failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

# The value of NAME=value or NAME="value" at the start of a line of the script.
function constant() {
    local line
    line=$(grep -E "^$2=" "$1" | sed -n 1p)
    [ -n "$line" ] || { fail "$1: no $2"; return; }
    line=${line#*=}
    line=${line%%[[:space:]]#*}
    line=${line#\"} line=${line%\"}
    printf '%s' "$line"
}

# The README line that starts with $1 must exist once and hold each value after it in backticks,
# or the word none for an empty value.
function line_holds() {
    local prefix="$1" line value
    shift
    if [ "$(grep -cF -- "$prefix" "$README")" -ne 1 ]; then
        fail "$README: expected one line starting with $prefix"
        return
    fi
    line=$(grep -F -- "$prefix" "$README")
    case $line in
        "$prefix"*) ;;
        *) fail "$README: the line holding $prefix does not start with it"; return ;;
    esac
    for value in "$@"; do
        if [ -z "$value" ]; then
            case $line in
                *none*) ;;
                *) fail "$README: '$prefix' gives a default where the script has none" ;;
            esac
        else
            case $line in
                *"\`$value\`"*) ;;
                *) fail "$README: '$prefix' does not give \`$value\`" ;;
            esac
        fi
    done
}

[ -f "$README" ] || { echo "FAIL readme-defaults: no $README"; exit 1; }

# Native install (scripts/install.sh).
N=scripts/install.sh
line_holds '- `-t, --threads PERCENT`' "$(constant $N DEFAULT_MAX_THREADS)"
line_holds '- `-p, --pool URL`' "$(constant $N DEFAULT_POOL_URL)"
line_holds '- `--name STRING`' "adjective_noun_NNN"
line_holds '- `-d, --dir DIR`' "\$HOME" "$(constant $N ROOT_BASE_DIR)"
line_holds '- `--service-as-root`'
grep -qF 'echo "  --name STRING         Display name for the mining worker (default: random adjective_noun_NNN)"' $N ||
    fail "$N: --help does not give the random worker name as the --name default"

# Docker install (scripts/docker_setup.sh).
D=scripts/docker_setup.sh
line_holds '- `--worker-name NAME`' "$(constant $D DEFAULT_WORKER_NAME)"
line_holds '- `--cpus N` / `--memory LIMIT`' "$(constant $D DEFAULT_CPU_COUNT)" "$(constant $D DEFAULT_MEMORY_LIMIT)"
line_holds '- `--threads PCT` / `--force-threads N`' "$(constant $D DEFAULT_MAX_THREADS)" "$(constant $D DEFAULT_FORCE_THREAD_COUNT)"
line_holds '- `--image REF`' "$(constant $D DEFAULT_XMRIG_IMAGE)"
line_holds '- `--overwrite-env`'

grep -qxF "  --cpus $(constant $D DEFAULT_CPU_COUNT) --memory $(constant $D DEFAULT_MEMORY_LIMIT) \\" "$README" ||
    fail "$README: the minimal docker run does not use the Docker defaults"
grep -qxF '  --security-opt no-new-privileges:true \' "$README" ||
    fail "$README: the minimal docker run does not set no-new-privileges"
grep -qxF '      - no-new-privileges:true' docker/compose.yml ||
    fail "docker/compose.yml: no no-new-privileges, which the README claims"
if grep -n '/app/logs' "$README"; then
    fail "$README: names /app/logs, where the image writes no log"
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "PASS readme-defaults"
