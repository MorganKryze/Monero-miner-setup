#!/bin/bash
# The boot-time tuning a dedicated miner's board runs as root (scripts/host_tuning.sh, installed as
# /usr/local/sbin/xmrig-host-tuning, run by xmrig-host-tuning.service): `apply` sets each cpufreq
# policy the values file names (the mining ones to performance, capped in eco, the others to
# powersave) and raises the 2 MB huge page reservation, recording what it found once; `restore`
# gives each policy back its governor and maximum. A policy it cannot set, or a line not of the
# expected form, is left as found with one journal line, and apply always exits 0 so the miner starts.
# Runs against fixture cpufreq trees holding the values a Raspberry Pi 5 and an Orange Pi 5 Plus
# report under DietPi; PATH holds only links to plain tools, and nothing of this host's /sys, /proc,
# /etc or /run is read or written. Run from the repository root. Prints FAIL lines, exits 1 on any
# miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
same() { # label, expected, got
  [ "$2" = "$3" ] || { fail "$1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/    /'; }
}
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/tools"
for t in awk grep rm cat mv; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/tools/$t"
done

# The script reads and writes only these paths, every one fixed in its constants.
same "constants" 'TUNING_CONF="/etc/xmrig-host-tuning.conf"
RECORD="/run/xmrig-host-tuning/found"
CPUFREQ_DIR="/sys/devices/system/cpu/cpufreq"
MEMINFO="/proc/meminfo"
NR_HUGEPAGES="/proc/sys/vm/nr_hugepages"' "$(sed -n '/^# ===== Constants =====$/,/^$/p' "$root/scripts/host_tuning.sh" | sed '1d;$d')"
same "absolute paths outside the constants" "" \
  "$(sed '/^# ===== Constants =====$/,/^$/d' "$root/scripts/host_tuning.sh" | grep -v '^ *#' | grep -oE '(^|[ "=<>])/[a-z]+/[^ "]*' | grep -v '/dev/null')"
same "unit" '[Unit]
Description=Host tuning for the XMRig miner (CPU frequency, huge pages)
After=dietpi-preboot.service ondemand.service cpufrequtils.service
Before=xmrig.service
[Service]
Type=oneshot
RemainAfterExit=yes
RuntimeDirectory=xmrig-host-tuning
RuntimeDirectoryMode=0700
RuntimeDirectoryPreserve=yes
ExecStart=/usr/local/sbin/xmrig-host-tuning apply
ExecStop=/usr/local/sbin/xmrig-host-tuning restore
[Install]
WantedBy=multi-user.target' "$(grep -v -e '^#' -e '^$' "$root/templates/xmrig-host-tuning.service.template")"

# policy <tree> <name> <cpus> <hw max> <governor> <max> <frequencies>
policy() {
  local d="$w/$1/cpufreq/$2"
  mkdir -p "$d"
  printf '%s\n' "$3" > "$d/related_cpus"
  printf '%s\n' "$4" > "$d/cpuinfo_max_freq"
  printf '%s\n' "$5" > "$d/scaling_governor"
  printf '%s\n' "$6" > "$d/scaling_max_freq"
  printf '%s \n' "$7" > "$d/scaling_available_frequencies"
  printf 'conservative ondemand userspace powersave performance schedutil \n' > "$d/scaling_available_governors"
}
rk="408000 600000 816000 1008000 1200000 1416000 1608000 1800000"
big="$rk 2016000 2208000 2400000"
pi="1500000 1600000 1700000 1800000 1900000 2000000 2100000 2200000 2300000 2400000"
# tree <name> <board>: a fresh tree as the board reports it after boot.
tree() {
  rm -rf "${w:?}/$1"
  mkdir -p "$w/$1/run"
  if [ "$2" = opi5plus ]; then
    policy "$1" policy0 "0 1 2 3" 1800000 schedutil 1800000 "$rk"
    policy "$1" policy4 "4 5" 2400000 schedutil 2400000 "$big"
    policy "$1" policy6 "6 7" 2400000 schedutil 2400000 "$big"
    printf 'MemTotal:       16184388 kB\nHugepagesize:       2048 kB\n' > "$w/$1/meminfo"
  else
    policy "$1" policy0 "0 1 2 3" 2400000 schedutil 2400000 "$pi"
    printf 'MemTotal:        8255824 kB\n' > "$w/$1/meminfo"
  fi
  printf '0\n' > "$w/$1/nr_hugepages"
}
# run <tree> <command>, the values file read from <tree>/conf.
run() {
  local d="$w/$1"
  env -i PATH="$w/tools" "$BASH" --norc --noprofile -c '
    source "$1" || exit 9
    TUNING_CONF=$2/conf RECORD=$2/run/found CPUFREQ_DIR=$2/cpufreq MEMINFO=$2/meminfo NR_HUGEPAGES=$2/nr_hugepages
    "$3"' host-tuning "$root/scripts/host_tuning.sh" "$d" "$2" 2>&1
  echo "exit $?"
}
state() { # <tree>: each policy's governor and maximum, then the huge pages
  local p
  for p in "$w/$1"/cpufreq/policy*; do echo "${p##*/} $(cat "$p/scaling_governor") $(cat "$p/scaling_max_freq")"; done
  echo "hugepages $(cat "$w/$1/nr_hugepages")"
}

# Orange Pi 5 Plus in eco: the big clusters mine at 1.8 GHz at most, the little one saves power.
tree opi opi5plus
printf '%s\n' '# Written by the service setup.' mode=eco policy0=powersave 'policy4=performance 1800000' 'policy6=performance 1800000' hugepages=1280 > "$w/opi/conf"
same "opi eco apply" 'xmrig-host-tuning: mode eco.
xmrig-host-tuning: policy0: governor powersave.
xmrig-host-tuning: policy4: governor performance, at most 1800 MHz.
xmrig-host-tuning: policy6: governor performance, at most 1800 MHz.
xmrig-host-tuning: huge pages: 1280 of 2 MB reserved (wanted 1280).
exit 0' "$(run opi apply)"
same "opi eco state" 'policy0 powersave 1800000
policy4 performance 1800000
policy6 performance 1800000
hugepages 1280' "$(state opi)"
same "opi record" 'policy0 schedutil 1800000
policy4 schedutil 2400000
policy6 schedutil 2400000' "$(cat "$w/opi/run/found")"
# A second apply (the unit started again without a stop) keeps the first record.
run opi apply >/dev/null
same "opi record after a second apply" 'policy0 schedutil 1800000
policy4 schedutil 2400000
policy6 schedutil 2400000' "$(cat "$w/opi/run/found")"
same "opi restore" 'xmrig-host-tuning: policy0: given back governor schedutil, at most 1800 MHz.
xmrig-host-tuning: policy4: given back governor schedutil, at most 2400 MHz.
xmrig-host-tuning: policy6: given back governor schedutil, at most 2400 MHz.
exit 0' "$(run opi restore)"
# The huge pages stay until the next boot: restore never writes the reservation.
same "opi state after restore" 'policy0 schedutil 1800000
policy4 schedutil 2400000
policy6 schedutil 2400000
hugepages 1280' "$(state opi)"
[ -e "$w/opi/run/found" ] && fail "restore left its record"
same "restore with no record" "exit 0" "$(run opi restore)"

# Orange Pi 5 Plus in max: every policy mines at its hardware maximum, raised from a lower cap the
# OS booted with.
tree opi opi5plus
printf '1800000\n' > "$w/opi/cpufreq/policy4/scaling_max_freq"
printf '%s\n' mode=max 'policy0=performance max' 'policy4=performance max' 'policy6=performance max' hugepages=1280 > "$w/opi/conf"
same "opi max apply" 'xmrig-host-tuning: mode max.
xmrig-host-tuning: policy0: governor performance, at most 1800 MHz.
xmrig-host-tuning: policy4: governor performance, at most 2400 MHz.
xmrig-host-tuning: policy6: governor performance, at most 2400 MHz.
xmrig-host-tuning: huge pages: 1280 of 2 MB reserved (wanted 1280).
exit 0' "$(run opi apply)"
same "opi max state" 'policy0 performance 1800000
policy4 performance 2400000
policy6 performance 2400000
hugepages 1280' "$(state opi)"

# Raspberry Pi 5: one policy; no huge page size in its kernel, so no huge-page line is written.
tree pi pi5
printf '%s\n' mode=eco 'policy0=performance 1800000' > "$w/pi/conf"
same "pi eco apply" 'xmrig-host-tuning: mode eco.
xmrig-host-tuning: policy0: governor performance, at most 1800 MHz.
exit 0' "$(run pi apply)"
same "pi eco state" 'policy0 performance 1800000
hugepages 0' "$(state pi)"
tree pi pi5
printf '1800000\n' > "$w/pi/cpufreq/policy0/scaling_max_freq"
printf '%s\n' mode=max 'policy0=performance max' > "$w/pi/conf"
same "pi max apply" 'xmrig-host-tuning: mode max.
xmrig-host-tuning: policy0: governor performance, at most 2400 MHz.
exit 0' "$(run pi apply)"
same "pi max state" 'policy0 performance 2400000
hugepages 0' "$(state pi)"
# A huge-page line on a kernel without a 2 MB default page writes nothing.
printf '%s\n' hugepages=1280 > "$w/pi/conf"
same "pi huge pages" 'xmrig-host-tuning: huge pages: none reserved, the kernel'"'"'s default huge page is not 2 MB.
exit 0' "$(run pi apply)"
same "pi huge pages state" "0" "$(cat "$w/pi/nr_hugepages")"

# Refusals: each policy left byte for byte as found, one line each, the miner still started.
tree opi opi5plus
printf 'conservative ondemand powersave schedutil \n' > "$w/opi/cpufreq/policy6/scaling_available_governors"
printf '%s\n' 'policy9=performance 1800000' 'policy4=performance 2600000' 'policy0=performance 1700000' 'policy6=performance 1800000' > "$w/opi/conf"
same "refusals" 'xmrig-host-tuning: policy9: left as found, this host has no such policy.
xmrig-host-tuning: policy4: left as found, 2600000 kHz is above its hardware maximum of 2400000 kHz.
xmrig-host-tuning: policy0: left as found, 1700000 kHz is not one of its available frequencies.
xmrig-host-tuning: policy6: left as found, it does not offer the performance governor.
exit 0' "$(run opi apply)"
same "refusals state" 'policy0 schedutil 1800000
policy4 schedutil 2400000
policy6 schedutil 2400000
hugepages 0' "$(state opi)"
[ -e "$w/opi/run/found" ] && fail "a refused policy was recorded"
# Lines not of the expected form write nothing: a value that is not a number or max, another
# governor, a path, a second value, an oversized count.
printf '%s\n' 'policy4=performance 1800000; rm -rf /' 'policy4=userspace' '../policy4=performance' 'policy4=performance 1800000 2' 'hugepages=9999999' 'policy4 = performance' > "$w/opi/conf"
same "malformed lines" "$(printf 'xmrig-host-tuning: skipped a line of %s that is not of the expected form.\n' "$w/opi/conf" "$w/opi/conf" "$w/opi/conf" "$w/opi/conf" "$w/opi/conf" "$w/opi/conf")
exit 0" "$(run opi apply)"
same "malformed state" 'policy0 schedutil 1800000
policy4 schedutil 2400000
policy6 schedutil 2400000
hugepages 0' "$(state opi)"
# A kernel whose default huge page is 1 GB gets none either.
printf 'MemTotal:       16184388 kB\nHugepagesize:    1048576 kB\n' > "$w/opi/meminfo"
printf '%s\n' hugepages=1280 > "$w/opi/conf"
run opi apply >/dev/null
same "1 GB default page" "0" "$(cat "$w/opi/nr_hugepages")"
printf 'MemTotal:       16184388 kB\nHugepagesize:       2048 kB\n' > "$w/opi/meminfo"
# A reservation the user made larger is never lowered.
printf '2000\n' > "$w/opi/nr_hugepages"
printf '%s\n' hugepages=1280 > "$w/opi/conf"
run opi apply >/dev/null
same "larger reservation kept" "2000" "$(cat "$w/opi/nr_hugepages")"
# No values file: nothing set, exit 0. A bad command: usage, exit 2.
rm -f "$w/opi/conf"
same "no values file" "xmrig-host-tuning: no values file at $w/opi/conf: nothing set.
exit 0" "$(run opi apply)"
out=$(env -i PATH="$w/tools" "$BASH" --norc --noprofile "$root/scripts/host_tuning.sh" start 2>&1); code=$?
[ "$code" -eq 2 ] && [[ "$out" == "Usage: "*" apply|restore" ]] || fail "unknown command: exit $code, $out"
# The unit's own entry points: the script run as a file with `apply`, then `restore`, from a copy
# whose constants name the fixture tree.
tree opi opi5plus
printf '%s\n' mode=eco 'policy4=performance 1800000' > "$w/opi/conf"
sed -e "s|^TUNING_CONF=.*|TUNING_CONF=\"$w/opi/conf\"|" -e "s|^RECORD=.*|RECORD=\"$w/opi/run/found\"|" \
  -e "s|^CPUFREQ_DIR=.*|CPUFREQ_DIR=\"$w/opi/cpufreq\"|" -e "s|^MEMINFO=.*|MEMINFO=\"$w/opi/meminfo\"|" \
  -e "s|^NR_HUGEPAGES=.*|NR_HUGEPAGES=\"$w/opi/nr_hugepages\"|" "$root/scripts/host_tuning.sh" > "$w/host_tuning.sh"
same "fixture copy" 5 "$(grep -c "^[A-Z_]*=\"$w/opi/" "$w/host_tuning.sh")"
out=$(env -i PATH="$w/tools" "$BASH" --norc --noprofile "$w/host_tuning.sh" apply 2>&1); code=$?
same "file apply" 'xmrig-host-tuning: mode eco.
xmrig-host-tuning: policy4: governor performance, at most 1800 MHz.
exit 0' "$out
exit $code"
same "file apply state" 'policy0 schedutil 1800000
policy4 performance 1800000
policy6 schedutil 2400000
hugepages 0' "$(state opi)"
out=$(env -i PATH="$w/tools" "$BASH" --norc --noprofile "$w/host_tuning.sh" restore 2>&1); code=$?
same "file restore" 'xmrig-host-tuning: policy4: given back governor schedutil, at most 2400 MHz.
exit 0' "$out
exit $code"
same "file restore state" 'policy0 schedutil 1800000
policy4 schedutil 2400000
policy6 schedutil 2400000
hugepages 0' "$(state opi)"
[ -e "$w/opi/run/found" ] && fail "restore run as a file left its record"
# A record line not of the expected form is skipped, never written to a path.
tree opi opi5plus
printf '%s\n' '../../x performance 1' 'policy4 schedutil 2400000' > "$w/opi/run/found"
same "malformed record" 'xmrig-host-tuning: skipped a record line that is not of the expected form.
xmrig-host-tuning: policy4: given back governor schedutil, at most 2400 MHz.
exit 0' "$(run opi restore)"

# A write back that fails keeps the record and exits non-zero; a later apply does not record the
# tuned values as found.
tree opi opi5plus
printf '%s\n' 'policy4=performance 1800000' > "$w/opi/conf"
run opi apply >/dev/null
chmod 444 "$w/opi/cpufreq/policy4/scaling_governor"
same "failed restore" 'xmrig-host-tuning: policy4: could not be given back governor schedutil and maximum 2400000 kHz.
exit 1' "$(run opi restore)"
chmod 644 "$w/opi/cpufreq/policy4/scaling_governor"
same "record kept after a failed restore" 'policy4 schedutil 2400000' "$(cat "$w/opi/run/found" 2>&1)"
run opi apply >/dev/null
same "record after a failed restore and an apply" 'policy4 schedutil 2400000' "$(cat "$w/opi/run/found" 2>&1)"
# A partial failure keeps only the lines it could not give back: a policy given back is recorded
# afresh at the next apply, so a value the user set while the tuning was stopped is not overwritten.
tree opi opi5plus
printf '%s\n' policy0=powersave 'policy4=performance 1800000' > "$w/opi/conf"
run opi apply >/dev/null
rm -rf "${w:?}/opi/cpufreq/policy4"
same "partly failed restore" 'xmrig-host-tuning: policy0: given back governor schedutil, at most 1800 MHz.
xmrig-host-tuning: policy4: could not be given back governor schedutil and maximum 2400000 kHz.
exit 1' "$(run opi restore)"
same "record after a partly failed restore" 'policy4 schedutil 2400000' "$(cat "$w/opi/run/found" 2>&1)"
printf 'ondemand\n' > "$w/opi/cpufreq/policy0/scaling_governor"
run opi apply >/dev/null
run opi restore >/dev/null
same "a governor set after a partly failed restore" 'policy0 ondemand 1800000
policy6 schedutil 2400000
hugepages 0' "$(state opi)"
# A record that cannot be cut down (a full /run; here a directory where the new record goes) keeps
# every line it held: the policy not given back still has what was first found for it.
tree opi opi5plus
printf '%s\n' policy0=powersave 'policy4=performance 1800000' > "$w/opi/conf"
run opi apply >/dev/null
rm -rf "${w:?}/opi/cpufreq/policy4"
mkdir "$w/opi/run/found.new"
same "record not cut down" 'xmrig-host-tuning: policy0: given back governor schedutil, at most 1800 MHz.
xmrig-host-tuning: policy4: could not be given back governor schedutil and maximum 2400000 kHz.
xmrig-host-tuning: the record could not be cut down to the policies not given back.
exit 1' "$(run opi restore)"
same "record kept whole when it cannot be cut down" 'policy0 schedutil 1800000
policy4 schedutil 2400000' "$(cat "$w/opi/run/found" 2>&1)"
# The full count is reserved while 1024 MiB stays free: a 4 GB board, MemTotal 3776 MiB, keeps 1280.
tree opi opi5plus
printf 'MemTotal:        3866960 kB\nHugepagesize:       2048 kB\n' > "$w/opi/meminfo"
printf '%s\n' hugepages=1280 > "$w/opi/conf"
same "huge pages on a 4 GB board" 'xmrig-host-tuning: huge pages: 1280 of 2 MB reserved (wanted 1280).
exit 0' "$(run opi apply)"
same "huge pages on a 4 GB board state" "1280" "$(cat "$w/opi/nr_hugepages")"
# A count that would leave less than 1024 MiB free is not reserved at all: the dataset needs it whole.
tree opi opi5plus
printf 'MemTotal:        2699264 kB\nHugepagesize:       2048 kB\n' > "$w/opi/meminfo"
printf '%s\n' hugepages=1280 > "$w/opi/conf"
same "huge pages too many" 'xmrig-host-tuning: huge pages: none reserved, 1280 would leave less than 1024 MiB free.
exit 0' "$(run opi apply)"
same "huge pages too many state" "0" "$(cat "$w/opi/nr_hugepages")"
# No directory for the record: the policy is left as found.
tree opi opi5plus
rm -rf "${w:?}/opi/run"
printf '%s\n' 'policy4=performance 1800000' > "$w/opi/conf"
same "no record directory" 'xmrig-host-tuning: policy4: left as found, the record of what was found cannot be written.
exit 0' "$(run opi apply)"
same "no record directory state" 'policy0 schedutil 1800000
policy4 schedutil 2400000
policy6 schedutil 2400000
hugepages 0' "$(state opi)"
# A frequency matched as a whole word only (16000 is part of 1600000), and a found governor not of
# the expected form, are each left as found.
tree opi opi5plus
printf 'sched2\n' > "$w/opi/cpufreq/policy6/scaling_governor"
printf '%s\n' 'policy4=performance 16000' 'policy6=performance 1800000' > "$w/opi/conf"
same "word match and odd governor" 'xmrig-host-tuning: policy4: left as found, 16000 kHz is not one of its available frequencies.
xmrig-host-tuning: policy6: left as found, its current governor or maximum cannot be read.
exit 0' "$(run opi apply)"
same "word match and odd governor state" 'policy0 schedutil 1800000
policy4 schedutil 2400000
policy6 sched2 2400000
hugepages 0' "$(state opi)"
[ -e "$w/opi/run/found" ] && fail "a left policy was recorded"
# A record maximum that is not a number is skipped.
printf '%s\n' 'policy4 schedutil 24x' > "$w/opi/run/found"
same "malformed record maximum" 'xmrig-host-tuning: skipped a record line that is not of the expected form.
exit 0' "$(run opi restore)"
same "malformed record maximum state" 'policy4 schedutil 2400000' "$(sed -n 2p <(state opi))"

[ "$rc" -eq 0 ] && echo "PASS host-tuning-boot"
exit "$rc"
