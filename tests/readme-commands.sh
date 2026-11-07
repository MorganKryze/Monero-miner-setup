#!/bin/bash
# The README's install commands: each fetches the installer with curl -fsSL into a variable, stops
# with a non-zero exit when the download fails, is cut or comes back empty, and otherwise hands the
# installer exactly the flags and variables it shows. Every block runs under env -i with a stub
# curl on a PATH that holds only the stubs and a link to bash: no rc file, alias or real curl takes
# part, so nothing is fetched and no installer runs.
set -u

README=README.md
URL="https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh"
FETCH="installer=\"\$(curl -fsSL $URL)\" && \\"
READ="   curl -fsSL $URL | less"
RUN_RE='^(sudo )?(([A-Z_]+='"'"'[^'"'"']*'"'"' )*)bash -c "\$\{installer:\?the download came back empty\}" -- \\$'
EMPTY_LINE="installer: the download came back empty"
# fish cannot parse the fetch line: the README says so once, above the commands.
POSIX_LINE="The install commands below need a POSIX shell such as bash or zsh. In fish, run \`bash\` first, then paste them."

failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

w=$(mktemp -d "${TMPDIR:-/tmp}/readme-commands.XXXXXX") && [ -d "$w" ] || { echo "FAIL readme-commands: mktemp"; exit 1; }
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
    [ "$found" = "$w/$d/curl" ] || { echo "FAIL readme-commands: the $d run would use ${found:-no curl}, not its stub"; exit 1; }
done

[ -f "$README" ] || { echo "FAIL readme-commands: no $README"; exit 1; }

[ "$(grep -cxF "$POSIX_LINE" "$README")" -eq 1 ] || fail "$README: the POSIX shell line is not there once"
first=$(grep -nxF "$FETCH" "$README" | sed -n 1p | cut -d: -f1)
posix=$(grep -nxF "$POSIX_LINE" "$README" | cut -d: -f1)
[ -n "$posix" ] && [ -n "$first" ] && [ "$posix" -lt "$first" ] || fail "$README: the POSIX shell line does not come before the first install command"

if grep -n 'bash <(' "$README"; then
    fail "the old bash <(curl ...) form is still in $README (lines above)"
fi
while IFS= read -r line; do
    case $line in
        *'curl -fsSL '*) ;;
        *) fail "a curl without -fsSL at $README: $line" ;;
    esac
done < <(grep -n 'curl ' "$README" | grep -v 'curl/bash')
# A line that runs curl on the installer is one of the two forms above; prose may name the URL.
while IFS= read -r line; do
    [ "$line" = "$FETCH" ] || [ "$line" = "$READ" ] || fail "a curl of the installer in a form the check does not know: $line"
done < <(grep -F "$URL" "$README" | grep -F 'curl')

# Each block: from its fetch line to the end of its code fence.
blocks=0
while IFS= read -r start; do
    blocks=$((blocks + 1))
    # The fetch line opens its code block: a line above it would not be part of the command.
    if [ "$(sed -n "$((start - 1))p" "$README")" != '```bash' ]; then
        fail "block at line $start: the fetch line does not open its code block"
    fi
    block=$(sed -n "$start,\$p" "$README" | sed '/^```/,$d')
    second=$(printf '%s\n' "$block" | sed -n 2p)
    if ! [[ $second =~ $RUN_RE ]]; then
        fail "block at line $start: second line is not the guarded run: $second"
        continue
    fi
    env_words=${BASH_REMATCH[2]}

    out=$(env -i PATH="$w/ok:$w/tools" HOME="$w" bash --norc --noprofile -c "$block" 2>&1)
    rc=$?
    args=$(printf '%s\n' "$out" | sed -n 's/^ARG://p')
    [ "$rc" -eq 0 ] || fail "block at line $start: exit $rc on a good download"
    [ "$(printf '%s\n' "$args" | sed -n 1p)" = "--" ] || fail "block at line $start: \$0 is not --"
    printf '%s\n' "$args" | grep -qx -- '-w' || fail "block at line $start: no -w"
    [ "$(printf '%s\n' "$args" | grep -A1 -x -- '-w' | sed -n 2p)" = "YOUR_MONERO_WALLET" ] ||
        fail "block at line $start: -w is not followed by YOUR_MONERO_WALLET"
    printf '%s\n' "$args" | grep -q '[\\[:space:]]' && fail "block at line $start: an argument holds a backslash or a space"
    printf '%s\n' "$args" | grep -qx '' && fail "block at line $start: an empty argument"
    for pair in $env_words; do
        name=${pair%%=*} value=${pair#*=}
        value=${value#\'} value=${value%\'}
        printf '%s\n' "$out" | grep -qxF "ENV:$name=$value" || fail "block at line $start: $name does not reach the installer"
    done

    out=$(env -i PATH="$w/cut:$w/tools" HOME="$w" bash --norc --noprofile -c "$block" 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "block at line $start: exit 0 on a cut download"
    printf '%s\n' "$out" | grep -qx 'RAN' && fail "block at line $start: a cut download ran"

    out=$(env -i PATH="$w/empty:$w/tools" HOME="$w" bash --norc --noprofile -c "$block" 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "block at line $start: exit 0 on an empty download"
    case $out in
        *"$EMPTY_LINE"*) ;;
        *) fail "block at line $start: no '$EMPTY_LINE' line on an empty download" ;;
    esac
done < <(grep -nxF "$FETCH" "$README" | cut -d: -f1)

[ "$blocks" -gt 0 ] || fail "no install command found in $README"

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "PASS readme-commands ($blocks install commands)"
