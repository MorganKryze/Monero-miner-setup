#!/bin/bash
# The README's "Dedicated board (--mode)" section names what the host tuning installs and how to
# undo it: the unit, boot script and values file of scripts/setup_service_tuning.sh (read from its
# constants, so a renamed file fails here), the /run record, configs/board-mode, the huge page count,
# make service-disable, the chain that drops the mode and the cost inputs of make status. It never
# promises an overclock.
# Fixture-free: reads the repository's files. Run from the repository root.
set -u

README=README.md
SETUP=scripts/setup_service_tuning.sh
failed=0
function fail() {
    echo "FAIL $*"
    failed=1
}

[ -f "$README" ] && [ -f "$SETUP" ] || { echo "FAIL readme-host-tuning: no $README or $SETUP"; exit 1; }

section=$(sed -n '/^### Dedicated board (--mode)$/,/^### /p' "$README")
[ -n "$section" ] || { echo "FAIL readme-host-tuning: no '### Dedicated board (--mode)' section in $README"; exit 1; }

wanted=()
for name in TUNING_UNIT TUNING_BIN TUNING_CONF; do
    value=$(sed -n "s/^$name=\"\(.*\)\"$/\1/p" "$SETUP")
    [ -n "$value" ] || fail "readme-host-tuning: $SETUP sets no $name"
    wanted+=("$value")
done
wanted+=(/run/xmrig-host-tuning configs/board-mode WALL_WATTS KWH_PRICE "make service-disable" 1280)
for word in "${wanted[@]}"; do
    [ -z "$word" ] || grep -qF -- "$word" <<<"$section" || fail "readme-host-tuning: the section does not name $word"
done
# A re-run of the installer keeps the service config and its board-mode, and never sets the
# service up again: dropping the mode takes the whole chain, named in one sentence.
chain="run \`make clean-configs\`, the installer again without \`--mode\`, then \`make service-setup\` and \`make restart\`"
grep -qF -- "$chain" <<<"$section" || fail "readme-host-tuning: the section does not name the chain that drops the mode: $chain"
if grep -qF -- "the installer run again without" <<<"$section"; then
    fail "readme-host-tuning: the section says a re-run of the installer alone drops the mode"
fi
grep -qF -- "When the installer writes a new service config" <<<"$section" || fail "readme-host-tuning: the section does not say the installer writes configs/board-mode only with a new service config"
for word in overclock config.txt; do
    if grep -qiF -- "$word" <<<"$section"; then fail "readme-host-tuning: the section names $word"; fi
done

[ "$failed" -eq 0 ] && echo "PASS readme-host-tuning"
exit "$failed"
