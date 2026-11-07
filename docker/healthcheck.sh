#!/bin/bash

# The container's health, read from the miner process: unhealthy only when the miner is gone, or
# when it holds an established connection to its pool, its pause flags do not let it pause, and it
# used no CPU time since the last check. A check sources this file and points these at fixtures.
PROC_DIR=/proc
CONFIG=/app/configs/config.json
# The last reading, "<pid> <ticks>", in memory: nothing is written to the disk.
STATE=/dev/shm/xmrig-health

# The CPU time a process used, in clock ticks: user plus system, fields 14 and 15 of its stat
# line, counted after the last ')' since the process name may hold spaces or parentheses.
function cpu_ticks() {
    local line fields
    read -r line <"$PROC_DIR/$1/stat" || return 1
    read -ra fields <<<"${line##*)}"
    [[ ${fields[11]} =~ ^[0-9]+$ ]] && [[ ${fields[12]} =~ ^[0-9]+$ ]] || return 1
    echo $((fields[11] + fields[12]))
}

# Whether the config sets a pause flag, so an idle miner may simply be paused.
function may_pause() {
    jq -e '."pause-on-battery" == true or ."pause-on-active" == true' "$CONFIG" >/dev/null 2>&1
}

# Whether the process holds an established TCP connection, over IPv4 or IPv6: one of its socket
# inodes in its own network namespace's tables with state 01.
function has_connection() {
    local fd link table st inode
    local -A mine=()
    for fd in "$PROC_DIR/$1"/fd/*; do
        link=$(readlink "$fd" 2>/dev/null) || continue
        if [[ $link =~ ^socket:\[([0-9]+)\]$ ]]; then mine[${BASH_REMATCH[1]}]=1; fi
    done
    [ "${#mine[@]}" -gt 0 ] || return 1
    for table in "$PROC_DIR/$1/net/tcp" "$PROC_DIR/$1/net/tcp6"; do
        [ -r "$table" ] || continue
        while read -r _ _ _ st _ _ _ _ _ inode _; do
            [ "$st" = 01 ] && [ -n "${mine[$inode]:-}" ] && return 0
        done <"$table"
    done
    return 1
}

function main() {
    local pid ticks last_pid="" last_ticks=""
    pid=$(pgrep -xo xmrig) || { echo "Unhealthy: the miner process is gone."; exit 1; }
    ticks=$(cpu_ticks "$pid") || { echo "Unhealthy: the miner process is gone."; exit 1; }
    if [ -r "$STATE" ]; then read -r last_pid last_ticks _ <"$STATE"; fi
    printf '%s %s\n' "$pid" "$ticks" >"$STATE"
    if [ "$last_pid" != "$pid" ] || ! [[ $last_ticks =~ ^[0-9]+$ ]]; then
        echo "Healthy: first check since the miner started."
    elif [ "$ticks" -gt "$last_ticks" ]; then
        echo "Healthy: mining."
    elif may_pause; then
        echo "Healthy: idle, and its pause flags let it pause."
    elif ! has_connection "$pid"; then
        echo "Healthy: waiting for its pool."
    else
        echo "Unhealthy: connected to its pool, not paused, and no CPU time since the last check."
        exit 1
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
