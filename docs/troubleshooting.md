# Troubleshooting

Read this when the miner or its setup stops, or mines less than it should: each entry starts with the symptom or the exact error line you see.

**Service won't start.** Run `make status`. It prints the tail of the error log. Common causes: wallet rejected by the validator (wrong length, wrong leading char, non-base58 character), missing executable bit on `./xmrig`, or XMRig exiting on a missing CPU feature.

**Hashrate lower than expected.** Run `make doctor` and apply its recommendations. The `msr` kernel module helps only a service installed with `--service-as-root` on x86: 5–15% on Ryzen and EPYC.

**Service keeps coming back after `make stop`.** Use `make service-disable`. `systemd` and `launchd` re-spawn stopped units; `stop` alone won't keep them down.

**Docker container reports unhealthy.** The healthcheck reports unhealthy only when the miner process is gone, or when it holds its pool connection, isn't paused, and used no CPU time since the last check. `start_period` is 60 s. Under 2560 MiB the miner runs in light mode instead of being OOM-killed: give it `--memory 3g`.

**Build fails on macOS.** `make deps-macos` installs `cmake`, `libuv`, `openssl`, `hwloc` with Homebrew, and stops with Homebrew's install command when `brew` isn't on your `PATH`.

**`The account <account> cannot run <clone>/xmrig; move the clone where it can, such as /opt.`** The miner's account can't reach the clone. Installed as root in `/root`? Follow the `/root` step of [Upgrading](upgrading.md#upgrading-an-install-made-before-010). Otherwise run `make service-disable` in that clone, then the installer again with `-d /opt` and your wallet and flags: a moved clone keeps its config links to the old path.

**`<path> can be changed by a user other than you, so this run does not use <clone>.`** (or `belongs to another user`, `is not a git clone`) Someone else could have changed that clone, so the native installer won't build or run it. Don't fix its modes and reuse it: files may already have been changed. Move it away and run the installer again with your wallet and flags, or pass `-d` with another base directory. Right after a fresh clone, the cause is your umask: remove the clone, run `umask 022`, then the installer again.

**`<clone> is already there or cannot be made, so this run does not clone into it.`** Something turned up at the clone's path after the installer checked it, and whoever made it could change what git puts there. Move it away and run the installer again, or pass `-d` with another base directory.

**`<clone> is a link, so this run does not use it.`** The installer won't act through a link at the clone's path. Pass `-d` with the folder that holds the one the link points to (the error line names it), so the installer finds the clone there. A link to nothing: move it away and run the installer again.

**`<directory> can be changed by a user other than you, so this run does not use <clone>.`** followed by `Pass -d with a directory only you can change.` Another user could swap the clone inside that directory between the check and the build. A sticky directory such as `/tmp` is fine. Pass `-d` with a directory that only you (or root) can change.

**Mining stopped and the log says `Failed to verify server certificate fingerprint`.** The pool's certificate isn't the pinned one. The miner logs that line with the pool URL, then the fingerprint it was given and the one configured, in `make status` and `/var/log/xmrig/<account>/xmrig.log` (macOS: `logs/xmrig_stdout.log` in the clone) or, for Docker, `docker compose logs xmrig` from `docker/`. It gets no new jobs and MoneroOcean's panel shows the worker offline, but the Docker healthcheck stays healthy: the process is alive and reconnecting. Either MoneroOcean changed its certificate, or someone on the network path is answering in its place. Never pin the fingerprint the miner reports as given: that's the one a man in the middle would show you. Pick one fix:

- Update to a release that carries the new pin. Native: `make update`, then `make clean-configs`, the installer again with your wallet and flags, `make service-setup` and `make restart`. Docker, from `docker/`: `docker compose pull` and `docker compose up -d`, or with the VPN `docker compose -f compose.yml -f compose.vpn.yml pull` and `docker compose -f compose.yml -f compose.vpn.yml up -d`.
- Pin a fingerprint you checked yourself from a second network (a phone hotspot, say): `openssl s_client -connect gulf.moneroocean.stream:20128 -servername gulf.moneroocean.stream </dev/null | openssl x509 -noout -fingerprint -sha256`. It prints `sha256 Fingerprint=` (`SHA256 Fingerprint=` with LibreSSL) and 32 colon-separated pairs: keep only the part after the `=`, that's the value. Native: `make clean-configs`, the installer again with `--tls-fingerprint <that value>` and your flags, then `make service-setup` and `make restart`. Docker: set `TLS_FINGERPRINT=<that value>` in `docker/.env`, then `docker compose up -d` from `docker/` (`docker compose -f compose.yml -f compose.vpn.yml up -d` if you use the VPN).
- Mine without TLS, if you accept that anyone on the path can read and change the pool's traffic: the same steps with `--pool stratum+tcp://gulf.moneroocean.stream` (Docker: `POOL_URL=stratum+tcp://gulf.moneroocean.stream`).

## A DietPi card at first boot

These are the stops of a card set up from `dietpi-first-boot.zip`. [Boards](boards.md#set-up-a-card-that-mines-on-first-boot) has the whole card path.

**The status LED stays steady on.** The setup stopped. `journalctl -u xmrig-first-boot.service` has the line that says why, and that line ends with its remedy. For a bad setting, the remedy reads: Flash the card again, copy the files from `dietpi-first-boot.zip` onto it, then fix it in the settings at the top of `Automation_Custom_Script.sh`; or edit `/var/lib/xmrig-first-boot/settings` as root on the board and reboot.

**`Wi-Fi was asked for (wifi_ssid) but the Wi-Fi step never set it up: flash the card again, then copy all three files of dietpi-first-boot.zip onto it, Automation_Custom_PreScript.sh included; /var/lib/dietpi/logs/dietpi-firstboot.log has the step's own line.`** The settings ask for Wi-Fi, but `Automation_Custom_PreScript.sh` never set it up, for example because it wasn't on the card. The setup stops before it installs the miner. Copying the files onto the used card isn't enough: DietPi has already run its first boot.

1. Flash the DietPi image on the card again.
2. Copy all three files of `dietpi-first-boot.zip` onto it, `Automation_Custom_PreScript.sh` included.
3. Set your settings again, then power the board.

**The board never joins the Wi-Fi.** A wrong name or key with no cable leaves DietPi's first run unfinished. The setup never runs and the LED stays the board's own.

1. Flash the card again.
2. Copy the three files of `dietpi-first-boot.zip` onto it.
3. Fix `wifi_ssid`, `wifi_key` and `wifi_country` in the settings at the top of `Automation_Custom_Script.sh`, then power the board.

A router whose key changed leaves a board that was set up off the network. Flash it again with the new key, or set it with `dietpi-config` from a screen or the cable.
