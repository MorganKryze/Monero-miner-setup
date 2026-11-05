#!/bin/bash
# What updates reach a host and how: Gluetun on a release tag (its latest tag is built from
# master), no third-party image on latest, and Dependabot's four entries as set, its one ignore
# rule naming ubuntu alone, so any other image keeps its minor updates.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
v=docker/compose.vpn.yml
[ "$(grep -cxE '    image: qmcgaw/gluetun:v[0-9]+\.[0-9]+\.[0-9]+' "$v")" -eq 1 ] \
  && [ "$(grep -c 'image:' "$v")" -eq 1 ] || { echo "FAIL gluetun on a release tag: $(grep 'image:' "$v" | xargs)"; rc=1; }
# Images without a variable, on latest or on no tag at all.
bad=$(grep -hE '^ *image: [^$]*$' docker/compose*.yml | grep -vE ':[A-Za-z0-9_.-]+$|:[A-Za-z0-9_.-]+@sha256:[0-9a-f]{64}$')
bad="$bad$(grep -hE '^ *image: [^$]*:latest *$' docker/compose*.yml)"
[ -z "$bad" ] || { echo "FAIL a third-party image on latest or untagged: $bad"; rc=1; }
y=.github/dependabot.yml
# One line per entry: ecosystem directory interval limit prefix ignore-rules.
got=$(awk '
  function flush() { if (eco != "") print eco, dir, intv, lim, pre, (ign == "" ? "-" : ign) }
  { line = $0; sub(/ *#.*/, "", line); gsub(/"/, "", line) }
  line ~ /^  - package-ecosystem: / { flush(); eco = line; sub(/.*: /, "", eco); dir = intv = lim = pre = ign = ""; next }
  line ~ /^    directory: /                { dir = line; sub(/.*: /, "", dir) }
  line ~ /^      interval: /               { intv = line; sub(/.*: /, "", intv) }
  line ~ /^    open-pull-requests-limit: / { lim = line; sub(/.*: /, "", lim) }
  line ~ /^      prefix: /                 { pre = line; sub(/.*: /, "", pre) }
  line ~ /^      - dependency-name: /      { n = line; sub(/.*: /, "", n); ign = ign (ign == "" ? "" : ",") n }
  line ~ /^        update-types: /         { t = line; sub(/.*: /, "", t); ign = ign ":" t }
  END { flush() }' "$y")
want=$(printf '%s\n' 'gitsubmodule / weekly 3 deps -' 'github-actions / weekly 3 ci -' \
  'docker /docker weekly 3 deps ubuntu:[version-update:semver-minor]' 'docker-compose /docker weekly 3 deps -')
[ "$got" = "$want" ] || { echo "FAIL dependabot entries"; diff <(echo "$want") <(echo "$got"); rc=1; }
# The awk reads by indentation: the same keys at any other depth would slip past it.
[ "$(grep -c 'package-ecosystem:' "$y")" -eq 4 ] || { echo "FAIL dependabot entry count"; rc=1; }
[ "$(grep -c 'dependency-name:' "$y")" -eq 1 ] && [ "$(grep -c 'update-types:' "$y")" -eq 1 ] \
  && [ "$(grep -c 'interval:' "$y")" -eq 4 ] && [ "$(grep -c 'open-pull-requests-limit:' "$y")" -eq 4 ] \
  || { echo "FAIL dependabot keys outside the four entries"; rc=1; }
[ "$rc" -eq 0 ] && echo "PASS update-policy"
exit "$rc"
