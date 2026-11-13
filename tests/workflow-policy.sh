#!/bin/bash
# What may reach main and :latest without the owner: the Dependabot auto-merge workflow merges
# Actions patch and minor bumps only, from a pull_request run with no default permissions; a
# manual publish refuses the tag names the push and release rules own, and runs that check
# before the tags are computed. CI keeps the job names main's protection requires.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
a=.github/workflows/dependabot-automerge.yml
p=.github/workflows/publish.yml
# YAML breaks lines at a carriage return too, and libyaml at U+0085 and U+2028, where awk and
# grep see one line: a scope or a condition hidden behind one would pass every check below.
! LC_ALL=C grep -q '[^ -~]' "$a" "$p" .github/workflows/ci.yml \
  || { echo "FAIL a byte other than printable ASCII in a guarded workflow"; rc=1; }
block() { # file, first line: from that whole line to the next line indented as little or less
  # YAML reads past comment and whitespace-only lines whatever their indent, so neither ends the
  # block: a comment indented as little or less is skipped, a whitespace-only line is compared.
  awk -v first="$2" '
    !on && $0 == first { on = 1; match($0, /^ */); ind = RLENGTH; print; next }
    on { match($0, /^ */); if (RLENGTH <= ind && /^ *#/) next
      if (RLENGTH <= ind && !/^ *$/) exit; print }' "$1"
}
major() { sed -E 's/^( *(- )?uses: [^@ ]+@v)[0-9]+$/\1N/'; } # stdin: a workflow, majors as @vN
grep -qx 'on: pull_request' "$a" || { echo "FAIL automerge trigger"; rc=1; }
grep -qx 'permissions: {}' "$a" || { echo "FAIL automerge default permissions"; rc=1; }
[ "$(grep -cxF "    if: github.event.pull_request.user.login == 'dependabot[bot]'" "$a")" -eq 2 ] \
  || { echo "FAIL automerge jobs not limited to Dependabot's pull requests"; rc=1; }
# The whole auto-merge workflow, line for line: an extra merge step, a meta output set to a
# constant or a scope added anywhere fails here. Only an action's major version may move
# (Dependabot bumps it), so `uses:` lines are compared with @v<major> read as @vN.
want=$(cat <<'YML'
name: Dependabot auto-merge

on: pull_request

# Nothing by default; each job below gets only what it needs.
permissions: {}

jobs:
  meta:
    name: Read Dependabot metadata
    # Check who opened the PR, not who triggered the run: github.actor is
    # whoever re-ran the job or pushed last, which must not count as Dependabot.
    if: github.event.pull_request.user.login == 'dependabot[bot]'
    runs-on: ubuntu-latest
    # The third-party action runs apart from the write token: compromised, it
    # could only misreport this PR's metadata, not merge or push anything.
    permissions:
      pull-requests: read
    outputs:
      package-ecosystem: ${{ steps.meta.outputs.package-ecosystem }}
      update-type: ${{ steps.meta.outputs.update-type }}
    steps:
      - name: Read Dependabot metadata
        id: meta
        uses: dependabot/fetch-metadata@v3

  automerge:
    name: Auto-merge Dependabot PRs
    needs: meta
    if: github.event.pull_request.user.login == 'dependabot[bot]'
    runs-on: ubuntu-latest
    # The merge step waits up to 60 minutes for the required checks.
    timeout-minutes: 70
    # A newer push to the same PR restarts the wait; the older run's view is stale.
    concurrency:
      group: automerge-${{ github.event.pull_request.number }}
      cancel-in-progress: true
    permissions:
      contents: write
      pull-requests: write
    steps:
      - name: Merge once CI is green, then publish main
        # Only Actions patch and minor bumps merge on their own. A submodule bump
        # pulls in upstream XMRig source and a major bump can break the workflows,
        # so both wait for the owner to review.
        if: >-
          needs.meta.outputs.package-ecosystem == 'github_actions' &&
          (needs.meta.outputs.update-type == 'version-update:semver-patch' ||
          needs.meta.outputs.update-type == 'version-update:semver-minor')
        # --auto queues the merge; GitHub waits for required status checks
        # (configured in branch protection) before merging.
        # A merge made with the workflow token fires no push event, so neither CI
        # nor the publish workflow would see it. repository_dispatch is one of the
        # two events that token may still trigger, so we wait for the merge and
        # send it ourselves.
        run: |
          gh pr merge --auto --squash "$PR_URL"
          for _ in $(seq 1 120); do
            # The runner uses bash -e: one failed API call must not end the wait.
            state=$(gh pr view "$PR_URL" --json state --jq .state) || state=""
            case "$state" in
              MERGED)
                gh api "repos/$GITHUB_REPOSITORY/dispatches" -f event_type=main-merged
                exit 0
                ;;
              CLOSED)
                echo "PR closed without merging; nothing to publish."
                exit 0
                ;;
            esac
            sleep 30
          done
          # Disarm the queued merge: a later one made with this token would send no
          # signal, while the owner's own merge pushes to main and publishes.
          gh pr merge --disable-auto "$PR_URL"
          echo "::error::Not merged after 60 minutes; check the required CI checks, then merge by hand."
          exit 1
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
YML
)
want=$(printf '%s\n' "$want" | major); got=$(major < "$a")
[ "$got" = "$want" ] || { echo "FAIL automerge workflow"; diff <(echo "$want") <(echo "$got"); rc=1; }
! grep -n 'continue-on-error' "$a" "$p" || { echo "FAIL continue-on-error in a guarded workflow"; rc=1; }

# The manual publish input: its step runs first, on dispatch only, and refuses what it must.
step='      - name: Validate dispatch input (allowed characters, no reserved name)'
order=$(grep -nxF -e "$step" -e '      - name: Compute tags' -e '      - name: Create multi-arch manifest' "$p" | cut -d: -f2- | sed 's/^      - name: //')
[ "$order" = "$(printf '%s\n' 'Validate dispatch input (allowed characters, no reserved name)' 'Compute tags' 'Create multi-arch manifest')" ] \
  || { echo "FAIL the dispatch check does not run before the tags"; rc=1; }
[ "$(block "$p" "$step" | sed -n 2p)" = "        if: \${{ github.event_name == 'workflow_dispatch' }}" ] \
  || { echo "FAIL the dispatch check's condition"; rc=1; }
d=$(mktemp -d) && [ -d "$d" ] || { echo "FAIL mktemp -d"; exit 1; }
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
            type=semver,pattern={{major}}.{{minor}},enable=${{ github.event_name == 'push' && !contains(github.ref, '-') }}
            type=raw,value=latest,enable=${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') && !contains(github.ref, '-') }}
            type=raw,value=${{ env.DISPATCH_TAG }},enable=${{ github.event_name == 'workflow_dispatch' }}
YML
)
got=$(grep -E '^ +(flavor: |type=(raw|sha|semver),)' "$p")
[ "$got" = "$want" ] || { echo "FAIL publish tag rules"; diff <(echo "$want") <(echo "$got"); rc=1; }

# main's protection requires these check names; a renamed job would block every pull request.
want=$(printf '    name: %s\n' 'ShellCheck' 'Hadolint' 'Makefile dry-run' 'Regression checks' 'Docker build smoke test (${{ matrix.arch }})')
[ "$(grep -E '^    name: ' .github/workflows/ci.yml)" = "$want" ] || { echo "FAIL ci job names"; rc=1; }
# The Regression checks job runs the runner's own check outside the runner, then make check,
# and only those: a make check that ignored failures would ignore that check failing too.
want=$(cat <<'YML'
  checks:
    name: Regression checks
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      # No submodules: the checks build their own fixtures and need no network.
      # make check runs this one too, but a runner that ignored failures would
      # pass it, so it runs on its own first.
      - name: make check fails when a check fails
        run: bash tests/make-check.sh

      - name: make check
        run: make check
YML
)
got=$(block .github/workflows/ci.yml '  checks:' | major)
want=$(printf '%s\n' "$want" | major)
[ "$got" = "$want" ] || { echo "FAIL ci regression checks job"; diff <(echo "$want") <(echo "$got"); rc=1; }

# The release binary: the workflow-wide token stays read plus packages, the build job (upstream code)
# holds read only, and only the publish job holds the write and signing scopes. The two jobs are
# pinned line for line, then their two scripts run on stubs: the glibc gate and the release call.
want=$(printf '%s\n' 'permissions:' '  contents: read' '  packages: write')
[ "$(block "$p" 'permissions:')" = "$want" ] || { echo "FAIL workflow-wide permissions"; rc=1; }
want=$(cat <<'YML'
  release-build:
    name: Build release binary (linux/arm64)
    if: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
    runs-on: ubuntu-24.04-arm
    container: debian:trixie
    permissions:
      contents: read
    defaults:
      run:
        shell: bash
    outputs:
      xmrig-commit: ${{ steps.source.outputs.commit }}
    steps:
      # git first: without it in the container, actions/checkout fetches no submodule.
      - name: Install build packages
        run: |
          apt-get update
          apt-get install -y --no-install-recommends ca-certificates git build-essential cmake libuv1-dev libssl-dev libhwloc-dev

      - uses: actions/checkout@vN
        with:
          submodules: recursive
          persist-credentials: false

      # The checkout belongs to the runner's user, not the container's root: git must be told the
      # folder is safe.
      - name: Read the pinned XMRig commit
        id: source
        run: echo "commit=$(git -c safe.directory='*' -C dependencies/xmrig rev-parse HEAD)" >> "$GITHUB_OUTPUT"

      # Unmodified, from the commit the tag pins, as docker/Dockerfile builds it: libuv from the
      # shared library, so the board loads its packaged libuv1t64 and gets its updates.
      - name: Build XMRig
        run: |
          cmake -S dependencies/xmrig -B build -DUV_LIBRARY="/usr/lib/$(gcc -dumpmachine)/libuv.so"
          cmake --build build -j"$(nproc)"
          strip build/xmrig
          mkdir dist
          cp build/xmrig dist/xmrig-linux-arm64

      # The installer refuses a host older than its RELEASE_MIN_GLIBC: a binary needing a newer
      # glibc fails the tag here, before anything is published.
      - name: Check the binary's glibc, libuv and version
        run: |
          min=$(sed -n 's/^RELEASE_MIN_GLIBC="\([0-9]*\.[0-9]*\)"$/\1/p' scripts/install.sh)
          need=$(objdump -T dist/xmrig-linux-arm64 | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' | sort -uV | tail -n 1)
          if [ -z "$min" ] || [ -z "$need" ] || [ "$(printf '%s\n' "$need" "$min" | sort -V | tail -n 1)" != "$min" ]; then
            echo "::error::The binary needs glibc ${need:-unknown}, and the installer's minimum is ${min:-unset}."
            exit 1
          fi
          ldd dist/xmrig-linux-arm64 | grep -E '^[[:space:]]libuv[.]so[.]1 => /'
          dist/xmrig-linux-arm64 --version

      - uses: actions/upload-artifact@vN
        with:
          name: release-binary
          path: dist/xmrig-linux-arm64
          if-no-files-found: error
          retention-days: 1

  release-bundle:
    name: Build DietPi first-boot zip
    if: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    outputs:
      zip-sha256: ${{ steps.zip.outputs.sha256 }}
    steps:
      - uses: actions/checkout@vN
        with:
          persist-credentials: false

      - name: Build the zip
        env:
          TAG: ${{ github.ref_name }}
        run: |
          mkdir dist
          bash scripts/dietpi_bundle.sh "$TAG" dist

      # The publish job checks the zip it downloads against this sum, made where the zip was built.
      - name: Sum the zip
        id: zip
        run: |
          echo "sha256=$(sha256sum dist/dietpi-first-boot.zip | cut -d ' ' -f 1)" >> "$GITHUB_OUTPUT"

      - uses: actions/upload-artifact@vN
        with:
          name: release-bundle
          path: dist/dietpi-first-boot.zip
          if-no-files-found: error
          retention-days: 1

  release-publish:
    name: Publish release binary
    needs: [release-build, release-bundle]
    if: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      id-token: write
      attestations: write
    steps:
      - uses: actions/download-artifact@vN
        with:
          name: release-binary
          path: dist

      - uses: actions/download-artifact@vN
        with:
          name: release-bundle
          path: dist

      # The XMRig build job's token can replace a run's artifact, so the zip must match the sum the
      # bundle job made before it is summed, attested and published.
      - name: Check the zip is the one the bundle job built
        working-directory: dist
        env:
          BUNDLE_SHA256: ${{ needs.release-bundle.outputs.zip-sha256 }}
        run: |
          [[ $BUNDLE_SHA256 =~ ^[0-9a-f]{64}$ ]]
          printf '%s  dietpi-first-boot.zip\n' "$BUNDLE_SHA256" | sha256sum -c -

      - name: Sum the binary and the zip
        working-directory: dist
        run: sha256sum xmrig-linux-arm64 dietpi-first-boot.zip > SHA256SUMS

      - uses: actions/attest@vN
        with:
          subject-path: |
            dist/xmrig-linux-arm64
            dist/dietpi-first-boot.zip

      # gh release create fails when the release exists, so a published asset is never replaced. A
      # tag with a pre-release part (v0.2.0-rc.1) makes a pre-release.
      - name: Publish the release
        working-directory: dist
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ github.ref_name }}
          XMRIG_COMMIT: ${{ needs.release-build.outputs.xmrig-commit }}
        run: |
          [[ $XMRIG_COMMIT =~ ^[0-9a-f]{40}$ ]]
          pre=()
          case $TAG in *-*) pre=(--prerelease) ;; esac
          {
            echo "xmrig-linux-arm64 is XMRig for Linux arm64, built unmodified by this repository's CI on Debian 13 from https://github.com/MoneroOcean/xmrig at commit $XMRIG_COMMIT, the commit this tag pins. XMRig is licensed under GPL-3.0; that commit is its source."
            echo
            echo "Check it from a PC: gh attestation verify xmrig-linux-arm64 --repo MorganKryze/Monero-miner-setup"
            echo "Check it on the board: sha256sum -c SHA256SUMS"
            echo
            echo "dietpi-first-boot.zip holds dietpi.txt and Automation_Custom_Script.sh for a DietPi card: the script installs this release only. Check it from a PC: gh attestation verify dietpi-first-boot.zip --repo MorganKryze/Monero-miner-setup"
          } > notes.md
          gh release create "$TAG" --repo "$GITHUB_REPOSITORY" --verify-tag --title "$TAG" --notes-file notes.md "${pre[@]}" xmrig-linux-arm64 dietpi-first-boot.zip SHA256SUMS
YML
)
got=$({ block "$p" '  release-build:'; block "$p" '  release-bundle:'; block "$p" '  release-publish:'; } | major)
[ "$got" = "$want" ] || { echo "FAIL release jobs"; diff <(echo "$want") <(echo "$got"); rc=1; }
# Every write scope in the file must be exactly these five. A `#` mid-line may sit inside a quoted
# value, so only full-line comments are dropped, and every bare `write` counts: a quoted, folded,
# aliased or tagged value, a write-all, a one-line permissions map or a third job adds a token and
# fails (so does a trailing comment that says write). An escape that can spell a letter fails too.
# A double-quoted value joins two lines at a trailing backslash, and counting quotes cannot tell
# whether a line sits inside one, so only the manifest step's two shell continuations may end a
# line with a backslash. The mutants below prove each way in stays shut.
want='attestations: write,contents: write,id-token: write,packages: write'
breaks=$(cat <<'YML'
          docker buildx imagetools create \
            $(jq -cr '.tags | map("-t " + .) | join(" ")' <<< "$DOCKER_METADATA_OUTPUT_JSON") \
YML
)
write_scopes() { # file: FAIL lines on stdout, status 1 on any
  local s got r=0
  s=$(grep -v '^ *#' "$1")
  got=$(printf '%s\n' "$s" | grep -oE '[a-z-]+: *write|write-all|write' | tr -s ' ' | sort | paste -sd, -)
  [ "$got" = "$want" ] || { echo "FAIL write scopes in $1: $got"; r=1; }
  ! printf '%s\n' "$s" | grep -qE '\\[xuU]' || { echo "FAIL an escape that can spell a scope in $1"; r=1; }
  [ "$(printf '%s\n' "$s" | grep '\\$')" = "$breaks" ] \
    || { echo "FAIL a line ending in a backslash besides the manifest step's two in $1"; r=1; }
  return $r
}
write_scopes "$p" || rc=1
mutant() { # name, where (third | after:<job line>), lines of the inserted YAML
  local name=$1 where=$2
  shift 2
  printf '%s\n' "$@" > "$d/ins"
  case $where in
    third) { cat "$p"; printf '\n  extra:\n    runs-on: ubuntu-24.04\n'; cat "$d/ins"
      printf '    steps:\n      - run: echo hi\n'; } > "$d/m.yml" ;;
    tail) { cat "$p"; printf '\n'; cat "$d/ins"; } > "$d/m.yml" ;;
    after:*) awk -v job="${where#after:}" -v f="$d/ins" '{ print } $0 == job { while ((getline l < f) > 0) print l }' \
      "$p" > "$d/m.yml" ;;
  esac
  write_scopes "$d/m.yml" > /dev/null && { echo "FAIL write scopes let through: $name"; rc=1; }
}
mutant 'write-all on merge' 'after:  merge:' '    permissions: write-all'
mutant 'one-line map on build' 'after:  build:' '    permissions: { contents: write, id-token: write, packages: write }'
mutant 'trailing comment on a scope' 'after:  merge:' '    permissions:' '      id-token: write # attest'
mutant 'write-all on a third job' third '    permissions: write-all'
mutant 'double-quoted' third '    permissions:' '      contents: "write"'
mutant 'single-quoted' third '    permissions:' "      contents: 'write'"
mutant 'value on the next line' third '    permissions:' '      contents:' '        write'
mutant 'alias' third '    env:' '      W: &w write' '    permissions:' '      contents: *w'
mutant 'tag' third '    permissions:' '      contents: !!str write'
mutant 'quoted key' third '    permissions:' '      "contents": write'
mutant 'explicit key' third '    permissions:' '      ? contents' '      : write'
mutant 'quoted one-line map on merge' 'after:  merge:' '    permissions: { contents: "write", id-token: "write", packages: "write" }'
mutant 'hex escape in write-all' 'after:  merge:' '    permissions: "write\x2dall"'
mutant 'escaped line break in write-all' 'after:  merge:' '    permissions: "write-\' '      all"'
mutant 'hex escape in write' third '    permissions:' '      contents: "\x77rite"'
mutant 'escaped line break in write' third '    permissions:' '      contents: "wr\' '        ite"'
mutant 'escaped line breaks, a quote in the name' tail '  extra: { name: a"b, runs-on: ubuntu-24.04, permissions: { contents: "wr\' '    ite", id-token: "wr\' '    ite" }, steps: [ { run: echo hi } ] }'
{ cat "$p"; printf '%s\n' '' '  extra: { name: " #x", runs-on: ubuntu-24.04, permissions: { contents: write, id-token: write }, steps: [ { run: echo hi } ] }'; } > "$d/m.yml"
write_scopes "$d/m.yml" > /dev/null && { echo "FAIL write scopes let through: a flow-line job after a quoted #"; rc=1; }
step() { block "$p" "      - name: $1" | sed -n '/^        run: |$/,$p' | sed '1d;s/^          //'; }
mkdir -p "$d/rel/bin" "$d/rel/dist" "$d/rel/scripts"
step "Check the binary's glibc, libuv and version" > "$d/glibc.sh"
step 'Publish the release' > "$d/publish.sh"
step 'Sum the zip' > "$d/zipsum.sh"
step 'Check the zip is the one the bundle job built' > "$d/zipcheck.sh"
for t in grep sed sort tail printf cat cut sha256sum; do ln -s "$(type -P $t)" "$d/rel/bin/$t"; done
cat > "$d/rel/bin/objdump" <<'STUB'
#!/bin/bash
echo "0000 DF *UND* 0 GLIBC_2.17 memcpy"
echo "0000 DF *UND* 0 GLIBC_$NEED stat"
STUB
cat > "$d/rel/bin/ldd" <<'STUB'
#!/bin/bash
[ -n "$STATIC" ] || printf '\tlibuv.so.1 => /usr/lib/aarch64-linux-gnu/libuv.so.1 (0x1)\n'
printf '\tlibc.so.6 => /lib/aarch64-linux-gnu/libc.so.6 (0x2)\n'
STUB
printf '#!/bin/bash\necho "XMRig 6.0.0"\n' > "$d/rel/dist/xmrig-linux-arm64"
cat > "$d/rel/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
STUB
chmod +x "$d/rel/bin/"* "$d/rel/dist/xmrig-linux-arm64"
glibc() { # installer line, glibc the binary needs, STATIC
  printf '%s\n' "$1" > "$d/rel/scripts/install.sh"
  (cd "$d/rel" && env -i PATH="$d/rel/bin" NEED="$2" STATIC="$3" "$BASH" --norc --noprofile -eo pipefail "$d/glibc.sh") >/dev/null 2>&1
}
glibc 'RELEASE_MIN_GLIBC="2.38"' 2.38 '' || { echo "FAIL glibc gate refused a binary needing exactly the minimum"; rc=1; }
glibc 'RELEASE_MIN_GLIBC="2.38"' 2.4 '' || { echo "FAIL glibc gate refused a binary needing 2.4"; rc=1; }
glibc 'RELEASE_MIN_GLIBC="2.38"' 2.39 '' && { echo "FAIL glibc gate passed a binary needing 2.39"; rc=1; }
glibc '' 2.38 '' && { echo "FAIL glibc gate passed with no minimum in the installer"; rc=1; }
glibc 'RELEASE_MIN_GLIBC="2.38"' 2.38 1 && { echo "FAIL glibc gate passed a binary without a shared libuv"; rc=1; }
publish() { # tag, commit
  rm -f "$d/gh.log" "$d/rel/dist/notes.md"
  (cd "$d/rel/dist" && env -i PATH="$d/rel/bin" GH_LOG="$d/gh.log" TAG="$1" XMRIG_COMMIT="$2" \
    GITHUB_REPOSITORY=MorganKryze/Monero-miner-setup "$BASH" --norc --noprofile -eo pipefail "$d/publish.sh") >/dev/null 2>&1
}
commit=0123456789abcdef0123456789abcdef01234567
base='release create TAG --repo MorganKryze/Monero-miner-setup --verify-tag --title TAG --notes-file notes.md'
publish v0.2.0-rc.1 "$commit" && [ "$(cat "$d/gh.log")" = "${base//TAG/v0.2.0-rc.1} --prerelease xmrig-linux-arm64 dietpi-first-boot.zip SHA256SUMS" ] \
  || { echo "FAIL release call for a pre-release tag"; rc=1; }
publish v0.2.0 "$commit" && [ "$(cat "$d/gh.log")" = "${base//TAG/v0.2.0} xmrig-linux-arm64 dietpi-first-boot.zip SHA256SUMS" ] \
  || { echo "FAIL release call for a final tag"; rc=1; }
grep -qF "built unmodified by this repository's CI on Debian 13 from https://github.com/MoneroOcean/xmrig at commit $commit, the commit this tag pins. XMRig is licensed under GPL-3.0; that commit is its source." "$d/rel/dist/notes.md" \
  && grep -qF 'Check it from a PC: gh attestation verify xmrig-linux-arm64 --repo MorganKryze/Monero-miner-setup' "$d/rel/dist/notes.md" \
  || { echo "FAIL release notes"; rc=1; }
publish v0.2.0 'abc; rm -rf /' && { echo "FAIL release step accepted a commit that is not 40 hex digits"; rc=1; }
[ ! -e "$d/gh.log" ] || { echo "FAIL release step called gh with a bad commit"; rc=1; }
# The zip's sum crosses jobs as an output: the publish job takes only the bytes the bundle job summed.
zipcheck() { # sum the publish job is given
  (cd "$d/rel/dist" && env -i PATH="$d/rel/bin" BUNDLE_SHA256="$1" "$BASH" --norc --noprofile -eo pipefail "$d/zipcheck.sh") >/dev/null 2>&1
}
printf 'zip as built\n' > "$d/rel/dist/dietpi-first-boot.zip"
: > "$d/out"
(cd "$d/rel" && env -i PATH="$d/rel/bin" GITHUB_OUTPUT="$d/out" "$BASH" --norc --noprofile -eo pipefail "$d/zipsum.sh") >/dev/null 2>&1 \
  || { echo "FAIL zip sum step"; rc=1; }
built=$(sed -n 's/^sha256=//p' "$d/out")
[[ $built =~ ^[0-9a-f]{64}$ ]] && [ "$(wc -l < "$d/out")" -eq 1 ] || { echo "FAIL zip sum output: $(cat "$d/out")"; rc=1; }
zipcheck "$built" || { echo "FAIL zip check refused the zip the bundle job built"; rc=1; }
zipcheck '' && { echo "FAIL zip check passed with no sum"; rc=1; }
zipcheck "${built:0:63}" && { echo "FAIL zip check passed with a short sum"; rc=1; }
printf 'zip swapped\n' > "$d/rel/dist/dietpi-first-boot.zip"
zipcheck "$built" && { echo "FAIL zip check passed a swapped zip"; rc=1; }
[ "$rc" -eq 0 ] && echo "PASS workflow-policy"
exit "$rc"
