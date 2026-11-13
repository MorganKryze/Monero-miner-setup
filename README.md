# Monero-miner-setup

![Monero Miner Setup Banner](https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/assets/banner.png)

[![CI](https://github.com/MorganKryze/Monero-miner-setup/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/MorganKryze/Monero-miner-setup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/MorganKryze/Monero-miner-setup)](./LICENSE)
![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Debian%2FUbuntu%20%7C%20Docker-blue)

Sets up [XMRig](https://xmrig.com) as a background service that mines Monero to a [MoneroOcean](https://moneroocean.stream) pool. Two install paths: a Docker container (anywhere Docker runs) or a native install with a `systemd` or `launchd` service on Debian/Ubuntu and macOS.

> **⚠️ Before you run this.** Mining consumes power, heats hardware, and can violate your cloud provider's ToS. Expect antivirus tools to flag XMRig. This project is not endorsed by Monero or MoneroOcean. You run it at your own risk.

## Install

Both paths go through the same installer script. Pass `--docker` for the container path; omit it for the native path.

The install commands below need a POSIX shell such as bash or zsh. In fish, run `bash` first, then paste them.

| Pick       | Best when                                                        |
| ---------- | ---------------------------------------------------------------- |
| **Docker** | You want isolation, no system changes, easy teardown             |
| **Native** | Debian/Ubuntu or macOS. Unlocks huge pages, and the MSR boost with `--service-as-root` on x86 |

### Docker (prebuilt image, recommended)

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
bash -c "${installer:?the download came back empty}" -- \
  --docker -w YOUR_MONERO_WALLET --autostart
```

Pulls a multi-arch prebuilt image (`amd64` + `arm64`) from GHCR — no compile step, no Dockerfile toolchain on the host. Run from a clone's own `scripts/install.sh`, the installer uses that clone; otherwise it clones the repository to `$HOME/Monero-miner-setup` (`-d DIR` picks another base directory), and a re-run reuses that clone only when it's a git clone that you or root own and no other user can write to. It never adopts a folder because it sits above where you run it: from inside another copy of the project, it stops with an error. The installer writes `docker/.env` (and `docker/.env.vpn` with `--vpn`) only when it's missing or you pass `--overwrite-env`, with mode 600 from the first byte. A kept file that other users can read gets a warning and the `chmod 600` command that restricts it; one that another user can change, or that isn't owned by you or root (as root, also by the user who ran `sudo`), stops the run. With `--autostart` it brings up the stack (compose, healthcheck, log rotation, optional VPN sidecar); a re-run without `--vpn` starts it without the VPN sidecar. The container runs as a non-root `xmrig` user, with `no-new-privileges` set in the compose file.

Under 2560 MiB usable (the memory limit or the host's available memory, whichever is lower, plus its free huge pages), the miner warns and runs in light mode. At each start it runs XMRig's offline benchmark in light mode, connected to nothing, and stops it as soon as XMRig saves its thread count: under a second, five at most.

Common flags (run `install.sh --docker --help` for the complete list):

- `--worker-name NAME`: label shown on the pool (default: `docker_miner`)
- `--pool URL`: pool override (default: `gulf.moneroocean.stream`). A `stratum+ssl://` URL is kept as given, so give its port; only a bare or `stratum+tcp://` MoneroOcean URL gets the computed port
- `--cpus N` / `--memory LIMIT`: container caps (defaults: `2.0`, `3g`). Under 2560 MiB the miner runs in RandomX light mode, at a fraction of the hashrate
- `--threads PCT` / `--force-threads N`: threads as a percentage of the container's CPU quota, at most the count XMRig picks itself, or exactly N threads (defaults: `75`, none). On arm64 each thread gets its own CPU, the biggest first, so the count is at most the CPUs the container may use
- `--pause-battery` / `--pause-active`: pause mining when on battery or when the user is active
- `--vpn PROVIDER`: route mining through a VPN, see [VPN config](#vpn-config-docker)
- `--image REF`: pin a specific tag or point at a fork (default: `ghcr.io/morgankryze/monero-miner-setup:latest`)
- `--build`: build the image locally from source instead of pulling (see below)
- `--overwrite-env`: rewrite `docker/.env` (and `docker/.env.vpn` with `--vpn`) from this run's flags. Without it, a re-run keeps both files as they are

Available image tags:

- `:latest`: follows `main`. Rebuilt on every push to `main` and after each Dependabot merge, never by a manual run.
- `:main-abc1234`: one per commit on `main`.
- `:X.Y.Z`, `:X.Y`: release pins, without the `v`. A `vX.Y.Z` git tag publishes both and moves `:latest`.

An image older than 0.1.0 under the new compose file writes its log file inside the container, and it grows unbounded.

To pin a release, clone it and run its own installer: the commands above fetch `docker_setup.sh` from `main`, so `--image` alone pins only the image, not the installer. A tag checkout has no branch, so `make update` doesn't apply to it: check out the next tag instead.

```bash
git clone --branch v0.2.0-rc.1 --recurse-submodules https://github.com/MorganKryze/Monero-miner-setup.git
cd Monero-miner-setup
./scripts/install.sh --docker --image ghcr.io/morgankryze/monero-miner-setup:0.2.0-rc.1 -w YOUR_MONERO_WALLET --autostart
```

### Docker (build from source)

Pass `--build` if you'd rather compile locally — useful when you've patched XMRig, when you don't want to pull from GHCR, or when a prebuilt image isn't available for your platform.

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
bash -c "${installer:?the download came back empty}" -- \
  --docker --build -w YOUR_MONERO_WALLET --autostart
```

First run compiles XMRig (3–8 min). The runtime image is about 190 MB. Everything else is identical to the prebuilt path.

### Minimal `docker run`

If you don't want the installer, compose, or VPN support, a single `docker run` is enough to get mining:

```bash
docker run -d \
  --name monero_xmrig_miner \
  --restart unless-stopped \
  --cpus 2.0 --memory 3g \
  --security-opt no-new-privileges:true \
  -e WALLET_ADDRESS=YOUR_MONERO_WALLET \
  ghcr.io/morgankryze/monero-miner-setup:latest
```

Tail logs: `docker logs -f monero_xmrig_miner`. Stop: `docker stop monero_xmrig_miner && docker rm monero_xmrig_miner`. For VPN routing, `.env`-based config, and the healthcheck wiring, use the installer above instead.

### Native (Debian/Ubuntu, macOS)

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
bash -c "${installer:?the download came back empty}" -- \
  -w YOUR_MONERO_WALLET
```

Clones to `$HOME/Monero-miner-setup`, builds the XMRig commit the repository pins, writes `config.json` + `config_background.json`, registers a `systemd` (Linux) or `launchd` (macOS) service. Needs `git`, `curl`, `make` on the `PATH`. As root on Linux with no `-d`, the clone goes to `/opt/Monero-miner-setup`, unless an earlier install left one in root's home: a re-run keeps using that one. As root on Linux, the installer refuses a base directory, a clone, or a directory above them that a user other than root or the `sudo` user can change. A re-run reuses `Monero-miner-setup` in the base directory only when it's a git clone in which every file and folder belongs to you or root (or the `sudo` user) and no other user can change one; otherwise the installer stops with one error line, before it clones or builds anything. It stops the same way when the clone's path is a link, or when another user can change the base directory or a directory above it (a sticky one such as `/tmp` is fine). It clones and builds with group and other write turned off in its umask (a stricter umask stays), so no other user can change the clone while it's being written.

The service runs the miner as you. Installed with `sudo`, it runs as the user who ran `sudo`; installed as root with no `sudo` user, it runs as the system account `xmrig` (no login shell, no home), created once and reused. That account owns nothing in the clone. systemd creates `/etc/xmrig`, `/var/lib/xmrig/<account>` (its config and calibration) and `/var/log/xmrig/<account>`, and removes them on `make service-disable`.

`--service-as-root` is for systemd only: the macOS service refuses it, and refuses to run as root. It exists for the x86 RandomX MSR boost, which needs root. With it, the miner runs as root on the host: a flaw in XMRig, a hostile pool, or anyone on the network path to the pool (the default connection has no TLS) reaches a root process. Without it, the miner gets no MSR boost and can't reserve huge pages itself, so reserve them with `sysctl` (see [Tuning](#tuning-for-performance)).

Common flags (run `install.sh --help` for the complete list):

- `-t, --threads PERCENT`: `max-threads-hint` 1–100, a percentage of the host's cores (default: `75`). On arm64, where XMRig would start a thread on every core whatever the hint, the config lists the cores to mine on instead: that share of them, rounded up, the biggest first
- `-p, --pool URL`: pool override (default: `gulf.moneroocean.stream`). A `stratum+ssl://` URL is used as given, so give its port.
- `--mode max|eco`: on a board with a profile (Raspberry Pi 5, RK3588 boards), mine on the CPUs of that profile's `max` or `eco` list (see [Board profiles](#board-profiles)). Not with `-t`: the two both choose the CPUs, so the installer stops if you pass both
- `--name STRING`: worker name (default: random `adjective_noun_NNN`)
- `-d, --dir DIR`: where the clone goes (default: `$HOME`; as root on Linux, `/opt`)
- `--service-as-root`: run the systemd service as root, for the x86 RandomX MSR boost (see below)
- `--donate PERCENT`: 0–5
- `--autostart`: start the service right after install
- `--only-manual`: install the binary, skip service setup
- `-y, --yes`: skip the root prompt and the 15 s pre-install delay

### Native on an arm64 board (prebuilt binary)

On a Raspberry Pi 5 or an RK3588 board running Debian 13 or DietPi Trixie, `--prebuilt` skips the compile:

```bash
sudo git clone --branch vX.Y.Z --recurse-submodules https://github.com/MorganKryze/Monero-miner-setup.git /opt/Monero-miner-setup
sudo /opt/Monero-miner-setup/scripts/install.sh --prebuilt -w YOUR_MONERO_WALLET -y
```

It installs the release the clone is checked out at. A clone at no release tag is refused; with no clone, the installer clones `v<its own version>`. It downloads `xmrig-linux-arm64` and `SHA256SUMS` over HTTPS and checks the sum before it installs anything. It then runs `apt-get install` for `libuv1t64 libssl3t64 libhwloc15` and puts the binary at `<clone>/xmrig`, mode 0755, so only root can change it. The release and the sum go in `xmrig.release`, next to it.

It refuses, with one error line, a host it can't serve: Debian 12 Bookworm and any glibc before 2.38, amd64, macOS, a run without root, and a clone under a directory another user can change. A re-run with the same binary downloads nothing.

To see where the miner binary comes from, run `journalctl -u xmrig | grep 'Miner binary'`. The installer's last lines say the same. There are three origins:

- `release vX.Y.Z, sha256 …`: the binary matches the sum `xmrig.release` records.
- `compiled on this host`: there's no `xmrig.release`, so the binary was built here.
- `unknown (sha256 … matches no release record)`: the binary isn't the one the record names. Install again.

To check the binary yourself, on your PC download `xmrig-linux-arm64` from the release page, then run:

```bash
gh attestation verify xmrig-linux-arm64 --repo MorganKryze/Monero-miner-setup
```

`make update` refuses in a clone that runs a release binary. To move to another release, run as root in the clone: `git fetch --tags; git checkout --recurse-submodules vX.Y.Z; scripts/install.sh --prebuilt -w YOUR_MONERO_WALLET -y; make restart`.

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
| `/run/xmrig-host-tuning/found` | The governor and maximum each policy had before the boot script changed it. Gone at shutdown |

When the installer writes a new service config, it writes the mode to `configs/board-mode` in the clone. A kept service config keeps the `configs/board-mode` it came with, so a re-run of the installer, with or without `--mode`, leaves the mode as it was. `make service-setup` reads it and writes the values again, and `make update` keeps the mode since it runs `make service-setup`. The values file is written at each setup, so a hand edit of `/etc/xmrig-host-tuning.conf` is replaced at the next one. A setup with no `configs/board-mode` removes the three files, giving the settings back. To keep the service and mine without the tuning, run `make clean-configs`, the installer again without `--mode`, then `make service-setup` and `make restart`, passing your wallet and flags again.

To give the settings back, run `make service-disable` (or `make wipe`). It stops the tuning, which gives each policy the governor and maximum it had, then removes the three files. The huge pages stay reserved until the next boot frees them.

This release never raises a CPU past its stock maximum frequency.

`make status` adds a board readout under the service's status: the hottest thermal zone, each policy's frequency, the last hashrate the miner logged, and the cost per day.

- Raspberry Pi 5: the firmware's throttle flags, now and since boot (under-voltage, frequency capped, throttled, soft temperature limit). Power is the PMIC's, the sum of its rails: it excludes USB, the fan and the 5 V input, so the wall draws more.
- RK3588: there's no throttle flag, so a line such as `CPU policy4 runs at 1608 MHz, below the 2256 MHz its mode set: likely held by heat.` stands in for one. The board has no power sensor: use a wall meter.

For the cost per day, give your wall meter's watts and your price per kWh:

```bash
make status WALL_WATTS=9.5 KWH_PRICE=0.25
```

### DietPi first boot

Use this for a Raspberry Pi 5 or an RK3588 board with no screen and no keyboard: you flash DietPi, drop two files on the card, plug in Ethernet and power, and the board sets itself up and mines under its own name.

Each release ships `dietpi-first-boot.zip` with two files: `dietpi.txt` and `Automation_Custom_Script.sh`.

1. Flash the official DietPi Trixie image for your board on an SD card.
2. Copy both files from the zip onto the card, replacing DietPi's `dietpi.txt`:
   - Raspberry Pi 5: the boot partition, the FAT one your PC opens. The files stay there.
   - Orange Pi 5 Plus and 5 Max: the small FAT partition named `DIETPISETUP`. DietPi imports the files at first boot, then deletes that partition.
3. Open `Automation_Custom_Script.sh` and edit the settings at its top, between `: <<'END_OF_MINER_SETTINGS'` and `END_OF_MINER_SETTINGS`. Set `wallet` at least.
4. Plug in Ethernet (Wi-Fi isn't set up), then power.

Edit with an editor that keeps Unix (LF) line ends, such as VS Code or Notepad++. A value's trailing CR is dropped, but a script saved with CRLF line ends won't run.

The settings are `key = value` lines, read as data: nothing in them is run or expanded. A line starting with `#` is a comment, so remove the `# ` to set a key. An empty value keeps the default. An unknown key, a key given twice or a value of the wrong form stops the setup, with one line naming the key, or the line number of a line that is not `key = value`.

| Setting as shipped | Default | Form |
| --- | --- | --- |
| `wallet =` | none: required | your Monero address, 1 to 128 base58 characters |
| `mode = eco` | none: required, shipped as `eco` | `max` mines on every CPU the board's profile allows; `eco` leaves headroom and runs cooler (see [Dedicated board](#dedicated-board---mode)) |
| `pool = gulf.moneroocean.stream:10128` | the installer's, `gulf.moneroocean.stream:10128` | 1 to 255 letters, digits or `. + : / _ -` |
| `name = rpi5-3fa2` | the board's host name | the worker name the pool shows, 1 to 64 letters, digits or `. _ - @ : +` |
| `donate = 0` | the installer's, `0` | a whole number from 0 to 5, in percent |
| `light = no` | `no` | `yes` lets a board under 2560 MiB of memory mine in RandomX's slower light mode; without it, such a board is refused |
| `mdns = off` | `off` | `on` installs `avahi-daemon` to announce `<host name>.local` |
| `ssh_key = ssh-ed25519 AAAA... you@laptop` | none: SSH off | one `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp384`, `ecdsa-sha2-nistp521` or `ssh-rsa` public key, then an optional comment |

**What happens at first boot.** DietPi runs its first run, then our script once, as root. The script copies your settings to a root-only file, installs `xmrig-first-boot.service` and starts it. That service runs the setup at each boot until it has finished once. A board that lost power during the setup picks it up at the next boot; network waits retry every 10 seconds within the boot. A power cut in the first seconds, before the service is installed, needs a reflash: DietPi never runs the script again.

**The status LED.** The setup drives the board's status LED (Pi 5: `ACT`; 5 Plus: `green:indicator-2`; the 5 Max has none known, so it goes without):

| LED | Meaning |
| --- | --- |
| blinks, half a second on, half off | setting up, or waiting for the network |
| heartbeat | set up. It doesn't say the miner is mining now: `make status` or the pool's panel do |
| steady on | the setup stopped. `journalctl -u xmrig-first-boot.service` has the line that says why. Follow that line's remedy: for a setting, fix it and flash again, or fix `/var/lib/xmrig-first-boot/settings` over SSH and reboot |

A reboot gives the LED back to the board's own trigger until the setup unit sets it again, early in the boot.

**What the setup changes on the host:**

- `/usr/local/sbin/xmrig-first-boot` (0755, the script without your settings), `/etc/systemd/system/xmrig-first-boot.service` (0644) and the folder `/var/lib/xmrig-first-boot` (0700: your `settings` at 0600, the fetched `install.sh`, and the records `installing`, `done` and `mdns-installed`).
- The host name: `<model>-<last 4 hex digits of the first wired MAC>`, such as `rpi5-3fa2`, `opi5plus-3fa2` or `opi5max-3fa2`, in `/etc/hostname`, with one `127.0.1.1 <name>` line in `/etc/hosts` in place of any other `127.0.1.1` line. It's also the worker name unless you set `name`.
- SSH. With no `ssh_key`, every SSH unit (`dropbear` or `ssh`) is disabled, stopped and masked, so SSH is off. With one, it's added once to `/root/.ssh/authorized_keys` and password logins are turned off (a drop-in for OpenSSH, `-s -g` for Dropbear), so only key logins work, as `root`. A key the setup can't add turns SSH off. Until DietPi's first run and then the setup act, the image's own SSH server takes `root` with DietPi's default password: keep the board on a network you trust for its first minutes.
- With `mdns = on`: `avahi-daemon`, when it isn't installed yet. It's Debian's (main, LGPL-2.1, about 0.3 MB installed for 0.8-16 on arm64, plus its libraries) and opens UDP port 5353.
- The miner, as the native install sets it: the setup fetches the release's `scripts/install.sh` from `https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/<tag>/scripts/install.sh`, checks it against the sha256 the zip's script carries, and runs it with `-w <wallet> --mode <mode> --prebuilt --autostart -y --name <name>`, plus `-p` and `--donate` when set. That installer clones `v<its version>` to `/opt/Monero-miner-setup`, a tag the repository owner controls, and sets up `xmrig.service` and the board tuning as [Dedicated board](#dedicated-board---mode) says. The sha256 covers the installer alone; what it then runs comes from that tag.

Bluetooth stays as the image ships it.

`make service-disable` (or `make wipe`) in `/opt/Monero-miner-setup` removes the unit, the script and `/var/lib/xmrig-first-boot`, and `avahi-daemon` when the setup installed it. The host name and the SSH settings (masked units, the sshd drop-in, Dropbear's `-s -g`, the key in `authorized_keys`) stay.

**`dietpi.txt`** is DietPi's own file from DietPi v10.8, under GPL-2.0, with three keys changed:

- `AUTO_SETUP_AUTOMATED=1`: the first run asks nothing.
- `SOFTWARE_DISABLE_SSH_PASSWORD_LOGINS=1`: DietPi turns SSH password logins off.
- `SURVEY_OPTED_IN=0`: no survey upload, no prompt.

**Check the zip from your PC** before you copy it. Download `dietpi-first-boot.zip` and `SHA256SUMS` from the release page, then run:

```bash
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify dietpi-first-boot.zip --repo MorganKryze/Monero-miner-setup
```

**An RK3588 board that won't boot from the SD card.** It boots something else first. Erase it from your PC with the board in MaskROM mode, then boot from SD again:

- Orange Pi 5 Plus: a factory bootloader in SPI flash. Hold the MaskROM button and connect the USB-C port next to it to your PC.
- Orange Pi 5 Max: Android on the soldered eMMC. Connect the upper USB-A port to your PC with an A-to-A cable.

### Manual install

If you'd rather clone and inspect before running anything:

```bash
git clone --recurse-submodules https://github.com/MorganKryze/Monero-miner-setup.git
cd Monero-miner-setup
less scripts/install.sh        # review

# Native:
make install-debian            # or: make install-macos
make service-setup && make start

# Docker (pull prebuilt image):
cp docker/.env.example docker/.env
# Set WALLET_ADDRESS in docker/.env, then:
docker compose -f docker/compose.yml up -d

# Docker (build locally instead of pulling):
docker compose -f docker/compose.yml up -d --build
```

## VPN config (Docker)

The Docker install can route all mining traffic through a [Gluetun](https://github.com/qdm12/gluetun) VPN sidecar. Supported providers: **Mullvad**, **ProtonVPN**, **PIA**, **NordVPN**. After `--autostart`, the installer waits for the tunnel to be healthy and prints your VPN exit IP.

### Providers

| Provider  | Protocol  | Mining policy  | `--vpn-location` maps to | Where to get credentials                                                                                                                   |
| --------- | --------- | -------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Mullvad   | WireGuard | Allowed        | `SERVER_CITIES`          | [mullvad.net/account/wireguard-config](https://mullvad.net/en/account/wireguard-config)                                                    |
| ProtonVPN | WireGuard | Allowed (paid) | `SERVER_COUNTRIES`       | [account.protonvpn.com/downloads](https://account.protonvpn.com/downloads) (WireGuard tab)                                                 |
| PIA       | OpenVPN   | Allowed        | `SERVER_REGIONS`         | Your PIA account login                                                                                                                     |
| NordVPN   | OpenVPN   | Check ToS      | `SERVER_COUNTRIES`       | [my.nordaccount.com/.../manual-setup](https://my.nordaccount.com/dashboard/nordvpn/manual-setup/) (Service credentials, not account login) |

### All VPN arguments (inline / file / env)

Every secret has three input forms — pick one per field. Files are the recommended form because the path lands in shell history, the content doesn't. Inline flags work but leak to history. Env vars work anywhere (CI, systemd drop-ins, `.envrc`, etc.).

```text
Common (all providers):
  --vpn PROVIDER             mullvad | protonvpn | pia | nordvpn | none
  --vpn-location LOC         provider-specific — see Providers table
  --autostart                bring the stack up after setup
  -y, --non-interactive      fail fast on missing secrets, skip prompts

WireGuard providers (mullvad, protonvpn):
  Private key — pick ONE:
    --wg-key KEY                       inline (warns: visible in shell history)
    --wg-key-file PATH                 read from file  (recommended)
    env WIREGUARD_PRIVATE_KEY=KEY      environment variable
  Interface address — pick ONE:
    --wg-address ADDR                  inline  (e.g. 10.64.0.1/32)
    --wg-address-file PATH             read from file
    env WIREGUARD_ADDRESSES=ADDR       environment variable

OpenVPN providers (pia, nordvpn):
  Username — pick ONE:
    --vpn-user USER                    inline
    --vpn-user-file PATH               read from file  (recommended)
    env OPENVPN_USER=USER              environment variable
  Password — pick ONE:
    --vpn-pass PASS                    inline (warns: visible in shell history)
    --vpn-pass-file PATH               read from file  (recommended)
    env OPENVPN_PASSWORD=PASS          environment variable
```

If nothing is set and `-y` wasn't passed, the installer prompts for each missing secret via `read -s` (silent). Under `-y`, a missing secret aborts the run instead.

### Per-provider commands

Drop the curl/bash prefix and your wallet in, then pick one block. All examples use `--*-file` so secrets never land in shell history. Replace `~/.secrets/...` paths with your own.

**Mullvad (WireGuard).** Download a config from your Mullvad account page; copy `PrivateKey` and `Address` out of the `[Interface]` block.

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
bash -c "${installer:?the download came back empty}" -- \
  --docker -w YOUR_MONERO_WALLET \
  --vpn mullvad \
  --wg-key-file ~/.secrets/mullvad.key \
  --wg-address 10.64.0.1/32 \
  --vpn-location Zurich \
  --autostart
```

**ProtonVPN (WireGuard).** Generate a WireGuard config in the Proton dashboard (requires a paid plan). Copy `PrivateKey` and `Address` the same way.

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
bash -c "${installer:?the download came back empty}" -- \
  --docker -w YOUR_MONERO_WALLET \
  --vpn protonvpn \
  --wg-key-file ~/.secrets/protonvpn.key \
  --wg-address 10.2.0.2/32 \
  --vpn-location Switzerland \
  --autostart
```

**PIA (OpenVPN).** Uses your regular PIA account username and password. PIA's location field is a **region**, not a country (`Swiss`, `US East`, `CA Toronto`, `UK London`, etc.) — see the [gluetun PIA docs](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/private-internet-access.md) for the full list.

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
bash -c "${installer:?the download came back empty}" -- \
  --docker -w YOUR_MONERO_WALLET \
  --vpn pia \
  --vpn-user-file ~/.secrets/pia.user \
  --vpn-pass-file ~/.secrets/pia.pass \
  --vpn-location Swiss \
  --autostart
```

Fully non-interactive, credentials via env vars (useful for CI and Ansible):

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
OPENVPN_USER='p1234567' OPENVPN_PASSWORD='xxxxx' bash -c "${installer:?the download came back empty}" -- \
  --docker -w YOUR_MONERO_WALLET \
  --vpn pia --vpn-location Swiss \
  -y --autostart
```

**NordVPN (OpenVPN).** You must use NordVPN's **service credentials**, not your account login — grab them from the manual-setup page in the [nord account dashboard](https://my.nordaccount.com/dashboard/nordvpn/manual-setup/). NordVPN's ToS prohibits crypto-mining on some plans; verify yours before running long.

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
bash -c "${installer:?the download came back empty}" -- \
  --docker -w YOUR_MONERO_WALLET \
  --vpn nordvpn \
  --vpn-user-file ~/.secrets/nord.user \
  --vpn-pass-file ~/.secrets/nord.pass \
  --vpn-location Switzerland \
  --autostart
```

### Manual override

Skip the installer and wire the override yourself:

```bash
cd docker/
cp .env.vpn.example .env.vpn && chmod 600 .env.vpn
# Uncomment ONE provider block in .env.vpn and fill in credentials.
docker compose -f compose.yml -f compose.vpn.yml up -d
```

### Verify and caveats

Check the exit IP is not yours:

```bash
docker exec monero_xmrig_gluetun wget -qO- https://ifconfig.io
```

Gluetun's killswitch is on by Gluetun's default: if the tunnel drops, outbound traffic stops, so your real IP can't leak. Nothing the project writes turns it off.

Tradeoffs to know about:

- +1–5 ms latency per share submission. Not material for mining.
- Some pools rate-limit VPN IP ranges. MoneroOcean accepts them in practice; watch the acceptance rate if you see drops.
- NordVPN's ToS prohibits crypto-mining on some plans. Mullvad and ProtonVPN are the safe bets.

## Operating the miner

For the native install, run from the repo root. Targets work on both Linux (systemd) and macOS (launchd).

| Command                | What it does                                                          |
| ---------------------- | --------------------------------------------------------------------- |
| `make help`            | Print all targets. Also the default when you just type `make`         |
| `make start`           | Start the mining service                                              |
| `make stop`            | Stop the service and kill any stray `xmrig` processes                 |
| `make restart`         | `stop` + `start`                                                      |
| `make status`          | Service state, PIDs, and the last 5 log lines (systemd: `/var/log/xmrig/<account>/xmrig.log`). On Linux, a board readout: temperature, CPU frequencies, and on a board with a profile throttling, hashrate, power and cost (`WALL_WATTS=9.5 KWH_PRICE=0.25`) |
| `make test`            | Run XMRig in the foreground. Ctrl-C to exit                           |
| `make doctor`          | Check host tuning (huge pages, MSR, AES, the board and its profile, the CPUs each native config mines on) and print recommendations |
| `make benchmark`       | 1-minute RandomX benchmark. Prints a hashrate score                   |
| `make benchmark-long`  | 10-minute RandomX benchmark. More stable for hardware comparisons     |
| `make bench-layouts`   | Bench each CPU layout of the board profile offline, one XMRig run per layout (`MODE=eco`, `BENCH=1M`). arm64 Linux only; refuses root |
| `make update`          | `git pull`, the pinned submodule commits, rebuild, `make service-setup` again |
| `make service-disable` | Stop and disable the service, remove the unit and the logrotate file; systemd removes `/etc/xmrig`, `/var/lib/xmrig/<account>` and `/var/log/xmrig/<account>`. On a board set up with `--mode`, it also gives the CPU settings back and removes `/etc/systemd/system/xmrig-host-tuning.service`, `/usr/local/sbin/xmrig-host-tuning` and `/etc/xmrig-host-tuning.conf` |
| `make clean-build`     | Remove the build directory, the `xmrig` binary or link, and `xmrig.release` |
| `make clean-configs`   | Remove generated configs                                              |
| `make wipe`            | `clean-build` + `clean-configs` + `service-disable`                   |
| `make check`           | Run the regression checks in `tests/`. No build, no mining            |

Neither `make service-disable` nor `make wipe` removes the `xmrig` account. Remove it with `sudo userdel xmrig`.

Docker equivalents, from `docker/`: `docker compose up -d`, `down`, `logs -f`, `restart`, `ps`. `docker compose down -v` also removes the config volume.

One-off benchmark from a Docker install, run from `docker/` (builds the image if needed, no wallet required):

```bash
docker compose run --rm --entrypoint /app/xmrig xmrig --bench=1M
```

## Upgrading an install made before 0.1.0

An update keeps your wallet, pool and worker settings. A few steps are yours.

**Native.**

- Update the way you installed: as yourself, with `sudo`, or as root. The service keeps running the miner as the account that way of installing gives: you, the user who ran `sudo`, or the system account `xmrig`.
- Before you update, run `grep -n -- --remote Makefile` in the clone. If it prints a line, your clone has the old recipe: a `make update` would build XMRig's upstream tip instead of the pinned commit. Run `git pull` first, then `make update`.
- `make update` sets the service up without `--service-as-root`. To keep a root service, run `SERVICE_AS_ROOT=yes make update` as root.
- The setup turns background mode off in `configs/config_background.json`, that one setting alone, and says so. Miners an earlier background start left running are reported with the command that stops them (add `sudo` if they run as another user). Nothing is stopped for you.
- The service keeps running the old binary until you run `make restart`.
- On arm64, a kept config has no CPU list, or one naming every CPU, so the miner runs on every core whatever `--threads` says. The installer warns: `--threads does not apply to the kept configs: they let the miner run on every CPU. To apply it, run 'make clean-configs', the installer again, then 'make service-setup' and 'make restart'.` Do that, passing your wallet and flags again.
- Installed as root with the clone in `/root`? The miner's account can't enter root's home, so `make update` stops with `The account xmrig cannot run /root/Monero-miner-setup/xmrig; move the clone where it can, such as /opt.` and your old service keeps running. Run `make service-disable` in the old clone, then the installer again as root with `-d /opt` (or without `-d` once `/root/Monero-miner-setup` is gone), passing your wallet and flags again.

**Docker.**

- A re-run keeps your `docker/.env`, and its old values with it. One the old installer wrote holds `FORCE_THREAD_COUNT=2` (2 threads, whatever `--threads` says) and `MEMORY_LIMIT=1g`, under which the miner now runs in light mode instead of restarting in a loop. For the new defaults, run the installer again with `--overwrite-env` and your flags, or set `FORCE_THREAD_COUNT=` and `MEMORY_LIMIT=3g` in the file.
- A `docker/.env` that leaves a key out gets the new defaults: worker name `docker_miner` (it was `miner_docker`, so the pool shows a new worker), threads 75 % (was 25 % with 2 forced), memory 3g (was 1g).
- The config moved from `docker/docker-configs` to the `xmrig-configs` volume, and the log from `docker/logs` to the container's output. Delete both folders; use `sudo` if Docker created them as root.
- An old `docker/.env.vpn` keeps a `FIREWALL=on` line. Gluetun never read it, so it changes nothing; delete it if you like.
- The MoneroOcean calibration is redone at every container start, as before.

## Tuning for performance

Run `make doctor` first. It inspects your host and prints a numbered list of concrete commands to apply. On arm64 Linux it checks AES (the ARMv8 Crypto Extensions) and huge pages in the kernel's page size, skips the x86-only checks, and warns about a native config with no CPU list. Common wins on Linux:

- **Reserve 2 MB huge pages**: `sudo sysctl -w vm.nr_hugepages=1280`. Persist in `/etc/sysctl.d/99-xmrig.conf`.
- **Load the `msr` module**: `sudo modprobe msr`. Persist via `echo msr | sudo tee /etc/modules-load.d/msr.conf`. It helps only a service installed with `--service-as-root`. Worth 5–15% on Ryzen and EPYC.
- **Enable 1 GB pages** (if the CPU has `pdpe1gb`): add `hugepagesz=1G hugepages=3 default_hugepagesz=2M` to `GRUB_CMDLINE_LINUX`, regenerate GRUB, reboot. Worth 1–5%.

macOS has no userspace equivalent for any of these. Expect 10–30% less hashrate than a tuned Linux host on the same silicon.

### Board profiles

`scripts/board_profiles.conf` lists the boards the installer knows, matched on the device tree's `compatible` strings. With `--mode max|eco` a new native config mines on that profile's CPU list. Both profiles are `untested` until someone records a measured run on a given board model.

| Profile | Boards (`compatible`) | `max` CPUs | `eco` CPUs | `eco` cap (cpufreq, kHz) | Status |
| ------- | --------------------- | ---------- | ---------- | ------------------------ | ------ |
| `bcm2712` | `brcm,bcm2712` | `0-3` | `0-3` | `policy0=1800000` | untested |
| `rk3588` | `rockchip,rk3588`, `rockchip,rk3588s` | `0-7` | `4-7` | `policy4=1800000`, `policy6=1800000` | untested |

With the systemd service, `--mode` also sets each policy's governor and maximum (the `eco` cap in `eco`) and, where the kernel has 2 MB huge pages (RK3588, not the Pi 5's stock kernel), huge pages at each boot: see [Dedicated board](#dedicated-board---mode). `make doctor` shows the `eco` cap next to each policy's current maximum.

Under 2560 MiB of memory RandomX's fast mode does not fit: the installer warns and new configs use light mode, slower but within memory. `make doctor` warns about it too.

To compare the layouts on your board, run `make bench-layouts [MODE=eco] [BENCH=1M]` on the arm64 Linux board as a normal user (it refuses root and other hosts). It runs XMRig once per layout of the profile (`MODE=eco`: the `eco` list), offline, from a throwaway folder, and prints the hashrate of each. `BENCH` is 250K by default, or 500K, or 1M to 10M; the time per layout grows with it, so start with the default.

## Configuration

**Native.** Generated configs live under `configs/`:

- `config.json`: used by `make test`
- `config_background.json`: the service's. The setup installs it as `/etc/xmrig/config.json`; at the first start after it changed, the service copies it into `/var/lib/xmrig/<account>/config.json`, and otherwise keeps the calibration it saved there. Edit it, then run `make service-setup` and `make restart`.

The installer fills both in from `templates/*.json.template`, and a re-run keeps them. To regenerate them, run `make clean-configs`, then the installer.

**Docker.** Runtime config lives in `docker/.env` (and `docker/.env.vpn` if VPN is enabled). The installer writes them, mode 600, only when they're missing or you pass `--overwrite-env`. The miner's config is built at every start into the named volume `xmrig-configs` (`docker volume ls` shows `docker_xmrig-configs`). `docker compose down` keeps it; `docker compose down -v` removes it. `docker/.env.example` documents every variable, including `XMRIG_IMAGE` for pinning a specific tag or pointing compose at a forked image.

For the XMRig schema itself, see the [XMRig docs](https://xmrig.com/docs).

## Logs

| Install | Location                                           | Rotation                                                                                              |
| ------- | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Linux   | `/var/log/xmrig/<account>/xmrig.log`               | `/etc/logrotate.d/xmrig` (daily, 7 kept, compressed, as the account) if `logrotate` is installed. The service restarts after each rotation: one short pool reconnect a day |
| macOS   | `$REPO/logs/xmrig_stdout.log` + `xmrig_stderr.log` | None. Truncate them yourself if they grow                                                             |
| Docker  | Container output only: `docker compose logs -f`    | Compose rotates it at 3 files of 10 MB. `docker compose down` drops it with the container             |

## Security

XMRig is legitimate open-source software. AV tools flag it because malware installs miners without the user's consent. Your AV will flag this project too.

### What the installers fetch

The installers fetch from the sources below and nothing else. All of it comes over HTTPS except the packages apt installs: apt uses the archives its sources list names (the base image's, in a Docker build), plain HTTP by default on Debian and Ubuntu, and checks what it gets against the archive's signing key.

| What | From | When |
| --- | --- | --- |
| The installer | `https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh` | the install commands above |
| Its log helpers (bash-toolbox) | your clone's submodule, else `https://raw.githubusercontent.com/MorganKryze/bash-toolbox/<commit>/src/prefix.sh` at the commit `dependencies/bash-toolbox` pins | every native install (`--docker` hands off before it loads them) |
| The Docker installer | your clone's copy, else `https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/docker_setup.sh` | `--docker` |
| The repository | `https://github.com/MorganKryze/Monero-miner-setup.git`, its submodules at the commits it pins: `https://github.com/MoneroOcean/xmrig.git`, `https://github.com/MorganKryze/bash-toolbox.git` | when there's no clone yet |
| The release binary | `https://github.com/MorganKryze/Monero-miner-setup/releases/download/<tag>/xmrig-linux-arm64` and `SHA256SUMS` beside it, from the release your clone is checked out at | `--prebuilt` |
| The image | `ghcr.io/morgankryze/monero-miner-setup`, built by this repository's CI | Docker, unless `--build` |
| The base image and its packages | `ubuntu` from Docker Hub, at the tag `docker/Dockerfile` names, and Ubuntu's packages through apt in both build stages | `--build`, or when the image pull fails |
| The Dockerfile frontend | `docker/dockerfile` from Docker Hub, at the version the `# syntax=` line of `docker/Dockerfile` names: BuildKit runs it to read the Dockerfile | `--build`, or when the image pull fails |
| The VPN sidecar | `qmcgaw/gluetun`, pinned to a release in `docker/compose.vpn.yml` | `--vpn` |
| Your exit IP | `https://ifconfig.io`, asked from inside the VPN container | `--vpn --autostart` |

The native build's packages come from your package manager: `build-essential cmake libuv1-dev libssl-dev libhwloc-dev` through apt, with `--no-upgrade`, or `cmake libuv openssl hwloc` through Homebrew. Homebrew itself is never installed for you.

### What runs as root

On Linux, these steps go through `sudo` (`make deps-debian`, `scripts/setup_service_debian.sh` and the service targets):

- `apt-get update` and `apt-get install` of the packages above
- `useradd --system` to create the `xmrig` account, when the service needs it
- `install -d` of `/etc/xmrig`, then `install` of `/etc/xmrig/config.json`, `/etc/logrotate.d/xmrig` and `/etc/systemd/system/xmrig.service`, root-owned, from private temp files
- `rm -f` of `/etc/systemd/system/xmrig.service` and `/etc/logrotate.d/xmrig`, on `make service-disable`
- with `--mode` on a board with a profile: `install` of `/etc/xmrig-host-tuning.conf`, `/usr/local/sbin/xmrig-host-tuning` and `/etc/systemd/system/xmrig-host-tuning.service`, root-owned, from private temp files, and removed again by a setup without a mode or by `make service-disable`
- on a board set up from the DietPi files, on `make service-disable`: `test` of the setup's record that it installed `avahi-daemon`, then `apt-get remove` of it when it did; removal of `/etc/systemd/system/xmrig-first-boot.service`, `/usr/local/sbin/xmrig-first-boot` and the folder `/var/lib/xmrig-first-boot`
- `systemctl daemon-reload`, `enable`, `start`, `try-restart`, `stop`, `status`, `disable`, `reset-failed` and `clean`

`--prebuilt` runs the installer itself as root: `apt-get update` and `apt-get install` of `libuv1t64 libssl3t64 libhwloc15`, the download into a root-only folder in the clone, and the rename onto `<clone>/xmrig` and `xmrig.release`.

The service runs the miner as root only with `--service-as-root`. `make test` runs it as whoever runs `make`. An install you run as root runs every step as root, not only these: the clone, the XMRig build, and turning off background mode in the clone's config.

### Why these scripts get flagged

Expect 1–4 hits out of ~91 vendors on every file in this repo, and similar on any miner-adjacent project. Three things drive the verdict:

1. **URL reputation.** Once any script under `raw.githubusercontent.com/.../Monero-miner-setup/...` is reported, it lands in shared block-lists (e.g. `Chong Lua Dao`). The contents stop mattering at that point.
2. **Keyword heuristics.** Static scanners grep for `xmrig`, `moneroocean`, `wallet`, `hashrate`, `donate-level`, the base58 address regex, the curl-into-bash install pattern. Any 3–4 of these in one file triggers a YARA rule from the `BAT.CoinMiner.*` family.
3. **Behavioral patterns.** A bash script that clones a repo, builds a binary, registers a `systemd` / `launchd` unit with `Restart=on-failure`, and generates a randomised worker name matches the same template that real cryptojackers (TeamTNT, Kinsing, 8220 Mining Group) use. The pattern, not the intent, is what gets matched.

### What the verdicts mean

The vendors that flag (BitDefender, Fortinet, G-Data, Chong Lua Dao) classify these files as **Riskware** / **PUA**: the same tier as Mimikatz, nmap, and PsExec. Concrete labels you'll see:

- BitDefender / G-Data: `Application.RiskTool.CoinMiner.X` or `Application.Generic.X`
- Fortinet: `Riskware/CoinMiner` or `BAT/Agent.X!tr`

None of them claim the script does something it doesn't advertise. They're saying "this category of tool is high-risk." For comparison, the upstream XMRig binary sits at around 30/70 on VirusTotal; the wrappers in this repo score the 1–4 above. The prebuilt GHCR image does ship an XMRig binary: this repository's CI builds it from the pinned submodule, unmodified. The native install builds it on your host.

### Verify before running

1. **Read the install script in your terminal**:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh | less
   ```

   To read the exact bytes you'll run, paste the first line of an install command alone, read them with `printf '%s\n' "$installer" | less`, then paste the second line.

2. **Check the VirusTotal URL scans** for each entry point:

   | File                      | Scan                                                                                                                        |
   | ------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
   | `install.sh`              | [VirusTotal](https://www.virustotal.com/gui/url/39d67119bd9c0dcb96d6594167b654e40141f522b8305112bbc532678c145a07/detection) |
   | `Makefile`                | [VirusTotal](https://www.virustotal.com/gui/url/77e9022659f5b43b8d75c5c83f4a8f63c99e945c9c04ea478433e0219bdcd66e/detection) |
   | `setup_service_debian.sh` | [VirusTotal](https://www.virustotal.com/gui/url/a734f2bf7ae11cce6db7dd8e7712be3600ce318d83cc3c4bf39fb204d37dbc4f/detection) |
   | `setup_service_macos.sh`  | [VirusTotal](https://www.virustotal.com/gui/url/484e20f6475c96f001e4e7c87a3e826a28f8f88d4f75a6e7a6b5b14054869280/detection) |

3. **Clone and read the source**:

   ```bash
   git clone https://github.com/MorganKryze/Monero-miner-setup.git
   cd Monero-miner-setup && less scripts/install.sh Makefile docker/Dockerfile
   ```

The container runs as uid 999, `xmrig`. The compose file and the minimal run above set `no-new-privileges`; a bare `docker run` without that flag doesn't. Both installers and the container check the wallet, the worker name, the pool and every number and flag before they write them, and write every value that reaches the miner's config as a value. The native installer reuses a clone only when nothing in it belongs to, or can be changed by, another user. As root on Linux, it also refuses a base directory, a clone, or a directory above them that another user can change, and the service setup refuses a binary anyone but root can change when it runs it as another account. The installer still warns before running as root.

## Troubleshooting

**Service won't start.** Run `make status`. It prints the tail of the error log. Common causes: wallet rejected by the validator (wrong length, wrong leading char, non-base58 character), missing executable bit on `./xmrig`, or XMRig exiting on a missing CPU feature.

**Hashrate lower than expected.** Run `make doctor` and apply its recommendations. The `msr` kernel module helps only a service installed with `--service-as-root` on x86: 5–15% on Ryzen and EPYC.

**Service keeps coming back after `make stop`.** Use `make service-disable`. `systemd` and `launchd` re-spawn stopped units; `stop` alone won't keep them down.

**Docker container reports unhealthy.** The healthcheck reports unhealthy only when the miner process is gone, or when it holds its pool connection, isn't paused, and used no CPU time since the last check. `start_period` is 60 s. Under 2560 MiB the miner runs in light mode instead of being OOM-killed: give it `--memory 3g`.

**Build fails on macOS.** `make deps-macos` installs `cmake`, `libuv`, `openssl`, `hwloc` with Homebrew, and stops with Homebrew's install command when `brew` isn't on your `PATH`.

**`The account <account> cannot run <clone>/xmrig; move the clone where it can, such as /opt.`** The miner's account can't reach the clone. Installed as root in `/root`? Follow the `/root` step of [Upgrading](#upgrading-an-install-made-before-010). Otherwise run `make service-disable` in that clone, then the installer again with `-d /opt` and your wallet and flags: a moved clone keeps its config links to the old path.

**`<path> can be changed by a user other than you, so this run does not use <clone>.`** (or `belongs to another user`, `is not a git clone`) Someone else could have changed that clone, so the native installer won't build or run it. Don't fix its modes and reuse it: files may already have been changed. Move it away and run the installer again with your wallet and flags, or pass `-d` with another base directory. Right after a fresh clone, the cause is your umask: remove the clone, run `umask 022`, then the installer again.

**`<clone> is already there or cannot be made, so this run does not clone into it.`** Something turned up at the clone's path after the installer checked it, and whoever made it could change what git puts there. Move it away and run the installer again, or pass `-d` with another base directory.

**`<clone> is a link, so this run does not use it.`** The installer won't act through a link at the clone's path. Pass `-d` with the folder that holds the one the link points to (the error line names it), so the installer finds the clone there. A link to nothing: move it away and run the installer again.

**`<directory> can be changed by a user other than you, so this run does not use <clone>.`** followed by `Pass -d with a directory only you can change.` Another user could swap the clone inside that directory between the check and the build. A sticky directory such as `/tmp` is fine. Pass `-d` with a directory that only you (or root) can change.

## Development

- CI (`.github/workflows/ci.yml`) runs `shellcheck`, `hadolint`, the `make -n` dry runs, `make check` and the Docker build smoke test on amd64 and arm64. It runs on pushes and pull requests to `main`, and after a Dependabot merge. A pull request to `main` needs green CI to merge (the maintainer can still push directly). First-time contributor PRs require maintainer approval before workflows run.
- Dependabot opens weekly PRs for the `xmrig` and `bash-toolbox` submodules, the GitHub Actions, the Dockerfile's base image and Gluetun. Only Actions patch and minor bumps merge on their own, once CI is green; the rest wait for review.
- Pull requests welcome. Fork, branch, run `make check`, open a PR.

## License

MIT. See [LICENSE](./LICENSE).

Banner artwork, scripts, and templates © Yann M. Vidamment 2025. This project is not endorsed by Monero or MoneroOcean.

## Resources

- [XMRig documentation](https://xmrig.com/docs)
- [XMRig config wizard](https://xmrig.com/wizard#start)
- [Monero project](https://www.getmonero.org/)
- [MoneroOcean pool](https://moneroocean.stream/)
