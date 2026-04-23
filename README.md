# Monero-miner-setup

![Monero Miner Setup Banner](https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/assets/banner.png)

[![CI](https://github.com/MorganKryze/Monero-miner-setup/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/MorganKryze/Monero-miner-setup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/MorganKryze/Monero-miner-setup)](./LICENSE)
![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Debian%2FUbuntu%20%7C%20Docker-blue)

Sets up [XMRig](https://xmrig.com) as a background service that mines Monero to a [MoneroOcean](https://moneroocean.stream) pool. Two install paths: a Docker container (works on anything) or a native install that gets a `systemd` or `launchd` service on Debian/Ubuntu or macOS.

> **⚠️ Before you run this.** Mining consumes power, heats hardware, and can violate your cloud provider's ToS. Expect antivirus tools to flag XMRig. This project is not endorsed by Monero or MoneroOcean. You run it at your own risk.

## Quick start (Docker)

Everything runs in a non-root container. Only `./logs/` gets written to your host.

```bash
git clone https://github.com/MorganKryze/Monero-miner-setup.git
cd Monero-miner-setup/docker
cp .env.example .env
# Open .env and set WALLET_ADDRESS to your Monero wallet (95 or 106 chars).
docker compose up -d
docker compose logs -f
```

To stop it: `docker compose down`.

First build takes 3–8 min (compiles XMRig from source in a builder stage). The runtime image is ~128 MB.

### `.env` reference

| Variable              | Default                   | Purpose                                                                  |
| --------------------- | ------------------------- | ------------------------------------------------------------------------ |
| `WALLET_ADDRESS`      | _(required)_              | Your Monero wallet. 95 or 106 chars, starts with `4` or `8`, base58 only |
| `WORKER_NAME`         | `docker_miner`            | Label the pool uses to identify this worker                              |
| `POOL_URL`            | `gulf.moneroocean.stream` | Pool hostname. Port is auto-computed for MoneroOcean                     |
| `DONATE_LEVEL`        | `0`                       | 0–5% donation to XMRig devs                                              |
| `CPU_COUNT`           | `2.0`                     | Container-level CPU quota                                                |
| `MAX_THREADS_PERCENT` | `25`                      | Share of cores for `max-threads-hint` in the XMRig config                |
| `FORCE_THREAD_COUNT`  | `2`                       | Hard thread count. Leave empty to derive from `MAX_THREADS_PERCENT`      |
| `MEMORY_LIMIT`        | `1g`                      | Container memory cap                                                     |
| `PAUSE_ON_BATTERY`    | `false`                   | Pause mining when the host is on battery                                 |
| `PAUSE_ON_ACTIVE`     | `false`                   | Pause mining when the host has active user input                         |

## Native install (Debian/Ubuntu or macOS)

Pick this path if you want huge pages, MSR tuning, or the miner registered as a proper system service. Other OSes (Fedora, Arch, FreeBSD, Windows) don't have a native install path: use Docker.

### One-liner

```bash
bash <(curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh) \
  -w YOUR_MONERO_WALLET_ADDRESS
```

The installer clones the repo into `$HOME/Monero-miner-setup`, builds XMRig from source, writes `config.json` + `config_background.json`, and registers the service (systemd on Linux, launchd on macOS). Inspect the script before running: see [Security](#security).

### Flags

| Flag                           | Default                   | Purpose                                                    |
| ------------------------------ | ------------------------- | ---------------------------------------------------------- |
| `-w, --wallet WALLET`          | _(required)_              | Your Monero wallet                                         |
| `-t, --threads PERCENT`        | `75`                      | `max-threads-hint` (1–100)                                 |
| `-p, --pool URL`               | `gulf.moneroocean.stream` | Pool URL                                                   |
| `--name STRING`                | random                    | Worker name shown on the pool                              |
| `--donate PERCENT`             | `0`                       | 0–5                                                        |
| `-d, --dir DIR`                | `$HOME`                   | Install dir (repo clones to `$DIR/Monero-miner-setup`)     |
| `--pause-active`               | off                       | Pause on user input                                        |
| `--pause-battery`              | off                       | Pause on battery                                           |
| `--only-manual`                | off                       | Skip service setup (install binary only)                   |
| `--autostart`                  | off                       | Start the service after install                            |
| `-y, --yes, --non-interactive` | off                       | Skip the root-user prompt and the 15 s pre-install delay   |

### Manual install

If you'd rather drive the build yourself:

```bash
git clone --recurse-submodules https://github.com/MorganKryze/Monero-miner-setup.git
cd Monero-miner-setup
make deps-debian           # or: make deps-macos
make build                 # compiles XMRig via CMake
# Edit templates/config.json.template with your wallet and pool,
# then run: make service-setup && make start
```

## Operating the miner

Run from the repo root. Targets work on both Linux (systemd) and macOS (launchd).

| Command                | What it does                                                        |
| ---------------------- | ------------------------------------------------------------------- |
| `make help`            | Print all targets. This is also the default when you just type `make` |
| `make start`           | Start the mining service                                            |
| `make stop`            | Stop the service and kill any stray `xmrig` processes               |
| `make restart`         | `stop` + `start`                                                    |
| `make status`          | Service state, PIDs, and the last 5 log lines                       |
| `make test`            | Run XMRig in the foreground. Ctrl-C to exit                         |
| `make doctor`          | Check host tuning (huge pages, MSR, AES-NI) and print recommendations |
| `make update`          | `git pull`, update submodules, rebuild, re-install the service unit |
| `make service-disable` | Stop the service and remove the system unit                         |
| `make clean-build`     | Remove the build directory and the `xmrig` symlink                  |
| `make clean-configs`   | Remove generated configs                                            |
| `make wipe`            | `clean-build` + `clean-configs` + `service-disable`                 |

Docker equivalents: `docker compose up -d`, `down`, `logs -f`, `restart`, `ps`.

## Tuning for performance

Run `make doctor` first. It inspects your host and prints a numbered list of concrete commands to run. Common wins on Linux:

- **Reserve 2 MB huge pages**: `sudo sysctl -w vm.nr_hugepages=1280`. Persist it in `/etc/sysctl.d/99-xmrig.conf`.
- **Load the `msr` module**: `sudo modprobe msr`. Persist via `echo msr | sudo tee /etc/modules-load.d/msr.conf`. Worth 5–15% on Ryzen and EPYC.
- **Enable 1 GB pages** (if the CPU supports `pdpe1gb`): add `hugepagesz=1G hugepages=3 default_hugepagesz=2M` to `GRUB_CMDLINE_LINUX`, regenerate GRUB, reboot. Worth 1–5%.

macOS has no userspace equivalent for any of these. Expect 10–30% less hashrate than a tuned Linux host on the same silicon.

## Configuration

Configs live under `configs/` after install:

- `config.json`: used by `make test`
- `config_background.json`: used by the service

Both are generated from `templates/*.json.template` via `sed` substitution. Edit the templates if you want different defaults for future installs. For the full XMRig schema, see the [XMRig docs](https://xmrig.com/docs).

## Logs

| Install    | Location                                           | Rotation                                                                      |
| ---------- | -------------------------------------------------- | ----------------------------------------------------------------------------- |
| Linux      | `$REPO/logs/xmrig.log`                             | `/etc/logrotate.d/xmrig` (daily, 7 rotations, compressed) if `logrotate` is installed |
| macOS      | `$REPO/logs/xmrig_stdout.log` + `xmrig_stderr.log` | None. Truncate them yourself if they grow                                     |
| Docker     | `./logs/xmrig.log` + container stdout              | Container stdout rotates via compose (`max-size: 10m`, `max-file: 3`). File log grows until truncated |

## Security

XMRig is legitimate open-source software. AV tools flag it because malware installs miners without the user's consent. Your AV will flag this project too.

To verify before running:

1. **Read the install script**:

   ```bash
   curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh | less
   ```

2. **Check VirusTotal URL scans** for the key files:

   | File                      | Scan                                                                                                                          |
   | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
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

**Hashrate lower than you expected.** Run `make doctor` and apply its recommendations. On Ryzen/EPYC, the `msr` kernel module is the single biggest lever.

**Service keeps coming back after `make stop`.** Use `make service-disable`. `systemd` and `launchd` re-spawn stopped units; `stop` alone won't keep them down.

**Docker container reports unhealthy on startup.** The first 30–60 s of RandomX dataset allocation predates the healthcheck. `start_period` is set to 60 s, so Docker won't mark it unhealthy during that window. If it lasts longer, check `docker compose logs` for an OOM.

**Build fails on macOS.** `make deps-macos` installs `cmake`, `libuv`, `openssl`, `hwloc` via Homebrew. The target installs Homebrew first if it isn't on your `PATH`.

## Development

- CI (`.github/workflows/ci.yml`) runs `shellcheck`, `hadolint`, a `make -n` dry-run, and a full Docker build smoke test on every push and PR. First-time contributor PRs require maintainer approval before workflows run.
- Dependabot opens weekly PRs for the vendored `xmrig` and `bash-toolbox` submodules, and for the GitHub Actions in the workflow. A companion workflow auto-merges Dependabot PRs once CI is green.
- Pull requests welcome. Fork, branch, open a PR. The CI will tell you if anything's broken before a human looks at it.

## License

MIT. See [LICENSE](./LICENSE).

Banner artwork, scripts, and templates © Yann M. Vidamment 2025. This project is not endorsed by Monero or MoneroOcean.

## Resources

- [XMRig documentation](https://xmrig.com/docs)
- [XMRig config wizard](https://xmrig.com/wizard#start)
- [Monero project](https://www.getmonero.org/)
- [MoneroOcean pool](https://moneroocean.stream/)
