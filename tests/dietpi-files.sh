#!/bin/bash
# The DietPi files a release ships. templates/dietpi.txt is DietPi's own file at the pinned
# version with only the named keys changed: put back, the file hashes to that version's. The zip
# holds exactly Automation_Custom_Script.sh and dietpi.txt, dated after DietPi's own 2021-01-01
# 00:02 so its import takes them; the script is scripts/first_boot.sh with only the release tag
# and the installer's sha256 filled in. A bad tag, a tag other than the installer's version, a
# missing placeholder or a source that is a link
# builds nothing.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }

# DietPi v10.8 (MichaIng/DietPi tag v10.8, commit 0639bb3cad73c58bacad972d1ccd62e4e50fbd0c).
UPSTREAM_SHA256=76364c9e795be3e5e824ef5115c04d130b76f9e6b20f70f30df112499ae582f0
# key, our value, DietPi's value
CHANGED='AUTO_SETUP_AUTOMATED 1 0
SOFTWARE_DISABLE_SSH_PASSWORD_LOGINS 1 0
SURVEY_OPTED_IN 0 -1'
# Kept at DietPi's value, and asserted, as the first boot relies on them.
KEPT='AUTO_SETUP_NET_ETHERNET_ENABLED 1
AUTO_SETUP_NET_WIFI_ENABLED 0
AUTO_SETUP_SSH_SERVER_INDEX -1
AUTO_SETUP_CUSTOM_SCRIPT_EXEC 0
AUTO_SETUP_DESKTOP none'
d=templates/dietpi.txt
back=$(cat "$d")
while read -r key ours theirs; do
  [ "$(grep -c "^$key=" "$d")" = 1 ] && grep -qx "$key=$ours" "$d" || fail "dietpi.txt: $key is not set once to $ours"
  back=$(printf '%s\n' "$back" | sed "s/^$key=$ours\$/$key=$theirs/")
done <<<"$CHANGED"
while read -r key value; do
  [ "$(grep -c "^$key=" "$d")" = 1 ] && grep -qx "$key=$value" "$d" || fail "dietpi.txt: $key is not kept once at $value"
done <<<"$KEPT"
got=$(printf '%s\n' "$back" | sha256sum 2>/dev/null | awk '{ print $1 }')
[ "$got" = "$UPSTREAM_SHA256" ] || fail "dietpi.txt differs from DietPi v10.8 in more than the named keys"

w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
bundle() { # tag, out folder: runs the bundle from the repository root, stdout and stderr dropped
  (cd "$root" && env -i PATH="$PATH" HOME="$w" bash --norc --noprofile scripts/dietpi_bundle.sh "$1" "$2") >/dev/null 2>&1
}
# The zip and the installer it fetches must name the same release: the tag is v + its VERSION.
tag=v$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/install.sh)
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || fail "install.sh: no VERSION line"
mkdir -p "$w/out" "$w/x"
bundle "$tag" "$w/out" || fail "bundle: exit non-zero for $tag"
z=$w/out/dietpi-first-boot.zip
[ "$(unzip -Z1 "$z" 2>/dev/null | LC_ALL=C sort)" = "$(printf '%s\n' Automation_Custom_Script.sh dietpi.txt)" ] \
  || fail "zip: not exactly Automation_Custom_Script.sh and dietpi.txt"
while read -r t; do
  [[ $t =~ ^[0-9]{8}\.[0-9]{6}$ ]] && [ "${t/./}" -gt 20210101000200 ] || fail "zip: a file dated $t, not after 2021-01-01 00:02"
done < <(zipinfo -T "$z" 2>/dev/null | awk '/^-/ { print $(NF - 1) }')
(cd "$w/x" && unzip -q "$z") || fail "zip: does not extract"
cmp -s "$w/x/dietpi.txt" "$d" || fail "zip: dietpi.txt is not templates/dietpi.txt"
sum=$(sha256sum scripts/install.sh | awk '{ print $1 }')
want=$(sed -e 's/^RELEASE_TAG=""$/RELEASE_TAG="'"$tag"'"/' -e "s/^INSTALLER_SHA256=\"\"\$/INSTALLER_SHA256=\"$sum\"/" scripts/first_boot.sh)
[ "$(cat "$w/x/Automation_Custom_Script.sh")" = "$want" ] || fail "zip: the script is not scripts/first_boot.sh with the tag and the installer's sum"
grep -qx "RELEASE_TAG=\"$tag\"" "$w/x/Automation_Custom_Script.sh" || fail "zip: no release tag line"
grep -qx "INSTALLER_SHA256=\"$sum\"" "$w/x/Automation_Custom_Script.sh" || fail "zip: no installer sum line"
[ -x "$w/x/Automation_Custom_Script.sh" ] || fail "zip: the script is not executable"
cp "$z" "$w/first.zip"
bundle "$tag" "$w/out" && cmp -s "$z" "$w/first.zip" || fail "zip: a second build differs"
for t in 'v9.8.7' "$tag-x" 'v1.2' 'v1.2.3; rm -rf /' 'main' 'v1.2.3/x' ''; do
  rm -f "$z"
  bundle "$t" "$w/out" && fail "bundle: accepted the tag '$t'"
  [ ! -e "$z" ] || fail "bundle: wrote a zip for the tag '$t'"
done
bundle "$tag" "$w/none" && fail "bundle: accepted a folder that does not exist"
# A source without its placeholder line builds nothing.
cp -R "$root/scripts" "$root/templates" "$w/" && mkdir -p "$w/tree" && mv "$w/scripts" "$w/templates" "$w/tree/"
(cd "$w/tree" && git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m t) >/dev/null 2>&1
sed -i.bak '/^INSTALLER_SHA256=""$/d' "$w/tree/scripts/first_boot.sh"
(cd "$w/tree" && env -i PATH="$PATH" HOME="$w" bash --norc --noprofile scripts/dietpi_bundle.sh "$tag" "$w/out") >/dev/null 2>&1 \
  && fail "bundle: built without the installer sum placeholder"
[ "$rc" -eq 0 ] && echo "PASS dietpi-files"
exit "$rc"
