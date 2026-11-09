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
git clone --branch v0.1.1 --recurse-submodules https://github.com/MorganKryze/Monero-miner-setup.git
cd Monero-miner-setup
./scripts/install.sh --docker --image ghcr.io/morgankryze/monero-miner-setup:0.1.1 -w YOUR_MONERO_WALLET --autostart
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
- `--name STRING`: worker name (default: random `adjective_noun_NNN`)
- `-d, --dir DIR`: where the clone goes (default: `$HOME`; as root on Linux, `/opt`)
- `--service-as-root`: run the systemd service as root, for the x86 RandomX MSR boost (see below)
- `--donate PERCENT`: 0–5
- `--autostart`: start the service right after install
- `--only-manual`: install the binary, skip service setup
- `-y, --yes`: skip the root prompt and the 15 s pre-install delay

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
| `make status`          | Service state, PIDs, and the last 5 log lines (systemd: `/var/log/xmrig/<account>/xmrig.log`) |
| `make test`            | Run XMRig in the foreground. Ctrl-C to exit                           |
| `make doctor`          | Check host tuning (huge pages, MSR, AES, the CPUs each native config mines on) and print recommendations |
| `make benchmark`       | 1-minute RandomX benchmark. Prints a hashrate score                   |
| `make benchmark-long`  | 10-minute RandomX benchmark. More stable for hardware comparisons     |
| `make update`          | `git pull`, the pinned submodule commits, rebuild, `make service-setup` again |
| `make service-disable` | Stop and disable the service, remove the unit and the logrotate file; systemd removes `/etc/xmrig`, `/var/lib/xmrig/<account>` and `/var/log/xmrig/<account>` |
| `make clean-build`     | Remove the build directory and the `xmrig` symlink                    |
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
- `systemctl daemon-reload`, `enable`, `start`, `stop`, `status`, `disable`, `reset-failed` and `clean`

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
