#!/bin/bash
# Sourced by setup_service_debian.sh and setup_service_macos.sh; runs nothing itself.
#
# In background mode xmrig forks and the process the service manager started exits 0 at once:
# systemd then counts the service as ended, and launchd starts a new one, each start leaving one
# more miner nobody supervises. The service config runs the miner in the foreground.

BACKGROUND_ON='^[[:space:]]*"background":[[:space:]]*true,?$'

# True when the config at $1 turns background mode on.
function background_is_on() {
    grep -Eq "$BACKGROUND_ON" "$1" 2>/dev/null
}

# Turns background mode off in the config at $1, that one line alone, and says so. Written
# through the configs/ link, so the file keeps its place, owner and mode; the trailing x keeps
# the file's last newlines, which command substitution would strip.
function turn_background_off() {
    local config="$1" edited
    background_is_on "$config" || return 0
    edited=$(sed -E 's/^([[:space:]]*"background":[[:space:]]*)true(,?)$/\1false\2/' "$config" && echo x) || return 1
    printf '%s' "${edited%x}" > "$config" || return 1
    echo "Turned off background mode in $config: the service now supervises the miner."
}

# Reports the xmrig processes of an account ($3, this user when empty) that run on a service config
# ($1) with no terminal, other than the one the service manager started ($2, empty or 0 for none):
# those an earlier background-mode start left behind. Prints the command that stops them; stops none of them.
function report_detached_miners() {
    local config="$1" service_pid="${2:-0}" account="${3:-$(id -u)}" pid tty args found=()
    for pid in $(pgrep -u "$account" -x xmrig); do
        [ "$pid" = "$service_pid" ] && continue
        read -r tty args < <(ps -o tty= -o args= -p "$pid")
        case $tty in '?' | '??') ;; *) continue ;; esac
        case $args in *"$config"*) found+=("$pid") ;; esac
    done
    [ ${#found[@]} -gt 0 ] || return 0
    echo "Warning: xmrig is still running detached from an earlier background-mode start: PID ${found[*]}."
    echo "Stop it with: kill ${found[*]}"
}
