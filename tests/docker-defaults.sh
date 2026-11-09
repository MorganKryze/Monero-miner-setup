#!/bin/bash
# One set of Docker defaults: the installer, its --help, the compose file, docker/.env.example and
# the container agree on each, and the example files carry the keys the installer writes. The VPN
# files set no FIREWALL= key, which Gluetun never reads, and nothing the project ships sets the one
# key that turns Gluetun's killswitch off; the VPN example says the killswitch is Gluetun's default.
# Read from the files and from the installer's --help; nothing runs but that.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
fail() { echo "FAIL $*"; rc=1; }
setup=scripts/docker_setup.sh compose=docker/compose.yml example=docker/.env.example vpnex=docker/.env.vpn.example
entry=docker/entrypoint.sh
# key, installer constant, default ('' for none), and whether the container sets it too.
while read -r key const value in_entry; do
  [ "$value" = "''" ] && value=""
  case $const in
    DEFAULT_DONATE_LEVEL | DEFAULT_MAX_THREADS | DEFAULT_PAUSE_ON_*) want="$const=$value" ;;
    *) want="$const=\"$value\"" ;;
  esac
  grep -qxF "$want" "$setup" || fail "$setup: no line $want"
  grep -qxF "      - $key=\${$key:-$value}" "$compose" || fail "$compose: $key does not default to '$value'"
  grep -qxF "$key=$value" "$example" || fail "$example: no line $key=$value"
  if [ "$in_entry" = yes ]; then
    grep -qxF "    $key=\${$key:-$value}" "$entry" || fail "$entry: $key does not default to '$value'"
  fi
done <<'TABLE'
WORKER_NAME DEFAULT_WORKER_NAME docker_miner yes
POOL_URL DEFAULT_POOL_URL gulf.moneroocean.stream yes
DONATE_LEVEL DEFAULT_DONATE_LEVEL 0 yes
MAX_THREADS_PERCENT DEFAULT_MAX_THREADS 75 yes
FORCE_THREAD_COUNT DEFAULT_FORCE_THREAD_COUNT '' yes
PAUSE_ON_BATTERY DEFAULT_PAUSE_ON_BATTERY false yes
PAUSE_ON_ACTIVE DEFAULT_PAUSE_ON_ACTIVE false yes
TABLE
grep -qxF 'DEFAULT_CPU_COUNT="2.0"' "$setup" && grep -qxF "    cpus: '\${CPU_COUNT:-2.0}'" "$compose" && grep -qxF 'CPU_COUNT=2.0' "$example" \
  || fail "the CPU quota does not default to 2.0 everywhere"
grep -qxF 'DEFAULT_MEMORY_LIMIT="3g"' "$setup" && grep -qxF "    mem_limit: '\${MEMORY_LIMIT:-3g}'" "$compose" && grep -qxF 'MEMORY_LIMIT=3g' "$example" \
  || fail "the memory limit does not default to 3g everywhere"
grep -qxF '# XMRIG_IMAGE=ghcr.io/morgankryze/monero-miner-setup:latest' "$example" \
  && grep -qxF 'DEFAULT_XMRIG_IMAGE="ghcr.io/morgankryze/monero-miner-setup:latest"' "$setup" \
  && grep -qxF '    image: ${XMRIG_IMAGE:-ghcr.io/morgankryze/monero-miner-setup:latest}' "$compose" || fail "the image default differs"

# --help, as printed: each default as the scripts use it, and --overwrite-env.
help=$(bash "$setup" --help | sed 's/\x1b\[[0-9;]*m//g')
while IFS= read -r line; do
  printf '%s\n' "$help" | grep -qxF -- "$line" || fail "--help: no line '$line'"
done <<'HELP'
  --worker-name NAME           Worker name, 1-64 letters, digits or . _ - @ : +
                               (default: docker_miner)
  --pool URL                   Pool host[:port], optionally after stratum+tcp:// or
                               stratum+ssl:// (default: gulf.moneroocean.stream)
  --donate N                   Donation level 0-5 (default: 0)
  --threads N                  Threads as a percentage 1-100 of the container's CPU quota,
                               at most xmrig's own count (default: 75)
  --force-threads N            Mine with N threads, 1-1024, at most the CPUs the container
                               may use, with a warning above that (default: none)
  --cpus N                     Container CPU quota (default: 2.0)
  --memory LIMIT               Container memory limit, digits with b, k, m or g
                               (default: 3g; under 2560m, RandomX light mode)
  --overwrite-env              Rewrite docker/.env (and docker/.env.vpn with --vpn) from
                               this run's flags; without it, existing files are kept
HELP

# The keys: what the installer writes into docker/.env is what the example holds.
written=$(sed -n '/^function env_content() {$/,/^}$/p' "$setup" | sed -nE 's/^([A-Z_]+)=.*/\1/p' | sort | tr '\n' ' ')
held=$(sed -nE 's/^#? ?([A-Z_]+)=.*/\1/p' "$example" | sort | tr '\n' ' ')
[ -n "$written" ] && [ "$written" = "$held" ] || fail "$example keys '$held', the installer writes '$written'"
# Each key the installer can write into docker/.env.vpn is in its example, set or commented.
for key in $(sed -n '/^function env_vpn_content() {$/,/^}$/p' "$setup" | grep -oE '[A-Z_]{2,}=|SERVER_[A-Z]+' | sort -u | tr -d '='); do
  grep -qE "^(# )?$key=" "$vpnex" || fail "$vpnex has no $key"
done

# FIREWALL: no such key written or shipped, nothing ships the killswitch's off switch, and the
# example says the killswitch is Gluetun's default.
grep -nE '(^|[^A-Z_])FIREWALL=' "$setup" "$vpnex" docker/compose*.yml && fail "a FIREWALL= key is set"
if git ls-files --error-unmatch "$setup" >/dev/null 2>&1; then
  shipped=$(git ls-files | grep -v '^tests/' | grep -v '^dependencies/')
  # shellcheck disable=SC2086 # one path per line, none with a space
  hits=$(grep -l 'FIREWALL_ENABLED_DISABLING_IT_SHOOTS_YOU_IN_YOUR_FOOT' $shipped 2>/dev/null)
  [ -z "$hits" ] || fail "the killswitch off switch is set in: $hits"
else
  fail "not a git checkout: cannot list the shipped files"
fi
want=$(printf '%s\n' "# Killswitch: Gluetun's firewall is on by its own default and blocks every connection outside the" \
  "# tunnel, so xmrig can't reach the pool if the VPN drops. This project never turns it off.")
printf '%s\n' "$(cat "$vpnex")" | grep -qxF -- "$(printf '%s\n' "$want" | head -1)" \
  && printf '%s\n' "$(cat "$vpnex")" | grep -qxF -- "$(printf '%s\n' "$want" | tail -1)" || fail "$vpnex: no killswitch lines"
[ "$rc" -eq 0 ] && echo "PASS docker-defaults"
exit "$rc"
