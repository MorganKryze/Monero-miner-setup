#!/bin/bash
# The defaults the docs list are the ones the installers use. Reads README.md and docs/*.md as one
# text: each flag line of the "Common flags" lists holds, once across them, in backticks, the value of the constant behind it (or "none" for an
# empty one), and the minimal docker run uses the Docker defaults and the compose file's
# no-new-privileges. A default changed in a script without its docs line fails here.
set -u

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

# The docs line that starts with $1 must exist once and hold each value after it in backticks,
# or the word none for an empty value.
function line_holds() {
    local prefix="$1" line value
    shift
    if [ "$(grep -cF -- "$prefix" <<<"$all")" -ne 1 ]; then
        fail "the docs: expected one line starting with $prefix"
        return
    fi
    line=$(grep -F -- "$prefix" <<<"$all")
    case $line in
        "$prefix"*) ;;
        *) fail "the docs: the line holding $prefix does not start with it"; return ;;
    esac
    for value in "$@"; do
        if [ -z "$value" ]; then
            case $line in
                *none*) ;;
                *) fail "the docs: '$prefix' gives a default where the script has none" ;;
            esac
        else
            case $line in
                *"\`$value\`"*) ;;
                *) fail "the docs: '$prefix' does not give \`$value\`" ;;
            esac
        fi
    done
}

[ -f README.md ] || { echo "FAIL docs-defaults: no README.md"; exit 1; }
all=$(cat README.md docs/*.md) || { echo "FAIL docs-defaults: cannot read the docs"; exit 1; }

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
line_holds '- `--pool URL`' "$(constant $D DEFAULT_POOL_URL)"
line_holds '- `--worker-name NAME`' "$(constant $D DEFAULT_WORKER_NAME)"
line_holds '- `--cpus N` / `--memory LIMIT`' "$(constant $D DEFAULT_CPU_COUNT)" "$(constant $D DEFAULT_MEMORY_LIMIT)"
line_holds '- `--threads PCT` / `--force-threads N`' "$(constant $D DEFAULT_MAX_THREADS)" "$(constant $D DEFAULT_FORCE_THREAD_COUNT)"
line_holds '- `--image REF`' "$(constant $D DEFAULT_XMRIG_IMAGE)"
line_holds '- `--overwrite-env`'

grep -qxF "  --cpus $(constant $D DEFAULT_CPU_COUNT) --memory $(constant $D DEFAULT_MEMORY_LIMIT) \\" <<<"$all" ||
    fail "the docs: the minimal docker run does not use the Docker defaults"
grep -qxF '  --security-opt no-new-privileges:true \' <<<"$all" ||
    fail "the docs: the minimal docker run does not set no-new-privileges"
grep -qxF '      - no-new-privileges:true' docker/compose.yml ||
    fail "docker/compose.yml: no no-new-privileges, which the docs claim"
# The one-off Docker benchmark runs the same 1-minute bench as make benchmark.
grep -qxF 'docker compose run --rm --entrypoint /app/xmrig xmrig --bench=1M' <<<"$all" ||
    fail "the docs: no one-off Docker benchmark line running --bench=1M"
grep -qxF '	@./xmrig --bench=1M' Makefile ||
    fail "Makefile: make benchmark no longer runs --bench=1M, which the Docker benchmark line matches"
if grep -n '/app/logs' <<<"$all"; then
    fail "the docs: names /app/logs, where the image writes no log"
fi

# TLS to the pool. The docs' port range is the one the code computes: the native installer adds
# 10000 to its clear-text port (10001 to 18192), the container adds 20000 to the power of two.
case $(grep -F -- '- `-p, --pool URL`' <<<"$all") in
    *"from 20001 to 28192"*) ;;
    *) fail "the docs: the native --pool line does not give the TLS ports 20001 to 28192" ;;
esac
grep -qF 'POOL_WRITTEN="stratum+ssl://$hostport:$(($2 + 10000))"' $N ||
    fail "$N: the TLS port is no longer the clear-text port + 10000"
grep -qF 'if [ "$PORT" -lt "10001" -o "$PORT" -gt "18192" ]; then' $N ||
    fail "$N: the clear-text port range is no longer 10001 to 18192"
grep -qF 'FULL_POOL_URL="stratum+ssl://${hostport}:$((20000 + PORT))"' docker/entrypoint.sh ||
    fail "docker/entrypoint.sh: the TLS port is no longer 20000 + PORT"
# Each TLS setting the docs name is one its script takes.
for pair in "--tls-fingerprint $N" "--tls-fingerprint $D" "TLS_FINGERPRINT docker/entrypoint.sh" \
    "tls_fingerprint scripts/first_boot.sh"; do
    read -r name script <<<"$pair"
    grep -qF -- "\`$name" <<<"$all" || fail "the docs: do not name $name"
    grep -qF -- "$name" "$script" || fail "$script: does not take $name, which the docs name"
done
# XMRig's own line when the pool's certificate is not the pinned one (src/base/net/stratum/Tls.cpp).
ENTRY='**Mining stopped and the log says `Failed to verify server certificate fingerprint`.** '
[ "$(grep -cF -- "$ENTRY" <<<"$all")" -eq 1 ] && case $(grep -F -- "$ENTRY" <<<"$all") in "$ENTRY"*) ;; *) false ;; esac ||
    fail "the docs: no troubleshooting entry starting with XMRig's 'Failed to verify server certificate fingerprint'"
# XMRig writes that line to stdout (src/base/io/log/backends/ConsoleLog.cpp): on macOS it lands in
# the file launchd sends stdout to, which the entry must name.
PLIST=templates/com.moneroocean.xmrig.plist.template
out_log=$(grep -A1 -F '<key>StandardOutPath</key>' "$PLIST" | sed -n 's|.*%%LOG_PATH%%/\([^<]*\)</string>.*|\1|p')
[ -n "$out_log" ] || fail "$PLIST: no StandardOutPath under %%LOG_PATH%%"
case $(grep -F -- "$ENTRY" <<<"$all") in
    *"(macOS: \`logs/$out_log\` in the clone)"*) ;;
    *) fail "the docs: the certificate entry does not send macOS users to logs/$out_log, where launchd writes XMRig's output" ;;
esac
# A VPN install runs the stack from both compose files (scripts/docker_setup.sh): a remedy that
# recreates the miner from compose.yml alone takes it out of the tunnel, so each one gives both forms.
for cmd in "up -d" pull; do
    while IFS= read -r line; do
        case $line in
            *"\`docker compose -f compose.yml -f compose.vpn.yml $cmd\`"*) ;;
            *) fail "the docs: gives 'docker compose $cmd' without the VPN form: ${line:0:80}" ;;
        esac
    done < <(grep -F -- "\`docker compose $cmd\`" <<<"$all")
done
grep -qF 'compose_args+=("-f" "$REPO_DIR/docker/compose.vpn.yml")' "$D" ||
    fail "$D: no longer adds compose.vpn.yml to the stack, which the docs' VPN forms name"
# The TLS move has its own upgrade section on docs/upgrading.md, with the path make update leaves
# silent; the older section keeps its heading, which the CHANGELOG and the troubleshooting entries
# link.
UPGRADE='## Upgrading from 0.1.x or 0.2.0-rc.x'
section=$(awk -v h="$UPGRADE" '$0 == h { on = 1; next } on && /^##? / { exit } on' docs/upgrading.md)
for want in "mines on MoneroOcean without TLS. To switch to TLS" "\`make update\` doesn't run the installer" \
    "\`POOL_URL\` that's a MoneroOcean host with no port" "On x86, nothing else changes"; do
    case $section in
        *"$want"*) ;;
        *) fail "docs/upgrading.md: '$UPGRADE' does not hold '$want'" ;;
    esac
done
grep -qxF '## Upgrading an install made before 0.1.0' docs/upgrading.md ||
    fail "docs/upgrading.md: no 'Upgrading an install made before 0.1.0' heading, which CHANGELOG.md links"
unreleased=$(awk '/^## \[Unreleased\]/ { on = 1; next } on && /^## / { exit } on' CHANGELOG.md)
case $unreleased in
    *"blocks ports 20001 to 28192"*"stratum+tcp://gulf.moneroocean.stream"*) ;;
    *) fail "CHANGELOG.md: [Unreleased] does not say a network blocking 20001 to 28192 stops mining, and the stratum+tcp:// way out" ;;
esac
# A MoneroOcean URL with no port gets the computed one on both paths, and the container gives other
# portless hosts :3333; the docs that say "used as given" say so, and take openssl's colon form.
case $(grep -F -- '- `-p, --pool URL`' <<<"$all") in
    *"a MoneroOcean URL with no port gets the computed one"*) ;;
    *) fail "the docs: the native --pool line does not say a MoneroOcean URL with no port gets the computed port" ;;
esac
grep -qF 'FULL_POOL_URL="${POOL_URL}:3333"' docker/entrypoint.sh ||
    fail "docker/entrypoint.sh: no longer gives a portless pool :3333, which docker/.env.example says"
pool_doc=$(sed -n '/^# Optional: Mining pool URL/,/^POOL_URL=/p' docker/.env.example)
case $pool_doc in
    *":3333"*) ;;
    *) fail "docker/.env.example: the POOL_URL comment does not give the :3333 a portless host gets" ;;
esac
fp_doc=$(sed -n '/^# Optional: pin your TLS pool/,/^TLS_FINGERPRINT=/p' docker/.env.example)
case $fp_doc in
    *"colon"*) ;;
    *) fail "docker/.env.example: the TLS_FINGERPRINT comment does not take the colon form" ;;
esac
# openssl prints the fingerprint after "sha256 Fingerprint=", which --tls-fingerprint refuses: the
# entry's recipe says what to keep.
case $(grep -F -- '- Pin a fingerprint you checked yourself' <<<"$all") in
    *"openssl x509 -noout -fingerprint -sha256"*"after the \`=\`"*) ;;
    *) fail "the docs: the certificate entry's openssl recipe does not say to keep the part after the =" ;;
esac
if grep -nF 'the default connection has no TLS' <<<"$all"; then
    fail "the docs: still says the default connection has no TLS"
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "PASS docs-defaults"
