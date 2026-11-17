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

Moved to [Upgrading from 0.1.x or 0.2.0-rc.x](docs/upgrading.md#upgrading-from-01x-or-020-rcx).

## Upgrading an install made before 0.1.0

Moved to [Upgrading an install made before 0.1.0](docs/upgrading.md#upgrading-an-install-made-before-010).

## Tuning for performance

Moved to [Make it faster](docs/native-install.md#make-it-faster).

## Configuration

Moved to the native install's [Configuration](docs/native-install.md#configuration) and the Docker page's [Configuration](docs/docker.md#configuration).

## Logs

Moved to [Logs](docs/operating.md#logs).

## Security

Moved to [Security and privacy](docs/security.md).

## Troubleshooting

Moved to [Troubleshooting](docs/troubleshooting.md).

## Development

Moved to [Development](docs/development.md).

## License

MIT. See [LICENSE](./LICENSE).

Banner artwork, scripts, and templates © Yann M. Vidamment 2025, except `templates/dietpi.txt`: it is DietPi v10.8's `dietpi.txt` (© the DietPi authors, GPL-2.0, https://github.com/MichaIng/DietPi) with the settings this project needs changed. This project is not endorsed by Monero or MoneroOcean.

## Resources

- [XMRig documentation](https://xmrig.com/docs)
- [XMRig config wizard](https://xmrig.com/wizard#start)
- [Monero project](https://www.getmonero.org/)
- [MoneroOcean pool](https://moneroocean.stream/)
