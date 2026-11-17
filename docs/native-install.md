# Native install on Linux or macOS

Read this when you want XMRig built on your Debian, Ubuntu or macOS host and run as a `systemd` or `launchd` service, without Docker.

The native install unlocks huge pages, and the MSR boost with `--service-as-root` on x86. For the container path, see [Docker](docker.md). To run the miner once it's in, see [Run and watch the miner](operating.md).

## Install

The install commands below need a POSIX shell such as bash or zsh. In fish, run `bash` first, then paste them.

1. Check that `git`, `curl` and `make` are on your `PATH`.
2. Run the installer with your wallet.

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
bash -c "${installer:?the download came back empty}" -- \
  -w YOUR_MONERO_WALLET
```

3. Start the service with `make start` from the clone, or pass `--autostart` next time.

The installer clones to `$HOME/Monero-miner-setup` and builds the XMRig commit the repository pins. It writes `config.json` + `config_background.json`, then registers a `systemd` (Linux) or `launchd` (macOS) service.

As root on Linux with no `-d`, the clone goes to `/opt/Monero-miner-setup`, unless an earlier install left one in root's home. A re-run keeps using that one. As root on Linux, the installer refuses a base directory, a clone, or a directory above them that a user other than root or the `sudo` user can change.

A re-run reuses `Monero-miner-setup` in the base directory only when it's a git clone in which every file and folder belongs to you or root (or the `sudo` user) and no other user can change one. Otherwise the installer stops with one error line, before it clones or builds anything. It stops the same way when the clone's path is a link, or when another user can change the base directory or a directory above it. A sticky one such as `/tmp` is fine. It clones and builds with group and other write turned off in its umask (a stricter umask stays), so no other user can change the clone while it's being written.

The service runs the miner as you. Installed with `sudo`, it runs as the user who ran `sudo`. Installed as root with no `sudo` user, it runs as the system account `xmrig` (no login shell, no home), created once and reused. That account owns nothing in the clone. systemd creates `/etc/xmrig`, `/var/lib/xmrig/<account>` (its config and calibration) and `/var/log/xmrig/<account>`, and removes them on `make service-disable`.

## Flags

Common flags (run `install.sh --help` for the complete list):

- `-t, --threads PERCENT`: `max-threads-hint` 1–100, a percentage of the host's cores (default: `75`). On arm64, where XMRig would start a thread on every core whatever the hint, the config lists the cores to mine on instead: that share of them, rounded up, the biggest first
- `-p, --pool URL`: pool override (default: `gulf.moneroocean.stream`, over TLS with MoneroOcean's certificate pinned, on a port from 20001 to 28192 the CPU count picks). `stratum+tcp://gulf.moneroocean.stream` mines without TLS; a MoneroOcean URL with no port gets the computed one (from 10001 to 18192 without TLS). Any other URL is used as given, so a TLS pool needs `stratum+ssl://` and its port.
- `--tls-fingerprint HEX`: pin your TLS pool's certificate, its sha256 as 64 hex digits or the 32 colon-separated pairs `openssl x509 -fingerprint -sha256` prints. It replaces MoneroOcean's built-in pin.
- `--mode max|eco`: on a board with a profile (Raspberry Pi 5, RK3588 boards), mine on the CPUs of that profile's `max` or `eco` list (see [Board profiles](boards.md#board-profiles)). Not with `-t`: the two both choose the CPUs, so the installer stops if you pass both
- `--name STRING`: worker name (default: random `adjective_noun_NNN`)
- `-d, --dir DIR`: where the clone goes (default: `$HOME`; as root on Linux, `/opt`)
- `--service-as-root`: run the systemd service as root, for the x86 RandomX MSR boost (see [below](#run-the-service-as-root-for-the-msr-boost))
- `--donate PERCENT`: 0–5
- `--autostart`: start the service right after install
- `--only-manual`: install the binary, skip service setup
- `-y, --yes`: skip the root prompt and the 15 s pre-install delay

## Run the service as root for the MSR boost

`--service-as-root` is for systemd only. The macOS service refuses it, and refuses to run as root. It exists for the x86 RandomX MSR boost, which needs root.

With it, the miner runs as root on the host, so a flaw in XMRig or a hostile pool reaches a root process. The default connection is TLS with MoneroOcean's certificate pinned. A pool you add without TLS or without a pin is still open to anyone on the network path to it, and through it to that root process.

Without it, the miner gets no MSR boost and can't reserve huge pages itself, so reserve them with `sysctl` (see [Make it faster](#make-it-faster)).

## On a Raspberry Pi 5 or RK3588 board: the prebuilt binary

On a Raspberry Pi 5 or an RK3588 board running Debian 13 or DietPi Trixie, `--prebuilt` skips the compile. To flash a card that mines on first boot, the `--mode` tuning and the board profiles, see [the boards page](boards.md).

1. Clone the release you want as root, then run its installer.

   ```bash
   sudo git clone --branch vX.Y.Z --recurse-submodules https://github.com/MorganKryze/Monero-miner-setup.git /opt/Monero-miner-setup
   sudo /opt/Monero-miner-setup/scripts/install.sh --prebuilt -w YOUR_MONERO_WALLET -y
   ```

2. Read the installer's last lines. They say where the miner binary comes from.

It installs the release the clone is checked out at. A clone at no release tag is refused. With no clone, the installer clones `v<its own version>`. It downloads `xmrig-linux-arm64` and `SHA256SUMS` over HTTPS and checks the sum before it installs anything. It then runs `apt-get install` for `libuv1t64 libssl3t64 libhwloc15` and puts the binary at `<clone>/xmrig`, mode 0755, so only root can change it. The release and the sum go in `xmrig.release`, next to it.

It refuses, with one error line, a host it can't serve. That's Debian 12 Bookworm and any glibc before 2.38, amd64, macOS, a run without root, and a clone under a directory another user can change. A re-run with the same binary downloads nothing.

`make update` refuses in a clone that runs a release binary. To move to another release, run as root in the clone: `git fetch --tags; git checkout --recurse-submodules vX.Y.Z; scripts/install.sh --prebuilt -w YOUR_MONERO_WALLET -y; make restart`.

### Where the miner binary comes from

Run `journalctl -u xmrig | grep 'Miner binary'`. It prints one of three origins:

| Origin | Means |
| --- | --- |
| `release vX.Y.Z, sha256 …` | the binary matches the sum `xmrig.release` records |
| `compiled on this host` | there's no `xmrig.release`, so the binary was built here |
| `unknown (sha256 … matches no release record)` | the binary isn't the one the record names. Install again |

To check the binary yourself, download `xmrig-linux-arm64` from the release page on your PC, then run this.

```bash
gh attestation verify xmrig-linux-arm64 --repo MorganKryze/Monero-miner-setup
```

## Install by hand

Clone and read the code before you run anything.

1. Clone the repository and review the installer.

   ```bash
   git clone --recurse-submodules https://github.com/MorganKryze/Monero-miner-setup.git
   cd Monero-miner-setup
   less scripts/install.sh        # review
   ```

2. Install the dependencies and the miner, then start the service.

   ```bash
   # Native:
   make install-debian            # or: make install-macos
   make service-setup && make start
   ```

For the same steps with Docker, see [Docker](docker.md#install-with-the-prebuilt-image).

## Make it faster

Run `make doctor` first. It inspects your host and prints a numbered list of concrete commands to apply. On arm64 Linux it checks AES (the ARMv8 Crypto Extensions) and huge pages in the kernel's page size, skips the x86-only checks, and warns about a native config with no CPU list.

These are the common wins on Linux.

- **Reserve 2 MB huge pages**: `sudo sysctl -w vm.nr_hugepages=1280`. Persist in `/etc/sysctl.d/99-xmrig.conf`.
- **Load the `msr` module**: `sudo modprobe msr`. Persist via `echo msr | sudo tee /etc/modules-load.d/msr.conf`. It helps only a service installed with `--service-as-root`. Worth 5–15% on Ryzen and EPYC.
- **Enable 1 GB pages** (if the CPU has `pdpe1gb`): add `hugepagesz=1G hugepages=3 default_hugepagesz=2M` to `GRUB_CMDLINE_LINUX`, regenerate GRUB, reboot. Worth 1–5%.

macOS has no userspace equivalent for any of these. Expect 10–30% less hashrate than a tuned Linux host on the same silicon.

See [Board profiles](boards.md#board-profiles) for the boards the installer knows.

## Configuration

Generated configs live under `configs/`.

- `config.json`: used by `make test`
- `config_background.json`: the service's. The setup installs it as `/etc/xmrig/config.json`. At the first start after it changed, the service copies it into `/var/lib/xmrig/<account>/config.json`, and otherwise keeps the calibration it saved there. Edit it, then run `make service-setup` and `make restart`.

The installer fills both in from `templates/*.json.template`, and a re-run keeps them. To regenerate them, run `make clean-configs`, then the installer.

For the XMRig schema itself, see the [XMRig docs](https://xmrig.com/docs).
