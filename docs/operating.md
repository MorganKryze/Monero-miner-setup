# Run and watch the miner

Read this once the miner is installed, when you want to start, stop, check, update or remove it, or find its logs.

## Make commands

For the native install, run from the repo root. Targets work on both Linux (systemd) and macOS (launchd).

| Command                | What it does                                                          |
| ---------------------- | --------------------------------------------------------------------- |
| `make help`            | Print all targets. Also the default when you just type `make`         |
| `make start`           | Start the mining service                                              |
| `make stop`            | Stop the service and kill any stray `xmrig` processes                 |
| `make restart`         | `stop` + `start`                                                      |
| `make status`          | Service state, PIDs, and the last 5 log lines (systemd: `/var/log/xmrig/<account>/xmrig.log`). On Linux, a board readout: temperature, CPU frequencies, and on a board with a profile throttling, hashrate, power and cost (`WALL_WATTS=9.5 KWH_PRICE=0.25`) |
| `make test`            | Run XMRig in the foreground. Ctrl-C to exit                           |
| `make doctor`          | Check host tuning (huge pages, MSR, AES, the board and its profile, the CPUs each native config mines on) and print recommendations |
| `make benchmark`       | 1-minute RandomX benchmark. Prints a hashrate score                   |
| `make benchmark-long`  | 10-minute RandomX benchmark. More stable for hardware comparisons     |
| `make bench-layouts`   | Bench each CPU layout of the board profile offline, one XMRig run per layout (`MODE=eco`, `BENCH=1M`). arm64 Linux only; refuses root |
| `make update`          | `git pull`, the pinned submodule commits, rebuild, `make service-setup` again |
| `make service-disable` | Stop and disable the service, remove the unit and the logrotate file; systemd removes `/etc/xmrig`, `/var/lib/xmrig/<account>` and `/var/log/xmrig/<account>`. On a board set up with `--mode`, it also gives the CPU settings back and removes `/etc/systemd/system/xmrig-host-tuning.service`, `/usr/local/sbin/xmrig-host-tuning`, `/etc/xmrig-host-tuning.conf` and the folder `/run/xmrig-host-tuning` |
| `make clean-build`     | Remove the build directory, the `xmrig` binary or link, and `xmrig.release` |
| `make clean-configs`   | Remove generated configs                                              |
| `make wipe`            | `clean-build` + `clean-configs` + `service-disable`                   |
| `make check`           | Run the regression checks in `tests/`. No build, no mining            |

Neither `make service-disable` nor `make wipe` removes the `xmrig` account. Remove it with `sudo userdel xmrig`.

## Logs

| Install | Location                                           | Rotation                                                                                              |
| ------- | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Linux   | `/var/log/xmrig/<account>/xmrig.log`               | `/etc/logrotate.d/xmrig` (daily, 7 kept, compressed, as the account) if `logrotate` is installed. The service restarts after each rotation, so expect one short pool reconnect a day |
| macOS   | `$REPO/logs/xmrig_stdout.log` + `xmrig_stderr.log` | None. Truncate them yourself if they grow                                                             |
| Docker  | Container output only: `docker compose logs -f`    | Compose rotates it at 3 files of 10 MB. `docker compose down` drops it with the container             |

## With Docker

Run these from `docker/`. Each is `docker compose` with `up -d`, `down`, `logs -f`, `restart` or `ps`.

| Command | What it does |
| --- | --- |
| `docker compose up -d` | start or recreate the stack (with the VPN, `docker compose -f compose.yml -f compose.vpn.yml up -d`) |
| `docker compose down` | stop and remove the containers, keep the config volume |
| `docker compose down -v` | also removes the config volume |
| `docker compose logs -f` | follow the miner's output |
| `docker compose restart` | restart the containers |
| `docker compose ps` | show their state |

With the VPN sidecar, put `-f compose.yml -f compose.vpn.yml` before each, as in `docker compose -f compose.yml -f compose.vpn.yml up -d`. Without it, compose recreates the miner outside the tunnel.

For a one-off benchmark from a Docker install, run from `docker/` (it builds the image if needed, no wallet required):

```bash
docker compose run --rm --entrypoint /app/xmrig xmrig --bench=1M
```
