# Security and privacy

Read this before you install, to know who can see your mining, what the project fetches and what it runs as root.

## Who sees what

The miner talks to one pool. This table says what each party on the way can read, with the default TLS connection alone and with the Docker install's VPN sidecar on top.

| Who | TLS alone | TLS with the VPN sidecar |
| --- | --- | --- |
| The network path: your ISP, the owner of the Wi-Fi or LAN | your IP and the pool's IP and port, so that you mine on MoneroOcean; not your wallet, your worker name or your shares | your IP and the VPN server's IP; not the pool, your wallet, your worker name or your shares |
| The pool (MoneroOcean) | your IP, your wallet, your worker name and your shares | the VPN's exit IP instead of yours; your wallet, your worker name and your shares all the same |
| The VPN provider | nothing: no VPN runs | your IP and the pool's IP and port; not your wallet, your worker name or your shares, which TLS keeps from it |

A pool you set with `stratum+tcp://` drops the TLS of every row: anyone on the path can read your wallet and worker name, and answer in the pool's place.

The VPN sidecar ships only with the Docker install. No VPN ships for the native install or the boards: on those, the network path sees what the TLS alone column says.

## TLS and the pinned certificate

The miner talks to the default pool over TLS, with MoneroOcean's certificate pinned: a certificate that doesn't match stops mining instead of mining for someone else. A pool you add with `stratum+tcp://` or without a pin can be read and answered by anyone on the network path.

When the pool's certificate changes, the miner stops getting jobs. [Troubleshooting](troubleshooting.md) gives the fixes, under the entry that starts with the log line `Failed to verify server certificate fingerprint`.

## What the VPN sidecar adds

The Docker install's `--vpn` adds a [Gluetun](https://github.com/qdm12/gluetun) container, `qmcgaw/gluetun`, pinned to a release in `docker/compose.vpn.yml`. That file gives Gluetun `NET_ADMIN` and `/dev/net/tun`, and runs the miner container on Gluetun's network, so all of the miner's traffic goes through the tunnel. The miner starts only once Gluetun reports the tunnel healthy.

Gluetun's killswitch is on by Gluetun's default: if the tunnel drops, outbound traffic stops. Nothing the project writes turns it off.

The VPN hides your IP from the pool and the pool from your network path. It hands both to the VPN provider instead, so pick one you trust. [Route mining through a VPN](docker.md#route-mining-through-a-vpn) sets it up.

## Your Wi-Fi key

On a DietPi card, the key sits in clear text on the `wifi_key` line of the settings at the top of `Automation_Custom_Script.sh` until first boot. Anyone who holds the card can read it then.

At first boot, before the network, `Automation_Custom_PreScript.sh` hands the key to DietPi in `dietpi-wifi.txt` (0600), then empties the `wifi_key` value in `Automation_Custom_Script.sh`, even when the Wi-Fi step fails. A key typed under another `wifi_` name is emptied too. When that write fails, the error line says so: delete the value on your computer before you use the card again.

Afterwards the key lives in DietPi's `/var/lib/dietpi/dietpi-wifi.db` and `/etc/wpa_supplicant/wpa_supplicant.conf`, root-only, as the derived PSK. The setup removes it from `/boot/Automation_Custom_Script.sh` and from its own copy of the settings. The card's free space may still hold it until overwritten: the FAT's deleted blocks, and the blocks the root filesystem freed.

## What the installers fetch

The installers fetch from the sources below and nothing else. All of it comes over HTTPS except the packages apt installs: apt uses the archives its sources list names (the base image's, in a Docker build), plain HTTP by default on Debian and Ubuntu, and checks what it gets against the archive's signing key.

| What | From | When |
| --- | --- | --- |
| The installer | `https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh` | the [install commands](../README.md#install) |
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

## What runs as root

On Linux, these steps go through `sudo` (`make deps-debian`, `scripts/setup_service_debian.sh` and the service targets):

- `apt-get update` and `apt-get install` of the packages above
- `useradd --system` to create the `xmrig` account, when the service needs it
- `install -d` of `/etc/xmrig`, then `install` of `/etc/xmrig/config.json`, `/etc/logrotate.d/xmrig` and `/etc/systemd/system/xmrig.service`, root-owned, from private temp files
- `rm -f` of `/etc/systemd/system/xmrig.service` and `/etc/logrotate.d/xmrig`, on `make service-disable`
- with `--mode` on a board with a profile: `install` of `/etc/xmrig-host-tuning.conf`, `/usr/local/sbin/xmrig-host-tuning` and `/etc/systemd/system/xmrig-host-tuning.service`, root-owned, from private temp files, and removed again, with the folder `/run/xmrig-host-tuning`, by a setup without a mode or by `make service-disable`
- on a board set up from the DietPi files, on `make service-disable`: `test` of the setup's record that it installed `avahi-daemon`, then `apt-get remove` of it when it did; removal of `/etc/systemd/system/xmrig-first-boot.service`, `/usr/local/sbin/xmrig-first-boot` and the folder `/var/lib/xmrig-first-boot`
- on a DietPi card set up from the release's `dietpi-first-boot.zip`, the first-boot setup runs as root, from DietPi's own custom-script hooks: with `wifi_ssid`, the Wi-Fi step's `dietpi-wifi.txt`, `dietpi.txt` lines, `/var/lib/xmrig-first-boot/wifi` record and emptied `wifi_key`; the SSH settings, the host name and its `/etc/hosts` line, root's `authorized_keys`, the board LED, its unit and state folder, `git`, `make` and `bc` when they're missing, `avahi-daemon` with `mdns = on`, then the installer above with `--prebuilt` (the full list is in [What the setup changes on the board](boards.md#what-the-setup-changes-on-the-board))
- `systemctl daemon-reload`, `enable`, `start`, `try-restart`, `stop`, `status`, `disable`, `reset-failed` and `clean`

`--prebuilt` runs the installer itself as root: `apt-get update` and `apt-get install` of `libuv1t64 libssl3t64 libhwloc15`, the download into a root-only folder in the clone, and the rename onto `<clone>/xmrig` and `xmrig.release`.

The service runs the miner as root only with `--service-as-root`. `make test` runs it as whoever runs `make`. An install you run as root runs every step as root, not only these: the clone, the XMRig build, and turning off background mode in the clone's config.

## Why antivirus tools flag it

XMRig is legitimate open-source software. AV tools flag it because malware installs miners without the user's consent. Your AV will flag this project too.

Expect 1–4 hits out of ~91 vendors on every file in this repo, and similar on any miner-adjacent project. Three things drive the verdict:

1. **URL reputation.** Once any script under `raw.githubusercontent.com/.../Monero-miner-setup/...` is reported, it lands in shared block-lists (e.g. `Chong Lua Dao`). The contents stop mattering at that point.
2. **Keyword heuristics.** Static scanners grep for `xmrig`, `moneroocean`, `wallet`, `hashrate`, `donate-level`, the base58 address regex, the curl-into-bash install pattern. Any 3–4 of these in one file triggers a YARA rule from the `BAT.CoinMiner.*` family.
3. **Behavioral patterns.** A bash script that clones a repo, builds a binary, registers a `systemd` / `launchd` unit with `Restart=on-failure`, and generates a randomised worker name matches the same template that real cryptojackers (TeamTNT, Kinsing, 8220 Mining Group) use. The pattern, not the intent, is what gets matched.

## What the verdicts mean

The vendors that flag (BitDefender, Fortinet, G-Data, Chong Lua Dao) classify these files as **Riskware** / **PUA**: the same tier as Mimikatz, nmap, and PsExec. Concrete labels you'll see:

- BitDefender / G-Data: `Application.RiskTool.CoinMiner.X` or `Application.Generic.X`
- Fortinet: `Riskware/CoinMiner` or `BAT/Agent.X!tr`

None of them claim the script does something it doesn't advertise. They're saying "this category of tool is high-risk." For comparison, the upstream XMRig binary sits at around 30/70 on VirusTotal; the wrappers in this repo score the 1–4 above. The prebuilt GHCR image does ship an XMRig binary: this repository's CI builds it from the pinned submodule, unmodified. The native install builds it on your host.

## Check before you run it

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

## The container

The container runs as uid 999, `xmrig`. The compose file and the [single `docker run`](docker.md#a-single-docker-run) set `no-new-privileges`; a bare `docker run` without that flag doesn't. Both installers and the container check the wallet, the worker name, the pool and every number and flag before they write them, and write every value that reaches the miner's config as a value. The native installer reuses a clone only when nothing in it belongs to, or can be changed by, another user. As root on Linux, it also refuses a base directory, a clone, or a directory above them that another user can change, and the service setup refuses a binary anyone but root can change when it runs it as another account. The installer still warns before running as root.
