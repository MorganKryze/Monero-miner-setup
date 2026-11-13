#!/bin/bash
# Builds the DietPi first-boot zip of a release: our dietpi.txt and Automation_Custom_Script.sh
# (scripts/first_boot.sh with the release tag and the sha256 of that tag's scripts/install.sh
# filled in), nothing else. Run from the repository root at the tagged commit:
#   bash scripts/dietpi_bundle.sh v0.2.0 dist
# DietPi copies a file from the card only when it is newer than its own (dated 2021-01-01 00:02),
# so both files carry the commit's time, which also makes the zip the same on every run.
set -euo pipefail

ZIP_NAME="dietpi-first-boot.zip"
SOURCE_SCRIPT="scripts/first_boot.sh"
SOURCE_DIETPI="templates/dietpi.txt"
# DietPi's licence (GPL-2.0), shipped beside its dietpi.txt.
SOURCE_LICENSE="templates/dietpi-LICENSE.txt"
INSTALLER="scripts/install.sh"

function die() {
    echo "[  ERROR  ] $*" >&2
    exit 1
}

tag=${1-}
out=${2-}
# The tag ends up in a download URL on every board: the same form the installer accepts.
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "Give a release tag such as v0.2.0, not '$tag'."
[ -n "$out" ] && [ -d "$out" ] || die "Give a folder for the zip that exists, not '$out'."
for f in "$SOURCE_SCRIPT" "$SOURCE_DIETPI" "$SOURCE_LICENSE" "$INSTALLER"; do
    [ -f "$f" ] && [ ! -L "$f" ] || die "$f is missing or a link: run this from the repository root."
done
# The script fetches that tag's installer: a zip naming another release would install a version
# that does not match its own.
version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$INSTALLER")
[ "$tag" = "v$version" ] || die "The tag $tag is not v + the VERSION of $INSTALLER ($version)."
[ "$(grep -cx 'RELEASE_TAG=""' "$SOURCE_SCRIPT")" = 1 ] && [ "$(grep -cx 'INSTALLER_SHA256=""' "$SOURCE_SCRIPT")" = 1 ] \
    || die "$SOURCE_SCRIPT must hold the lines RELEASE_TAG=\"\" and INSTALLER_SHA256=\"\" once each."
sum=$(sha256sum -- "$INSTALLER" | awk '{ print $1 }')
[[ $sum =~ ^[0-9a-f]{64}$ ]] || die "Failed to sum $INSTALLER."
when=$(git log -1 --format=%ct) && [[ $when =~ ^[0-9]+$ ]] || die "Failed to read the commit's time."

stage=$(mktemp -d) && [ -d "$stage" ] || die "Failed to create a temp folder."
trap 'rm -rf -- "$stage"' EXIT
sed -e "s/^RELEASE_TAG=\"\"\$/RELEASE_TAG=\"$tag\"/" -e "s/^INSTALLER_SHA256=\"\"\$/INSTALLER_SHA256=\"$sum\"/" \
    "$SOURCE_SCRIPT" > "$stage/Automation_Custom_Script.sh"
cp -- "$SOURCE_DIETPI" "$stage/dietpi.txt"
cp -- "$SOURCE_LICENSE" "$stage/LICENSE-dietpi.txt"
chmod 0755 "$stage/Automation_Custom_Script.sh"
chmod 0644 "$stage/dietpi.txt" "$stage/LICENSE-dietpi.txt"
stamp=$(TZ=UTC date -u -r "$when" +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC date -u -d "@$when" +%Y%m%d%H%M.%S)
TZ=UTC touch -t "$stamp" "$stage/Automation_Custom_Script.sh" "$stage/dietpi.txt" "$stage/LICENSE-dietpi.txt"
rm -f -- "$out/$ZIP_NAME"
(cd "$stage" && TZ=UTC zip -q -X "$ZIP_NAME" Automation_Custom_Script.sh dietpi.txt LICENSE-dietpi.txt)
mv -- "$stage/$ZIP_NAME" "$out/$ZIP_NAME"
echo "[ SUCCESS ] $out/$ZIP_NAME for $tag (installer sha256 $sum)."
