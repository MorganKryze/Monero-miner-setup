#!/bin/bash
# What may reach main and :latest without the owner: the Dependabot auto-merge workflow merges
# Actions patch and minor bumps only, from a pull_request run with no default permissions; a
# manual publish refuses the tag names the push and release rules own, and runs that check
# before the tags are computed. CI keeps the job names main's protection requires.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
a=.github/workflows/dependabot-automerge.yml
p=.github/workflows/publish.yml
block() { # file, first line: from that whole line to the next line indented as little or less
  awk -v first="$2" '
    !on && $0 == first { on = 1; match($0, /^ */); ind = RLENGTH; print; next }
    on { match($0, /^ */); if ($0 != "" && RLENGTH <= ind) exit; print }' "$1"
}
grep -qx 'on: pull_request' "$a" || { echo "FAIL automerge trigger"; rc=1; }
grep -qx 'permissions: {}' "$a" || { echo "FAIL automerge default permissions"; rc=1; }
[ "$(grep -cxF "    if: github.event.pull_request.user.login == 'dependabot[bot]'" "$a")" -eq 2 ] \
  || { echo "FAIL automerge jobs not limited to Dependabot's pull requests"; rc=1; }
want=$(cat <<'YML'
        if: >-
          needs.meta.outputs.package-ecosystem == 'github_actions' &&
          (needs.meta.outputs.update-type == 'version-update:semver-patch' ||
          needs.meta.outputs.update-type == 'version-update:semver-minor')
YML
)
[ "$(block "$a" '        if: >-')" = "$want" ] || { echo "FAIL automerge allowlist"; rc=1; }
# Each job's permissions block whole: a scope appended to either one fails here.
want=$(printf '%s\n' '    permissions:' '      pull-requests: read' \
  '    permissions:' '      contents: write' '      pull-requests: write')
got=$(awk '/^    permissions:$/ {on = 1; print; next} on && /^      / {print; next} {on = 0}' "$a")
[ "$(grep -c 'permissions:' "$a")" -eq 3 ] && [ "$got" = "$want" ] \
  || { echo "FAIL automerge job permissions"; rc=1; }
! grep -n 'continue-on-error' "$a" "$p" || { echo "FAIL continue-on-error in a guarded workflow"; rc=1; }

# The manual publish input: its step runs first, on dispatch only, and refuses what it must.
step='      - name: Validate dispatch input (allowed characters, no reserved name)'
order=$(grep -nxF -e "$step" -e '      - name: Compute tags' -e '      - name: Create multi-arch manifest' "$p" | cut -d: -f2- | sed 's/^      - name: //')
[ "$order" = "$(printf '%s\n' 'Validate dispatch input (allowed characters, no reserved name)' 'Compute tags' 'Create multi-arch manifest')" ] \
  || { echo "FAIL the dispatch check does not run before the tags"; rc=1; }
[ "$(block "$p" "$step" | sed -n 2p)" = "        if: \${{ github.event_name == 'workflow_dispatch' }}" ] \
  || { echo "FAIL the dispatch check's condition"; rc=1; }
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
block "$p" "$step" | sed -n '/^        run: |$/,$p' | sed '1d;s/^          //' > "$d/validate.sh"
for tag in latest main-0ce9664 buildcache-amd64 v1.2.3 v1 1.2.3 1.2 '' 'dev latest' "$(printf 'dev\nlatest')" 'a/b' '../x'; do
  INPUT_TAG=$tag bash -e "$d/validate.sh" >/dev/null 2>&1 && { echo "FAIL dispatch tag accepted: '$tag'"; rc=1; }
done
for tag in dev nightly test_1 rc.2; do
  INPUT_TAG=$tag bash -e "$d/validate.sh" >/dev/null 2>&1 || { echo "FAIL dispatch tag refused: '$tag'"; rc=1; }
done
# Only push and the main-merged signal may add :latest or :main-<sha>; versions on a tag push.
want=$(cat <<'YML'
          flavor: latest=false
            type=raw,value=latest,enable=${{ (github.event_name == 'push' || github.event_name == 'repository_dispatch') && github.ref == 'refs/heads/main' }}
            type=sha,prefix=main-,enable=${{ (github.event_name == 'push' || github.event_name == 'repository_dispatch') && github.ref == 'refs/heads/main' }}
            type=semver,pattern={{version}},enable=${{ github.event_name == 'push' }}
            type=semver,pattern={{major}}.{{minor}},enable=${{ github.event_name == 'push' }}
            type=raw,value=latest,enable=${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
            type=raw,value=${{ env.DISPATCH_TAG }},enable=${{ github.event_name == 'workflow_dispatch' }}
YML
)
got=$(grep -E '^ +(flavor: |type=(raw|sha|semver),)' "$p")
[ "$got" = "$want" ] || { echo "FAIL publish tag rules"; diff <(echo "$want") <(echo "$got"); rc=1; }

# main's protection requires these check names; a renamed job would block every pull request.
want=$(printf '    name: %s\n' 'ShellCheck' 'Hadolint' 'Makefile dry-run' 'Regression checks' 'Docker build smoke test (${{ matrix.arch }})')
[ "$(grep -E '^    name: ' .github/workflows/ci.yml)" = "$want" ] || { echo "FAIL ci job names"; rc=1; }
# The Regression checks job runs make check, and only that.
want=$(cat <<'YML'
  checks:
    name: Regression checks
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      # No submodules: the checks build their own fixtures and need no network.
      - name: make check
        run: make check
YML
)
got=$(block .github/workflows/ci.yml '  checks:')
[ "$got" = "$want" ] || { echo "FAIL ci regression checks job"; diff <(echo "$want") <(echo "$got"); rc=1; }
[ "$rc" -eq 0 ] && echo "PASS workflow-policy"
exit "$rc"
