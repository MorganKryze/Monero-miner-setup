# Docker

Read this when you want the miner in a container on any host Docker runs on, with an optional VPN sidecar and no system changes.

You get isolation and an easy teardown. For huge pages and the MSR boost, see the [native install](native-install.md). To run the miner once it's in, see [Run and watch the miner](operating.md#with-docker).

## Install with the prebuilt image

The install commands below need a POSIX shell such as bash or zsh. In fish, run `bash` first, then paste them.

1. Run the installer with your wallet:

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
bash -c "${installer:?the download came back empty}" -- \
  --docker -w YOUR_MONERO_WALLET --autostart
```

2. Watch it start with `docker compose logs -f` from `docker/`.

The installer pulls a multi-arch prebuilt image (`amd64` + `arm64`) from GHCR. There's no compile step and no Dockerfile toolchain on the host.

Run from a clone's own `scripts/install.sh`, the installer uses that clone. Otherwise it clones the repository to `$HOME/Monero-miner-setup` (`-d DIR` picks another base directory), and a re-run reuses that clone only when it's a git clone that you or root own and no other user can write to. It never adopts a folder because it sits above where you run it. From inside another copy of the project, it stops with an error.

The installer writes `docker/.env` (and `docker/.env.vpn` with `--vpn`) only when it's missing or you pass `--overwrite-env`, with mode 600 from the first byte. A kept file that other users can read gets a warning and the `chmod 600` command that restricts it. One that another user can change, or that isn't owned by you or root (as root, also by the user who ran `sudo`), stops the run.

With `--autostart` it brings up the stack (compose, healthcheck, log rotation, optional VPN sidecar). A re-run without `--vpn` starts it without the VPN sidecar. The container runs as a non-root `xmrig` user, with `no-new-privileges` set in the compose file.

To skip the installer, run compose yourself from a clone:

```bash
# Docker (pull prebuilt image):
cp docker/.env.example docker/.env
# Set WALLET_ADDRESS in docker/.env, then:
docker compose -f docker/compose.yml up -d
```

## Flags

Common flags (run `install.sh --docker --help` for the complete list):

- `--worker-name NAME`: label shown on the pool (default: `docker_miner`)
- `--pool URL`: pool override (default: `gulf.moneroocean.stream`, over TLS with MoneroOcean's certificate pinned, on the port the container's threads pick). `stratum+tcp://gulf.moneroocean.stream` mines without TLS; a MoneroOcean URL with no port gets the computed one (from 20001 to 28192 over TLS). Any other URL is used as given, except a host with no port and no `stratum+ssl://`, which gets `:3333`
- `--tls-fingerprint HEX`: pin your TLS pool's certificate, its sha256 as 64 hex digits or the 32 colon-separated pairs `openssl x509 -fingerprint -sha256` prints (`TLS_FINGERPRINT` in `docker/.env`); it replaces MoneroOcean's built-in pin
- `--cpus N` / `--memory LIMIT`: container caps (defaults: `2.0`, `3g`). Under 2560 MiB the miner runs in RandomX light mode, at a fraction of the hashrate
- `--threads PCT` / `--force-threads N`: threads as a percentage of the container's CPU quota, at most the count XMRig picks itself, or exactly N threads (defaults: `75`, none). On arm64 each thread gets its own CPU, the biggest first, so the count is at most the CPUs the container may use
- `--pause-battery` / `--pause-active`: pause mining when on battery or when the user is active
- `--vpn PROVIDER`: route mining through a VPN, see [Route mining through a VPN](#route-mining-through-a-vpn)
- `--image REF`: pin a specific tag or point at a fork (default: `ghcr.io/morgankryze/monero-miner-setup:latest`)
- `--build`: build the image locally from source instead of pulling (see [Build from source](#build-from-source))
- `--overwrite-env`: rewrite `docker/.env` (and `docker/.env.vpn` with `--vpn`) from this run's flags. Without it, a re-run keeps both files as they are

## Image tags

| Tag | What it follows |
| --- | --- |
| `:latest` | follows `main`. Rebuilt on every push to `main` and after each Dependabot merge, never by a manual run |
| `:main-abc1234` | one per commit on `main` |
| `:X.Y.Z`, `:X.Y` | release pins, without the `v`. A `vX.Y.Z` git tag publishes both and moves `:latest` |

An image older than 0.1.0 under the new compose file writes its log file inside the container, and it grows unbounded.

## Pin a release

The commands above fetch `docker_setup.sh` from `main`, so `--image` alone pins only the image, not the installer. To pin both, clone the release and run its own installer:

```bash
git clone --branch v0.2.0-rc.3 --recurse-submodules https://github.com/MorganKryze/Monero-miner-setup.git
cd Monero-miner-setup
./scripts/install.sh --docker --image ghcr.io/morgankryze/monero-miner-setup:0.2.0-rc.3 -w YOUR_MONERO_WALLET --autostart
```

A tag checkout has no branch, so `make update` doesn't apply to it. Check out the next tag instead.

## Build from source

Pass `--build` if you'd rather compile locally. That helps when you've patched XMRig, when you don't want to pull from GHCR, or when a prebuilt image isn't available for your platform.

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
bash -c "${installer:?the download came back empty}" -- \
  --docker --build -w YOUR_MONERO_WALLET --autostart
```

First run compiles XMRig (3–8 min). The runtime image is about 190 MB. Everything else is identical to the prebuilt path.

Without the installer, from a clone with `docker/.env` set:

```bash
# Docker (build locally instead of pulling):
docker compose -f docker/compose.yml up -d --build
```

## A single docker run

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

Tail logs with `docker logs -f monero_xmrig_miner`. Stop it with `docker stop monero_xmrig_miner && docker rm monero_xmrig_miner`. For VPN routing, `.env`-based config, and the healthcheck wiring, use the installer instead.

## Memory and light mode

Under 2560 MiB usable, the miner warns and runs in light mode. Usable means the memory limit or the host's available memory, whichever is lower, plus its free huge pages. Light mode mines at a fraction of the hashrate, so give the container `--memory 3g` when you can.

At each start the miner runs XMRig's offline benchmark in light mode, connected to nothing, and stops it as soon as XMRig saves its thread count. That takes under a second, five at most.

## Configuration

Runtime config lives in `docker/.env` (and `docker/.env.vpn` if VPN is enabled). The installer writes them, mode 600, only when they're missing or you pass `--overwrite-env`.

The miner's config is built at every start into the named volume `xmrig-configs` (`docker volume ls` shows `docker_xmrig-configs`). `docker compose down` keeps it; `docker compose down -v` removes it.

`docker/.env.example` documents every variable, including `XMRIG_IMAGE` for pinning a specific tag or pointing compose at a forked image. For the XMRig schema itself, see the [XMRig docs](https://xmrig.com/docs).

## Route mining through a VPN

The Docker install can route all mining traffic through a [Gluetun](https://github.com/qdm12/gluetun) VPN sidecar. The native install has no VPN option. Supported providers are **Mullvad**, **ProtonVPN**, **PIA** and **NordVPN**. After `--autostart`, the installer waits for the tunnel to be healthy and prints your VPN exit IP.

### Providers

| Provider  | Protocol  | Mining policy  | `--vpn-location` maps to | Where to get credentials                                                                                                                   |
| --------- | --------- | -------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Mullvad   | WireGuard | Allowed        | `SERVER_CITIES`          | [mullvad.net/account/wireguard-config](https://mullvad.net/en/account/wireguard-config)                                                    |
| ProtonVPN | WireGuard | Allowed (paid) | `SERVER_COUNTRIES`       | [account.protonvpn.com/downloads](https://account.protonvpn.com/downloads) (WireGuard tab)                                                 |
| PIA       | OpenVPN   | Allowed        | `SERVER_REGIONS`         | Your PIA account login                                                                                                                     |
| NordVPN   | OpenVPN   | Check ToS      | `SERVER_COUNTRIES`       | [my.nordaccount.com/.../manual-setup](https://my.nordaccount.com/dashboard/nordvpn/manual-setup/) (Service credentials, not account login) |

### Three ways to pass each secret

Every secret has three input forms. Pick one per field:

| Form | Use it when |
| --- | --- |
| A file (`--*-file PATH`) | recommended: the path lands in shell history, the content doesn't |
| An inline flag | it works, but the secret lands in shell history |
| An environment variable | anywhere (CI, systemd drop-ins, `.envrc`, etc.) |

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

### Commands per provider

Pick one block and put your wallet in. All examples use `--*-file` so secrets never land in shell history. Replace `~/.secrets/...` paths with your own.

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

**PIA (OpenVPN).** Uses your regular PIA account username and password. PIA's location field is a **region**, not a country (`Swiss`, `US East`, `CA Toronto`, `UK London`, etc.). The [gluetun PIA docs](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/private-internet-access.md) have the full list.

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

**NordVPN (OpenVPN).** You must use NordVPN's **service credentials**, not your account login. Grab them from the manual-setup page in the [nord account dashboard](https://my.nordaccount.com/dashboard/nordvpn/manual-setup/). NordVPN's ToS prohibits crypto-mining on some plans; verify yours before running long.

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

### Wire the VPN by hand

Skip the installer and wire the override yourself:

1. Copy the example file and restrict it.
2. Uncomment one provider block and fill in credentials.
3. Bring the stack up with both compose files.

```bash
cd docker/
cp .env.vpn.example .env.vpn && chmod 600 .env.vpn
# Uncomment ONE provider block in .env.vpn and fill in credentials.
docker compose -f compose.yml -f compose.vpn.yml up -d
```

### Check the exit IP

Check the exit IP is not yours:

```bash
docker exec monero_xmrig_gluetun wget -qO- https://ifconfig.io
```

Gluetun's killswitch is on by Gluetun's default. If the tunnel drops, outbound traffic stops, so your real IP can't leak. Nothing the project writes turns it off.

Tradeoffs to know about:

- +1–5 ms latency per share submission. Not material for mining.
- Some pools rate-limit VPN IP ranges. MoneroOcean accepts them in practice; watch the acceptance rate if you see drops.
- NordVPN's ToS prohibits crypto-mining on some plans. Mullvad and ProtonVPN are the safe bets.
