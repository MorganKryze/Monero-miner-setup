#!/bin/bash
# A re-run of the native installer reuses Monero-miner-setup in its base directory only when it is
# a git clone in which every path belongs to the user or root (as root, also to the user who ran
# sudo) and none can be changed by another user, the clone's folder carrying no ACL; anything else
# stops with one error line before anything is cloned, built, written or set up, and a fresh clone
# gets the same check. So does a clone found again where the install decides to reuse it. A link at
# the clone's path is refused, and so is a base directory, or one above it, another user can change
# (a sticky one passes). The whole runs are a copy of the installer in its own scratch clone with a
# fixture toolbox, under env -i, with stub id, find, git and sleep; PATH holds only the stub and
# tool-link directories, with no curl and no make, so a run the check lets through stops at the
# dependency check. The root, fresh-clone and re-check cases run the functions taken from scripts/install.sh.
# Every fixture mode is set, not left to the umask. Nothing is cloned, built, installed or started.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d "${TMPDIR:-/tmp}/native-clone-trust.XXXXXX") && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'chmod -R u+rwx -- "$w" 2>/dev/null; rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
: > "$w/stamp"
mkdir -p "$w/bin" "$w/tools" "$w/home" "$w/base"
chmod 755 "$w/home" "$w/base"
for t in awk cat cut dirname grep head ls mkdir sed tr uname wc; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
me=$(id -un) uid=$(id -u) real_id=$(command -v id) real_find=$(command -v find)
# ID_UID: the uid id -u gives; ID_MODE=private: the user's primary group is their own (Ubuntu).
cat > "$w/bin/id" <<STUB
#!/bin/bash
case \$* in
  -u) echo "\${ID_UID:-$uid}" ;;
  -gn) if [ "\${ID_MODE:-shared}" = private ]; then echo "$me"; else echo shared-group; fi ;;
  *) exec "$real_id" "\$@" ;;
esac
STUB
# OTHER_OWNS=<path>: find's owner test reports that path, as if another user owned it.
cat > "$w/bin/find" <<STUB
#!/bin/bash
if [ -n "\${OTHER_OWNS:-}" ]; then
  for a in "\$@"; do [ "\$a" = -user ] && { echo "\$OTHER_OWNS"; exit 0; }; done
fi
exec "$real_find" "\$@"
STUB
# The stub git records its arguments and lays out a clone where it was asked to, its folders at
# GIT_MODE (755 unless set), its files 644.
cat > "$w/bin/git" <<STUB
#!/bin/bash
echo "\$*" >> "$w/git.log"
for last; do :; done
"$(command -v mkdir)" -p "\$last/.git" "\$last/scripts" && : > "\$last/Makefile" &&
  "$(command -v chmod)" "\${GIT_MODE:-755}" "\$last" "\$last/.git" "\$last/scripts" && "$(command -v chmod)" 644 "\$last/Makefile"
STUB
printf '#!/bin/sh\nexit 0\n' > "$w/bin/sleep"
chmod 755 "$w/bin/id" "$w/bin/find" "$w/bin/git" "$w/bin/sleep"
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

# clone <dir>: a built-looking clone, every mode set.
clone() {
  mkdir -p "$1/.git/hooks" "$1/scripts" "$1/templates" "$1/dependencies/xmrig/src" "$1/build-xmrig"
  : > "$1/Makefile"; : > "$1/.git/config"; : > "$1/scripts/setup_service_debian.sh"
  : > "$1/dependencies/xmrig/src/xmrig.cpp"; : > "$1/build-xmrig/xmrig"
  ln -s build-xmrig/xmrig "$1/xmrig"
  find "$1" -type d -exec chmod 755 {} +
  find "$1" -type f -exec chmod 644 {} +
}
c="$w/base/Monero-miner-setup"
remedy="Move $c away and run the installer again, or pass -d with another base directory."
open_line() { echo "[ERROR] $1 can be changed by a user other than you, so this run does not use $c. $remedy"; }
owner_line() { echo "[ERROR] $1 belongs to another user, so this run does not use $c. $remedy"; }
base_line="[INFO] Using base directory: $w/base."
went_on="[ERROR] This script requires 'curl' utility to work correctly."
env_vars() {
  printf '%s\n' HOME="$w/home" PATH="$w/bin:$w/tools" ${ID_UID:+ID_UID=$ID_UID} ${ID_MODE:+ID_MODE=$ID_MODE} \
    ${SUDO:+SUDO_USER=$SUDO} ${OTHER_OWNS:+OTHER_OWNS=$OTHER_OWNS} ${GIT_MODE:+GIT_MODE=$GIT_MODE}
}
# run <name>: the whole installer with -d $w/base. Sets out, err, code; snap: the clone before.
run() {
  rm -f "$w/git.log"
  snap=$(ls -laR "$c" 2>/dev/null)
  local vars=(); while IFS= read -r v; do vars+=("$v"); done < <(env_vars)
  (cd "$w/home" && env -i "${vars[@]}" "$BASH" "$r/scripts/install.sh" -w "$wallet" -y -d "${DIR:-$w/base}") > "$w/out" 2> "$w/err"
  code=$?; out=$(cat "$w/out"); err=$(cat "$w/err")
}
want() { # name, label, expected, got
  [ "$3" = "$4" ] || { echo "FAIL $1: $2"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'; rc=1; }
}
# refused <name> <error line>: that one line on stderr, exit 1, no git, the clone unchanged.
refused() {
  want "$1" exit 1 "$code"
  want "$1" stderr "$base_line"$'\n'"$2" "$err"
  [ ! -e "$w/git.log" ] || fail "$1: git ran: $(cat "$w/git.log")"
  want "$1" "clone unchanged" "$snap" "$(ls -laR "$c" 2>/dev/null)"
}
# kept <name>: the check let the clone through and the run went on to the dependency check.
kept() {
  want "$1" exit 1 "$code"
  want "$1" stderr "$base_line"$'\n'"$went_on" "$err"
  [ ! -e "$w/git.log" ] || fail "$1: git ran: $(cat "$w/git.log")"
}

clone "$c"
run clean; kept clean
mkdir -p "$w/base/empty" && chmod 755 "$w/base/empty" && rmdir "$w/base/empty"
mv "$c/.git" "$w/git.away"
run no-git; refused no-git "[ERROR] $c is not a git clone, so this run does not use it. $remedy"
mv "$w/git.away" "$c/.git"
# Any path others or a shared group can write, at any depth, is named; links count by owner only.
for p in "$c" "$c/Makefile" "$c/.git/config" "$c/.git/hooks" "$c/scripts" "$c/dependencies/xmrig/src/xmrig.cpp" "$c/build-xmrig"; do
  for m in 666:646 777:757 group:g; do
    if [ -d "$p" ]; then mode=${m%%:*}; [ "$mode" = 666 ] && mode=757; else mode=${m%%:*}; [ "$mode" = 777 ] && mode=646; fi
    [ "$m" = group:g ] && { if [ -d "$p" ]; then mode=775; else mode=664; fi; }
    chmod "$mode" "$p"
    run "open $p $mode"; refused "open $p $mode" "$(open_line "$p")"
    if [ -d "$p" ]; then chmod 755 "$p"; else chmod 644 "$p"; fi
  done
done
chmod 1777 "$c/templates"
run sticky; refused sticky "$(open_line "$c/templates")"
chmod 755 "$c/templates"
# The user's own private group (Ubuntu's umask 0002) may write; a shared one may not (above).
chmod 775 "$c" "$c/scripts"; chmod 664 "$c/Makefile"
ID_MODE=private run private; kept private
chmod 755 "$c" "$c/scripts"; chmod 644 "$c/Makefile"
[ "$(uname -s)" = Darwin ] && chmod -h 777 "$c/xmrig"
run link-inside; kept link-inside
# Owners: another user owns the tree (id -u says 54321), or one path deep in it.
ID_UID=54321 run other-owner; refused other-owner "$(owner_line "$c")"
OTHER_OWNS="$c/dependencies/xmrig/src/xmrig.cpp" run deep-owner; refused deep-owner "$(owner_line "$c/dependencies/xmrig/src/xmrig.cpp")"
# A folder the run cannot read whole is refused, not skipped.
chmod 000 "$c/build-xmrig"
run unreadable; refused unreadable "[ERROR] $c cannot be read whole, so this run does not use it. $remedy"
chmod 755 "$c/build-xmrig"
# A link at the clone's path is refused, even to a good clone: later steps would act through it.
mv "$c" "$w/real"; ln -s "$w/real" "$c"
run link-path; refused link-path "[ERROR] $c is a link, so this run does not use it. Pass -d with the folder it points to."
rm "$c"; mv "$w/real" "$c"
# The base directory: another user could swap the clone in it, unless it is sticky.
parent_line="[ERROR] $w/base can be changed by a user other than you, so this run does not use $c. Pass -d with a directory only you can change."
chmod 0777 "$w/base"; run parent-open; refused parent-open "$parent_line"
chmod 1777 "$w/base"; run parent-sticky; kept parent-sticky
chmod 0775 "$w/base"; run parent-group; refused parent-group "$parent_line"
# The user's own private group may write the base directory too (mkdir under Ubuntu's umask 0002).
ID_MODE=private run parent-private; kept parent-private
chmod 0755 "$w/base"
# -d through a link in a folder anyone can write: the run checks and uses the real path, so a link
# re-pointed after the check changes nothing.
mkdir "$w/open" && chmod 0777 "$w/open" && ln -s "$w/base" "$w/open/lb"
resolved="[INFO] Using base directory: $w/open/lb."$'\n'"[INFO] Resolved to $w/base."
DIR="$w/open/lb" run link-base; want link-base exit 1 "$code"; want link-base stderr "$resolved"$'\n'"$went_on" "$err"
chmod 666 "$c/Makefile"
DIR="$w/open/lb" run link-base-open; want link-base-open exit 1 "$code"
want link-base-open stderr "$resolved"$'\n'"$(open_line "$c/Makefile")" "$err"
[ ! -e "$w/git.log" ] || fail "link-base-open: git ran: $(cat "$w/git.log")"
chmod 644 "$c/Makefile"; rm "$w/open/lb"; rmdir "$w/open"
# A directory above the base directory counts the same.
chmod 0777 "$w"; run parent-above
refused parent-above "[ERROR] $w can be changed by a user other than you, so this run does not use $c. Pass -d with a directory only you can change."
chmod 0700 "$w"
if [ "$(uname -s)" = Darwin ]; then
  chmod +a "everyone allow add_file" "$c"
  run acl; refused acl "$(open_line "$c")"
  chmod -N "$c"
fi
# Nothing at the path: the run goes on (it would clone there).
mv "$c" "$w/away"; run missing; kept missing; mv "$w/away" "$c"

# Functions taken from scripts/install.sh: root, sudo and a fresh clone.
fns="only_user_can_write check_base_clone clone_repository check_repo_exists install_project"
{
  printf 'info() { echo "[INFO] $1"; }\nsuccess() { echo "[SUCCESS] $1"; }\nwarning() { echo "[WARNING] $1"; }\nerror() { echo "[ERROR] $1" >&2; return 1; }\n'
  # Every step install_project takes after it decides to clone or reuse: one ran if STEP shows.
  for f in check_if_built configs_exist service_is_set_up set_script_permissions generate_config_files build_project setup_service; do
    printf '%s() { echo "STEP %s" >&2; }\n' "$f" "$f"
  done
  # appear: the path passes empty, then a clone with a Makefile anyone can write turns up there.
  printf 'appear() { check_base_clone "$BASE_DIR/$REPO_NAME" || return 9; mkdir -p "$BASE_DIR/$REPO_NAME/.git" && %q 755 "$BASE_DIR/$REPO_NAME" "$BASE_DIR/$REPO_NAME/.git" && : > "$BASE_DIR/$REPO_NAME/Makefile" && %q 666 "$BASE_DIR/$REPO_NAME/Makefile" && install_project; }\n' "$(command -v chmod)" "$(command -v chmod)"
  for f in $fns; do sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/install.sh"; done
  printf 'BASE_DIR=%q REPO_NAME=Monero-miner-setup REPO_URL=https://example.invalid/repo.git\n"$@"\n' "$w/base"
} > "$w/drive.sh"
for f in $fns; do grep -qx "function $f() {" "$w/drive.sh" || fail "no function $f in scripts/install.sh"; done
call() { # name, function and arguments: sets out, err, code
  rm -f "$w/git.log"
  local vars=(); while IFS= read -r v; do vars+=("$v"); done < <(env_vars)
  local name=$1; shift
  (cd "$w/home" && env -i "${vars[@]}" "$BASH" "$w/drive.sh" "$@") > "$w/out" 2> "$w/err"
  code=$?; out=$(cat "$w/out"); err=$(cat "$w/err")
}
ID_UID=0 call root-alone check_base_clone "$c"; want root-alone stderr "$(owner_line "$c")" "$err"
ID_UID=0 SUDO=$me call root-sudo check_base_clone "$c"; want root-sudo exit 0 "$code"
# As root, the sudo user's clone their group can also write is still refused (that group is
# root's own lookup's business, not this check's: the root walk refuses it first on Linux).
chmod 775 "$c" "$c/scripts"; chmod 664 "$c/Makefile"
ID_UID=0 SUDO=$me call root-sudo-group check_base_clone "$c"; want root-sudo-group stderr "$(open_line "$c")" "$err"
chmod 755 "$c" "$c/scripts"; chmod 644 "$c/Makefile"
# The walk from / down: the first directory that belongs to neither id -u (54321) nor root.
d= p="$w/base" first=
while :; do
  [ -n "$(find "$d/" -maxdepth 0 -user 0 -print)" ] || { first=${d:-/}; break; }
  [ "${d:-/}" = "$p" ] && break
  rest=${p#"$d"/}; d=$d/${rest%%/*}
done
[ -n "$first" ] || fail "parent-owner: root owns every directory down to $w/base"
ID_UID=54321 call parent-owner check_base_clone "$w/base/none"
want parent-owner exit 1 "$code"
want parent-owner stderr "[ERROR] $first can be changed by a user other than you, so this run does not use $w/base/none. Pass -d with a directory only you can change." "$err"
# Every directory above the base directory is read, not only the base directory itself.
mkdir "$w/base/deep" && chmod 755 "$w/base/deep" && chmod 0777 "$w"
call parent-deep check_base_clone "$w/base/deep/none"
want parent-deep exit 1 "$code"
want parent-deep stderr "[ERROR] $w can be changed by a user other than you, so this run does not use $w/base/deep/none. Pass -d with a directory only you can change." "$err"
chmod 0700 "$w"; rmdir "$w/base/deep"
mv "$c" "$w/away"
GIT_MODE=755 call fresh clone_repository; want fresh exit 0 "$code"; want fresh stderr "" "$err"
rm -rf "$c"
GIT_MODE=775 call fresh-open clone_repository
want fresh-open exit 1 "$code"
want fresh-open stderr "[ERROR] $c can be changed by a user other than you, so this run does not use $c. This run has just cloned it, so your umask is the likely cause: remove $c, run umask 022, and run the installer again." "$err"
grep -qxF "clone --recurse-submodules https://example.invalid/repo.git $c" "$w/git.log" || fail "fresh-open: git did not clone into $c"
rm -rf "$c"
call appeared appear
want appeared exit 1 "$code"
want appeared stderr "$(open_line "$c/Makefile")" "$err"
rm -rf "$c"; mv "$w/away" "$c"

# Nothing above ran in, or wrote to, the repository itself.
changed=$(find "$root/scripts" "$root/templates" "$root/tests" -newer "$w/stamp" 2>/dev/null)
[ -z "$changed" ] || fail "the repository changed: $changed"
[ "$rc" -eq 0 ] && echo "PASS native-clone-trust"
exit "$rc"
