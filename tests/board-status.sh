#!/bin/bash
# The board readout `make status` prints on Linux (scripts/board_status.sh): the hottest thermal
# zone by name, each cpufreq policy's frequency; on a board with a profile, the Pi 5 firmware's
# throttle flags in words (now and since boot) or, on RK3588, each tuned mining policy held below
# the maximum its mode set; the last hashrate the miner logged; the power line (Pi 5: the PMIC
# rails' sum, labelled partial; RK3588: no sensor); the cost per day from the wall figure and price
# the user gives, never from the PMIC figure, or how to give them. A reading it cannot get is
# printed as unavailable and it exits 0; on macOS it prints nothing. The board functions are the
# installer's, byte for byte. Fixture sysfs, device tree, values file and service log; stubs for
# uname, vcgencmd, systemctl and sudo (which only runs tail on the fixture log); nothing of this
# host's /sys, /proc, /etc or /var is read. Run from the repository root. Prints FAIL lines, exits
# 1 on any miss.
rc=0
root=$PWD
fail() { echo "FAIL $*"; rc=1; }
same() { # label, expected, got
  [ "$2" = "$3" ] || { fail "$1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/    /'; }
}
for f in board_compatible find_profile expand_cpus profile_ok; do
  a=$(sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/board_status.sh")
  b=$(sed -n "/^function $f() {\$/,/^}\$/p" "$root/scripts/install.sh")
  { [ -n "$b" ] && [ "$a" = "$b" ]; } || fail "$f differs between board_status.sh and install.sh"
done
w=$(mktemp -d) && [ -d "$w" ] || { echo "FAIL mktemp -d"; exit 1; }
trap 'rm -rf -- "$w"' EXIT
w=$(cd "$w" && pwd -P)
mkdir -p "$w/bin"
for t in awk cat cut dirname sed sort tail tr; do
  p=$(command -v "$t") || { echo "FAIL no $t on this host"; exit 1; }
  ln -s "$p" "$w/bin/$t"
done
cat > "$w/bin/uname" <<'EOS'
#!/bin/sh
echo "${UNAME_S:-Linux}"
EOS
# vcgencmd answers from fixture files; a missing file is a failed call.
cat > "$w/bin/vcgencmd" <<EOS
#!/bin/sh
[ -f "\$FX/vc-\$1" ] || exit 1
cat "\$FX/vc-\$1"
EOS
cat > "$w/bin/systemctl" <<'EOS'
#!/bin/sh
[ "$1 $3" = "show User" ] && echo "${SVC_USER:-}"
exit 0
EOS
# sudo: only `sudo -u <account> tail ...` runs, and only tail; it records the call.
cat > "$w/bin/sudo" <<EOS
#!/bin/sh
echo "sudo \$*" >> "$w/sudo.log"
[ "\$1 \$3" = "-u tail" ] || exit 1
shift 2
exec "$w/bin/tail" "\$@"
EOS
chmod 755 "$w/bin/"*

zone() { mkdir -p "$FX/thermal/thermal_zone$1"; printf '%s\n' "$2" > "$FX/thermal/thermal_zone$1/type"; printf '%s\n' "$3" > "$FX/thermal/thermal_zone$1/temp"; }
pol() { # name cur max hw
  mkdir -p "$FX/cpufreq/$1"
  printf '%s\n' "$2" > "$FX/cpufreq/$1/scaling_cur_freq"; printf '%s\n' "$3" > "$FX/cpufreq/$1/scaling_max_freq"
  printf '%s\n' "$4" > "$FX/cpufreq/$1/cpuinfo_max_freq"
}
fx() { # name compatible...
  FX="$w/$1"; shift
  mkdir -p "$FX/log/alice"
  printf '%s\0' "$@" > "$FX/compatible"
}
status() { # runs the script against FX; extra NAME=value pairs
  env -i PATH="$w/bin" FX="$FX" SVC_USER=alice "$@" "$BASH" --norc --noprofile -c '
    s=$1; source "$s" || exit 9
    THERMAL_DIR=$FX/thermal CPUFREQ_DIR=$FX/cpufreq DT_COMPATIBLE=$FX/compatible TUNING_CONF=$FX/conf LOG_ROOT=$FX/log
    main' board-status "$root/scripts/board_status.sh" 2>&1
  echo "exit $?"
}
speed='[2026-11-10 12:00:00.123]  miner    speed 10s/60s/15m 2345.6 2340.1 n/a H/s max 2400.3 H/s'

# Orange Pi 5 Plus, tuned in eco: policy6 held at 1.6 GHz under its 1.8 GHz cap.
fx opi xunlong,orangepi-5-plus rockchip,rk3588
zone 0 package-thermal 61000; zone 1 bigcore0-thermal 63615; zone 2 bigcore2-thermal 62000
zone 3 littlecore-thermal 55000; zone 4 center-thermal 58000; zone 5 gpu-thermal 50000; zone 6 npu-thermal 50000
pol policy0 408000 1800000 1800000; pol policy4 1800000 1800000 2400000; pol policy6 1608000 1800000 2400000
printf '%s\n' mode=eco policy0=powersave 'policy4=performance 1800000' 'policy6=performance 1800000' hugepages=1280 > "$FX/conf"
printf '%s\n' 'older line' "$speed" 'net      new job' > "$FX/log/alice/xmrig.log"
same "opi, no wall figure" '
Board readout:
  Temperature: bigcore0-thermal at 63.6 °C, the hottest of 7 zones.
  CPU policy0: 408 MHz now, at most 1800 MHz.
  CPU policy4: 1800 MHz now, at most 1800 MHz.
  CPU policy6: 1608 MHz now, at most 1800 MHz.
  CPU policy6 runs at 1608 MHz, below the 1800 MHz its mode set: likely held by heat.
  Hashrate: 2340.1 H/s, the last the miner logged.
  Power: no power sensor: use a wall meter.
  Cost: give your wall meter'"'"'s watts and your price per kWh, such as: make status WALL_WATTS=9.5 KWH_PRICE=0.25
exit 0' "$(status)"
same "opi cost" '  Cost: 0.06 per day at 9.5 W from the wall and 0.25 per kWh; 246.3 H/s per wall watt.' \
  "$(status WALL_WATTS=9.5 KWH_PRICE=0.25 | grep 'Cost:')"
same "the log read as the account" "sudo -u alice tail -n 500 -- $FX/log/alice/xmrig.log" "$(tail -n 1 "$w/sudo.log")"
for bad in "WALL_WATTS=0 KWH_PRICE=0.25" "WALL_WATTS=9.5" "WALL_WATTS=-3 KWH_PRICE=0.25" "WALL_WATTS=9.5 KWH_PRICE=1e3" "WALL_WATTS=9,5 KWH_PRICE=0.25"; do
  # shellcheck disable=SC2086
  same "cost refused: $bad" "  Cost: give your wall meter's watts and your price per kWh, such as: make status WALL_WATTS=9.5 KWH_PRICE=0.25" "$(status $bad | grep 'Cost:')"
done
# max: held below the hardware maximum; a policy at its setting says nothing.
printf '%s\n' mode=max 'policy0=performance max' 'policy4=performance max' 'policy6=performance max' > "$FX/conf"
pol policy0 1800000 1800000 1800000; pol policy4 2400000 2400000 2400000; pol policy6 2208000 2400000 2400000
same "opi max held" '  CPU policy6 runs at 2208 MHz, below the 2400 MHz its mode set: likely held by heat.' "$(status | grep 'held')"
# Untuned: no held line; no account or no speed line: hashrate unavailable.
rm "$FX/conf"
same "opi untuned" "" "$(status | grep 'held')"
printf 'net      new job\n' > "$FX/log/alice/xmrig.log"
same "no speed line" "  Hashrate: unavailable (no speed line in the service log yet)." "$(status | grep 'Hashrate')"
# An account name not of the expected form is never put in a path, even when a log sits there.
mkdir -p "$FX/root"; printf '%s\n' "$speed" > "$FX/root/xmrig.log"; : > "$w/sudo.log"
same "bad account name" "  Hashrate: unavailable (no speed line in the service log yet)." "$(status SVC_USER='../root' | grep 'Hashrate')"
same "bad account name: no read" "" "$(cat "$w/sudo.log")"

# Raspberry Pi 5: the firmware flags in words, the PMIC sum labelled partial, never in the cost.
fx pi raspberrypi,5-model-b brcm,bcm2712
zone 0 cpu-thermal 71250
pol policy0 1800000 1800000 2400000
printf '%s\n' "$speed" > "$FX/log/alice/xmrig.log"
printf 'throttled=0x50005\n' > "$FX/vc-get_throttled"
printf '%s\n' ' 3V3_SYS_A current(1)=0.50000000A' '  VDD_CORE_A current(7)=2.00000000A' '  3V3_SYS_V volt(9)=3.30000000V' \
  '  VDD_CORE_V volt(15)=0.80000000V' '     EXT5V_V volt(24)=5.07190000V' '  HDMI_A current(22)=0.02002440A' > "$FX/vc-pmic_read_adc"
same "pi" '
Board readout:
  Temperature: cpu-thermal at 71.2 °C, the hottest of 1 zones.
  CPU policy0: 1800 MHz now, at most 1800 MHz.
  Throttling now: under-voltage, throttled.
  Throttling since boot: under-voltage, throttled.
  Hashrate: 2340.1 H/s, the last the miner logged.
  Power: PMIC ≈ 3.2 W (excludes USB, fan, 5 V).
  Cost: 0.06 per day at 10 W from the wall and 0.25 per kWh; 234.0 H/s per wall watt.
exit 0' "$(status WALL_WATTS=10 KWH_PRICE=0.25)"
printf 'throttled=0x0\n' > "$FX/vc-get_throttled"
# Rails with a current and no voltage give no figure.
printf '%s\n' '  HDMI_A current(22)=0.02002440A' '     EXT5V_V volt(24)=5.07190000V' > "$FX/vc-pmic_read_adc"
same "pi unpaired rails" "  Power: PMIC unavailable (vcgencmd pmic_read_adc gave no answer)." "$(status | grep 'Power:')"
same "pi no flags" "  Throttling now: none.
  Throttling since boot: none." "$(status | grep Throttling)"
printf 'throttled=0xA0008\n' > "$FX/vc-get_throttled"
same "pi past flags" "  Throttling now: soft temperature limit.
  Throttling since boot: frequency capped, soft temperature limit." "$(status | grep Throttling)"
# Without vcgencmd answers, without sensors or frequencies: unavailable lines, exit 0.
rm "$FX/vc-get_throttled" "$FX/vc-pmic_read_adc"
rm -r "$FX/thermal" "$FX/cpufreq"
same "pi, nothing readable" '
Board readout:
  Temperature: unavailable.
  CPU frequencies: unavailable.
  Throttling: unavailable (vcgencmd get_throttled gave no answer).
  Hashrate: 2340.1 H/s, the last the miner logged.
  Power: PMIC unavailable (vcgencmd pmic_read_adc gave no answer).
  Cost: give your wall meter'"'"'s watts and your price per kWh, such as: make status WALL_WATTS=9.5 KWH_PRICE=0.25
exit 0' "$(status)"

# A host with no profile: temperature and frequencies only. macOS: nothing.
fx pc acme,desktop
zone 0 x86_pkg_temp 45000
pol policy0 3000000 4000000 4000000
same "no profile" '
Board readout:
  Temperature: x86_pkg_temp at 45.0 °C, the hottest of 1 zones.
  CPU policy0: 3000 MHz now, at most 4000 MHz.
exit 0' "$(status)"
same "macOS" "exit 0" "$(status UNAME_S=Darwin)"
# make status runs the readout through BOARD_STATUS, after the service's status.
grep -qx '	@bash $(BOARD_STATUS)' "$root/Makefile" || fail "make status does not run the readout"
same "readout path" 'BOARD_STATUS := ./scripts/board_status.sh' "$(grep '^BOARD_STATUS :=' "$root/Makefile")"

[ "$rc" -eq 0 ] && echo "PASS board-status"
exit "$rc"
