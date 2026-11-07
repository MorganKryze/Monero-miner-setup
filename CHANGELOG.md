# Changelog

Every release of Monero-miner-setup, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-07

The first tagged release. Installed before it? Read
[Upgrading an install made before 0.1.0](README.md#upgrading-an-install-made-before-010) first:
some steps are yours to run.

### Added

- Release images on GHCR: a `v0.1.0` tag publishes `:0.1.0` and `:0.1`, so you can pin a version instead of following `:latest`.
- `--overwrite-env` for the Docker installer. Without it, a re-run keeps `docker/.env` and `docker/.env.vpn` as they are and says so.
- `--service-as-root` for the native installer on Linux, for the x86 RandomX MSR boost, which needs root. The macOS service refuses it.
- The Docker miner starts in RandomX light mode, with a warning, when it can use less than 2560 MiB; it used to be OOM-killed in a restart loop.
- `make check` runs the regression checks in `tests/`: no network, nothing built or mined. CI runs them too.

### Changed

- The native service runs the miner as its own account: you, when you install as yourself or with sudo, otherwise a system account `xmrig` with no login. systemd creates and removes its directories: `/etc/xmrig`, `/var/lib/xmrig/<account>`, `/var/log/xmrig/<account>`. The account owns nothing in the clone.
- As root on Linux with no `-d`, the native install goes to `/opt/Monero-miner-setup`, which the account can enter. A clone an earlier install left in root's home keeps being used, and the service setup stops there: run `make service-disable`, then install again with `-d /opt`.
- The native service runs XMRig in the foreground, so systemd and launchd supervise it. The setup turns background mode off in the service config and reports miners an earlier background start left running, with the command to stop them. It stops none of them.
- Native service logs go to `/var/log/xmrig/<account>/xmrig.log`, rotated daily as the account; the service restarts after each rotation (one short pool reconnect a day).
- `install.sh` and `make update` build the XMRig commit this repository pins, never XMRig's upstream master. The native build runs one job per CPU, at most one per GiB of available memory.
- Docker defaults are the same in the installer, its `--help`, `compose.yml` and `.env.example`: threads 75 % of the container's CPU quota, no forced thread count, memory 3g, worker name `docker_miner`.
- `--threads` on Docker is a percentage of the CPUs the container may use, capped at the count XMRig picks itself. To read that count, each container start runs XMRig's offline benchmark for under a second (five at most), in light mode, connected to nothing.
- The Docker miner logs only to the container's output, which Compose rotates at 3 × 10 MB. Its config lives in the named volume `xmrig-configs` instead of `docker/docker-configs`.
- The container healthcheck reads the miner process and its CPU time. A miner its pause flags let pause, or one still waiting for its pool, stays healthy.
- The image is built on Ubuntu 26.04 and loads libuv from the system package. Gluetun is pinned to `v3.41.3`.
- `make deps-debian` installs the build packages and nothing else: no system upgrade. `make deps-macos` stops with Homebrew's install command when `brew` is missing, instead of installing Homebrew for you.
- `make service-disable` also removes the logrotate config and the service's directories, and works on a failed unit or one from an older release.
- A re-run of the native installer after a failed build finishes the setup and keeps the configs you already have.
- `:latest` moves on every push to `main`, after each Dependabot merge and on a version tag; a manual publish never moves it.

### Removed

- `FIREWALL=on` from `docker/.env.vpn` and its example: Gluetun never read that key. Its killswitch is on by default, and nothing the project writes turns it off.
- The FreeBSD branches of the Makefile.

### Fixed

- `--threads` on Docker changed nothing: a forced count of 2 always won.
- A pool URL starting with `stratum+ssl://` got the plain-TCP MoneroOcean port. A TLS URL is now kept as given, so pass its port.
- On Linux, a default Docker install could not write its config, owned by root once dockerd created the folder.
- CI had been red since #11 while Dependabot kept merging, and its merges never rebuilt `:latest`. CI is green again and required for merges.

### Security

- The native installer loads bash-toolbox from its own clone's submodule, when only you can write to that clone, or from the commit it pins, with `curl -fsSL`; a failed or empty fetch stops the install. It never loads the toolbox from the current directory.
- As root on Linux, the native installer refuses a base directory, a clone or a directory above them that a user other than root or the one who ran sudo can change, and the service setup refuses to run, as another account, a binary anyone but root can change.
- The Docker installer uses only the clone it runs from or the `Monero-miner-setup` clone in its base directory, cloned there when missing, and only a git clone owned by you or root (as root, also by the user who ran `sudo`) that no other user can write to, nor to its `docker/` folder. It no longer adopts a folder above the current directory because it holds the project's Docker files: it stops with an error line instead.
- Wallet, worker name, pool and every number and flag are checked on both install paths, and every value that reaches the miner's config is written as a value, never as code: a crafted `--pool` or `--name` can no longer make sed run a command.
- `docker/.env` and `docker/.env.vpn` are created mode 600 before their first byte; a kept file with a looser mode gets a warning. No `docker/.env*` file reaches the image's build context.
- The image's miner and scripts belong to root, so the account that runs them cannot replace them.
- Dependabot auto-merges only GitHub Actions patch and minor bumps, once CI is green. XMRig, bash-toolbox, base image and Gluetun bumps wait for review.
- The README's install commands use `curl -fsSL` and stop with an error when the download fails or comes back empty.

[0.1.0]: https://github.com/MorganKryze/Monero-miner-setup/releases/tag/v0.1.0
