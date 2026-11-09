#!/bin/bash
# The Docker installer uses only its own clone, or else $BASE_DIR/Monero-miner-setup, cloned when
# missing, and only a git clone owned by the user or root (as root, also by the user who ran sudo)
# that no other user can write to, nor to its docker/ folder, its Compose files or its Dockerfile;
# anything else stops with one error line. A folder at or above the current directory that only holds the project's Docker files is
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
# The stub git records its arguments and lays out a clone where it was asked to, its root and
# docker/ at mode GIT_MODE (755 unless set).
cat > "$w/bin/git" <<STUB
#!/bin/bash
echo "\$*" >> "$w/git.log"
for last; do :; done
"$(command -v mkdir)" -p "\$last/.git" "\$last/docker" "\$last/scripts" && : > "\$last/docker/compose.yml" && : > "\$last/docker/Dockerfile" &&
  "$(command -v chmod)" "\${GIT_MODE:-755}" "\$last" "\$last/docker" &&
  "$(command -v chmod)" 644 "\$last/docker/compose.yml" "\$last/docker/Dockerfile"
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
# OTHER_OWNS=<path>: find's owner test says another user owns that path (no chown needed).
real_find=$(command -v find)
cat > "$w/bin/find" <<STUB
#!/bin/bash
if [ -n "\${OTHER_OWNS:-}" ] && [ "\$2" = "\$OTHER_OWNS" ]; then
  for a in "\$@"; do [ "\$a" = -user ] && exit 0; done
fi
exec "$real_find" "\$@"
STUB
chmod +x "$w/bin/docker" "$w/bin/git" "$w/bin/id" "$w/bin/find"
cp "$root/scripts/docker_setup.sh" "$w/fetched/docker_setup.sh"
wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge

# clone <dir>: a clone of the project, with this tree's installer in it, modes set, not left to umask.
clone() {
  mkdir -p "$1/.git" "$1/docker" "$1/scripts"
  : > "$1/docker/compose.yml"; : > "$1/docker/compose.vpn.yml"; : > "$1/docker/Dockerfile"
  cp "$root/scripts/docker_setup.sh" "$1/scripts/docker_setup.sh"
  chmod 755 "$1" "$1/docker"
  chmod 644 "$1/docker/compose.yml" "$1/docker/compose.vpn.yml" "$1/docker/Dockerfile"
}
# lookalike <dir>: a folder holding the project's two Docker files and nothing else.
lookalike() { mkdir -p "$1/docker"; : > "$1/docker/compose.yml"; : > "$1/docker/Dockerfile"; chmod 755 "$1" "$1/docker"; chmod 644 "$1/docker/compose.yml" "$1/docker/Dockerfile"; }

# run <name> <dir> <script> <args...>: the installer from <dir>. Sets out, err, code. LPWD: the
# logical current directory the shell passes on, as when you cd through a link.
run() {
  local dir=$2 script=$3; shift 3
  rm -f "$w/docker.log" "$w/git.log"
  (cd "$dir" && env -i HOME="$w/home" PATH="${PATH_HEAD:+$PATH_HEAD:}$w/bin:$w/tools" ${ID_UID:+ID_UID=$ID_UID} ${ID_MODE:+ID_MODE=$ID_MODE} \
    ${SUDO:+SUDO_USER=$SUDO} ${LPWD:+PWD=$LPWD} ${GIT_MODE:+GIT_MODE=$GIT_MODE} ${OTHER_OWNS:+OTHER_OWNS=$OTHER_OWNS} "$BASH" --norc --noprofile "$script" -w "$wallet" -y "$@") > "$w/out" 2> "$w/err"
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
# refused <name> <error line> [folder that must stay as it was]: one error line, exit 1, no clone
# (CLONED=<dir>: only the clone into <dir>), only the two availability checks reached docker, no
# settings file written.
refused() {
  want "$1" exit 1 "$code"
  want "$1" stderr "[  ERROR  ] $2" "$err"
  if [ -n "${CLONED:-}" ]; then
    want "$1" git "clone --recurse-submodules https://github.com/MorganKryze/Monero-miner-setup.git $CLONED" "$(cat "$w/git.log" 2>/dev/null)"
  else
    [ ! -e "$w/git.log" ] || fail "$1: git ran: $(cat "$w/git.log")"
  fi
  want "$1" "docker calls" "compose version"$'\n'"--version" "$(cat "$w/docker.log" 2>/dev/null)"
  [ -z "${3:-}" ] || [ ! -e "$3/docker/.env" ] || [ -n "${KEPT:-}" ] || fail "$1: $3/docker/.env written"
}
# A lookalike's own installer is named only when it is a git clone its own run would accept.
look_line() { echo "$1 looks like a copy of Monero-miner-setup, but this run uses $2. Run again from outside $1, or, if it is your own clone, with its scripts/install.sh --docker."; }
# With a docker/.env there, a run from outside it would start a second set of settings: only the
# install.sh remedy is offered.
kept_line() { echo "$1 looks like a copy of Monero-miner-setup, but this run uses $2. If it is your own clone, run its scripts/install.sh --docker."; }
# Any other lookalike (no .git, another user's, or open to others) may hold files someone else
# planted or changed: no remedy runs anything from it.
foreign_line() { echo "$1 looks like a copy of Monero-miner-setup, but this run uses $2. It is not a git clone only you can change: run again from outside $1."; }
# With a docker/.env there, a fresh clone is the remedy.
foreign_kept_line() { echo "$1 looks like a copy of Monero-miner-setup, but this run uses $2. It is not a git clone only you can change: if it is your own, move it away and clone this project again."; }
mode_line() { echo "$1 is this script's clone, but a user other than you can change it, so this run does not use it. Its files may have been changed: move it away and clone this project again."; }
# open_line <checked path> <clone>
open_line() { echo "$1 can be changed by a user other than you, so this run does not use it. The clone's files may have been changed: move $2 away and clone this project again, or pass -d with another base directory."; }
# With settings in it, a run in another base directory would start a fresh set under the same
# Compose project: only the fresh clone is offered.
settings_line() { echo "$1 can be changed by a user other than you, so this run does not use it. The clone's files and settings may have been changed: move $2 away and clone this project again."; }
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
# Reached through a link, with the shell's PWD naming the link: the current directory is matched by
# its physical path, so the own clone is still the one in use.
ln -s "$w/own" "$w/own-link"
LPWD="$w/own-link" run own-via-link "$w/own-link" "$w/own/scripts/docker_setup.sh"
used own-via-link "$w/own" "Using this script's clone at $w/own."
# Its docker/ folder, where Compose reads its files, open to others: refused, nothing written.
chmod 777 "$w/own/docker"
run own-docker-open "$w/own" "$w/own/scripts/docker_setup.sh"
refused own-docker-open "$(open_line "$w/own/docker" "$w/own")" "$w/own"
chmod 755 "$w/own/docker"

# A folder that only looks like the project, at or above the current directory, is never adopted:
# not by a fetched copy, nor by a script read from a pipe, nor by the own clone of another copy.
# A planted docker/.env there stays unread and nothing starts, even with --autostart.
lookalike "$w/shared"
chmod 1777 "$w/shared"
printf 'WALLET_ADDRESS="planted"\n' > "$w/shared/docker/.env"
cp -p "$w/shared/docker/.env" "$w/planted.env"
mkdir -p "$w/shared/sub/dir"
run look-fetched "$w/shared" "$w/fetched/docker_setup.sh" --autostart
KEPT=1 refused look-fetched "$(foreign_kept_line "$w/shared" "$home_clone")" "$w/shared"
cmp -s "$w/shared/docker/.env" "$w/planted.env" || fail "look-fetched: the planted .env changed"
run look-below "$w/shared/sub/dir" "$w/fetched/docker_setup.sh" --autostart
KEPT=1 refused look-below "$(foreign_kept_line "$w/shared" "$home_clone")" "$w/shared"
(cd "$w/shared" && env -i HOME="$w/home" PATH="$w/bin:$w/tools" "$BASH" --norc --noprofile -s -- -w "$wallet" -y --autostart \
  < "$w/fetched/docker_setup.sh") > "$w/out" 2> "$w/err"
code=$? err=$(sed 's/\x1b\[[0-9;]*m//g' "$w/err")
want look-piped exit 1 "$code"
want look-piped stderr "[  ERROR  ] $(foreign_kept_line "$w/shared" "$home_clone")" "$err"
run look-own "$w/shared" "$w/own/scripts/docker_setup.sh" --autostart
KEPT=1 refused look-own "$(foreign_kept_line "$w/shared" "$w/own")" "$w/shared"
cmp -s "$w/shared/docker/.env" "$w/planted.env" || fail "look-own: the planted .env changed"
# A /tmp-like folder with a planted installer: no line names it, with or without a planted .env.
mkdir -p "$w/shared/scripts"
printf '#!/bin/bash\n: > "%s/planted-ran"\n' "$w" > "$w/shared/scripts/install.sh"
chmod 755 "$w/shared/scripts/install.sh"
run look-tmp-planted "$w/shared" "$w/fetched/docker_setup.sh" --autostart
KEPT=1 refused look-tmp-planted "$(foreign_kept_line "$w/shared" "$home_clone")" "$w/shared"
mv "$w/shared/docker/.env" "$w/shared.env"
run look-tmp-planted-no-env "$w/shared" "$w/fetched/docker_setup.sh" --autostart
refused look-tmp-planted-no-env "$(foreign_line "$w/shared" "$home_clone")" "$w/shared"
mv "$w/shared.env" "$w/shared/docker/.env"
[ ! -e "$w/planted-ran" ] || fail "look-tmp-planted: the planted installer ran"
# Another user's clone (id -u says 54321), open to all or closed: no line names its installer.
clone "$w/other-clone"
printf 'WORKER_NAME="rig8"\n' > "$w/other-clone/docker/.env"
chmod 600 "$w/other-clone/docker/.env"
chmod 777 "$w/other-clone" "$w/other-clone/docker"
ID_UID=54321 run look-other-open "$w/other-clone" "$w/fetched/docker_setup.sh"
KEPT=1 refused look-other-open "$(foreign_kept_line "$w/other-clone" "$home_clone")" "$w/other-clone"
chmod 755 "$w/other-clone" "$w/other-clone/docker"
ID_UID=54321 run look-other-closed "$w/other-clone" "$w/fetched/docker_setup.sh"
KEPT=1 refused look-other-closed "$(foreign_kept_line "$w/other-clone" "$home_clone")" "$w/other-clone"
# Each owner test on its own: the folder, or only its docker/, another user's.
OTHER_OWNS="$w/other-clone/" run look-other-owns-root "$w/other-clone" "$w/fetched/docker_setup.sh"
KEPT=1 refused look-other-owns-root "$(foreign_kept_line "$w/other-clone" "$home_clone")" "$w/other-clone"
OTHER_OWNS="$w/other-clone/docker/" run look-other-owns-docker "$w/other-clone" "$w/fetched/docker_setup.sh"
KEPT=1 refused look-other-owns-docker "$(foreign_kept_line "$w/other-clone" "$home_clone")" "$w/other-clone"
# The user's own closed git clone, other than the one in use: its installer is the remedy.
run look-clone "$w/other-clone" "$w/fetched/docker_setup.sh"
KEPT=1 refused look-clone "$(kept_line "$w/other-clone" "$home_clone")" "$w/other-clone"
rm "$w/other-clone/docker/.env"
run look-clone-no-env "$w/other-clone" "$w/fetched/docker_setup.sh"
refused look-clone-no-env "$(look_line "$w/other-clone" "$home_clone")" "$w/other-clone"
rm -rf "$w/other-clone"
clone "$w/open-clone"
printf 'WORKER_NAME="rig9"\n' > "$w/open-clone/docker/.env"
chmod 600 "$w/open-clone/docker/.env"
chmod 777 "$w/open-clone"
run look-open-clone "$w/open-clone" "$w/fetched/docker_setup.sh"
KEPT=1 refused look-open-clone "$(foreign_kept_line "$w/open-clone" "$home_clone")" "$w/open-clone"
chmod 755 "$w/open-clone"; chmod 777 "$w/open-clone/docker"
run look-open-clone-docker "$w/open-clone" "$w/fetched/docker_setup.sh"
KEPT=1 refused look-open-clone-docker "$(foreign_kept_line "$w/open-clone" "$home_clone")" "$w/open-clone"
rm -rf "$w/open-clone"
# A lookalike inside the own clone is nearer than the clone itself: it stops the run too.
lookalike "$w/own/sub"
run look-inside-own "$w/own/sub" "$w/own/scripts/docker_setup.sh"
refused look-inside-own "$(foreign_line "$w/own/sub" "$w/own")" "$w/own/sub"
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
# A fresh clone is checked like any other before anything is written into it or started from it:
# laid out open to others (umask 0000, or an empty folder someone else made first), or owned by
# another user.
for case in fresh-open fresh-other-owner; do
  mkdir "$w/$case"; c="$w/$case/Monero-miner-setup"
  if [ "$case" = fresh-open ]; then GIT_MODE=777; else ID_UID=54321; fi
  run "$case" "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/$case" --autostart
  unset GIT_MODE ID_UID
  CLONED=$c refused "$case" "$(open_line "$c" "$c")" "$c"
done
# A base directory not made yet, under a link: the fresh clone is used by its physical path.
mkdir "$w/real"; ln -s "$w/real" "$w/to-real"
run fresh-link "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/to-real/new"
want fresh-link exit 0 "$code"
has fresh-link "$out" "[ SUCCESS ] Wrote $w/real/new/Monero-miner-setup/docker/.env (mode 0600)."
want fresh-link stderr "" "$err"
# A link in the base directory: the clone it points to is checked and used, by its own path.
mkdir "$w/linked"; ln -s "$w/base/Monero-miner-setup" "$w/linked/Monero-miner-setup"
run dir-link "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/linked"
used dir-link "$w/base/Monero-miner-setup" "Found existing clone at $w/base/Monero-miner-setup."
# Run from inside the base clone reached through that link, with the shell's PWD naming the link.
LPWD="$w/linked/Monero-miner-setup" run base-via-link "$w/linked/Monero-miner-setup" "$w/fetched/docker_setup.sh" -d "$w/base"
used base-via-link "$w/base/Monero-miner-setup" "Found existing clone at $w/base/Monero-miner-setup."

# A clone in the base directory that is not a git clone, or that someone else can change.
mkdir -p "$w/nogit/Monero-miner-setup/docker"
run not-a-clone "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/nogit"
refused not-a-clone "$w/nogit/Monero-miner-setup is not a git clone. Move it away, or pass -d with another base directory." "$w/nogit/Monero-miner-setup"
c="$w/base/Monero-miner-setup"
for m in 777 1777 775 757; do
  chmod "$m" "$c"
  run "root-$m" "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
  refused "root-$m" "$(open_line "$c" "$c")" "$c"
  chmod 755 "$c"
  chmod "$m" "$c/docker"
  run "docker-$m" "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
  refused "docker-$m" "$(open_line "$c/docker" "$c")" "$c"
  chmod 755 "$c/docker"
done
# The files the daemon reads, Compose's and the Dockerfile's, open to others in a clone whose
# folders are not: refused, so no one else can add a privileged service or drop the image's user.
for f in compose.yml compose.vpn.yml Dockerfile; do
  chmod 666 "$c/docker/$f"
  run "file-open-$f" "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base" --autostart
  refused "file-open-$f" "$(open_line "$c/docker/$f" "$c")" "$c"
  chmod 644 "$c/docker/$f"
done
chmod 666 "$w/own/docker/compose.yml"
run own-file-open "$w/own" "$w/own/scripts/docker_setup.sh" --autostart
refused own-file-open "$(open_line "$w/own/docker/compose.yml" "$w/own")" "$w/own"
chmod 644 "$w/own/docker/compose.yml"
# Through a link, the file Compose reads is the one checked, open or not.
: > "$w/open.yml"; chmod 666 "$w/open.yml"
mv "$c/docker/compose.yml" "$w/compose.yml.real"; ln -s "$w/open.yml" "$c/docker/compose.yml"
run file-open-link "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
refused file-open-link "$(open_line "$c/docker/compose.yml" "$c")" "$c"
chmod 644 "$w/open.yml"
run file-closed-link "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
used file-closed-link "$c" "Found existing clone at $c."
rm "$c/docker/compose.yml"; mv "$w/compose.yml.real" "$c/docker/compose.yml"
# A clone holding settings that someone else can change: refused with no -d remedy, its .env kept.
printf 'WORKER_NAME="rig7"\n' > "$c/docker/.env"
cp -p "$c/docker/.env" "$w/settings.env"
chmod 775 "$c/docker"
run settings-docker-open "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base" --autostart
KEPT=1 refused settings-docker-open "$(settings_line "$c/docker" "$c")" "$c"
chmod 755 "$c/docker"; chmod 777 "$c"
run settings-root-open "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base" --autostart
KEPT=1 refused settings-root-open "$(settings_line "$c" "$c")" "$c"
chmod 755 "$c"; chmod 666 "$c/docker/compose.yml"
run settings-file-open "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base" --autostart
KEPT=1 refused settings-file-open "$(settings_line "$c/docker/compose.yml" "$c")" "$c"
chmod 644 "$c/docker/compose.yml"
cmp -s "$c/docker/.env" "$w/settings.env" || fail "settings: the .env changed"
rm "$c/docker/.env" "$w/settings.env"
ID_MODE=private; chmod 664 "$c/docker/compose.yml"
run file-private-group "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
used file-private-group "$c" "Found existing clone at $c."
unset ID_MODE; chmod 644 "$c/docker/compose.yml"
# Each part of the file check on its own: shared-group write, world write under a private group,
# a dangling link, and (macOS) an ACL.
chmod 664 "$c/docker/compose.yml"
run file-group "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base" --autostart
refused file-group "$(open_line "$c/docker/compose.yml" "$c")" "$c"
ID_MODE=private; chmod 666 "$c/docker/compose.yml"
run file-world-private "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base" --autostart
refused file-world-private "$(open_line "$c/docker/compose.yml" "$c")" "$c"
unset ID_MODE; chmod 644 "$c/docker/compose.yml"
mv "$c/docker/compose.vpn.yml" "$w/vpn.real"; ln -s "$w/nowhere.yml" "$c/docker/compose.vpn.yml"
run file-dangling "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base" --autostart
refused file-dangling "$(open_line "$c/docker/compose.vpn.yml" "$c")" "$c"
rm "$c/docker/compose.vpn.yml"; mv "$w/vpn.real" "$c/docker/compose.vpn.yml"
if [ "$(uname -s)" = Darwin ]; then
  chmod +a "everyone allow write" "$c/docker/Dockerfile"
  run file-acl "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base" --autostart
  refused file-acl "$(open_line "$c/docker/Dockerfile" "$c")" "$c"
  chmod -N "$c/docker/Dockerfile"
fi
# A GNU ls ahead of /bin in PATH (Homebrew's gnubin, nix) has no -e: the folders' and the files'
# ACLs are still read, with the system's own ls, and a clone that has none is used.
mkdir "$w/gnu" && printf '#!/bin/bash\nfor a; do case $a in --) break ;; -*e*) echo "ls: invalid option -- %s" >&2; exit 2 ;; esac; done\nexec %q "$@"\n' "'e'" "$(command -v ls)" > "$w/gnu/ls"
chmod 755 "$w/gnu" "$w/gnu/ls"
PATH_HEAD="$w/gnu" run gnu-ls "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
used gnu-ls "$c" "Found existing clone at $c."
if [ "$(uname -s)" = Darwin ]; then
  chmod +a "everyone allow write" "$c/docker/Dockerfile"
  PATH_HEAD="$w/gnu" run gnu-ls-acl "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base" --autostart
  refused gnu-ls-acl "$(open_line "$c/docker/Dockerfile" "$c")" "$c"
  chmod -N "$c/docker/Dockerfile"
fi
ID_MODE=private; chmod 775 "$c" "$c/docker"
run private-group "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
used private-group "$c" "Found existing clone at $c."
unset ID_MODE; chmod 755 "$c" "$c/docker"
# Owned by another user (id -u says 54321): refused, and the sudo user counts only for root.
ID_UID=54321
run other-owner "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
refused other-owner "$(open_line "$c" "$c")" "$c"
SUDO=$me run other-owner-sudo-user "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
refused other-owner-sudo-user "$(open_line "$c" "$c")" "$c"
ID_UID=0
run root-no-sudo "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
refused root-no-sudo "$(open_line "$c" "$c")" "$c"
SUDO=$me run root-sudo "$w/elsewhere" "$w/fetched/docker_setup.sh" -d "$w/base"
used root-sudo "$c" "Found existing clone at $c."
ID_UID=54321 run own-other-owner "$w/own" "$w/own/scripts/docker_setup.sh"
refused own-other-owner "$(open_line "$w/own" "$w/own")" "$w/own"
unset ID_UID
# An own clone others can write to is not used: the run names that cause and its remedy, from
# inside it and from elsewhere, and clones nothing.
chmod 777 "$w/own"
run own-open-inside "$w/own" "$w/own/scripts/docker_setup.sh"
refused own-open-inside "$(mode_line "$w/own")" "$w/own"
rm -rf "$home_clone"
run own-open-outside "$w/elsewhere" "$w/own/scripts/docker_setup.sh"
refused own-open-outside "$(mode_line "$w/own")" "$w/own"
[ ! -e "$home_clone" ] || fail "own-open-outside: a base clone was made"
chmod 755 "$w/own"

# Nothing above ran in the repository itself.
changed=$(find "$root/docker" "$root/scripts" -newer "$w/stamp" 2>&1)
want real-tree "changed in the repository" "" "$changed"
[ "$rc" -eq 0 ] && echo "PASS docker-own-clone"
exit "$rc"
