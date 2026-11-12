#!/bin/bash
# The README's "What runs as root" names every command the Makefile and the scripts run through
# sudo: the subcommand of systemctl and apt-get, the program otherwise, and the path that rm and
# install write, each in backticks. A sudo -u runs as that account, not as root, and a printed hint
# runs nothing. A new root step without its README line fails here.
# Reads the repository root, or the directory given as $1 (tests/readme-root-fixtures.sh points it
# at a copy with a change planted).
set -u

cd -- "${1:-.}" || { echo "FAIL readme-root: no directory ${1:-.}"; exit 1; }

README=README.md
failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

[ -f "$README" ] || { echo "FAIL readme-root: no $README"; exit 1; }
section=$(sed -n '/^### What runs as root$/,/^##/p' "$README" | sed '1d;$d')
[ -n "$section" ] || { echo "FAIL readme-root: $README has no What runs as root section"; exit 1; }

# True when the section holds $1 as a code span, or as the start of one.
function named() {
    case $section in *"\`$1\`"* | *"\`$1 "*) return 0 ;; esac
    return 1
}

# The value of NAME := value (Makefile) or NAME="value" (script) at the start of a line of $1.
function constant() {
    local line
    line=$(grep -E "^$2[[:space:]]*(:=|\?=|=)" "$1" | sed -n 1p)
    line=${line#*=}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line#\"}
    printf '%s' "${line%\"}"
}

# $2 with the variables it names replaced by their values in $1, or nothing when one is unknown.
function resolve() {
    local file="$1" word="$2" name value pattern='\$[({]?([A-Za-z_][A-Za-z0-9_]*)'
    word=${word//\"/}
    while [[ $word =~ $pattern ]]; do
        name=${BASH_REMATCH[1]}
        value=$(constant "$file" "$name")
        [ -n "$value" ] || return 0
        word=${word//\$($name)/$value}
        word=${word//\$\{$name\}/$value}
        word=${word//\$$name/$value}
    done
    printf '%s' "$word"
}

case $section in
    *'The service runs the miner as root only with `--service-as-root`.'*) ;;
    *) fail "$README: What runs as root does not say the service runs the miner as root only with --service-as-root" ;;
esac

# Checks the command that follows one sudo: $1 is the file, $2 its file:line, $3 the command.
function check_command() {
    local file="$1" at="$2" cmd="$3" target words
    case $cmd in -u\ *) return 0 ;; esac
    cmd=${cmd%%;*} cmd=${cmd%%||*} cmd=${cmd%%&&*} cmd=${cmd%% 2>*} cmd=${cmd%\\}
    read -ra words <<< "$cmd"
    count=$((count + 1))
    case ${words[0]} in
        systemctl) named "systemctl ${words[1]}" || named "${words[1]}" || fail "$README does not name systemctl ${words[1]}, which $at runs through sudo" ;;
        apt-get) named "apt-get ${words[1]}" || fail "$README does not name apt-get ${words[1]}, which $at runs through sudo" ;;
        rm | install)
            named "${words[0]} ${words[1]}" || named "${words[0]}" ||
                fail "$README does not name ${words[0]} ${words[1]}, which $at runs through sudo"
            target=$(resolve "$file" "${words[${#words[@]} - 1]}")
            if [ -z "$target" ]; then
                fail "the path $at writes through sudo could not be read"
            else
                named "$target" || fail "$README does not name $target, which $at writes through sudo"
            fi
            ;;
        *) named "${words[0]}" || fail "$README does not name ${words[0]}, which $at runs through sudo" ;;
    esac
}

count=0
while IFS= read -r hit; do
    file=${hit%%:*}
    cmd=${hit#*:}
    at=$file:${cmd%%:*}
    cmd=${cmd#*:}
    # Every sudo on the line counts: "sudo a || sudo b" runs both as root.
    while [[ $cmd == *"sudo "* ]]; do
        cmd=${cmd#*sudo }
        check_command "$file" "$at" "$cmd"
    done
done < <(grep -nE '(^|[[:space:];&|(!@])sudo ' Makefile scripts/*.sh |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|echo |@echo |warning |info |error |hint |RECOMMENDATIONS)')

[ "$count" -gt 0 ] || fail "no sudo command found in the Makefile or the scripts"

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "PASS readme-root ($count sudo commands)"
