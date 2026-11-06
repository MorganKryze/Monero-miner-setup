#!/bin/bash
# The native build's job count: one per CPU, at most one per whole GiB of memory available
# (Linux MemAvailable; macOS free, inactive and speculative pages), at least one, and one when
# memory cannot be read. Reads the count `make -n build` would use for set CPU and memory sizes,
# for fixture memory reports and for this host. The build line calls make, never $(MAKE):
# `make -n` runs $(MAKE) lines, so the dry-run checks would start a real build.
# Run from the repository root. Prints FAIL lines, exits 1 on any miss.
rc=0
f=Makefile
jobs_for() {
  make -n "$@" 2>/dev/null | sed -n 's/^cd build-xmrig && make -j\([0-9][0-9]*\); \\$/\1/p'
}
# Whole lines: the three variables, defined once each, and the build line.
while IFS= read -r line; do
  [ "$(grep -cxF -- "$line" "$f")" -eq 1 ] || { echo "FAIL line: ${line:0:24}"; rc=1; }
done <<'LINES'
CPUS := $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
MEM_GIB := $(shell awk '/^MemAvailable:/ {print int($$2 / 1048576)}' /proc/meminfo 2>/dev/null || vm_stat 2>/dev/null | awk '/page size of/ {p = $$8} /^Pages (free|inactive|speculative):/ {n += $$3} END {if (p) print int(n * p / 1073741824)}')
BUILD_JOBS := $(shell j=$(CPUS); m=$(MEM_GIB); [ "$${m:-0}" -lt "$$j" ] && j=$${m:-0}; [ "$$j" -ge 1 ] || j=1; echo "$$j")
	@cd $(BUILD_DIR) && make -j$(BUILD_JOBS); \
LINES
[ "$(grep -cE '^(CPUS|MEM_GIB|BUILD_JOBS)[[:space:]]*[:?+]?=' "$f")" -eq 3 ] || { echo "FAIL definitions (CPUS, MEM_GIB, BUILD_JOBS once each)"; rc=1; }
# The formula: CPUS MEM_GIB expected-jobs ("-" = memory unknown).
while read -r cpus mem want; do
  [ "$mem" = "-" ] && mem=""
  got=$(jobs_for build CPUS="$cpus" MEM_GIB="$mem")
  [ "$got" = "$want" ] || { echo "FAIL CPUS=$cpus MEM_GIB=$mem: -j${got:-none}, want -j$want"; rc=1; }
done <<'CASES'
4 0 1
4 1 1
4 3 3
4 7 4
8 - 1
1 16 1
16 64 16
CASES
# The log line names the count it builds with: one job, or N jobs.
for cpus in 1 4; do
  want="[  INFO   ] Building XMRig with $cpus parallel job$([ "$cpus" -eq 1 ] || echo s)..."
  got=$(TERM=dumb make -n build CPUS="$cpus" MEM_GIB=64 2>/dev/null | grep -F 'Building XMRig with' | sh)
  [ "$got" = "$want" ] || { echo "FAIL log line for $cpus job(s): '$got'"; rc=1; }
done
# The memory reading, through make itself: a copy of the Makefile reads a fixture instead of
# /proc/meminfo, and a vm_stat stub stands in for macOS's. 64 CPUs, so memory sets the count.
d=$(mktemp -d) && [ -d "$d" ] || { echo "FAIL mktemp -d"; exit 1; }
mkdir "$d/bin"
sed "s#/proc/meminfo#$d/meminfo#" "$f" > "$d/Makefile"
printf '#!/bin/sh\n[ -f "%s/vm_stat.out" ] || exit 1\ncat "%s/vm_stat.out"\n' "$d" "$d" > "$d/bin/vm_stat"
chmod +x "$d/bin/vm_stat"
fixture() { # name, want; the fixture files are in place
  got=$(PATH="$d/bin:$PATH" jobs_for -f "$d/Makefile" build CPUS=64)
  [ "$got" = "$2" ] || { echo "FAIL memory $1: -j${got:-none}, want -j$2"; rc=1; }
  rm -f "$d/meminfo" "$d/vm_stat.out"
}
# A 4 GB host while mining: 3.7 GiB installed, 1.4 GiB available.
printf 'MemTotal:        3884568 kB\nMemFree:          204800 kB\nMemAvailable:    1468006 kB\n' > "$d/meminfo"
fixture linux-mining 1
printf 'MemTotal:        8040524 kB\nMemFree:         5242880 kB\nMemAvailable:    7340032 kB\n' > "$d/meminfo"
fixture linux-idle 7
printf 'MemTotal:        8040524 kB\nMemFree:         5242880 kB\n' > "$d/meminfo"
fixture linux-no-memavailable 1
cat > "$d/vm_stat.out" <<'VM'
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                              100000.
Pages active:                            900000.
Pages inactive:                          200000.
Pages speculative:                        50000.
Pages throttled:                              0.
Pages wired down:                        300000.
Pages purgeable:                         400000.
VM
fixture macos 5
fixture neither 1
# This host: its CPUs, and one snapshot of its own memory report (real format, frozen, so
# memory moving while the check runs cannot change the answer).
cpus=$(getconf _NPROCESSORS_ONLN)
if [ -r /proc/meminfo ]; then
  cat /proc/meminfo > "$d/meminfo"
  m=$(awk '/^MemAvailable:/ {print int($2 / 1048576)}' "$d/meminfo")
else
  vm_stat > "$d/vm_stat.out"
  m=$(awk '/page size of/ {p = $8} /^Pages (free|inactive|speculative):/ {n += $3} END {print int(n * p / 1073741824)}' "$d/vm_stat.out")
fi
want=$(( cpus < ${m:-0} ? cpus : ${m:-0} ))
[ "$want" -ge 1 ] || want=1
got=$(PATH="$d/bin:$PATH" jobs_for -f "$d/Makefile" build)
[ "$got" = "$want" ] || { echo "FAIL this host ($cpus CPUs, ${m:-?} GiB available): -j${got:-none}, want -j$want"; rc=1; }
rm -r -- "${d:?}"
[ "$rc" -eq 0 ] && echo "PASS build-jobs (this host: -j$got, $cpus CPUs, ${m:-?} GiB available)"
exit "$rc"
