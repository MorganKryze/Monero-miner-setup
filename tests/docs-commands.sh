#!/bin/bash
# The install commands of README.md and docs/*.md: each fetches the installer with curl -fsSL into a variable, stops
# with a non-zero exit when the download fails, is cut or comes back empty, and otherwise hands the
# installer exactly the flags and variables it shows. Every block runs under env -i with a stub
# curl on a PATH that holds only the stubs and a link to bash: no rc file, alias or real curl takes
# part, so nothing is fetched and no installer runs.
set -u

PAGES=(README.md docs/*.md)
URL="https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh"
FETCH="installer=\"\$(curl -fsSL $URL)\" && \\"
READ="   curl -fsSL $URL | less"
RUN_RE='^(sudo )?(([A-Z_]+='"'"'[^'"'"']*'"'"' )*)bash -c "\$\{installer:\?the download came back empty\}" -- \\$'
EMPTY_LINE="installer: the download came back empty"
# fish cannot parse the fetch line: each page with an install command says so once, above the first.
POSIX_LINE="The install commands below need a POSIX shell such as bash or zsh. In fish, run \`bash\` first, then paste them."

failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

w=$(mktemp -d "${TMPDIR:-/tmp}/docs-commands.XXXXXX") && [ -d "$w" ] || { echo "FAIL docs-commands: mktemp"; exit 1; }
w=$(cd "$w" && pwd -P) || exit 1
trap 'rm -rf -- "$w"' EXIT

# The stub installer prints the name bash gives it, each argument, and the VPN variables it sees.
mkdir -p "$w/ok" "$w/cut" "$w/empty" "$w/tools"
cat >"$w/ok/curl" <<'EOF'
#!/bin/sh
printf '%s\n' 'printf "ARG:%s\n" "$0" "$@"; printf "ENV:%s\n" "OPENVPN_USER=${OPENVPN_USER-}" "OPENVPN_PASSWORD=${OPENVPN_PASSWORD-}"'
EOF
# A transfer cut half way: curl -f prints what it got, then exits 18.
cat >"$w/cut/curl" <<'EOF'
#!/bin/sh
printf '%s\n' 'echo RAN'
echo "curl: (18) transfer closed with outstanding read data remaining" >&2
exit 18
EOF
cat >"$w/empty/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
for d in ok cut empty; do
    printf '%s\n' '#!/bin/sh' 'exec "$@"' >"$w/$d/sudo"
    chmod +x "$w/$d/curl" "$w/$d/sudo"
done
ln -s "$(command -v bash)" "$w/tools/bash"
# Each run must find the stub curl and no other: a real one would fetch and run the installer.
for d in ok cut empty; do
    found=$(env -i PATH="$w/$d:$w/tools" "$w/tools/bash" --norc --noprofile -c 'command -v curl')
    [ "$found" = "$w/$d/curl" ] || { echo "FAIL docs-commands: the $d run would use ${found:-no curl}, not its stub"; exit 1; }
done

blocks=0
files=0
for page in "${PAGES[@]}"; do
    [ -f "$page" ] || { fail "no $page"; continue; }
    first=$(grep -nxF "$FETCH" "$page" | sed -n 1p | cut -d: -f1)
    if [ -n "$first" ]; then
        files=$((files + 1))
        [ "$(grep -cxF "$POSIX_LINE" "$page")" -eq 1 ] || fail "$page: the POSIX shell line is not there once"
        posix=$(grep -nxF "$POSIX_LINE" "$page" | sed -n 1p | cut -d: -f1)
        [ -n "$posix" ] && [ "$posix" -lt "$first" ] || fail "$page: the POSIX shell line does not come before the first install command"
    fi

    if grep -n 'bash <(' "$page"; then
        fail "the old bash <(curl ...) form is still in $page (lines above)"
    fi
    while IFS= read -r line; do
        case $line in
            *'curl -fsSL '*) ;;
            *) fail "a curl without -fsSL at $page: $line" ;;
        esac
    done < <(grep -n 'curl ' "$page" | grep -v 'curl/bash')
    # A line that runs curl on the installer is one of the two forms above; prose may name the URL.
    while IFS= read -r line; do
        [ "$line" = "$FETCH" ] || [ "$line" = "$READ" ] || fail "a curl of the installer in a form the check does not know: $line"
    done < <(grep -F "$URL" "$page" | grep -F 'curl')

    # Each block: from its fetch line to the end of its code fence.
    while IFS= read -r start; do
        blocks=$((blocks + 1))
        # The fetch line opens its code block: a line above it would not be part of the command.
        if [ "$(sed -n "$((start - 1))p" "$page")" != '```bash' ]; then
            fail "$page: block at line $start: the fetch line does not open its code block"
        fi
        block=$(sed -n "$start,\$p" "$page" | sed '/^```/,$d')
        second=$(printf '%s\n' "$block" | sed -n 2p)
        if ! [[ $second =~ $RUN_RE ]]; then
            fail "$page: block at line $start: second line is not the guarded run: $second"
            continue
        fi
        env_words=${BASH_REMATCH[2]}

        out=$(env -i PATH="$w/ok:$w/tools" HOME="$w" bash --norc --noprofile -c "$block" 2>&1)
        rc=$?
        args=$(printf '%s\n' "$out" | sed -n 's/^ARG://p')
        [ "$rc" -eq 0 ] || fail "$page: block at line $start: exit $rc on a good download"
        [ "$(printf '%s\n' "$args" | sed -n 1p)" = "--" ] || fail "$page: block at line $start: \$0 is not --"
        grep -qx -- '-w' <<<"$args" || fail "$page: block at line $start: no -w"
        [ "$(printf '%s\n' "$args" | grep -A1 -x -- '-w' | sed -n 2p)" = "YOUR_MONERO_WALLET" ] ||
            fail "$page: block at line $start: -w is not followed by YOUR_MONERO_WALLET"
        grep -q '[\\[:space:]]' <<<"$args" && fail "$page: block at line $start: an argument holds a backslash or a space"
        grep -qx '' <<<"$args" && fail "$page: block at line $start: an empty argument"
        for pair in $env_words; do
            name=${pair%%=*} value=${pair#*=}
            value=${value#\'} value=${value%\'}
            grep -qxF "ENV:$name=$value" <<<"$out" || fail "$page: block at line $start: $name does not reach the installer"
        done

        out=$(env -i PATH="$w/cut:$w/tools" HOME="$w" bash --norc --noprofile -c "$block" 2>&1)
        rc=$?
        [ "$rc" -ne 0 ] || fail "$page: block at line $start: exit 0 on a cut download"
        grep -qx 'RAN' <<<"$out" && fail "$page: block at line $start: a cut download ran"

        out=$(env -i PATH="$w/empty:$w/tools" HOME="$w" bash --norc --noprofile -c "$block" 2>&1)
        rc=$?
        [ "$rc" -ne 0 ] || fail "$page: block at line $start: exit 0 on an empty download"
        case $out in
            *"$EMPTY_LINE"*) ;;
            *) fail "$page: block at line $start: no '$EMPTY_LINE' line on an empty download" ;;
        esac
    done < <(grep -nxF "$FETCH" "$page" | cut -d: -f1)
done

[ "$blocks" -gt 0 ] || fail "no install command found in ${PAGES[*]}"

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "PASS docs-commands ($blocks install commands in $files files)"
