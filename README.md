# Monero-miner-setup

![Monero Miner Setup Banner](https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/assets/banner.png)

[![CI](https://github.com/MorganKryze/Monero-miner-setup/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/MorganKryze/Monero-miner-setup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/MorganKryze/Monero-miner-setup)](./LICENSE)
![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Debian%2FUbuntu%20%7C%20Docker-blue)

Sets up [XMRig](https://xmrig.com) as a background service that mines Monero to a [MoneroOcean](https://moneroocean.stream) pool. Two install paths: a Docker container (anywhere Docker runs) or a native install with a `systemd` or `launchd` service on Debian/Ubuntu and macOS.

> **⚠️ Before you run this.** Mining consumes power, heats hardware, and can violate your cloud provider's ToS. Expect antivirus tools to flag XMRig. This project is not endorsed by Monero or MoneroOcean. You run it at your own risk.

## Install

| Pick       | Best when                                                        | Guide |
| ---------- | ---------------------------------------------------------------- | ----- |
| **Docker** | You want isolation, no system changes, easy teardown             | [Docker](docs/docker.md) |
| **Native** | Debian/Ubuntu or macOS. Unlocks huge pages, and the MSR boost with `--service-as-root` on x86 | [Native install on Linux or macOS](docs/native-install.md) |

To flash a Raspberry Pi 5 or Orange Pi 5 card that mines on first boot, see [docs/boards.md](docs/boards.md).

## VPN config (Docker)

Moved to [Route mining through a VPN](docs/docker.md#route-mining-through-a-vpn).

## Operating the miner

Moved to [Run and watch the miner](docs/operating.md).

## Upgrading from 0.1.x or 0.2.0-rc.x

Read this when you installed 0.1.0 or a 0.2.0 release candidate: the default pool connection moves to TLS, on ports 20001 to 28192. Installed before 0.1.0? Read [Upgrading an install made before 0.1.0](#upgrading-an-install-made-before-010) as well.

**Native.**

- A kept config keeps its pool as it was: one that mines on MoneroOcean in clear text stays in clear text until you regenerate it. The installer warns with the flags that bring TLS: `<config> mines on MoneroOcean without TLS. To switch to TLS, run 'make clean-configs', the installer again with '--pool <host> --name <worker>' and the other flags you gave it (such as -t, --donate, --pause-active or --pause-battery), then 'make service-setup' and 'make restart'.`
- `make update` doesn't run the installer, so it keeps the configs as they are and prints no such line. To check, run `grep -E '"(url|pass)":' configs/*.json` in the clone: a MoneroOcean `url` that doesn't start with `stratum+ssl://` mines in clear text, and `pass` holds the worker name (`x` means none). To switch, run `make clean-configs`, the installer again with your wallet, `--name <that worker name>` and your other flags, then `make service-setup` and `make restart`.

**Docker.**

- A `POOL_URL` that's a MoneroOcean host with no port (the default) moves to TLS at the container's next start on the new image: port 20000 + n instead of 10000 + n, MoneroOcean's certificate pinned. A network that blocks those ports stops mining; set `POOL_URL=stratum+tcp://gulf.moneroocean.stream` in `docker/.env` and run `docker compose up -d` from `docker/` (`docker compose -f compose.yml -f compose.vpn.yml up -d` if you use the VPN) to mine in clear text again.

On x86, nothing else changes: only the first pool's URL, `tls` and `tls-fingerprint` differ. Threads, MSR, huge pages and the service stay as they were.

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

Moved to [Make it faster](docs/native-install.md#make-it-faster).

## Configuration

Moved to the native install's [Configuration](docs/native-install.md#configuration) and the Docker page's [Configuration](docs/docker.md#configuration).

## Logs

Moved to [Logs](docs/operating.md#logs).

## Security

The miner talks to the default pool over TLS, with MoneroOcean's certificate pinned: a certificate that doesn't match stops mining instead of mining for someone else. A pool you add with `stratum+tcp://` or without a pin can be read and answered by anyone on the network path.

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
| The first-boot setup's installer | `https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/<tag>/scripts/install.sh` of the release the DietPi files come from, refused unless its sha256 matches the one they carry; a HEAD request on `https://github.com/MorganKryze/Monero-miner-setup/releases/download/<tag>/SHA256SUMS` to wait for the network; `git`, `make` and `bc` through apt when they're missing; `avahi-daemon` through apt with `mdns = on` | a DietPi card set up from the release's `dietpi-first-boot.zip` |
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
- with `--mode` on a board with a profile: `install` of `/etc/xmrig-host-tuning.conf`, `/usr/local/sbin/xmrig-host-tuning` and `/etc/systemd/system/xmrig-host-tuning.service`, root-owned, from private temp files, and removed again, with the folder `/run/xmrig-host-tuning`, by a setup without a mode or by `make service-disable`
- on a board set up from the DietPi files, on `make service-disable`: `test` of the setup's record that it installed `avahi-daemon`, then `apt-get remove` of it when it did; removal of `/etc/systemd/system/xmrig-first-boot.service`, `/usr/local/sbin/xmrig-first-boot` and the folder `/var/lib/xmrig-first-boot`
- on a DietPi card set up from the release's `dietpi-first-boot.zip`, the first-boot setup runs as root, from DietPi's own custom-script hooks: with `wifi_ssid`, the Wi-Fi step's `dietpi-wifi.txt`, `dietpi.txt` lines, `/var/lib/xmrig-first-boot/wifi` record and emptied `wifi_key`; the SSH settings, the host name and its `/etc/hosts` line, root's `authorized_keys`, the board LED, its unit and state folder, `git`, `make` and `bc` when they're missing, `avahi-daemon` with `mdns = yes`, then the installer above with `--prebuilt` (the full list is in the DietPi section)
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

**Mining stopped and the log says `Failed to verify server certificate fingerprint`.** The pool's certificate isn't the pinned one. The miner logs that line with the pool URL, then the fingerprint it was given and the one configured, in `make status` and `/var/log/xmrig/<account>/xmrig.log` (macOS: `logs/xmrig_stdout.log` in the clone) or, for Docker, `docker compose logs xmrig` from `docker/`. It gets no new jobs and MoneroOcean's panel shows the worker offline, but the Docker healthcheck stays healthy: the process is alive and reconnecting. Either MoneroOcean changed its certificate, or someone on the network path is answering in its place. Never pin the fingerprint the miner reports as given: that's the one a man in the middle would show you. Pick one fix:

- Update to a release that carries the new pin. Native: `make update`, then `make clean-configs`, the installer again with your wallet and flags, `make service-setup` and `make restart`. Docker, from `docker/`: `docker compose pull` and `docker compose up -d`, or with the VPN `docker compose -f compose.yml -f compose.vpn.yml pull` and `docker compose -f compose.yml -f compose.vpn.yml up -d`.
- Pin a fingerprint you checked yourself from a second network (a phone hotspot, say): `openssl s_client -connect gulf.moneroocean.stream:20128 -servername gulf.moneroocean.stream </dev/null | openssl x509 -noout -fingerprint -sha256`. It prints `sha256 Fingerprint=` (`SHA256 Fingerprint=` with LibreSSL) and 32 colon-separated pairs: keep only the part after the `=`, that's the value. Native: `make clean-configs`, the installer again with `--tls-fingerprint <that value>` and your flags, then `make service-setup` and `make restart`. Docker: set `TLS_FINGERPRINT=<that value>` in `docker/.env`, then `docker compose up -d` from `docker/` (`docker compose -f compose.yml -f compose.vpn.yml up -d` if you use the VPN).
- Mine without TLS, if you accept that anyone on the path can read and change the pool's traffic: the same steps with `--pool stratum+tcp://gulf.moneroocean.stream` (Docker: `POOL_URL=stratum+tcp://gulf.moneroocean.stream`).

## Development

- CI (`.github/workflows/ci.yml`) runs `shellcheck`, `hadolint`, the `make -n` dry runs, `make check` and the Docker build smoke test on amd64 and arm64. It runs on pushes and pull requests to `main`, and after a Dependabot merge. A pull request to `main` needs green CI to merge (the maintainer can still push directly). First-time contributor PRs require maintainer approval before workflows run.
- Dependabot opens weekly PRs for the `xmrig` and `bash-toolbox` submodules, the GitHub Actions, the Dockerfile's base image and Gluetun. Only Actions patch and minor bumps merge on their own, once CI is green; the rest wait for review.
- Pull requests welcome. Fork, branch, run `make check`, open a PR.

## License

MIT. See [LICENSE](./LICENSE).

Banner artwork, scripts, and templates © Yann M. Vidamment 2025, except `templates/dietpi.txt`: it is DietPi v10.8's `dietpi.txt` (© the DietPi authors, GPL-2.0, https://github.com/MichaIng/DietPi) with the settings this project needs changed. This project is not endorsed by Monero or MoneroOcean.

## Resources

- [XMRig documentation](https://xmrig.com/docs)
- [XMRig config wizard](https://xmrig.com/wizard#start)
- [Monero project](https://www.getmonero.org/)
- [MoneroOcean pool](https://moneroocean.stream/)
