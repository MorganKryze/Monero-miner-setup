#!/bin/bash
# --prebuilt installs the release binary only after its checksum matches. The functions are taken
# from scripts/install.sh and run under a driver, in env -i, with stub curl, apt-get, ldd, git,
# stat and id; PATH holds only the stub and tool-link directories. The stub curl serves files from
# a fixture release folder. A good release replaces the binary and writes its record; every refusal
# (a sum that differs, two sums, none, a download that fails or is empty, apt failing, a missing
# library, a binary ldd cannot load, a folder where the binary goes, a tree another user can
# change) leaves the binary, the record and the clone as they were, with the exact error line, and
# apt is never called before the sum matched. Nothing is fetched, installed or started.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d "${TMPDIR:-/tmp}/prebuilt-install.XXXXXX") && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'chmod -R u+rwx -- "$w" 2>/dev/null; rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/bin" "$w/tools" "$w/home" "$w/opt"
chmod 755 "$w" "$w/home" "$w/opt"
for t in awk cat chmod cut dirname find grep head ln ls mkdir mktemp mv rm rmdir sed sha256sum sort tail tr wc; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done
real_id=$(command -v id)
cat > "$w/bin/id" <<STUB
#!/bin/bash
case \$* in
  -u) echo 0 ;;
  *) exec "$real_id" "\$@" ;;
esac
STUB
cat > "$w/bin/git" <<STUB
#!/bin/bash
case "\$*" in
  *"tag --points-at HEAD --list v*") [ -n "\${GIT_TAGS:-}" ] && printf '%b\n' "\$GIT_TAGS" ;;
esac
exit 0
STUB
cat > "$w/bin/stat" <<STUB
#!/bin/bash
for last; do :; done
line=\$(grep -F -- "\$last " "$w/stat.map" 2>/dev/null | head -n 1)
if [ -n "\$line" ]; then set -- \$line; echo "\$2 \$3"; else echo "root 755"; fi
STUB
cat > "$w/bin/curl" <<STUB
#!/bin/bash
echo "\$*" >> "$w/curl.log"
out= url=
while [ \$# -gt 0 ]; do
  case \$1 in -o) out=\$2; shift ;; http*) url=\$1 ;; esac
  shift
done
rel=\${url#\$RELEASE_URL/}
[ "\$rel" != "\$url" ] || exit 22
[ "\${CURL_FAIL:-}" != "\${rel##*/}" ] || exit 22
[ -f "$w/release/\$rel" ] || exit 22
cat "$w/release/\$rel" > "\$out"
STUB
cat > "$w/bin/apt-get" <<STUB
#!/bin/bash
echo "\$*" >> "$w/apt-get.log"
[ -z "\${APT_FAIL:-}" ] || exit 100
if [ -n "\${APT_SWAP:-}" ]; then rm -f -- "\$APT_SWAP_LINK"; ln -s "\$APT_SWAP" "\$APT_SWAP_LINK"; fi
exit 0
STUB
cat > "$w/bin/ldd" <<'STUB'
#!/bin/bash
[ -z "${LDD_FAIL:-}" ] || exit 1
printf '\tlibuv.so.1 => /usr/lib/aarch64-linux-gnu/libuv.so.1 (0x1)\n'
[ -z "${LDD_MISSING:-}" ] || printf '\t%s => not found\n' "$LDD_MISSING"
exit 0
STUB
chmod 755 "$w/bin/"*

d="$w/driver.sh"
{
  printf '%s() { echo "[%s] $1"; }\n' txt TXT info INFO warning WARNING success SUCCESS hint HINT
  printf 'error() { echo "[ERROR] $1" >&2; return 1; }\n'
  sed -n '/^# ===== Constants =====/,/^# ===== Own clone =====/p' "$root/scripts/install.sh"
  for f in trusted_by_root release_tag_of root_only_tree binary_sha256 binary_origin donate_level_of check_if_built install_project display_next_steps; do
    sed -n "/^function $f() {/,/^}/p" "$root/scripts/install.sh"
  done
  sed -n '/^function install_release_binary() (/,/^)/p' "$root/scripts/install.sh"
  cat <<'DRIVER'
check_repo_exists() { return 0; }
check_base_clone() { return 0; }
generate_config_files() { return 0; }
set_script_permissions() { :; }
configs_exist() { return 1; }
service_is_set_up() { return 1; }
setup_service() { echo SETUP_SERVICE; }
build_project() { echo BUILD_PROJECT; }
BASE_DIR=$1; shift; "$@"
DRIVER
} > "$d"
chmod 644 "$d"
grep -q '^function install_release_binary() (' "$d" || fail "no install_release_binary in scripts/install.sh"

want() { # name, label, expected, got
  [ "$3" = "$4" ] || { echo "FAIL $1: $2"; diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'; rc=1; }
}
clone="$w/opt/Monero-miner-setup"
url=https://github.com/MorganKryze/Monero-miner-setup/releases/download
asset=xmrig-linux-arm64
# The release, then a clone holding an old binary.
reset() {
  rm -rf "$w/release" "$clone" "$w/curl.log" "$w/apt-get.log"
  mkdir -p "$w/release/v0.2.0"
  printf 'release-binary' > "$w/release/v0.2.0/$asset"
  hash=$(cd "$w/release/v0.2.0" && sha256sum "$asset" | cut -d' ' -f1)
  (cd "$w/release/v0.2.0" && sha256sum "$asset" > SHA256SUMS)
  mkdir -p "$clone/.git"
  printf 'old' > "$clone/xmrig"
  chmod 755 "$clone" "$clone/.git" "$clone/xmrig" "$w/release" "$w/release/v0.2.0"
  chmod 644 "$w/release/v0.2.0/"*
  : > "$w/stat.map"
}
# run <vars...> -- <function> <args>: sets out, code.
run() {
  local vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  rm -f "$w/curl.log" "$w/apt-get.log"
  out=$(cd "$w/home" && env -i HOME="$w/home" PATH="$w/bin:$w/tools" RELEASE_URL="$url" GIT_TAGS=v0.2.0 "${vars[@]}" "$BASH" --norc --noprofile "$d" "$w/opt" "$@" 2>&1)
  code=$?
}
nostage() { case $(ls -A "$clone") in *.xmrig-release.*) fail "$1: staging folder left in the clone" ;; esac; }
untouched() { # name
  if [ ! -d "$clone/xmrig" ]; then
    want "$1" "xmrig" old "$(cat "$clone/xmrig" 2>/dev/null)"
  fi
  [ ! -e "$clone/xmrig.release" ] || fail "$1: wrote xmrig.release"
  nostage "$1"
}
left="so the miner is left as it was."
lib_tail="Run the installer without --prebuilt to compile the miner here."
refuse() { # name, expected error, vars...
  local name=$1 text=$2; shift 2
  run "$@" -- install_release_binary "$clone"
  want "$name" exit 1 "$code"
  want "$name" "error" "[ERROR] $text" "$(printf '%s\n' "$out" | grep -F '[ERROR]')"
  untouched "$name"
  case $name in
    sum-mismatch | two-sums | no-sum | asset-fails | sums-fails | empty-asset)
      [ ! -e "$w/apt-get.log" ] || fail "$name: apt ran before the sum matched" ;;
  esac
}
sha_of() { (cd "$clone" && sha256sum xmrig | cut -d' ' -f1); }

# a good release
reset
run -- install_release_binary "$clone"
want good exit 0 "$code"
want good out "[INFO] Installing libuv1t64 libssl3t64 libhwloc15 for the release binary...
[SUCCESS] Installed XMRig of release v0.2.0 (sha256 $hash) at $clone/xmrig." "$out"
want good binary release-binary "$(cat "$clone/xmrig")"
case $(ls -l "$clone/xmrig") in -rwxr-xr-x*) ;; *) fail "good: xmrig mode" ;; esac
want good record "v0.2.0 $hash" "$(cat "$clone/xmrig.release")"
want good "curl calls" 2 "$(wc -l < "$w/curl.log" | tr -d ' ')"
case $(sed -n 1p "$w/curl.log") in
  "-fsSL --proto =https --proto-redir =https -o $clone/.xmrig-release."*"/$asset $url/v0.2.0/$asset") ;;
  *) fail "good: first curl line: $(sed -n 1p "$w/curl.log")" ;;
esac
case $(sed -n 2p "$w/curl.log") in
  "-fsSL --proto =https --proto-redir =https -o $clone/.xmrig-release."*"/SHA256SUMS $url/v0.2.0/SHA256SUMS") ;;
  *) fail "good: second curl line: $(sed -n 2p "$w/curl.log")" ;;
esac
want good apt-get.log "update
install -y --no-upgrade libuv1t64 libssl3t64 libhwloc15" "$(cat "$w/apt-get.log")"
nostage good

reset
other=$(printf 'x' | sha256sum | cut -d' ' -f1)
printf '%s  %s\n' "$other" "$asset" > "$w/release/v0.2.0/SHA256SUMS"
refuse sum-mismatch "$asset of release v0.2.0 has sha256 $hash where SHA256SUMS says $other, $left Run the installer again; if it says the same, report it at https://github.com/MorganKryze/Monero-miner-setup/issues."

reset
cat "$w/release/v0.2.0/SHA256SUMS" "$w/release/v0.2.0/SHA256SUMS" > "$w/release/v0.2.0/S" && mv "$w/release/v0.2.0/S" "$w/release/v0.2.0/SHA256SUMS"
refuse two-sums "SHA256SUMS of release v0.2.0 does not hold exactly one sum for $asset, $left"

reset
printf '%s  other-file\n' "$hash" > "$w/release/v0.2.0/SHA256SUMS"
refuse no-sum "SHA256SUMS of release v0.2.0 does not hold exactly one sum for $asset, $left"

reset
refuse asset-fails "Failed to download $url/v0.2.0/$asset, $left Check your network and that release v0.2.0 has this file, then run the installer again." CURL_FAIL=$asset
refuse sums-fails "Failed to download $url/v0.2.0/SHA256SUMS, $left Check your network and that release v0.2.0 has this file, then run the installer again." CURL_FAIL=SHA256SUMS

reset
: > "$w/release/v0.2.0/$asset"
refuse empty-asset "Failed to download $url/v0.2.0/$asset, $left Check your network and that release v0.2.0 has this file, then run the installer again."

reset
refuse apt-fails "Failed to install libuv1t64 libssl3t64 libhwloc15 through apt, $left Fix apt, then run the installer again." APT_FAIL=1
refuse lib-missing "The release binary needs libhwloc.so.15, which this host lacks after apt installed libuv1t64 libssl3t64 libhwloc15, $left $lib_tail" LDD_MISSING=libhwloc.so.15
refuse ldd-fails "The release binary cannot be loaded on this host, $left $lib_tail" LDD_FAIL=1

reset
rm "$clone/xmrig"; mkdir "$clone/xmrig"; chmod 755 "$clone/xmrig"
refuse folder-at-xmrig "$clone/xmrig is a link or a folder, so the release binary is not installed over it. Remove it with rm -r -- '$clone/xmrig', then run the installer again."

reset
mkdir "$w/outside"; printf 'keep' > "$w/outside/keep"
rm "$clone/xmrig"; ln -s "$w/outside" "$clone/xmrig"
run -- install_release_binary "$clone"
want link-to-folder exit 1 "$code"
want link-to-folder error "[ERROR] $clone/xmrig is a link or a folder, so the release binary is not installed over it. Remove it with rm -r -- '$clone/xmrig', then run the installer again." "$(printf '%s\n' "$out" | grep -F '[ERROR]')"
want link-to-folder outside "keep" "$(ls -A "$w/outside" | tr '\n' ' ' | sed 's/ $//')"
[ ! -e "$clone/xmrig.release" ] || fail "link-to-folder: wrote xmrig.release"
nostage link-to-folder

reset
mkdir "$clone/xmrig.release"; chmod 755 "$clone/xmrig.release"
run -- install_release_binary "$clone"
want folder-at-record exit 1 "$code"
want folder-at-record error "[ERROR] $clone/xmrig.release is a link or a folder, so the release binary is not installed over it. Remove it with rm -r -- '$clone/xmrig.release', then run the installer again." "$(printf '%s\n' "$out" | grep -F '[ERROR]')"
want folder-at-record xmrig old "$(cat "$clone/xmrig")"
nostage folder-at-record

reset
echo "$w/opt alice 755" > "$w/stat.map"
run -- install_release_binary "$clone"
want tree exit 1 "$code"
want tree text "[ERROR] $w/opt can be changed by a user other than root, so --prebuilt does not install a binary under it. Pass -d with a directory only root can change, such as /opt." "$out"
[ ! -e "$w/curl.log" ] || fail "tree: curl ran"
untouched tree

reset
run GIT_TAGS= -- install_release_binary "$clone"
want no-tag exit 1 "$code"
want no-tag text "[ERROR] $clone is checked out at no release tag, so --prebuilt has no release to install." "$out"
[ ! -e "$w/curl.log" ] || fail "no-tag: curl ran"

# A compiled clone: xmrig links to the build output, which the release binary replaces as a plain file.
reset
mkdir "$clone/build-xmrig"; chmod 755 "$clone/build-xmrig"
printf 'compiled' > "$clone/build-xmrig/xmrig"; chmod 755 "$clone/build-xmrig/xmrig"
rm "$clone/xmrig"; ln -s build-xmrig/xmrig "$clone/xmrig"
run -- install_release_binary "$clone"
want compiled-clone exit 0 "$code"
[ ! -L "$clone/xmrig" ] && [ -f "$clone/xmrig" ] || fail "compiled-clone: xmrig is not a plain file"
want compiled-clone binary release-binary "$(cat "$clone/xmrig")"
want compiled-clone build compiled "$(cat "$clone/build-xmrig/xmrig")"
want compiled-clone record "v0.2.0 $hash" "$(cat "$clone/xmrig.release")"
nostage compiled-clone

# A compiled clone stays a link to its build output after a download, apt or ldd refusal.
for v in CURL_FAIL=$asset CURL_FAIL=SHA256SUMS APT_FAIL=1 LDD_FAIL=1; do
  reset
  mkdir "$clone/build-xmrig"; chmod 755 "$clone/build-xmrig"
  printf 'compiled' > "$clone/build-xmrig/xmrig"; chmod 755 "$clone/build-xmrig/xmrig"
  rm "$clone/xmrig"; ln -s build-xmrig/xmrig "$clone/xmrig"
  run "$v" -- install_release_binary "$clone"
  want "compiled-refused $v" exit 1 "$code"
  [ -L "$clone/xmrig" ] || fail "compiled-refused $v: xmrig link removed"
  want "compiled-refused $v" build compiled "$(cat "$clone/xmrig" 2>/dev/null)"
  [ ! -e "$clone/xmrig.release" ] || fail "compiled-refused $v: wrote xmrig.release"
  nostage "compiled-refused $v"
done

# The link's target turns into a link to a folder another account chose while apt runs: the release
# binary still lands as a plain file at xmrig, and that folder stays empty.
reset
mkdir "$clone/build-xmrig" "$w/victim"; chmod 755 "$clone/build-xmrig" "$w/victim"
printf 'compiled' > "$clone/build-xmrig/xmrig"; chmod 755 "$clone/build-xmrig/xmrig"
rm "$clone/xmrig"; ln -s build-xmrig/xmrig "$clone/xmrig"
run APT_SWAP="$w/victim" APT_SWAP_LINK="$clone/build-xmrig/xmrig" -- install_release_binary "$clone"
want swapped-target exit 0 "$code"
want swapped-target victim "" "$(ls -A "$w/victim")"
[ ! -L "$clone/xmrig" ] && [ -f "$clone/xmrig" ] || fail "swapped-target: xmrig is not a plain file"
want swapped-target binary release-binary "$(cat "$clone/xmrig")"
nostage swapped-target

# A link to a folder is refused before any download or apt.
reset
mkdir "$w/outside2"
rm "$clone/xmrig"; ln -s "$w/outside2" "$clone/xmrig"
run -- install_release_binary "$clone"
want early-refusal exit 1 "$code"
[ ! -e "$w/curl.log" ] || fail "early-refusal: curl ran"
[ ! -e "$w/apt-get.log" ] || fail "early-refusal: apt ran"
reset
mkdir "$clone/xmrig.release"; chmod 755 "$clone/xmrig.release"
run -- install_release_binary "$clone"
[ ! -e "$w/curl.log" ] || fail "early-record: curl ran"
[ ! -e "$w/apt-get.log" ] || fail "early-record: apt ran"

# A base with a space: the remedy pastes as one operand.
reset
sp="$w/sp ace"; mkdir "$sp"; mv "$clone" "$sp/Monero-miner-setup"; clone="$sp/Monero-miner-setup"
rm "$clone/xmrig"; mkdir "$clone/xmrig"; chmod 755 "$clone/xmrig" "$sp"
out=$(cd "$w/home" && env -i HOME="$w/home" PATH="$w/bin:$w/tools" RELEASE_URL="$url" GIT_TAGS=v0.2.0 "$BASH" --norc --noprofile "$d" "$sp" install_release_binary "$clone" 2>&1)
want space remedy "[ERROR] $clone/xmrig is a link or a folder, so the release binary is not installed over it. Remove it with rm -r -- '$clone/xmrig', then run the installer again." "$(printf '%s\n' "$out" | grep -F '[ERROR]')"
clone="$w/opt/Monero-miner-setup"

# check_if_built under --prebuilt
reset
printf 'v0.2.0 %s\n' "$(sha_of)" > "$clone/xmrig.release"; chmod 644 "$clone/xmrig.release"
run PREBUILT=yes -- check_if_built
want already exit 0 "$code"
want already text "[SUCCESS] XMRig of release v0.2.0 is already installed at $clone." "$out"
[ ! -e "$w/curl.log" ] || fail "already: curl ran"
printf 'v0.1.9 %s\n' "$(sha_of)" > "$clone/xmrig.release"
run PREBUILT=yes -- check_if_built
want older-record exit 1 "$code"
printf 'v0.2.0 %s\n' "$hash" > "$clone/xmrig.release"
run PREBUILT=yes -- check_if_built
want other-hash exit 1 "$code"

# A link at xmrig is not an installed release, even when the bytes match the record.
reset
printf 'release-binary' > "$w/outside-bin"
rm "$clone/xmrig"; ln -s "$w/outside-bin" "$clone/xmrig"
printf 'v0.2.0 %s\n' "$hash" > "$clone/xmrig.release"; chmod 644 "$clone/xmrig.release"
run PREBUILT=yes -- check_if_built
want link-installed exit 1 "$code"

# A record that is a link is no record.
reset
printf 'v0.2.0 %s\n' "$(sha_of)" > "$w/rec"; chmod 644 "$w/rec"
ln -s "$w/rec" "$clone/xmrig.release"
run PREBUILT=yes -- check_if_built
want link-record exit 1 "$code"
run -- binary_origin "$clone"
want link-record origin "compiled on this host" "$out"

# binary_origin: its three texts
reset
run -- binary_origin "$clone"
want origin-compiled text "compiled on this host" "$out"
h=$(sha_of)
printf 'v0.2.0 %s\n' "$h" > "$clone/xmrig.release"
run -- binary_origin "$clone"
want origin-release text "release v0.2.0, sha256 $h" "$out"
printf 'v0.2.0 %s\n' "$hash" > "$clone/xmrig.release"
run -- binary_origin "$clone"
want origin-unknown text "unknown (sha256 $h matches no release record)" "$out"
rm "$clone/xmrig"
run -- binary_origin "$clone"
want origin-unreadable text "unknown (sha256 unreadable matches no release record)" "$out"

# install_project
reset
run PREBUILT=yes -- install_project
want project-good exit 0 "$code"
case $out in *SETUP_SERVICE*) ;; *) fail "project-good: no service setup" ;; esac
case $out in *BUILD_PROJECT*) fail "project-good: compiled under --prebuilt" ;; esac
reset
printf 'x' > "$w/release/v0.2.0/$asset"
run PREBUILT=yes -- install_project
want project-bad exit 1 "$code"
case $out in *SETUP_SERVICE*) fail "project-bad: service set up after a refusal" ;; esac
reset
run PREBUILT=no -- install_project
case $out in *BUILD_PROJECT*) ;; *) fail "project-compiled: did not build" ;; esac
[ ! -e "$w/curl.log" ] || fail "project-compiled: curl ran"

# display_next_steps
reset
printf '{"donate-level": 1,\n}\n' > "$clone/config_background.json"; chmod 644 "$clone/config_background.json"
h=$(sha_of)
printf 'v0.2.0 %s\n' "$h" > "$clone/xmrig.release"
for pu in "" "https://example.test"; do
  run REPO_NAME=Monero-miner-setup SERVICE_MODE=setup BLUE= RESET= LINK= UNDERLINE= PROJECT_URL="$pu" -- display_next_steps
  want "next-steps $pu" first "[HINT] Miner binary: release v0.2.0, sha256 $h; donate level 1 (as XMRig applies it)" "$(printf '%s\n' "$out" | sed -n 1p)"
done

# the closing line gives the level XMRig applies, as the service's start-up line does
donate_case() { # name, expected level text, config body
  printf '%s' "$3" > "$clone/config_background.json"; chmod 644 "$clone/config_background.json"
  run REPO_NAME=Monero-miner-setup SERVICE_MODE=setup BLUE= RESET= LINK= UNDERLINE= PROJECT_URL= -- display_next_steps
  want "donate $1" first "[HINT] Miner binary: release v0.2.0, sha256 $h; donate level $2" "$(printf '%s\n' "$out" | sed -n 1p)"
}
pool() { printf '    "pools": [{\n        "url": "%s",\n    }],\n    "donate-level": %s,\n' "$1" "$2"; }
donate_case "other pool, level 0" "1 (as XMRig applies it)" "$(pool pool.example.org:4444 0)"
donate_case "other pool, level 3" "3 (as XMRig applies it)" "$(pool pool.example.org:4444 3)"
donate_case "other pool, level 100" "1 (as XMRig applies it)" "$(pool pool.example.org:4444 100)"
donate_case "moneroocean, level 1" "0 (as XMRig applies it)" "$(pool pool.moneroocean.stream:10128 1)"
donate_case "first pool decides, second moneroocean" "1 (as XMRig applies it)" '    "pools": [{
        "url": "pool.example.org:4444",
    }, {
        "url": "pool.moneroocean.stream:10128",
    }],
    "donate-level": 0,
'
donate_case "first pool moneroocean, second other" "0 (as XMRig applies it)" '    "pools": [{
        "url": "pool.moneroocean.stream:10128",
    }, {
        "url": "pool.example.org:4444",
    }],
    "donate-level": 1,
'
rm -f "$clone/config_background.json"
run REPO_NAME=Monero-miner-setup SERVICE_MODE=setup BLUE= RESET= LINK= UNDERLINE= PROJECT_URL= -- display_next_steps
want "donate no config" first "[HINT] Miner binary: release v0.2.0, sha256 $h; donate level unknown" "$(printf '%s\n' "$out" | sed -n 1p)"

[ "$rc" = 0 ] && echo "PASS prebuilt-install"
exit "$rc"
