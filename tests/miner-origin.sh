#!/bin/bash
# The service's start-up step that logs where the miner binary comes from and the donate level
# it starts with: compiled here (no release record), a release (the record's hash matches the
# binary), or unknown (the record matches nothing, or the binary cannot be read). It never blocks
# the start. The line is taken from the unit template, rendered as the setup does, and run as
# systemd would run it, with PATH holding only links to the plain tools it uses.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
same() { # label, expected, got
  [ "$2" = "$3" ] || { fail "$1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/    /'; }
}
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
chmod 755 "$w"
mkdir "$w/clone" "$w/tools" && chmod 755 "$w/clone" "$w/tools" || exit 1

sed -e "s|%%USER%%|alice|g" -e "s|%%GROUP%%|alice|g" -e "s|%%WORKING_DIR%%|$w/clone|g" \
  "$root/templates/xmrig.service.template" > "$w/unit" && chmod 644 "$w/unit"
n=$(grep -c "^ExecStartPre=-/bin/sh -c '.*Miner binary:" "$w/unit")
same "one start-up step names the binary's origin" "1" "$n"
line=$(grep "^ExecStartPre=-/bin/sh -c '.*Miner binary:" "$w/unit" | head -n 1)
next=$(grep -A1 "^ExecStartPre=-/bin/sh -c '.*Miner binary:" "$w/unit" | sed -n 2p)
case "$next" in ExecStart=*) ;; *) fail "the line after the step is not ExecStart=: $next" ;; esac
case "$line" in *"' miner-origin $w/clone /var/lib/xmrig/alice/config.json") ;; *) fail "the step does not end with its arguments" ;; esac
case "$line" in *%*) fail "the step holds a percent sign" ;; esac
case "$line" in *\\*) fail "the step holds a backslash" ;; esac

script=${line#*-c \'}
script=${script%\' miner-origin *}
script=$(printf '%s' "$script" | sed 's/\$\$/$/g')

for t in sha256sum cut grep cat; do
  ln -s "$(command -v "$t")" "$w/tools/$t" || exit 1
done
printf 'binary-a' > "$w/clone/xmrig" && chmod 755 "$w/clone/xmrig"
h=$(sha256sum < "$w/clone/xmrig" | cut -c1-64)
conf() { # pool url, donate level
  printf '    "pools": [{\n        "url": "%s",\n        "pass": "rig-secret",\n    }],\n    "donate-level": %s,\n' "$1" "$2" > "$w/config.json" && chmod 644 "$w/config.json"
}
conf pool.example.org:4444 1
zeros=$(printf '%064d' 0)
run() { env -i PATH="$w/tools" /bin/sh -c "$script" miner-origin "$w/clone" "$w/config.json" 2>/dev/null; }

same "no record" 'Miner binary: compiled on this host; donate level 1 (as XMRig applies it)' "$(run)"
printf 'v0.2.0 %s\n' "$h" > "$w/clone/xmrig.release" && chmod 644 "$w/clone/xmrig.release"
same "matching record" "Miner binary: release v0.2.0, sha256 $h"'; donate level 1 (as XMRig applies it)' "$(run)"
printf 'v0.2.0 %s\n' "$zeros" > "$w/clone/xmrig.release"
same "other record" "Miner binary: unknown (sha256 $h matches no release record)"'; donate level 1 (as XMRig applies it)' "$(run)"
mv "$w/clone/xmrig" "$w/xmrig.away"
same "record, no binary" 'Miner binary: unknown (sha256 unreadable matches no release record); donate level 1 (as XMRig applies it)' "$(run)"
printf 'v0.2.0 \n' > "$w/clone/xmrig.release"
same "empty hash, no binary" 'Miner binary: unknown (sha256 unreadable matches no release record); donate level 1 (as XMRig applies it)' "$(run)"
mv "$w/xmrig.away" "$w/clone/xmrig"
rm "$w/clone/xmrig.release"
conf pool.moneroocean.stream:10128 1
same "moneroocean pool" 'Miner binary: compiled on this host; donate level 0 (as XMRig applies it)' "$(run)"
conf pool.example.org:4444 0
same "other pool, level 0" 'Miner binary: compiled on this host; donate level 1 (as XMRig applies it)' "$(run)"
conf pool.example.org:4444 3
same "other pool, level 3" 'Miner binary: compiled on this host; donate level 3 (as XMRig applies it)' "$(run)"
conf pool.example.org:4444 100
same "other pool, level 100" 'Miner binary: compiled on this host; donate level 1 (as XMRig applies it)' "$(run)"
# The step writes nothing to stderr, which systemd sends to the journal too.
same "stderr" "" "$(env -i PATH="$w/tools" /bin/sh -c "$script" miner-origin "$w/clone" "$w/config.json" 2>&1 >/dev/null)"
printf '    "pools": [{\n        "url": "pool.example.org:4444",\n    }, {\n        "url": "pool.moneroocean.stream:10128",\n    }],\n    "donate-level": 0,\n' > "$w/config.json"
same "first pool decides, second is moneroocean" 'Miner binary: compiled on this host; donate level 1 (as XMRig applies it)' "$(run)"
printf '    "pools": [{\n        "url": "pool.moneroocean.stream:10128",\n    }, {\n        "url": "pool.example.org:4444",\n    }],\n    "donate-level": 1,\n' > "$w/config.json"
same "first pool moneroocean, second other" 'Miner binary: compiled on this host; donate level 0 (as XMRig applies it)' "$(run)"
mv "$w/config.json" "$w/config.away"
same "no config" 'Miner binary: compiled on this host; donate level unknown' "$(run)"

[ "$rc" -eq 0 ] && echo "PASS miner-origin"
exit "$rc"
