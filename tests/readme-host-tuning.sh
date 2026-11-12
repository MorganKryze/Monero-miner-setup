#!/bin/bash
# The README's "Dedicated board (--mode)" section names what the host tuning installs and how to
# undo it: the unit, boot script and values file of scripts/setup_service_tuning.sh (read from its
# constants, so a renamed file fails here), the /run record, configs/board-mode, the huge page count,
# make service-disable and the cost inputs of make status. It never promises an overclock.
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
for word in overclock config.txt; do
    if grep -qiF -- "$word" <<<"$section"; then fail "readme-host-tuning: the section names $word"; fi
done

[ "$failed" -eq 0 ] && echo "PASS readme-host-tuning"
exit "$failed"
