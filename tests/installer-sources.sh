#!/bin/bash
# What the installer loads and runs before it does anything else: the log helpers from its own
# clone's vendored toolbox, otherwise from the commit dependencies/bash-toolbox pins, fetched with
# curl -fsSL over HTTPS only; the Docker installer from its own clone, otherwise from GitHub; never a
# file from the current directory, and a stop with one error line on a failed, empty or partial
# load. A stub curl first on PATH serves fixtures and records each call; the installer only ever
# runs with --help or --docker, whose fixture prints its arguments. No network, nothing installed.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
pin=$(git ls-tree HEAD dependencies/bash-toolbox | awk '{print $3}')
[ "${#pin}" -eq 40 ] || { echo "FAIL no pinned commit for dependencies/bash-toolbox"; exit 1; }
tb_url="https://raw.githubusercontent.com/MorganKryze/bash-toolbox/$pin/src/prefix.sh"
dk_url="https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/docker_setup.sh"
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P) # the installer names its clone by its physical path (macOS: /private/var)
mkdir -p "$w/bin" "$w/fx"

# The fixtures: a toolbox defining the six helpers the installer calls, and a Docker installer.
toolbox() { # marker
  printf 'echo "TOOLBOX %s"\n' "$1"
  printf '%s() { echo "$1"; }\n' txt info warning success hint
  printf 'error() { echo "$1"; return 1; }\n'
}
toolbox fetched > "$w/fx/prefix.sh"
printf 'echo "DOCKER %s $*"\n' fetched > "$w/fx/docker_setup.sh"
# CURL_MODE: ok serves the fixtures, fail is an HTTP error, empty sends nothing, partial a script
# without the helpers. Each call's arguments go to curl.log, one line.
cat > "$w/bin/curl" <<STUB
#!/bin/bash
echo "\$*" >> "$w/curl.log"
url="" out=""
while [ \$# -gt 0 ]; do
  case \$1 in -o) out=\$2; shift 2 ;; https://*) url=\$1; shift ;; *) shift ;; esac
done
case \${CURL_MODE:-ok} in fail) exit 22 ;; empty) : > "\${out:-/dev/stdout}"; exit 0 ;; partial) body=': partial' ;; esac
case \$url in
  */src/prefix.sh) f="$w/fx/prefix.sh" ;;
  */scripts/docker_setup.sh) f="$w/fx/docker_setup.sh" ;;
  *) exit 6 ;;
esac
if [ -n "\${body:-}" ]; then echo "\$body" > "\${out:-/dev/stdout}"; else cat "\$f" > "\${out:-/dev/stdout}"; fi
STUB
printf '#!/bin/sh\nexit 0\n' > "$w/bin/sleep"
chmod +x "$w/bin/curl" "$w/bin/sleep"

# A clone (scripts/, .git, a checked-out toolbox), the same clone without its toolbox, a copy of
# the installer saved outside any clone next to a planted docker_setup.sh, and a current directory
# laid out like a clone and full of decoys: files named after what bash 5 reports as the script
# path of a piped script ("bash", "--"), a docker_setup.sh and a toolbox. A copy saved in a folder
# not named scripts, directly under that planted clone, still has no clone of its own. Nor has a
# copy saved as scripts/install.sh in a folder others can write to, like /tmp (open), a folder
# its group shares (group) or one only other users can write to (other): anyone may plant a .git
# and a toolbox there.
mkclone() { # dir, with-toolbox
  mkdir -p "$1/scripts" "$1/.git" "$1/dependencies/bash-toolbox/src"
  cp "$root/scripts/install.sh" "$1/scripts/install.sh"
  printf 'echo "DOCKER clone $*"\n' > "$1/scripts/docker_setup.sh"
  [ "$2" = yes ] && toolbox vendored > "$1/dependencies/bash-toolbox/src/prefix.sh"
  return 0
}
mkclone "$w/clone" yes
mkclone "$w/bare" no
mkdir -p "$w/loose" "$w/shared/scripts" "$w/cwd/scripts" "$w/cwd/.git" "$w/cwd/dependencies/bash-toolbox/src"
cp "$root/scripts/install.sh" "$w/loose/install.sh"
printf 'echo "DECOY ran"\n' > "$w/loose/docker_setup.sh"
# Laid out like a clone, but no .git: still not a clone.
cp "$root/scripts/install.sh" "$w/shared/scripts/install.sh"
printf 'echo "DECOY ran"\n' > "$w/shared/scripts/docker_setup.sh"
for f in bash -- docker_setup.sh install.sh; do printf 'echo "DECOY ran"\n' > "$w/cwd/scripts/$f"; done
toolbox decoy > "$w/fx/decoy.sh"
cp "$w/fx/decoy.sh" "$w/cwd/dependencies/bash-toolbox/src/prefix.sh"
mkdir -p "$w/cwd/loose"
cp "$root/scripts/install.sh" "$w/cwd/loose/install.sh"
for d in open:1777 group:775 other:757; do
  mkdir -p "$w/${d%:*}/scripts" "$w/${d%:*}/.git" "$w/${d%:*}/dependencies/bash-toolbox/src"
  cp "$root/scripts/install.sh" "$w/${d%:*}/scripts/install.sh"
  cp "$w/fx/decoy.sh" "$w/${d%:*}/dependencies/bash-toolbox/src/prefix.sh"
  chmod 755 "$w/${d%:*}/scripts" && chmod "${d#*:}" "$w/${d%:*}"
done
cwd="$w/cwd/scripts"

# run <name> <how> <args...>: how is file:<path>, pipe, procsub or dashc. Sets out, err, code, calls.
run() {
  local name=$1 how=$2; shift 2
  rm -f "$w/curl.log"
  case $how in
    file:*) (cd "$cwd" && PATH="$w/bin:$PATH" bash "${how#file:}" "$@") ;;
    pipe) (cd "$cwd" && PATH="$w/bin:$PATH" bash -s -- "$@" < "$root/scripts/install.sh") ;;
    procsub) (cd "$cwd" && PATH="$w/bin:$PATH" bash <(cat "$root/scripts/install.sh") "$@") ;;
    dashc) (cd "$cwd" && PATH="$w/bin:$PATH" bash -c "$(cat "$root/scripts/install.sh")" -- "$@") ;;
  esac > "$w/out" 2> "$w/err"
  code=$?
  out=$(cat "$w/out") err=$(cat "$w/err") calls=$(cat "$w/curl.log" 2>/dev/null)
  case "$out$err" in *DECOY*) echo "FAIL $name: ran a file from the current directory or next to a loose copy"; rc=1 ;; esac
}
want() { # name, label, expected, got
  [ "$3" = "$4" ] || { echo "FAIL $1: $2"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'; rc=1; }
}
toolbox_call="-fsSL --proto =https --connect-timeout 10 $tb_url"

# From a clone with its toolbox, the vendored copy, nothing fetched.
run vendored "file:$w/clone/scripts/install.sh" --help
want vendored exit 0 "$code"
want vendored "curl calls" "" "$calls"
printf '%s\n' "$out" | grep -qx 'TOOLBOX vendored' || { echo "FAIL vendored: the vendored toolbox was not loaded"; rc=1; }
printf '%s\n' "$out" | grep -qx "Usage: $w/clone/scripts/install.sh \[OPTIONS\]" || { echo "FAIL vendored: no usage line"; rc=1; }
# Without a checked-out toolbox, from a loose copy and from each stream form, one fetch
# of the pinned commit, silent about locating itself (stderr empty).
for how in "file:$w/bare/scripts/install.sh" "file:$w/loose/install.sh" "file:$w/cwd/loose/install.sh" "file:$w/shared/scripts/install.sh" "file:$w/open/scripts/install.sh" "file:$w/group/scripts/install.sh" "file:$w/other/scripts/install.sh" pipe procsub dashc; do
  name=fetched-${how#file:"$w"/}
  run "$name" "$how" --help
  want "$name" exit 0 "$code"
  want "$name" "curl calls" "$toolbox_call" "$calls"
  want "$name" stderr "" "$err"
  printf '%s\n' "$out" | grep -qx 'TOOLBOX fetched' || { echo "FAIL $name: the fetched toolbox was not loaded"; rc=1; }
done
# A failed, empty or partial load stops before the header, with one error line naming the
# source; the exit trap's line is all stdout holds.
for mode in fail empty partial; do
  CURL_MODE=$mode run "toolbox-$mode" pipe --help
  want "toolbox-$mode" exit 1 "$code"
  want "toolbox-$mode" stderr "[  ERROR  ] Failed to load the log helpers from $tb_url." "$err"
  want "toolbox-$mode" stdout "Script exited with error code 1." "$out"
done
toolbox() { printf 'echo "TOOLBOX %s"\ntxt() { echo "$1"; }\n' "$1"; }
toolbox partial > "$w/clone/dependencies/bash-toolbox/src/prefix.sh"
run vendored-partial "file:$w/clone/scripts/install.sh" --help
want vendored-partial exit 1 "$code"
want vendored-partial stderr "[  ERROR  ] Failed to load the log helpers from $w/clone/dependencies/bash-toolbox/src/prefix.sh." "$err"
want vendored-partial "curl calls" "" "$calls"
# --docker from a clone runs the clone's docker_setup.sh, fetching nothing.
run docker-clone "file:$w/clone/scripts/install.sh" --docker -y
want docker-clone exit 0 "$code"
want docker-clone output "Dispatching to $w/clone/scripts/docker_setup.sh..."$'\n'"DOCKER clone -y" "$out"
want docker-clone "curl calls" "" "$calls"
# From a loose copy and each stream form, the fetched one, never a decoy.
for how in "file:$w/loose/install.sh" "file:$w/cwd/loose/install.sh" "file:$w/shared/scripts/install.sh" pipe procsub dashc; do
  name=docker-${how#file:"$w"/}
  run "$name" "$how" --docker -y
  want "$name" exit 0 "$code"
  want "$name" output "Dispatching to docker_setup.sh (fetched)..."$'\n'"DOCKER fetched -y" "$out"
  want "$name" stderr "" "$err"
  [ "$(printf '%s\n' "$calls" | grep -c .)" -eq 1 ] && case $calls in "-fsSL --proto =https $dk_url -o "*) ;; *) false ;; esac \
    || { echo "FAIL $name: curl calls: $calls"; rc=1; }
done
# An empty Docker installer stops with an error line, running nothing.
CURL_MODE=empty run docker-empty pipe --docker -y
want docker-empty exit 1 "$code"
want docker-empty stderr "[  ERROR  ] Fetched an empty file from $dk_url. Check your network or install from a local clone." "$err"
want docker-empty stdout "" "$out"
# The installer names the pinned commit, as one whole line.
grep -qxF "TOOLBOX_COMMIT=\"$pin\"" "$root/scripts/install.sh" || { echo "FAIL install.sh does not name the pinned toolbox commit $pin"; rc=1; }
[ "$rc" -eq 0 ] && echo "PASS installer-sources"
exit "$rc"
