#!/bin/bash
# The native build dependencies. Debian: the package lists refreshed and the five build packages
# installed with --no-upgrade, no upgrade of anything (the whole recipe, read as text: it calls
# sudo, so it never runs here). macOS: with Homebrew, its four packages; without it, an error line,
# Homebrew's install command, a non-zero exit, and nothing downloaded or run. The macOS recipe runs
# with stub brew and curl first on a PATH the check first proves holds no other brew.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
recipe() { # target: its recipe lines, up to the next line that is not part of it
  awk -v t="$1:" '$0 == t {on = 1; next} on && /^[^\t]/ && !/^$/ {exit} on' "$root/Makefile" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}
want=$(cat <<'MK'
	@$(call log-info,"Updating package lists...")
	@sudo apt-get update; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to update package lists"); \
		exit 1; \
	fi

	@$(call log-info,"Installing required packages...")
	@sudo apt-get install -y --no-upgrade \
		build-essential \
		cmake \
		libuv1-dev \
		libssl-dev \
		libhwloc-dev; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to install packages"); \
		exit 1; \
	fi
MK
)
got=$(recipe deps-debian)
[ "$got" = "$want" ] || { echo "FAIL deps-debian recipe"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/    /'; rc=1; }
grep -nE '(apt|apt-get) .*(upgrade|dist-upgrade|full-upgrade)( |;|$)' "$root/Makefile" | grep -v -- '--no-upgrade' \
  && { echo "FAIL an upgrade command is left in the Makefile"; rc=1; }

w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/nobrew" "$w/brew"
for d in nobrew brew; do
  printf '#!/bin/sh\necho "curl $*" >> "%s/calls"\n' "$w" > "$w/$d/curl"
  chmod +x "$w/$d/curl"
done
printf '#!/bin/sh\necho "brew $*" >> "%s/calls"\n[ -z "$BREW_FAIL" ]\n' "$w" > "$w/brew/brew"
chmod +x "$w/brew/brew"
sys=/usr/bin:/bin
[ -z "$(PATH="$w/nobrew:$sys" command -v brew)" ] || { echo "FAIL harness: a brew is reachable on $sys"; exit 1; }
macos() { # path-dir: runs the recipe, sets out, code, calls
  rm -f "$w/calls"
  out=$(cd "$w" && PATH="$w/$1:$sys" TERM=dumb make -s -f "$root/Makefile" deps-macos 2>/dev/null); code=$?
  calls=$(cat "$w/calls" 2>/dev/null)
}
macos nobrew
[ "$code" -ne 0 ] || { echo "FAIL macos without brew: exit 0"; rc=1; }
want='[  INFO   ] Installing dependencies using Homebrew...
[  ERROR  ] Homebrew not found. Install it with the command below and run the installer again:
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
[ "$out" = "$want" ] || { echo "FAIL macos without brew: output"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$out") | sed 's/^/    /'; rc=1; }
[ -z "$calls" ] || { echo "FAIL macos without brew: ran $calls"; rc=1; }
macos brew
[ "$code" -eq 0 ] || { echo "FAIL macos with brew: exit $code"; rc=1; }
[ "$calls" = "brew install cmake libuv openssl hwloc" ] || { echo "FAIL macos with brew: calls '$calls'"; rc=1; }
BREW_FAIL=1 macos brew
[ "$code" -ne 0 ] || { echo "FAIL macos with a failing brew: exit 0"; rc=1; }
[ "${out##*$'\n'}" = "[  ERROR  ] Failed to install dependencies with Homebrew" ] || { echo "FAIL macos with a failing brew: last line '${out##*$'\n'}'"; rc=1; }
[ "$rc" -eq 0 ] && echo "PASS build-deps"
exit "$rc"
