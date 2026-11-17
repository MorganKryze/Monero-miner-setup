# Upgrading

Read this when you update an install made with an earlier release: it lists the steps that are yours.

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
