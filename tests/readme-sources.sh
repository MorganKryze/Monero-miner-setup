#!/bin/bash
# Nothing is fetched that the README does not name. The scripts fetch only from the sources listed
# below, by curl, wget or git clone (a submodule comes from .gitmodules, an image from the compose
# files, a base image and the frontend from the Dockerfile), and the README names each of them.
# Versions are left out (the toolbox commit, image tags), so a Dependabot bump stays green; a new
# source, in a script or in the README's absence, fails.
# Reads the repository root, or the directory given as $1 (tests/readme-sources-fixtures.sh
# points it at a copy with a change planted).
set -u

cd -- "${1:-.}" || { echo "FAIL readme-sources: no directory ${1:-.}"; exit 1; }

README=README.md
failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

# The value of NAME="value" at the start of a line of the script.
function constant() {
    local line
    line=$(grep -E "^$2=\"" "$1" | sed -n 1p)
    line=${line#*=\"}
    printf '%s' "${line%\"}"
}

[ -f "$README" ] || { echo "FAIL readme-sources: no $README"; exit 1; }

toolbox=$(constant scripts/install.sh TOOLBOX_URL)
toolbox=${toolbox//\$\{TOOLBOX_COMMIT\}/<commit>}
sources=(
    "$toolbox"
    "$(constant scripts/install.sh DOCKER_SCRIPT_URL)"
    "$(constant scripts/install.sh REPO_URL)"
    "$(constant scripts/docker_setup.sh REPO_URL)"
    "https://ifconfig.io"
)
while IFS= read -r url; do sources+=("$url"); done < <(sed -n 's/^[[:space:]]*url = //p' .gitmodules)
image=$(sed -n 's/^[[:space:]]*image: \${XMRIG_IMAGE:-\(.*\)}$/\1/p' docker/compose.yml)
sources+=("${image%:*}")
image=$(sed -n 's/^[[:space:]]*image: //p' docker/compose.vpn.yml)
sources+=("${image%:*}")
# A base image is named in backticks: a bare word like ubuntu would match any prose. A FROM that
# names an earlier stage fetches nothing.
stages=" "
while read -r from ref rest; do
    [ "$from" = FROM ] || continue
    case $ref in --*) read -r ref rest <<< "$rest" ;; esac
    case $stages in *" $ref "*) continue ;; esac
    case $rest in AS\ * | as\ *) stages+="${rest#* } " ;; esac
    ref=${ref%%@*}
    ref='`'"${ref%:*}"'`'
    case " ${sources[*]} " in *" $ref "*) ;; *) sources+=("$ref") ;; esac
done < docker/Dockerfile
# BuildKit pulls the image a `# syntax=` directive names to parse the Dockerfile, so that frontend
# is fetched too; it is named in backticks, without its version, as a base image is.
while IFS= read -r ref; do
    ref=${ref%%@*}
    sources+=('`'"${ref%:*}"'`')
done < <(sed -n 's/^#[[:space:]]*[sS][yY][nN][tT][aA][xX][[:space:]]*=[[:space:]]*\([^[:space:]]*\).*$/\1/p' docker/Dockerfile)

for s in "${sources[@]}"; do
    if [ -z "$s" ] || [ "$s" = "<commit>" ]; then
        fail "a source could not be read from the scripts"
        continue
    fi
    grep -qF -- "$s" "$README" || fail "$README does not name $s, which the project fetches"
done

# Every fetch line names one of the known sources; a printed hint, a comment or a check that curl
# exists is not a fetch.
while IFS= read -r hit; do
    line=${hit#*:*:}
    case $line in
        *'"$TOOLBOX_URL"'* | *'"$DOCKER_SCRIPT_URL"'* | *'"$REPO_URL"'* | *'https://ifconfig.io'*) ;;
        *'command -v curl'*) ;;
        *) fail "a fetch the README may not name: $hit" ;;
    esac
done < <(grep -nE 'curl |wget |git clone ' scripts/*.sh docker/*.sh Makefile |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|echo |@echo |warning |info |error |hint |txt )')

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "PASS readme-sources (${#sources[@]} sources)"
