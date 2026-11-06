#!/bin/bash

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
BASE_DIR=$(dirname "$SCRIPT_DIR")
TEMPLATE_FILE="$BASE_DIR/templates/xmrig.service.template"
TARGET_FILE="/etc/systemd/system/xmrig.service"
LOGROTATE_TEMPLATE="$BASE_DIR/templates/logrotate.xmrig.template"
LOGROTATE_TARGET="/etc/logrotate.d/xmrig"
SEED_SOURCE="$BASE_DIR/config_background.json"
SEED_DIR="/etc/xmrig"
SEED_TARGET="$SEED_DIR/config.json"

# shellcheck source=setup_service_common.sh
source "$SCRIPT_DIR/setup_service_common.sh" || { echo "ERROR: $SCRIPT_DIR/setup_service_common.sh not found."; exit 1; }

# Check if systemd is available
if ! command -v systemctl >/dev/null 2>&1; then
    echo "ERROR: systemd is not available on this system."
    exit 1
fi

# Check if template exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "ERROR: Template file not found at $TEMPLATE_FILE"
    exit 1
fi

# Fails when a user other than root owns the path or a directory above it, or its group or others
# can write one of them. stat drops a mode's leading zeros (0007 comes out as 7), so the mode is read
# as a whole octal number, and anything else stat prints counts as a no.
function only_root_can_change() {
    local p="$1" info mode
    while :; do
        info=$(stat -c '%U %a' "$p") || return 1
        mode=${info#* }
        [[ "$mode" =~ ^[0-7]+$ ]] || return 1
        [ "${info%% *}" = root ] && (( (8#$mode & 8#022) == 0 )) || return 1
        [ "$p" = / ] && return 0
        p=$(dirname "$p")
    done
}

# The service config the seed is read from: in background mode, systemd would lose the miner as
# soon as it starts. Done first, so a unit an earlier setup left gets a supervised miner even when
# this setup stops below. Root edits it only at the end of its links, inside the clone, and where
# only root can change it, the clone and every directory above: anyone else could point the link
# at a file of root's and have root write there. Elsewhere root leaves it and turns off the copy
# it installs.
CLONE_CONFIG=$SEED_SOURCE
if [ "$(id -u)" = 0 ] && { ! CLONE_CONFIG=$(readlink -f "$SEED_SOURCE") \
    || [ "${CLONE_CONFIG#"$BASE_DIR"/}" = "$CLONE_CONFIG" ] || ! only_root_can_change "$CLONE_CONFIG"; }; then
    CLONE_CONFIG=
fi
if [ -n "$CLONE_CONFIG" ] && ! turn_background_off "$CLONE_CONFIG" "$SEED_SOURCE"; then
    echo "ERROR: Failed to turn off background mode in $SEED_SOURCE."
    exit 1
fi

# Prints the account the service runs the miner as: root only when asked, else the user running
# the setup, else the user who ran sudo, else the system account xmrig.
function pick_account() {
    if [ "${SERVICE_AS_ROOT:-}" = yes ]; then
        echo root
    elif [ "$(id -u)" != 0 ]; then
        id -un
    elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        echo "$SUDO_USER"
    else
        echo xmrig
    fi
}

# The system account xmrig has no home and no login; an existing one is reused as it is.
function ensure_account() {
    local name="$1"
    [ "$name" = xmrig ] || return 0
    id xmrig >/dev/null 2>&1 && return 0
    if ! sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin xmrig; then
        echo "ERROR: Failed to create the system account xmrig."
        return 1
    fi
    echo "Created the system account xmrig to run the miner."
}

ACCOUNT=$(pick_account)
ensure_account "$ACCOUNT" || exit 1
if ! GROUP=$(id -gn "$ACCOUNT") || [ -z "$GROUP" ]; then
    echo "ERROR: Failed to find the group of $ACCOUNT."
    exit 1
fi
# The account is given nothing in the clone: the kernel decides whether it can run the binary.
if ! sudo -u "$ACCOUNT" test -x "$BASE_DIR/xmrig"; then
    echo "ERROR: The account $ACCOUNT cannot run $BASE_DIR/xmrig; move the clone where it can, such as /opt."
    exit 1
fi
# The unit runs the clone's binary through the link make build leaves. Root, or an account that does
# not own the binary, would run whatever its owner or anyone who can write a directory above it puts
# there, so only root may be able to change the binary, the link or the directories above them.
if ! BINARY=$(readlink -f "$BASE_DIR/xmrig") || ! BINARY_INFO=$(stat -c '%U %a' "$BINARY"); then
    echo "ERROR: Failed to read the owner of $BASE_DIR/xmrig."
    exit 1
fi
if [ "$ACCOUNT" = root ] || [ "${BINARY_INFO%% *}" != "$ACCOUNT" ]; then
    if ! only_root_can_change "$BINARY" || ! only_root_can_change "$BASE_DIR"; then
        echo "ERROR: A user other than root can change $BASE_DIR/xmrig, which the service would run as $ACCOUNT; move the clone where only root can change it, such as /opt."
        exit 1
    fi
fi
# The account the installed unit names, if any: asked of systemd, so nothing reads /etc here.
OLD_ACCOUNT=$(systemctl show -p User --value xmrig.service 2>/dev/null)

# Root installs what this user stages. Staged under a fixed name in the shared /tmp, another local
# user could create that name first and rewrite the unit, its User= line included; mktemp adds a
# random part nobody can guess and creates the file for this user alone (macOS's mktemp ignores
# TMPDIR without a template, hence the explicit one). All are created before anything
# is installed, so a failure leaves the host as it was.
LOGROTATE=false
if command -v logrotate >/dev/null 2>&1 && [ -f "$LOGROTATE_TEMPLATE" ]; then
    LOGROTATE=true
fi
# Cleared before the trap names them: a value inherited from the environment would be removed on exit.
SEED_STAGED=
LOGROTATE_STAGED=
UNIT_STAGED=$(mktemp "${TMPDIR:-/tmp}/xmrig-unit.XXXXXXXXXX") || { echo "ERROR: Failed to create a temporary file."; exit 1; }
trap 'rm -f -- "$UNIT_STAGED" "${SEED_STAGED:-}" "${LOGROTATE_STAGED:-}"' EXIT
SEED_STAGED=$(mktemp "${TMPDIR:-/tmp}/xmrig-config.XXXXXXXXXX") || { echo "ERROR: Failed to create a temporary file."; exit 1; }
if [ "$LOGROTATE" = true ]; then
    LOGROTATE_STAGED=$(mktemp "${TMPDIR:-/tmp}/xmrig-logrotate.XXXXXXXXXX") || { echo "ERROR: Failed to create a temporary file."; exit 1; }
fi

# A write that fails half way would install a cut file: each is checked before root installs it.
if ! sed -e "s|%%USER%%|${ACCOUNT}|g" -e "s|%%GROUP%%|${GROUP}|g" -e "s|%%WORKING_DIR%%|${BASE_DIR}|g" "$TEMPLATE_FILE" > "$UNIT_STAGED"; then
    echo "ERROR: Failed to write the unit from $TEMPLATE_FILE."
    exit 1
fi
# Read as this user, never as root: root would follow any link in the clone to a file it alone can
# read.
if ! cat "$SEED_SOURCE" > "$SEED_STAGED"; then
    echo "ERROR: Failed to write the service config from $SEED_SOURCE."
    exit 1
fi
if ! turn_background_off "$SEED_STAGED" "$SEED_TARGET"; then
    echo "ERROR: Failed to turn off background mode in $SEED_TARGET."
    exit 1
fi
if [ "$LOGROTATE" = true ]; then
    if ! sed -e "s|%%USER%%|${ACCOUNT}|g" -e "s|%%GROUP%%|${GROUP}|g" "$LOGROTATE_TEMPLATE" > "$LOGROTATE_STAGED"; then
        echo "ERROR: Failed to write the logrotate config from $LOGROTATE_TEMPLATE."
        exit 1
    fi
fi

# The service copies this config into its own state directory as the account when it starts;
# root writes only here, a directory the account can read through its group but not write.
if ! sudo install -d -o root -g root -m 0755 "$SEED_DIR"; then
    echo "ERROR: Failed to install $SEED_DIR."
    exit 1
fi
if ! sudo install -o root -g "$GROUP" -m 640 "$SEED_STAGED" "$SEED_TARGET"; then
    echo "ERROR: Failed to install $SEED_TARGET."
    exit 1
fi

# Install logrotate config (best-effort: skip if logrotate is absent)
# The su line makes root's logrotate act as the account in the account's own logs directory, so a
# link planted there cannot point it at root's files. It goes in before the unit, whose presence
# marks the service as set up: a failure leaves no unit, and the next run sets the service up again.
if [ "$LOGROTATE" = true ]; then
    if ! sudo install -o root -g root -m 644 "$LOGROTATE_STAGED" "$LOGROTATE_TARGET"; then
        echo "ERROR: Failed to install $LOGROTATE_TARGET."
        exit 1
    fi
    echo "Installed logrotate config at $LOGROTATE_TARGET (daily, 7 rotations)."
else
    echo "Skipping logrotate setup (logrotate not installed)."
fi

# Install systemd service file
if ! sudo install -o root -g root -m 644 "$UNIT_STAGED" "$TARGET_FILE"; then
    echo "ERROR: Failed to install $TARGET_FILE."
    exit 1
fi
sudo systemctl daemon-reload
sudo systemctl enable xmrig.service
# Miners an earlier background-mode start left ran on the clone's config, as the account the
# installed unit named.
report_detached_miners "$SEED_SOURCE" "$(systemctl show -p MainPID --value xmrig.service 2>/dev/null)" "$OLD_ACCOUNT"

# Each account has its own pair of directories, so an earlier one's files never reach the next.
if [ -n "$OLD_ACCOUNT" ] && [ "$OLD_ACCOUNT" != "$ACCOUNT" ]; then
    echo "The miner ran as $OLD_ACCOUNT before: its files stay in /var/lib/xmrig/$OLD_ACCOUNT and /var/log/xmrig/$OLD_ACCOUNT; remove them with: sudo rm -r /var/lib/xmrig/$OLD_ACCOUNT /var/log/xmrig/$OLD_ACCOUNT"
fi
echo "XMRig service has been setup and enabled, but not started."
echo "Use 'make start' to start mining."
echo "The service runs the miner as $ACCOUNT."

exit 0
