# Monero-miner-setup: mine Monero on a Raspberry Pi, a PC or Docker

![Monero Miner Setup banner](assets/banner.png)

[![CI](https://github.com/MorganKryze/Monero-miner-setup/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/MorganKryze/Monero-miner-setup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/MorganKryze/Monero-miner-setup)](./LICENSE)
![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Debian%2FUbuntu%20%7C%20Docker-blue)

Turn a Raspberry Pi, a spare PC or any Docker host into a quiet Monero miner: one command, TLS to the pool.

It isn't only for the Pi. The card setup and the eco and max profiles cover the Raspberry Pi 5 and RK3588 boards such as the Orange Pi 5 Plus and 5 Max. Any other 64-bit Linux single-board computer mines with the native install or Docker.

It sets up [XMRig](https://xmrig.com) as a background service that mines to a [MoneroOcean](https://moneroocean.stream) pool.

> **⚠️ Before you run this.** Mining consumes power, heats hardware, and can violate your cloud provider's ToS. Expect antivirus tools to flag XMRig. This project is not endorsed by Monero or MoneroOcean. You run it at your own risk.

## What you get

- **TLS to the pool.** The default pool is MoneroOcean over TLS, with MoneroOcean's certificate pinned. A certificate that doesn't match stops mining.
- **An eco mode for boards.** On a Raspberry Pi 5 or an RK3588 board, `--mode eco` leaves headroom and runs cooler, and `--mode max` mines on every CPU the board's profile allows.
- **A prebuilt arm64 binary.** On those boards, `--prebuilt` installs a release's XMRig, built by CI and attested, and skips the compile.
- **A card that mines on first boot.** Flash DietPi, copy three files, set your wallet, and the board sets itself up and mines. No screen, no keyboard, over Ethernet or Wi-Fi.
- **Docker, with an optional VPN.** A prebuilt multi-arch image, a non-root container, and a Gluetun VPN sidecar that hides your IP from the pool.

## Pick your install

| You have | Install | Guide |
| --- | --- | --- |
| A Raspberry Pi 5 or an Orange Pi 5 Plus or 5 Max | A DietPi card that mines on first boot | [Boards](docs/boards.md) |
| A Debian, Ubuntu or macOS host | XMRig built on the host, run as a `systemd` or `launchd` service | [Native install](docs/native-install.md) |
| Any host Docker runs on | The prebuilt image in a container, with an optional VPN sidecar | [Docker](docs/docker.md) |

The install commands below need a POSIX shell such as bash or zsh. In fish, run `bash` first, then paste them.

### On a Raspberry Pi 5 or Orange Pi 5

1. Flash the official DietPi Trixie image for your board on an SD card.
2. Copy the three files of `dietpi-first-boot.zip`, from the release page, onto the card.
3. Set `wallet` in the settings at the top of `Automation_Custom_Script.sh`.
4. Plug in Ethernet, or set `wifi_ssid`, `wifi_key` and `wifi_country` in the same settings.
5. Fit a cooler, put the card in the board and power it.

[Boards](docs/boards.md) has each step in full: where the files go on each board, every setting, and the status LED.

### On Linux or macOS

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
bash -c "${installer:?the download came back empty}" -- \
  -w YOUR_MONERO_WALLET
```

Then `make status` in the clone shows it running. [Native install](docs/native-install.md) gives every flag, the service as root and the tuning.

### With Docker

```bash
installer="$(curl -fsSL https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh)" && \
bash -c "${installer:?the download came back empty}" -- \
  --docker -w YOUR_MONERO_WALLET --autostart
```

[Docker](docs/docker.md) gives every flag, the image tags, the build from source and the VPN sidecar.

## Does it pay?

Rarely, and the hardware never does. Your coins a day are:

```text
XMR/day = H/s × 86 400 × block reward / network difficulty
```

On 2026-11-16 two cooled Raspberry Pi 5 in `eco` mined 800 H/s together: about 0.0015 XMR a month, or 0.72 EUR at 479 EUR/XMR. At 0.20 EUR/kWh you break even at about 160 H/s per watt. A Pi 5 in `eco` gives about 57 H/s per watt, an estimate until its wall power is measured. So mining pays only with free power. A board bought to mine never pays itself back.

[Does it pay?](docs/earnings.md) redoes the sum step by step, with the command for today's numbers, the power cost, MoneroOcean's payouts and the bandwidth.

## Docs

| Page | Read it when |
| --- | --- |
| [Boards](docs/boards.md) | you mine on a Raspberry Pi 5 or an RK3588 board |
| [Native install](docs/native-install.md) | you install on Debian, Ubuntu or macOS without Docker |
| [Docker](docs/docker.md) | you mine in a container, with or without the VPN sidecar |
| [Security and privacy](docs/security.md) | you want to know who sees your mining and what runs as root |
| [Does it pay?](docs/earnings.md) | you want to know what you'll earn and what the power costs |
| [Run and watch the miner](docs/operating.md) | you start, stop, check, update or remove it |
| [Upgrading](docs/upgrading.md) | you update an install made with an earlier release |
| [Troubleshooting](docs/troubleshooting.md) | the miner or its setup stops, or mines less than it should |
| [Development](docs/development.md) | you change the project or send a pull request |

The [docs index](docs/README.md) lists the same pages.

## License

MIT. See [LICENSE](./LICENSE).

Banner artwork, scripts, and templates © Yann M. Vidamment 2025, except `templates/dietpi.txt`: it is DietPi v10.8's `dietpi.txt` (© the DietPi authors, GPL-2.0, https://github.com/MichaIng/DietPi) with the settings this project needs changed. This project is not endorsed by Monero or MoneroOcean.

## Resources

- [XMRig documentation](https://xmrig.com/docs)
- [XMRig config wizard](https://xmrig.com/wizard#start)
- [Monero project](https://www.getmonero.org/)
- [MoneroOcean pool](https://moneroocean.stream/)
