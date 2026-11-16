# Raspberry Pi 5 and Orange Pi 5 boards

Read this if you mine on a Raspberry Pi 5 or an RK3588 board such as the Orange Pi 5 Plus or 5 Max, before you flash its card.

## What you need

- A Raspberry Pi 5, an Orange Pi 5 Plus or an Orange Pi 5 Max, with its power supply.
- A cooler. A Pi 5 needs one even in `eco`: see [Keep it cool](#keep-it-cool).
- An SD card and a PC that can write it.
- Ethernet, or one WPA-PSK Wi-Fi network.
- Your Monero wallet address.
- `dietpi-first-boot.zip` from the release page.

## Set up a card that mines on first boot

Use this for a board with no screen and no keyboard. You flash DietPi, drop three files on the card, plug in Ethernet or set Wi-Fi, power, and the board sets itself up and mines under its own name.

Each release ships `dietpi-first-boot.zip` with three files to copy, `dietpi.txt`, `Automation_Custom_Script.sh` and `Automation_Custom_PreScript.sh`, and `LICENSE-dietpi.txt`, the GPL-2.0 text that comes with DietPi's `dietpi.txt`.

1. Flash the official DietPi Trixie image for your board on an SD card.
2. Copy the three files from the zip onto the card, replacing DietPi's `dietpi.txt`:
   - Raspberry Pi 5: the boot partition, the FAT one your PC opens. DietPi moves the files off the FAT at first boot.
   - Orange Pi 5 Plus and 5 Max: the small FAT partition named `DIETPISETUP`. DietPi imports the files at first boot, then deletes that partition.
3. Open `Automation_Custom_Script.sh` and edit the settings at its top, between `: <<'END_OF_MINER_SETTINGS'` and `END_OF_MINER_SETTINGS`. Set `wallet` at least.
4. Plug in Ethernet, or set `wifi_ssid`, `wifi_key` and `wifi_country` in the settings (see [Wi-Fi](#wi-fi)).
5. Put the card in the board and power it.

Edit with an editor that keeps Unix (LF) line ends, such as VS Code or Notepad++. A value's trailing CR is dropped, but a script saved with CRLF line ends won't run.

### The settings

The settings are `key = value` lines, read as data: nothing in them is run or expanded. A line starting with `#` is a comment, so remove the `# ` to set a key. An empty value keeps the default. An unknown key, a key given twice or a value of the wrong form stops the setup, with one line naming the key, or the line number of a line that is not `key = value`.

| Setting as shipped | Default | Form |
| --- | --- | --- |
| `wallet =` | none: required | your Monero address, 1 to 128 base58 characters |
| `mode = eco` | none: required, shipped as `eco` | `max` mines on every CPU the board's profile allows; `eco` leaves headroom and runs cooler (see [Dedicated board](#dedicated-board---mode)) |
| `pool = gulf.moneroocean.stream` | the installer's, `gulf.moneroocean.stream` over TLS with MoneroOcean's certificate pinned; `stratum+tcp://gulf.moneroocean.stream` mines without TLS | 1 to 255 letters, digits or `. + : / _ -` |
| `name = rpi5-3fa2` | the board's host name | the worker name the pool shows, 1 to 64 letters, digits or `. _ - @ : +` |
| `donate = 0` | the installer's, `0` | a whole number from 0 to 5, in percent |
| `light = no` | `no` | `yes` lets a board under 2560 MiB of memory mine in RandomX's slower light mode; without it, such a board is refused |
| `mdns = off` | `off` | `on` installs `avahi-daemon` to announce `<host name>.local` |
| `ssh_key = ssh-ed25519 AAAA... you@laptop` | none: SSH off | one `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp384`, `ecdsa-sha2-nistp521` or `ssh-rsa` public key, then an optional comment |
| `tls_fingerprint =` | MoneroOcean's built-in pin on a MoneroOcean host over TLS; no pin on your own pool | your TLS pool's certificate sha256, 64 hex digits, with or without a colon between each pair. Needs a TLS pool: `stratum+ssl://` or a MoneroOcean host with no port |
| `wifi_ssid =` | none: no Wi-Fi, the cable only | the Wi-Fi network's name, 1 to 32 bytes with no control character, no `"` and no `\`. Needs `Automation_Custom_PreScript.sh` on the card, `wifi_key` and `wifi_country` |
| `wifi_key =` | none | the network's WPA-PSK key, 8 to 63 printable ASCII characters, or the 64 hex digits of its PSK; it's read as it stands after `=`, so put comments on their own line. Needs `Automation_Custom_PreScript.sh` on the card |
| `wifi_country = FR` | none | your country's two-letter code, such as `FR`, any case. Needs `Automation_Custom_PreScript.sh` on the card |

### Wi-Fi

Set `wifi_ssid`, `wifi_key` and `wifi_country` for one WPA-PSK network, such as `wifi_ssid = YOUR_WIFI_NAME` and `wifi_key = YOUR_WIFI_KEY`. The setup joins that one network and no other kind.

The key goes on the `wifi_key` line only. A key typed under another name, such as `wifi_password`, is an unknown key: the setup stops, and every `wifi_` line but `wifi_ssid` and `wifi_country` is emptied all the same.

A Wi-Fi name or key is read as it stands after `=`, a `#` or a quote included, so put comments on their own line. Quote a key only to keep a space at its start or end, or when it starts and ends with the same quote, and then with the kind of quote it doesn't hold (`wifi_key = ' YOUR WIFI KEY '`). For a key holding both kinds, give its 64-hex PSK instead.

Before DietPi's network, `Automation_Custom_PreScript.sh` runs as root. It writes `dietpi-wifi.txt` and sets `AUTO_SETUP_NET_WIFI_ENABLED=1` and your country in `dietpi.txt`. DietPi tries Wi-Fi first, then the cable when Wi-Fi fails.

- **A board with no Wi-Fi interface** uses its cable, with one journal line saying so.
- **A wrong name or key with no cable** leaves DietPi's first run unfinished. The setup never runs and the LED stays the board's own. Fix the settings on your PC, flash the card again, copy the three files and power.
- **A router whose key changed** leaves the board off the network. Flash it again with the new key, or set it with `dietpi-config` from a screen or the cable.

Afterwards the key lives in DietPi's `/var/lib/dietpi/dietpi-wifi.db` and `/etc/wpa_supplicant/wpa_supplicant.conf`, root-only, as the derived PSK. The setup removes it from `/boot/Automation_Custom_Script.sh` and from its own copy of the settings. The card's free space may still hold it until overwritten: the FAT's deleted blocks, and the blocks the root filesystem freed.

### What happens at first boot

1. `Automation_Custom_PreScript.sh` runs as root before the network and sets up Wi-Fi when you asked for it.
2. DietPi runs its first run, then our script once, as root.
3. The script copies your settings to a root-only file, installs `xmrig-first-boot.service` and starts it.
4. That service runs the setup at each boot until it has finished once.

A board that lost power during the setup picks it up at the next boot; network waits retry every 10 seconds within the boot. A power cut in the first seconds, before the service is installed, needs a reflash: DietPi never runs the script again.

### The status LED

The setup drives the board's status LED (Pi 5: `ACT`; 5 Plus: `green:indicator-2`; the 5 Max has none known, so it goes without):

| LED | Meaning |
| --- | --- |
| blinks, half a second on, half off | setting up, or waiting for the network |
| heartbeat | set up. It doesn't say the miner is mining now: `make status` or the pool's panel do |
| steady on | the setup stopped, for a bad setting or Wi-Fi asked for but never set up. `journalctl -u xmrig-first-boot.service` has the line that says why. Follow that line's remedy: for a setting, fix it and flash again, or fix `/var/lib/xmrig-first-boot/settings` over SSH and reboot |

A reboot gives the LED back to the board's own trigger until the setup unit sets it again, early in the boot.

### What the setup changes on the board

- `/usr/local/sbin/xmrig-first-boot` (0755, the script without your settings), `/etc/systemd/system/xmrig-first-boot.service` (0644) and the folder `/var/lib/xmrig-first-boot` (0700: your `settings` at 0600, the fetched `install.sh`, and the records `installing`, `done` and `mdns-installed`).
- With `wifi_ssid`, before DietPi's network: `dietpi-wifi.txt` (0600) in `/boot` on the root filesystem, `AUTO_SETUP_NET_WIFI_ENABLED=1` and `AUTO_SETUP_NET_WIFI_COUNTRY_CODE` in `dietpi.txt`, the record `/var/lib/xmrig-first-boot/wifi` (0600, the country only), and the `wifi_key` value emptied in `Automation_Custom_Script.sh`. DietPi then moves the key to its root-only database.
- The host name: `<model>-<last 4 hex digits of the first wired MAC>`, such as `rpi5-3fa2`, `opi5plus-3fa2` or `opi5max-3fa2`, in `/etc/hostname`, with one `127.0.1.1 <name>` line in `/etc/hosts` in place of any other `127.0.1.1` line. It's also the worker name unless you set `name`.
- SSH. With no `ssh_key`, every SSH unit (`dropbear` or `ssh`) is disabled, stopped and masked, so SSH is off. With one, it's added once to `/root/.ssh/authorized_keys` and password logins are turned off (a drop-in for OpenSSH, `-s -g` for Dropbear), so only key logins work, as `root`. A key the setup can't add turns SSH off. Until DietPi's first run and then the setup act, the image's own SSH server takes `root` with DietPi's default password: keep the board on a network you trust for its first minutes.
- `git`, `make` and `bc`, the ones DietPi's minimal image lacks: the installer needs them. They're Debian's, installed through apt without recommended packages.
- With `mdns = on`: `avahi-daemon`, when it isn't installed yet. It's Debian's (main, LGPL-2.1, about 0.3 MB installed for 0.8-16 on arm64, plus its libraries) and opens UDP port 5353.
- The miner, as the native install sets it: the setup fetches the release's `scripts/install.sh` from `https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/<tag>/scripts/install.sh`, checks it against the sha256 the zip's script carries, and runs it with `-w <wallet> --mode <mode> --prebuilt --autostart -y --name <name>`, plus `-p` and `--donate` when set. That installer clones `v<its version>` to `/opt/Monero-miner-setup`, a tag the repository owner controls, and sets up `xmrig.service` and the board tuning as [Dedicated board](#dedicated-board---mode) says. The sha256 covers the installer alone; what it then runs comes from that tag.

Bluetooth stays as the image ships it.

`make service-disable` (or `make wipe`) in `/opt/Monero-miner-setup` removes the unit, the script and `/var/lib/xmrig-first-boot`, and `avahi-daemon` when the setup installed it. The host name and the SSH settings (masked units, the sshd drop-in, Dropbear's `-s -g`, the key in `authorized_keys`) stay.

`dietpi.txt` is DietPi's own file from DietPi v10.8, under GPL-2.0, with three keys changed:

- `AUTO_SETUP_AUTOMATED=1`: the first run asks nothing.
- `SOFTWARE_DISABLE_SSH_PASSWORD_LOGINS=1`: DietPi turns SSH password logins off.
- `SURVEY_OPTED_IN=0`: no survey upload, no prompt.

### Check the zip from your PC

Do this before you copy the files.

1. Download `dietpi-first-boot.zip` and `SHA256SUMS` from the release page.
2. Run, in the folder that holds them:

```bash
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify dietpi-first-boot.zip --repo MorganKryze/Monero-miner-setup
```

### An RK3588 board that won't boot from the SD card

It boots something else first. Erase it from your PC with the board in MaskROM mode, then boot from SD again:

- **Orange Pi 5 Plus:** a factory bootloader in SPI flash. Hold the MaskROM button and connect the USB-C port next to it to your PC.
- **Orange Pi 5 Max:** Android on the soldered eMMC. Connect the upper USB-A port to your PC with an A-to-A cable.

## Keep it cool

A Pi 5 needs a cooler, even in `eco`. Measured on one board on 2026-11-16:

| Pi 5 | Mode | Hashrate | What happened |
| --- | --- | --- | --- |
| with a cooler | `eco` | 391 to 398 H/s | steady |
| with a cooler | `max` | 402 H/s | steady |
| without a cooler | `eco` | 372 H/s | reached 73-74 °C, hit the soft temperature limit and slowed down |

Your numbers will differ with the cooler, the case and the room. To see whether a board throttles, run `make status` in the clone. On a Pi 5 it prints the firmware's throttle flags, now and since boot. On an RK3588 board, a policy running below the maximum its mode set is the sign. See [Dedicated board](#dedicated-board---mode) for the full readout.

## Eco or max

`max` mines on every CPU the board's profile allows. `eco` leaves headroom and runs cooler. On a cooled Pi 5 the gap was small: see [Keep it cool](#keep-it-cool).

### Board profiles

`scripts/board_profiles.conf` lists the boards the installer knows, matched on the device tree's `compatible` strings. With `--mode max|eco` a new native config mines on that profile's CPU list. Both profiles are `untested` until someone records a measured run on a given board model.

| Profile | Boards (`compatible`) | `max` CPUs | `eco` CPUs | `eco` cap (cpufreq, kHz) | Status |
| ------- | --------------------- | ---------- | ---------- | ------------------------ | ------ |
| `bcm2712` | `brcm,bcm2712` | `0-3` | `0-3` | `policy0=1800000` | untested |
| `rk3588` | `rockchip,rk3588`, `rockchip,rk3588s` | `0-7` | `4-7` | `policy4=1800000`, `policy6=1800000` | untested |

With the systemd service, `--mode` also sets each policy's governor and maximum (the `eco` cap in `eco`) and, where the kernel has 2 MB huge pages (RK3588, not the Pi 5's stock kernel), huge pages at each boot: see [Dedicated board](#dedicated-board---mode). `make doctor` shows the `eco` cap next to each policy's current maximum.

Under 2560 MiB of memory RandomX's fast mode does not fit: the installer warns and new configs use light mode, slower but within memory. `make doctor` warns about it too.

### Dedicated board (--mode)

With `--mode max|eco` on a board with a profile (see [Board profiles](#board-profiles)) and the systemd service, the board is set up to mine and do nothing else. At each boot, before the miner starts, `xmrig-host-tuning.service` sets each cpufreq policy:

- a policy holding a CPU the mode mines on gets the `performance` governor: with `max`, at its hardware maximum; with `eco`, capped at the profile's `eco` cap.
- every other policy gets the `powersave` governor.

It also reserves 1280 huge pages of 2 MB when the kernel's default huge page is 2 MB, the board has at least 3584 MiB of memory and the service config runs RandomX's fast mode. RK3588 boards qualify; the Pi 5's stock kernel has no huge pages, so a Pi 5 gets none. It raises the reservation and never lowers it.

The miner's own unit changes too: no `Nice`, so it runs at normal priority, and it restarts 15 s after any exit, not only after a failure.

| File | What it does |
| ---- | ------------ |
| `/etc/systemd/system/xmrig-host-tuning.service` | Runs the boot script as root before `xmrig.service`, and runs it again to give the settings back when stopped |
| `/usr/local/sbin/xmrig-host-tuning` | The boot script, a root-owned copy of `scripts/host_tuning.sh`. Nothing in the clone is read at boot |
| `/etc/xmrig-host-tuning.conf` | The values: the mode, one line per policy, the huge pages |
| `/run/xmrig-host-tuning/found` | The governor and maximum each policy had before the boot script changed it. Gone at shutdown or on `make service-disable` |

When the installer writes a new service config, it writes the mode to `configs/board-mode` in the clone. A kept service config keeps the `configs/board-mode` it came with, so a re-run of the installer, with or without `--mode`, leaves the mode as it was. `make service-setup` reads it and writes the values again, and `make update` keeps the mode since it runs `make service-setup`. The values file is written at each setup, so a hand edit of `/etc/xmrig-host-tuning.conf` is replaced at the next one. A setup with no `configs/board-mode` removes the three files, giving the settings back.

To keep the service and mine without the tuning, run `make clean-configs`, the installer again without `--mode`, then `make service-setup` and `make restart`, passing your wallet and flags again.

To give the settings back, run `make service-disable` (or `make wipe`). It stops the tuning, which gives each policy the governor and maximum it had, then removes the three files. The huge pages stay reserved until the next boot frees them.

This release never raises a CPU past its stock maximum frequency.

`make status` adds a board readout under the service's status: the hottest thermal zone, each policy's frequency, the last hashrate the miner logged, and the cost per day.

- **Raspberry Pi 5:** the firmware's throttle flags, now and since boot (under-voltage, frequency capped, throttled, soft temperature limit). Power is the PMIC's, the sum of its rails: it excludes USB, the fan and the 5 V input, so the wall draws more.
- **RK3588:** there's no throttle flag, so a line such as `CPU policy4 runs at 1608 MHz, below the 2256 MHz its mode set: likely held by heat.` stands in for one. The board has no power sensor: use a wall meter.

For the cost per day, give your wall meter's watts and your price per kWh:

```bash
make status WALL_WATTS=9.5 KWH_PRICE=0.25
```

### Compare the layouts

To compare the layouts on your board, run `make bench-layouts [MODE=eco] [BENCH=1M]` on the arm64 Linux board as a normal user (it refuses root and other hosts). It runs XMRig once per layout of the profile (`MODE=eco`: the `eco` list), offline, from a throwaway folder, and prints the hashrate of each. `BENCH` is 250K by default, or 500K, or 1M to 10M; the time per layout grows with it, so start with the default.
