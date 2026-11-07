#!/bin/bash
# The Docker installer uses only its own clone, or else $BASE_DIR/Monero-miner-setup, cloned when
# missing, and only a git clone owned by the user or root (as root, also by the user who ran sudo)
# that no other user can write to, nor to its docker/ folder; anything else stops with one error
# line. A folder at or above the current directory that only holds the project's Docker files is
# never adopted: when it is not that clone, the run stops with one error line, before anything is
# cloned, written or started. Its own-clone functions are scripts/install.sh's, byte for byte.
# Every run is a copy of the installer in a scratch folder, under env -i, with stub docker, git and
# id; PATH holds only the stub and tool-link directories. Nothing is pulled, cloned, built or
# started, and the repository's own docker/ and scripts/ stay as they were.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
fn() { sed -n "/^function $2() {\$/,/^}\$/p" "$1"; }
for f in find_own_clone only_user_can_write; do
  first=$(fn scripts/install.sh "$f")
  [ -n "$first" ] || fail "scripts/install.sh has no $f"
  [ "$(fn scripts/docker_setup.sh "$f")" = "$first" ] || fail "scripts/docker_setup.sh: $f differs from scripts/install.sh's"
done
for s in scripts/install.sh scripts/docker_setup.sh; do
  grep -qxF 'SELF_PATH="${BASH_SOURCE[0]-}"' "$s" || fail "$s: SELF_PATH is not read from BASH_SOURCE at the top level"
done

w=$(mktemp -d "${TMPDIR:-/tmp}/docker-own-clone.XXXXXX") && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P) # the installer names folders by their physical path (macOS: /private/var)
: > "$w/stamp"
mkdir -p "$w/bin" "$w/tools" "$w/home" "$w/fetched"
for t in cat cut date dirname find head ls mktemp mv rm tr uname; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
me=$(id -un) uid=$(id -u) real_id=$(command -v id)
cat > "$w/bin/docker" <<STUB
#!/bin/bash
echo "\$*" >> "$w/docker.log"
case "\$*" in --version) echo "Docker version stub" ;; esac
exit 0
STUB
# The stub git records its arguments and lays out a clone where it was asked to.
cat > "$w/bin/git" <<STUB
#!/bin/bash
echo "\$*" >> "$w/git.log"
for last; do :; done
"$(command -v mkdir)" -p "\$last/.git" "\$last/docker" "\$last/scripts" && : > "\$last/docker/compose.yml" && : > "\$last/docker/Dockerfile"
STUB
# ID_UID: the uid id -u gives (another user's, or root's); ID_MODE=private: the user's primary
# group is their own, as Ubuntu gives each user.
cat > "$w/bin/id" <<STUB
#!/bin/bash
case \$* in
  -u) echo "\${ID_UID:-$uid}" ;;
  -gn) if [ "\${ID_MODE:-shared}" = private ]; then echo "$me"; else echo shared-group; fi ;;
  *) exec "$real_id" "\$@" ;;
esac
STUB
chmod +x "$w/bin/docker" "$w/bin/git" "$w/bin/id"
cp "$root/scripts/docker_setup.sh" "$w/fetched/docker_setup.sh"
wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge

# clone <dir>: a clone of the project, with this tree's installer in it, modes set, not left to umask.
clone() {
  mkdir -p "$1/.git" "$1/docker" "$1/scripts"
  : > "$1/docker/compose.yml"; : > "$1/docker/Dockerfile"
  cp "$root/scripts/docker_setup.sh" "$1/scripts/docker_setup.sh"
  chmod 755 "$1" "$1/docker"
}
# lookalike <dir>: a folder holding the project's two Docker files and nothing else.
lookalike() { mkdir -p "$1/docker"; : > "$1/docker/compose.yml"; : > "$1/docker/Dockerfile"; chmod 755 "$1" "$1/docker"; }

# run <name> <dir> <script> <args...>: the installer from <dir>. Sets out, err, code.
run() {
  local dir=$2 script=$3; shift 3
  rm -f "$w/docker.log" "$w/git.log"
  (cd "$dir" && env -i HOME="$w/home" PATH="$w/bin:$w/tools" ${ID_UID:+ID_UID=$ID_UID} ${ID_MODE:+ID_MODE=$ID_MODE} \
    ${SUDO:+SUDO_USER=$SUDO} "$BASH" "$script" -w "$wallet" -y "$@") > "$w/out" 2> "$w/err"
  code=$?
  out=$(sed 's/\x1b\[[0-9;]*m//g' "$w/out") err=$(sed 's/\x1b\[[0-9;]*m//g' "$w/err")
}
want() { # name, label, expected, got
  [ "$3" = "$4" ] || { echo "FAIL $1: $2"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'; rc=1; }
}
has() { printf '%s\n' "$2" | grep -qxF -- "$3" || fail "$1: no line '$3'"; }
# used <name> <clone> <info line>: the run used that clone, wrote its .env and nothing else.
used() {
  want "$1" exit 0 "$code"
  has "$1" "$out" "[  INFO   ] $3"
  has "$1" "$out" "[ SUCCESS ] Wrote $2/docker/.env (mode 0600)."
  want "$1" stderr "" "$err"
  rm -f "$2/docker/.env"
}
# refused <name> <error line> [folder that must stay as it was]: one error line, exit 1, no clone,
# only the two availability checks reached docker, no settings file written.
refused() {
  want "$1" exit 1 "$code"
  want "$1" stderr "[  ERROR  ] $2" "$err"
  [ ! -e "$w/git.log" ] || fail "$1: git ran: $(cat "$w/git.log")"
  want "$1" "docker calls" "compose version"$'\n'"--version" "$(cat "$w/docker.log" 2>/dev/null)"
  [ -z "${3:-}" ] || [ ! -e "$3/docker/.env" ] || [ -n "${KEPT:-}" ] || fail "$1: $3/docker/.env written"
}
look_line() { echo "$1 looks like a copy of Monero-miner-setup, but this run uses $2. Run again from outside $1, or, if it is your own clone, with its scripts/install.sh --docker."; }
open_line() { echo "$1 can be changed by a user other than you, so this run does not use it. Restrict it to you, or pass -d with another base directory."; }
home_clone="$w/home/Monero-miner-setup"

# The script's own clone, run from inside it or from elsewhere.
clone "$w/own"
run own-inside "$w/own" "$w/own/scripts/docker_setup.sh"
used own-inside "$w/own" "Using this script's clone at $w/own."
mkdir "$w/elsewhere"
run own-outside "$w/elsewhere" "$w/own/scripts/docker_setup.sh"
used own-outside "$w/own" "Using this script's clone at $w/own."
run own-relative "$w/own" scripts/docker_setup.sh
used own-relative "$w/own" "Using this script's clone at $w/own."
ID_MODE=private; chmod 775 "$w/own" "$w/own/docker"
run own-private-group "$w/own" "$w/own/scripts/docker_setup.sh"
used own-private-group "$w/own" "Using this script's clone at $w/own."
unset ID_MODE; chmod 755 "$w/own" "$w/own/docker"

# A folder that only looks like the project, at or above the current directory, is never adopted:
# not by a fetched copy, nor by a script read from a pipe, nor by the own clone of another copy.
# A planted docker/.env there stays unread and nothing starts, even with --autostart.
lookalike "$w/shared"
chmod 1777 "$w/shared"
printf 'WALLET_ADDRESS="planted"\n' > "$w/shared/docker/.env"
cp -p "$w/shared/docker/.env" "$w/planted.env"
mkdir -p "$w/shared/sub/dir"
run look-fetched "$w/shared" "$w/fetched/docker_setup.sh" --autostart
KEPT=1 refused look-fetched "$(look_line "$w/shared" "$home_clone")" "$w/shared"
cmp -s "$w/shared/docker/.env" "$w/planted.env" || fail "look-fetched: the planted .env changed"
run look-below "$w/shared/sub/dir" "$w/fetched/docker_setup.sh" --autostart
KEPT=1 refused look-below "$(look_line "$w/shared" "$home_clone")" "$w/shared"
(cd "$w/shared" && env -i HOME="$w/home" PATH="$w/bin:$w/tools" "$BASH" -s -- -w "$wallet" -y --autostart \
  < "$w/fetched/docker_setup.sh") > "$w/out" 2> "$w/err"
code=$? err=$(sed 's/\x1b\[[0-9;]*m//g' "$w/err")
want look-piped exit 1 "$code"
want look-piped stderr "[  ERROR  ] $(look_line "$w/shared" "$home_clone")" "$err"
run look-own "$w/shared" "$w/own/scripts/docker_setup.sh" --autostart
KEPT=1 refused look-own "$(look_line "$w/shared" "$w/own")" "$w/shared"
cmp -s "$w/shared/docker/.env" "$w/planted.env" || fail "look-own: the planted .env changed"
# A lookalike inside the own clone is nearer than the clone itself: it stops the run too.
lookalike "$w/own/sub"
run look-inside-own "$w/own/sub" "$w/own/scripts/docker_setup.sh"
refused look-inside-own "$(look_line "$w/own/sub" "$w/own")" "$w/own/sub"
rm -r "$w/own/sub"

# With no own clone and no clone in the base directory, it clones there, then writes .env there.
run fresh "$w/elsewhere" "$w/fetched/docker_setup.sh"
want fresh git "clone --recurse-submodules https://github.com/MorganKryze/Monero-miner-setup.git $home_clone" "$(cat "$w/git.log" 2>/dev/null)"
has fresh "$out" "[ SUCCESS ] Wrote $home_clone/docker/.env (mode 0600)."
want fresh exit 0 "$code"
rm -f "$home_clone/docker/.env"
# Then a re-run finds it, from outside it and from inside it.
chmod 755 "$home_clone" "$home_clone/docker"
run found "$w/elsewhere" "$w/fetched/docker_setup.sh"
used found "$home_clone" "Found existing clone at $home_clone."
run found-inside "$home_clone/docker" "$w/fetched/docker_setup.sh"
used found-inside "$home_clone" "Found existing clone at $home_clone."
mkdir -p "$w/base"; clone "$w/base/Monero-miner-setup"
run dir-flag "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
used dir-flag "$w/base/Monero-miner-setup" "Found existing clone at $w/base/Monero-miner-setup."
# A link in the base directory: the clone it points to is checked and used, by its own path.
mkdir "$w/linked"; ln -s "$w/base/Monero-miner-setup" "$w/linked/Monero-miner-setup"
run dir-link "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/linked"
used dir-link "$w/base/Monero-miner-setup" "Found existing clone at $w/base/Monero-miner-setup."

# A clone in the base directory that is not a git clone, or that someone else can change.
mkdir -p "$w/nogit/Monero-miner-setup/docker"
run not-a-clone "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/nogit"
refused not-a-clone "$w/nogit/Monero-miner-setup is not a git clone. Move it away, or pass -d with another base directory." "$w/nogit/Monero-miner-setup"
c="$w/base/Monero-miner-setup"
for m in 777 1777 775 757; do
  chmod "$m" "$c"
  run "root-$m" "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
  refused "root-$m" "$(open_line "$c")" "$c"
  chmod 755 "$c"
  chmod "$m" "$c/docker"
  run "docker-$m" "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
  refused "docker-$m" "$(open_line "$c/docker")" "$c"
  chmod 755 "$c/docker"
done
ID_MODE=private; chmod 775 "$c" "$c/docker"
run private-group "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
used private-group "$c" "Found existing clone at $c."
unset ID_MODE; chmod 755 "$c" "$c/docker"
# Owned by another user (id -u says 54321): refused, and the sudo user counts only for root.
ID_UID=54321
run other-owner "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
refused other-owner "$(open_line "$c")" "$c"
SUDO=$me run other-owner-sudo-user "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
refused other-owner-sudo-user "$(open_line "$c")" "$c"
ID_UID=0
run root-no-sudo "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
refused root-no-sudo "$(open_line "$c")" "$c"
SUDO=$me run root-sudo "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
used root-sudo "$c" "Found existing clone at $c."
ID_UID=54321 run own-other-owner "$w/own" "$w/own/scripts/docker_setup.sh"
refused own-other-owner "$(open_line "$w/own")" "$w/own"
unset ID_UID
# An own clone others can write to is not the script's own: it stops when run from inside it, and
# clones a fresh one when run from elsewhere.
chmod 777 "$w/own"
run own-open-inside "$w/own" "$w/own/scripts/docker_setup.sh"
refused own-open-inside "$(look_line "$w/own" "$home_clone")" "$w/own"
rm -rf "$home_clone"
run own-open-outside "$w/elsewhere" "$w/own/scripts/docker_setup.sh"
want own-open-outside git "clone --recurse-submodules https://github.com/MorganKryze/Monero-miner-setup.git $home_clone" "$(cat "$w/git.log" 2>/dev/null)"
[ ! -e "$w/own/docker/.env" ] || fail "own-open-outside: the open clone's .env written"
chmod 755 "$w/own"

# Nothing above ran in the repository itself.
changed=$(find "$root/docker" "$root/scripts" -newer "$w/stamp" 2>&1)
want real-tree "changed in the repository" "" "$changed"
[ "$rc" -eq 0 ] && echo "PASS docker-own-clone"
exit "$rc"
