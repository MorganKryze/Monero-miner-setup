#!/bin/bash
# --prebuilt installs the release binary only where it can serve the host and only from a tree root
# alone can change. The whole runs prove that a host it cannot serve (macOS, x86, not root, glibc
# below 2.38 or unreadable) stops with one error line before anything is cloned, fetched or
# installed, and that a Debian 13 host goes on. The function runs, taken from scripts/install.sh,
# prove the release tag a clone is checked out at (a final tag beats a pre-release, versions sort as
# numbers, anything else is no tag), the refusal of a tree another user can change (also for the
# user who ran sudo), and the clone of the release this installer comes from, while a compiled
# install clones as before. The installer is a copy in a scratch clone with a fixture toolbox,
# under env -i, with stub uname, id, getconf, git, stat, curl, apt-get and sleep; PATH holds only
# the stub and tool-link directories. Every fixture mode is set, not left to the umask. Nothing is
# cloned, fetched, installed or started.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d "${TMPDIR:-/tmp}/prebuilt-host.XXXXXX") && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'chmod -R u+rwx -- "$w" 2>/dev/null; rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/bin" "$w/tools" "$w/home" "$w/base" "$w/opt"
chmod 755 "$w" "$w/home" "$w/base" "$w/opt"
for t in awk cat chmod cut dirname find grep head ls mkdir mktemp mv rm rmdir sed sort tail tr wc; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
real_id=$(command -v id) real_mkdir=$(command -v mkdir)
cat > "$w/bin/uname" <<'STUB'
#!/bin/bash
case $1 in
  -s) echo "${UNAME_S:-Linux}" ;;
  -m) echo "${UNAME_M:-aarch64}" ;;
esac
STUB
cat > "$w/bin/id" <<STUB
#!/bin/bash
case \$* in
  -u) echo "\${ID_UID:-0}" ;;
  *) exec "$real_id" "\$@" ;;
esac
STUB
cat > "$w/bin/getconf" <<'STUB'
#!/bin/bash
[ "${GLIBC:-}" = none ] && exit 1
[ "$1" = GNU_LIBC_VERSION ] && echo "glibc ${GLIBC:-2.41}"
exit 0
STUB
cat > "$w/bin/git" <<STUB
#!/bin/bash
echo "\$*" >> "$w/git.log"
case "\$*" in
  *"tag --points-at HEAD --list v*") [ -n "\${GIT_TAGS+x}" ] && printf '%b\n' "\$GIT_TAGS" ;;
  clone*) for last; do :; done; "$real_mkdir" -p "\$last/.git" ;;
esac
exit 0
STUB
cat > "$w/bin/stat" <<STUB
#!/bin/bash
for last; do :; done
line=\$(grep -F -- "\$last " "$w/stat.map" 2>/dev/null | head -n 1)
if [ -n "\$line" ]; then set -- \$line; echo "\$2 \$3"; else echo "root 755"; fi
STUB
for n in curl apt-get; do
  printf '#!/bin/bash\necho "$*" >> %q\nexit 1\n' "$w/$n.log" > "$w/bin/$n"
done
printf '#!/bin/sh\nexit 0\n' > "$w/bin/sleep"
chmod 755 "$w/bin/"*
wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge

# The installer's own clone, with a toolbox that prints each level on one line, errors to stderr.
r="$w/runner"
mkdir -p "$r/.git" "$r/scripts" "$r/dependencies/bash-toolbox/src"
cp "$root/scripts/install.sh" "$r/scripts/install.sh"
{
  printf '%s() { echo "[%s] $1"; }\n' txt TXT info INFO warning WARNING success SUCCESS hint HINT
  printf 'error() { echo "[ERROR] $1" >&2; return 1; }\n'
} > "$r/dependencies/bash-toolbox/src/prefix.sh"
chmod 755 "$r" "$r/.git" "$r/scripts" "$r/dependencies" "$r/dependencies/bash-toolbox" "$r/dependencies/bash-toolbox/src"
chmod 644 "$r/scripts/install.sh" "$r/dependencies/bash-toolbox/src/prefix.sh"

want() { # name, label, expected, got
  [ "$3" = "$4" ] || { echo "FAIL $1: $2"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'; rc=1; }
}
none_of() { # name: no log of a clone, fetch or install
  local f
  for f in git curl apt-get; do [ ! -e "$w/$f.log" ] || fail "$1: $f ran: $(cat "$w/$f.log")"; done
}
# whole <vars...>: the whole installer with --prebuilt. Sets out, code.
whole() {
  rm -f "$w/git.log" "$w/curl.log" "$w/apt-get.log"
  out=$(cd "$w/home" && env -i HOME="$w/home" PATH="$w/bin:$w/tools" "$@" "$BASH" --norc --noprofile "$w/runner/scripts/install.sh" --prebuilt -w "$wallet" -y -d "$w/base" 2>&1)
  code=$?
}
tail_text="Run the installer without --prebuilt to compile the miner here."
refused() { # name, error text, vars...
  local name=$1 text=$2; shift 2
  whole "$@"
  want "$name" exit 1 "$code"
  want "$name" "error lines" "[ERROR] $text" "$(printf '%s\n' "$out" | grep -F '[ERROR]')"
  case $out in *"Using base directory"*) fail "$name: went on to the base directory" ;; esac
  none_of "$name"
}
glibc_low() { echo "--prebuilt needs glibc 2.38 or newer, and this host has $1 (Debian 12 has 2.36). $tail_text"; }
# A whole run as macOS needs macOS's own /bin/ls -le to find the installer's clone; elsewhere the
# refusal is checked on the host check itself, with the same stubs.
darwin_line="--prebuilt installs the Linux arm64 release binary, and this host is Darwin arm64. $tail_text"
if [ "$(uname -s)" = Darwin ]; then
  refused darwin "$darwin_line" UNAME_S=Darwin UNAME_M=arm64
else
  out=$({ cat "$r/dependencies/bash-toolbox/src/prefix.sh"
          sed -n '/^# ===== Constants =====/,/^# ===== Own clone =====/p' "$root/scripts/install.sh"
          sed -n '/^function check_prebuilt_host() {/,/^}/p' "$root/scripts/install.sh"
          echo 'check_prebuilt_host'
        } | env -i HOME="$w/home" PATH="$w/bin:$w/tools" UNAME_S=Darwin UNAME_M=arm64 "$BASH" --norc --noprofile -s 2>&1)
  code=$?
  want darwin exit 1 "$code"
  want darwin "error lines" "[ERROR] $darwin_line" "$(printf '%s\n' "$out" | grep -F '[ERROR]')"
fi
refused x86 "--prebuilt installs the Linux arm64 release binary, and this host is Linux x86_64. $tail_text" UNAME_M=x86_64
refused non-root "--prebuilt installs a binary only root can change, so it runs as root. Run the installer again with sudo, or without --prebuilt to compile the miner as you." ID_UID=1000
refused bookworm "$(glibc_low 2.36 | sed 's/here\./here, or use --docker./')" GLIBC=2.36
refused glibc-2.4 "$(glibc_low 2.4 | sed 's/here\./here, or use --docker./')" GLIBC=2.4
refused glibc-unread "--prebuilt needs glibc 2.38 or newer, and this host's glibc version cannot be read. $tail_text" GLIBC=none
for g in 2.38 2.41; do
  whole GLIBC=$g
  case $out in *"--prebuilt installs"* | *"--prebuilt needs"*) fail "glibc-$g: refused: $out" ;; esac
  case $out in *"[INFO] Using base directory: $w/base."*) ;; *) fail "glibc-$g: did not go on" ;; esac
done
help=$(env -i HOME="$w/home" PATH="$w/bin:$w/tools" "$BASH" --norc --noprofile "$w/runner/scripts/install.sh" --help 2>&1)
case $help in
  *$'\n'"  --prebuilt            Install the release binary instead of compiling: Linux arm64, as root, glibc 2.38 or newer"$'\n'*) ;;
  *) fail "help: no --prebuilt line" ;;
esac

# Function runs: the functions taken from scripts/install.sh, under a driver.
d="$w/driver.sh"
{
  cat "$r/dependencies/bash-toolbox/src/prefix.sh"
  sed -n '/^# ===== Constants =====/,/^# ===== Own clone =====/p' "$root/scripts/install.sh"
  for f in trusted_by_root release_tag_of root_only_tree check_if_built clone_repository; do
    sed -n "/^function $f() {/,/^}/p" "$root/scripts/install.sh"
  done
  echo 'check_base_clone() { return 0; }'
  echo 'BASE_DIR=$1; shift; "$@"; rc=$?; printf "\n[RETURNED] %s\n" "$rc"; exit "$rc"'
} > "$d"
chmod 644 "$d"
clone="$w/opt/Monero-miner-setup"
# fn <vars...> -- <function> <args>: sets out, code.
fn() {
  local vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  rm -f "$w/git.log"
  out=$(cd "$w/home" && env -i HOME="$w/home" PATH="$w/bin:$w/tools" "${vars[@]}" "$BASH" --norc --noprofile "$d" "$w/opt" "$@" 2>&1)
  code=$?
  # A function that exits never reaches the line after it; one that returns leaves a marker.
  ret=
  case $out in
    *"[RETURNED] "*)
      ret=${out##*"[RETURNED] "}
      out=${out%"[RETURNED] "*}
      while [ "${out%$'\n'}" != "$out" ]; do out=${out%$'\n'}; done ;;
  esac
}
: > "$w/stat.map"
tag_of() { fn GIT_TAGS="$1" -- release_tag_of "$clone"; want "tag $2" "tag" "$3" "$out"; want "tag $2" exit 0 "$code"; }
no_return() { [ -z "$ret" ] || fail "$1: returned instead of exiting"; }
tag_of 'v0.2.0-rc.1\nv0.2.0' final v0.2.0
tag_of 'v0.2.0-rc.1' pre-release v0.2.0-rc.1
tag_of 'v0.1.1\nv0.10.0\nv0.2.0' numeric v0.10.0
tag_of 'vfoo\nv1.2\nv1.2.3;rm\nv1.2.3/x\nvx/v1.2.3\nv1.2.3-a/b' junk ""

mkdir -p "$clone"; chmod 755 "$clone"
chmod 000 "$clone"
fn PREBUILT=yes GIT_TAGS=v0.2.0 -- check_if_built
chmod 755 "$clone"
want unreadable exit 1 "$code"
want unreadable text "[ERROR] $clone cannot be read, so --prebuilt does not install a binary there." "$out"
no_return unreadable
[ ! -e "$w/git.log" ] || fail "unreadable: the tag was read"
fn PREBUILT=yes -- check_if_built
want no-tag exit 1 "$code"
no_return no-tag
want no-tag text "[ERROR] $clone is checked out at no release tag, and --prebuilt installs the release the clone is checked out at. Run git -C $clone checkout --recurse-submodules vX.Y.Z with a release from https://github.com/MorganKryze/Monero-miner-setup/releases, then the installer again." "$out"
fn PREBUILT=yes GIT_TAGS=v0.2.0 -- check_if_built
want tagged exit 1 "$code"
want tagged text "[INFO] Monero miner not yet installed from release v0.2.0." "$out"
for entry in "$w/opt alice 755" "$clone alice 755" "$w/opt root 775" "$w root 1777" "$clone root 757"; do
  echo "$entry" > "$w/stat.map"
  p=${entry%% *}
  for s in "" alice; do
    fn PREBUILT=yes GIT_TAGS=v0.2.0 ${s:+SUDO_USER=$s} -- check_if_built
    want "tree $entry sudo=$s" exit 1 "$code"
    if [ "$p" = "$clone" ]; then
      want "tree $entry sudo=$s" text "[ERROR] $p can be changed by a user other than root, so --prebuilt does not install a binary under it. Move $p away and run the installer again, or pass -d with a directory only root can change." "$out"
    else
      want "tree $entry sudo=$s" text "[ERROR] $p can be changed by a user other than root, so --prebuilt does not install a binary under it. Pass -d with a directory only root can change, such as /opt." "$out"
    fi
    no_return "tree $entry sudo=$s"
    [ ! -e "$w/git.log" ] || fail "tree $entry sudo=$s: the tag was read before the tree check"
  done
done
: > "$w/stat.map"
rmdir "$clone"

url=https://github.com/MorganKryze/Monero-miner-setup.git
fn PREBUILT=yes VERSION=0.1.1 -- clone_repository
want clone-release exit 0 "$code"
# The tag cloned is v + the installer's own VERSION, whatever release this tree is.
version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$root/scripts/install.sh")
want clone-release git "clone --recurse-submodules --branch v$version $url $clone" "$(cat "$w/git.log" 2>/dev/null)"
rm -rf "$clone"
echo "$w/opt alice 755" > "$w/stat.map"
fn PREBUILT=yes -- clone_repository
want clone-open-base exit 1 "$code"
[ ! -e "$w/git.log" ] || fail "clone-open-base: git ran"
[ ! -e "$clone" ] || fail "clone-open-base: made the clone folder"
: > "$w/stat.map"
fn -- clone_repository
want clone-compiled exit 0 "$code"
want clone-compiled git "clone --recurse-submodules $url $clone" "$(cat "$w/git.log" 2>/dev/null)"

[ "$rc" = 0 ] && echo "PASS prebuilt-host"
exit "$rc"
