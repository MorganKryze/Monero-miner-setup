#!/bin/bash
# A re-run of the native installer finishes what an earlier run left undone: each missing step
# (configs, build, service) in a first install's order, configs from an earlier run kept byte for
# byte with one line each, nothing set up after a failed build, nothing changed once every step is
# done. install_project and the functions it reads are taken from scripts/install.sh; the steps
# that would clone, build or register a service are stubs that print a STEP line and leave the
# marker the next run looks for. Nothing is cloned, built, installed or registered.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
case $(uname) in Darwin) os=macos ;; *) os=linux ;; esac
wallet=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge
{
  for f in check_repo_exists check_if_built configs_exist generate_config_files service_is_set_up install_project; do
    sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/install.sh"
  done
} > "$w/functions.sh"
for f in check_repo_exists check_if_built configs_exist generate_config_files service_is_set_up install_project; do
  grep -qx "function $f() {" "$w/functions.sh" || fail "no function $f in scripts/install.sh"
done

# run <mode> [build-fails]: install_project for a host at $w/home, in a subshell.
run() {
  ( info() { echo "[INFO] $1"; }
    success() { echo "[SUCCESS] $1"; }
    warning() { echo "[WARNING] $1"; }
    error() { echo "[ERROR] $1"; return 1; }
    clone_repository() {
      echo "STEP clone"
      mkdir -p "$t/.git" "$t/templates"
      cp "$root/templates/config.json.template" "$root/templates/config_background.json.template" "$t/templates/"
    }
    set_script_permissions() { :; }
    build_fails=${2:-}
    build_project() {
      echo "STEP build"
      [ -z "$build_fails" ] || return 1
      mkdir -p "$t/build-xmrig"; : > "$t/xmrig"
    }
    setup_service() { echo "STEP service"; : > "$w/unit"; }
    # shellcheck disable=SC2034 # read by the functions taken from install.sh
    BASE_DIR="$w/home" REPO_NAME=Monero-miner-setup OS_TYPE=$os SERVICE_MODE=$1 \
      SYSTEMD_UNIT="$w/unit" LAUNCHD_PLIST="$w/unit" REPO_URL=none WALLET=$wallet POOL_URL=gulf.moneroocean.stream \
      PORT=10128 PASS=x DEFAULT_PASS=x MAX_THREADS=75 DONATE_LEVEL=0 PAUSE_ON_ACTIVE=false PAUSE_ON_BATTERY=false
    t="$BASE_DIR/$REPO_NAME"
    # shellcheck source=/dev/null
    source "$w/functions.sh"
    install_project ) > "$w/out" 2>&1
  code=$?
  out=$(cat "$w/out")
  steps=$(grep '^STEP ' "$w/out" | tr '\n' ' ')
}
t="$w/home/Monero-miner-setup"
host() { # state: a fresh host, then each part an earlier run left
  rm -rf "$w/home" "$w/unit"; mkdir -p "$w/home"
  for part in "$@"; do
    case $part in
      clone) mkdir -p "$t/.git" "$t/templates"; cp "$root"/templates/config*.template "$t/templates/" ;;
      configs) mkdir -p "$t/configs"
        sed "s/\"user\": \"[^\"]*\"/\"user\": \"EARLIER\"/" "$root/templates/config.json.template" > "$t/configs/config.json"
        sed "s/\"user\": \"[^\"]*\"/\"user\": \"EARLIER\"/" "$root/templates/config_background.json.template" > "$t/configs/config_background.json" ;;
      build) mkdir -p "$t/build-xmrig"; : > "$t/xmrig" ;;
      service) : > "$w/unit" ;;
    esac
  done
}
snapshot() { (cd "$w" && find home -type f -exec cksum {} + | LC_ALL=C sort; [ -e unit ] && echo unit) }
last() { printf '%s\n' "$out" | tail -1; }
keeping() { # file
  printf '%s\n' "$out" | grep -cxF "[INFO] Keeping $t/configs/$1. To regenerate it, run 'make clean-configs', then the installer again."
}

# A first install: every step, in order.
host
run setup
[ "$code" -eq 0 ] || fail "first install: exit $code"
[ "$steps" = "STEP clone STEP build STEP service " ] || fail "first install: steps '$steps'"
[ "$(last)" = "[SUCCESS] Project installed successfully." ] || fail "first install: last line '$(last)'"
grep -qxF "      \"user\": \"$wallet\"," "$t/configs/config_background.json" || fail "first install: the wallet is not in the service config"
# The clone of a run whose build failed: configs, build, service.
host clone
run setup
[ "$code" -eq 0 ] || fail "after a failed build: exit $code"
[ "$steps" = "STEP build STEP service " ] || fail "after a failed build: steps '$steps'"
configs_made=$(LC_ALL=C ls "$t/configs" 2>/dev/null | tr '\n' ' ')
[ "$configs_made" = "config.json config_background.json " ] || fail "after a failed build: configs '$configs_made'"
[ "$(last)" = "[SUCCESS] Project installed successfully." ] || fail "after a failed build: last line '$(last)'"
# The build fails again: no service, a non-zero exit.
host clone
run setup fails
[ "$code" -ne 0 ] || fail "failing build: exit 0"
[ "$steps" = "STEP build " ] || fail "failing build: steps '$steps'"
[ "$(last)" = "[ERROR] Failed to build project." ] || fail "failing build: last line '$(last)'"
# Built, configs kept, no service: the service alone; both configs byte-identical, one
# line each.
host clone configs build
cp "$t/configs/config.json" "$w/c1"; cp "$t/configs/config_background.json" "$w/c2"
run setup
[ "$steps" = "STEP service " ] || fail "no service yet: steps '$steps'"
cmp -s "$t/configs/config.json" "$w/c1" && cmp -s "$t/configs/config_background.json" "$w/c2" || fail "no service yet: a kept config changed"
[ "$(keeping config.json)" -eq 1 ] && [ "$(keeping config_background.json)" -eq 1 ] || fail "no service yet: not one keeping line per config"
[ "$(last)" = "[SUCCESS] Project installed successfully." ] || fail "no service yet: last line '$(last)'"
# One config missing: the other kept, the missing one generated.
host clone configs build service
rm "$t/configs/config_background.json"
cp "$t/configs/config.json" "$w/c1"
run setup
[ "$steps" = "" ] || fail "one config missing: steps '$steps'"
cmp -s "$t/configs/config.json" "$w/c1" || fail "one config missing: the kept config changed"
[ "$(keeping config.json)" -eq 1 ] && [ "$(keeping config_background.json)" -eq 0 ] || fail "one config missing: keeping lines"
grep -qxF "      \"user\": \"$wallet\"," "$t/configs/config_background.json" || fail "one config missing: not regenerated"
# Every step done (with --only-manual: no service asked; with --autostart: nothing started):
# nothing changes, and the run says so.
for mode in setup manual autostart; do
  case $mode in manual) host clone configs build ;; *) host clone configs build service ;; esac
  before=$(snapshot)
  run "$mode"
  [ "$code" -eq 0 ] || fail "complete ($mode): exit $code"
  [ "$steps" = "" ] || fail "complete ($mode): steps '$steps'"
  [ "$(snapshot)" = "$before" ] || fail "complete ($mode): files changed"
  [ "$out" = "[INFO] Checking project installation status...
[INFO] Project repository found at $t.
[SUCCESS] Monero miner appears to be already built at $t.
[SUCCESS] Project is already installed. No further action required." ] || { fail "complete ($mode): output"; printf '%s\n' "$out" | sed 's/^/    /'; }
done
[ "$rc" -eq 0 ] && echo "PASS installer-rerun"
exit "$rc"
