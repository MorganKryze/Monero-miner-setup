# Monero-miner-setup

![Monero Miner Setup Banner](https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/assets/banner.png)

[![CI](https://github.com/MorganKryze/Monero-miner-setup/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/MorganKryze/Monero-miner-setup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/MorganKryze/Monero-miner-setup)](./LICENSE)
![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Debian%2FUbuntu%20%7C%20Docker-blue)

Sets up [XMRig](https://xmrig.com) as a background service that mines Monero to a [MoneroOcean](https://moneroocean.stream) pool. Two install paths: a Docker container (anywhere Docker runs) or a native install with a `systemd` or `launchd` service on Debian/Ubuntu and macOS.

> **⚠️ Before you run this.** Mining consumes power, heats hardware, and can violate your cloud provider's ToS. Expect antivirus tools to flag XMRig. This project is not endorsed by Monero or MoneroOcean. You run it at your own risk.

## Install

Both paths go through the same installer script. Pass `--docker` for the container path; omit it for the native path.

| Pick       | Best when                                                        |
| ---------- | ---------------------------------------------------------------- |
| **Docker** | You want isolation, no system changes, easy teardown             |
| **Native** | Debian/Ubuntu or macOS. Unlocks huge pages + MSR tuning for max hashrate |

### Docker (prebuilt image, recommended)

```bash
bash <(curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh) \
  --docker -w YOUR_MONERO_WALLET --autostart
```

Pulls a multi-arch prebuilt image (`amd64` + `arm64`) from GHCR — no compile step, no Dockerfile toolchain on the host. The installer writes `docker/.env`, then brings up the full stack (compose, healthcheck, log rotation, optional VPN sidecar). The container runs as a non-root `xmrig` user with `no-new-privileges`.

Common flags (run `install.sh --docker --help` for the complete list):

- `--worker-name NAME`: label shown on the pool (default: `docker_miner`)
- `--cpus N` / `--memory LIMIT`: container caps (defaults: `2.0`, `1g`)
- `--threads PCT` / `--force-threads N`: XMRig thread tuning (defaults: `75`, `2`)
- `--pause-battery` / `--pause-active`: pause mining when on battery or when the user is active
- `--vpn PROVIDER`: route mining through a VPN, see [VPN config](#vpn-config-docker)
- `--image REF`: pin a specific tag or point at a fork (default: `ghcr.io/morgankryze/monero-miner-setup:latest`)
- `--build`: build the image locally from source instead of pulling (see below)

Available image tags:

- `:latest`: tracks the `main` branch. Auto-updates whenever `main` changes (Dependabot bumps, etc.).
- `:main-abc1234`: commit-pinned build off `main`. Use for reproducibility without committing to a version tag.
- `:vX.Y.Z`, `:vX.Y`: release pins. Match git tags on the repo.

### Docker (build from source)

Pass `--build` if you'd rather compile locally — useful when you've patched XMRig, when you don't want to pull from GHCR, or when a prebuilt image isn't available for your platform.

```bash
bash <(curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh) \
  --docker --build -w YOUR_MONERO_WALLET --autostart
```

First run compiles XMRig (3–8 min). The runtime image is ~128 MB. Everything else is identical to the prebuilt path.

### Minimal `docker run`

If you don't want the installer, compose, or VPN support, a single `docker run` is enough to get mining:

```bash
docker run -d \
  --name monero_xmrig_miner \
  --restart unless-stopped \
  --cpus 2.0 --memory 1g \
  -e WALLET_ADDRESS=YOUR_MONERO_WALLET \
  -v "$PWD/logs:/app/logs" \
  ghcr.io/morgankryze/monero-miner-setup:latest
```

Tail logs: `docker logs -f monero_xmrig_miner`. Stop: `docker stop monero_xmrig_miner && docker rm monero_xmrig_miner`. For VPN routing, `.env`-based config, and the healthcheck wiring, use the installer above instead.

### Native (Debian/Ubuntu, macOS)

```bash
bash <(curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh) \
  -w YOUR_MONERO_WALLET
```

Clones to `$HOME/Monero-miner-setup`, builds XMRig from source, writes `config.json` + `config_background.json`, registers a `systemd` (Linux) or `launchd` (macOS) service. Needs `git`, `curl`, `make` on the `PATH`.

Common flags (run `install.sh --help` for the complete list):

- `-t, --threads PERCENT`: `max-threads-hint` 1–100 (default: `75`)
- `-p, --pool URL`: pool override (default: `gulf.moneroocean.stream`)
- `--name STRING`: worker name (default: random `adjective_noun_NNN`)
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
bash <(curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh) \
  --docker -w YOUR_MONERO_WALLET \
  --vpn mullvad \
  --wg-key-file ~/.secrets/mullvad.key \
  --wg-address 10.64.0.1/32 \
  --vpn-location Zurich \
  --autostart
```

**ProtonVPN (WireGuard).** Generate a WireGuard config in the Proton dashboard (requires a paid plan). Copy `PrivateKey` and `Address` the same way.

```bash
bash <(curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh) \
  --docker -w YOUR_MONERO_WALLET \
  --vpn protonvpn \
  --wg-key-file ~/.secrets/protonvpn.key \
  --wg-address 10.2.0.2/32 \
  --vpn-location Switzerland \
  --autostart
```

**PIA (OpenVPN).** Uses your regular PIA account username and password. PIA's location field is a **region**, not a country (`Swiss`, `US East`, `CA Toronto`, `UK London`, etc.) — see the [gluetun PIA docs](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/private-internet-access.md) for the full list.

```bash
bash <(curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh) \
  --docker -w YOUR_MONERO_WALLET \
  --vpn pia \
  --vpn-user-file ~/.secrets/pia.user \
  --vpn-pass-file ~/.secrets/pia.pass \
  --vpn-location Swiss \
  --autostart
```

Fully non-interactive, credentials via env vars (useful for CI and Ansible):

```bash
OPENVPN_USER='p1234567' OPENVPN_PASSWORD='xxxxx' \
bash <(curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh) \
  --docker -w YOUR_MONERO_WALLET \
  --vpn pia --vpn-location Swiss \
  -y --autostart
```

**NordVPN (OpenVPN).** You must use NordVPN's **service credentials**, not your account login — grab them from the manual-setup page in the [nord account dashboard](https://my.nordaccount.com/dashboard/nordvpn/manual-setup/). NordVPN's ToS prohibits crypto-mining on some plans; verify yours before running long.

```bash
bash <(curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh) \
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
cp .env.vpn.example .env.vpn
# Uncomment ONE provider block in .env.vpn and fill in credentials.
docker compose -f compose.yml -f compose.vpn.yml up -d
```

### Verify and caveats

Check the exit IP is not yours:

```bash
docker exec monero_xmrig_gluetun wget -qO- https://ifconfig.io
```

Gluetun's killswitch (`FIREWALL=on`) blocks outbound traffic if the VPN drops, so your real IP can't leak.

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
| `make status`          | Service state, PIDs, and the last 5 log lines                         |
| `make test`            | Run XMRig in the foreground. Ctrl-C to exit                           |
| `make doctor`          | Check host tuning (huge pages, MSR, AES-NI) and print recommendations |
| `make benchmark`       | 1-minute RandomX benchmark. Prints a hashrate score                   |
| `make benchmark-long`  | 10-minute RandomX benchmark. More stable for hardware comparisons     |
| `make update`          | `git pull`, update submodules, rebuild, re-install the service unit   |
| `make service-disable` | Stop the service and remove the system unit                           |
| `make clean-build`     | Remove the build directory and the `xmrig` symlink                    |
| `make clean-configs`   | Remove generated configs                                              |
| `make wipe`            | `clean-build` + `clean-configs` + `service-disable`                   |

Docker equivalents: `docker compose up -d`, `down`, `logs -f`, `restart`, `ps`.

One-off benchmark from a Docker install (builds the image if needed, no wallet required):

```bash
docker compose run --rm --entrypoint /app/xmrig xmrig --bench=1M
```

## Tuning for performance

Run `make doctor` first. It inspects your host and prints a numbered list of concrete commands to apply. Common wins on Linux:

- **Reserve 2 MB huge pages**: `sudo sysctl -w vm.nr_hugepages=1280`. Persist in `/etc/sysctl.d/99-xmrig.conf`.
- **Load the `msr` module**: `sudo modprobe msr`. Persist via `echo msr | sudo tee /etc/modules-load.d/msr.conf`. Worth 5–15% on Ryzen and EPYC.
- **Enable 1 GB pages** (if the CPU has `pdpe1gb`): add `hugepagesz=1G hugepages=3 default_hugepagesz=2M` to `GRUB_CMDLINE_LINUX`, regenerate GRUB, reboot. Worth 1–5%.

macOS has no userspace equivalent for any of these. Expect 10–30% less hashrate than a tuned Linux host on the same silicon.

## Configuration

**Native.** Generated configs live under `configs/`:

- `config.json`: used by `make test`
- `config_background.json`: used by the service

Both come from `templates/*.json.template` via `sed` substitution. Edit the templates if you want different defaults for future installs.

**Docker.** Runtime config lives in `docker/.env` (and `docker/.env.vpn` if VPN is enabled). The installer writes these for you. Both files are `chmod 600`. `docker/.env.example` documents every variable, including `XMRIG_IMAGE` for pinning a specific tag or pointing compose at a forked image.

For the XMRig schema itself, see the [XMRig docs](https://xmrig.com/docs).

## Logs

| Install | Location                                           | Rotation                                                                                              |
| ------- | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Linux   | `$REPO/logs/xmrig.log`                             | `/etc/logrotate.d/xmrig` (daily, 7 rotations, compressed) if `logrotate` is installed                 |
| macOS   | `$REPO/logs/xmrig_stdout.log` + `xmrig_stderr.log` | None. Truncate them yourself if they grow                                                             |
| Docker  | `./logs/xmrig.log` + container stdout              | Container stdout rotates via compose (`max-size: 10m`, `max-file: 3`). File log grows until truncated |

## Security

XMRig is legitimate open-source software. AV tools flag it because malware installs miners without the user's consent. Your AV will flag this project too.

### Why these scripts get flagged

Expect 1–4 hits out of ~91 vendors on every file in this repo, and similar on any miner-adjacent project. Three things drive the verdict:

1. **URL reputation.** Once any script under `raw.githubusercontent.com/.../Monero-miner-setup/...` is reported, it lands in shared block-lists (e.g. `Chong Lua Dao`). The contents stop mattering at that point.
2. **Keyword heuristics.** Static scanners grep for `xmrig`, `moneroocean`, `wallet`, `hashrate`, `donate-level`, the base58 address regex, the `bash <(curl …)` install pattern. Any 3–4 of these in one file triggers a YARA rule from the `BAT.CoinMiner.*` family.
3. **Behavioral patterns.** A bash script that clones a repo, builds a binary, registers a `systemd` / `launchd` unit with `Restart=on-failure`, and generates a randomised worker name matches the same template that real cryptojackers (TeamTNT, Kinsing, 8220 Mining Group) use. The pattern, not the intent, is what gets matched.

### What the verdicts mean

The vendors that flag (BitDefender, Fortinet, G-Data, Chong Lua Dao) classify these files as **Riskware** / **PUA**: the same tier as Mimikatz, nmap, and PsExec. Concrete labels you'll see:

- BitDefender / G-Data: `Application.RiskTool.CoinMiner.X` or `Application.Generic.X`
- Fortinet: `Riskware/CoinMiner` or `BAT/Agent.X!tr`

None of them claim the script does something it doesn't advertise. They're saying "this category of tool is high-risk." For comparison, the upstream XMRig binary sits at around 30/70 on VirusTotal. This repo's wrappers come out far lower because the binary itself isn't shipped, only the source-build pipeline.

### Verify before running

1. **Read the install script in your terminal**:

   ```bash
   curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh | less
   ```

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

The Docker image runs as a non-root `xmrig` user with `no-new-privileges`. The installer rejects wallet addresses that fail length, leading-character, or base58 checks, and warns before running as root.

## Troubleshooting

**Service won't start.** Run `make status`. It prints the tail of the error log. Common causes: wallet rejected by the validator (wrong length, wrong leading char, non-base58 character), missing executable bit on `./xmrig`, or XMRig exiting on a missing CPU feature.

**Hashrate lower than expected.** Run `make doctor` and apply its recommendations. On Ryzen/EPYC, the `msr` kernel module is the single biggest lever.

**Service keeps coming back after `make stop`.** Use `make service-disable`. `systemd` and `launchd` re-spawn stopped units; `stop` alone won't keep them down.

**Docker container reports unhealthy on startup.** The first 30–60 s of RandomX dataset allocation predates the healthcheck. `start_period` is set to 60 s, so Docker won't mark it unhealthy during that window. If it lasts longer, check `docker compose logs` for an OOM.

**Build fails on macOS.** `make deps-macos` installs `cmake`, `libuv`, `openssl`, `hwloc` via Homebrew. The target installs Homebrew first if it isn't on your `PATH`.

## Development

- CI (`.github/workflows/ci.yml`) runs `shellcheck`, `hadolint`, a `make -n` dry-run, and a full Docker build smoke test on every push and PR. First-time contributor PRs require maintainer approval before workflows run.
- Dependabot opens weekly PRs for the vendored `xmrig` and `bash-toolbox` submodules, and for the GitHub Actions in the workflow. A companion workflow auto-merges Dependabot PRs once CI is green.
- Pull requests welcome. Fork, branch, open a PR. CI will tell you if anything's broken before a human looks at it.

## License

MIT. See [LICENSE](./LICENSE).

Banner artwork, scripts, and templates © Yann M. Vidamment 2025. This project is not endorsed by Monero or MoneroOcean.

## Resources

- [XMRig documentation](https://xmrig.com/docs)
- [XMRig config wizard](https://xmrig.com/wizard#start)
- [Monero project](https://www.getmonero.org/)
- [MoneroOcean pool](https://moneroocean.stream/)
