# Monero-miner-setup

![Monero Miner Setup Banner](https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/assets/banner.png)

A simplified, cross-platform setup solution for Monero mining with XMRig. This project aims to make cryptocurrency mining accessible by providing straightforward installation and service management.

## ⚠️ Disclaimer

This project is neither endorsed by Monero nor the MoneroOcean team. Cryptocurrency mining:

- May void your cloud provider's terms of service
- Consumes significant electrical power and system resources
- May cause hardware wear
- May reduce system performance for other tasks
- Could potentially trigger security software alerts

**Use at your own risk. The developers are not responsible for any damages, costs, or consequences.**

## 🔒 Security Verification

Cryptocurrency mining software is often flagged by antivirus programs due to its nature, even when legitimate. For your peace of mind, we've provided VirusTotal scan links for the main scripts in this repository:

### VirusTotal Scan Results

| File                    | VirusTotal Scan Link                                                                                                          |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| install.sh              | [Scan Results](https://www.virustotal.com/gui/url/39d67119bd9c0dcb96d6594167b654e40141f522b8305112bbc532678c145a07/detection) |
| Makefile                | [Scan Results](https://www.virustotal.com/gui/url/77e9022659f5b43b8d75c5c83f4a8f63c99e945c9c04ea478433e0219bdcd66e/detection) |
| setup_service_debian.sh | [Scan Results](https://www.virustotal.com/gui/url/a734f2bf7ae11cce6db7dd8e7712be3600ce318d83cc3c4bf39fb204d37dbc4f/detection) |
| setup_service_macos.sh  | [Scan Results](https://www.virustotal.com/gui/url/484e20f6475c96f001e4e7c87a3e826a28f8f88d4f75a6e7a6b5b14054869280/detection) |

### Verify Scripts Yourself

For maximum security, we recommend:

1. **Inspecting scripts before running them:**

```bash
curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh | less
```

2. **Downloading the repository and reviewing code before installation:**

```bash
git clone https://github.com/MorganKryze/Monero-miner-setup.git
cd Monero-miner-setup
# Review code, then run installation manually
```

This project is open source, so you can verify exactly what code will be executed on your system.

## 📋 Features

- Easy installation across multiple platforms (macOS, Debian/Ubuntu)
- Automatic system-specific configuration
- Systemd/launchd service management for background operation
- CPU thread management and power optimization
- Configurable mining pools
- Low maintenance configuration

## 🔧 Requirements

### Docker Installation

- **Docker**: Docker Engine 20.10+ and Docker Compose 2.0+
- **Operating Systems**: Any system that supports Docker (Linux, macOS, Windows)
- **Hardware**: Any x86/x64/ARM64/ARMv7/ARMv8 compatible CPU
- **Resources**: Minimum 1GB RAM, 500MB disk space

### Native Installation

- **Operating Systems**:

  - macOS 10.13+ (fully supported)
  - Debian/Ubuntu (fully supported)
  - Other Linux distributions (partially supported)
  - FreeBSD (partially supported)

- **Hardware**: Any x86/x64/ARM64/ARMv7/ARMv8 compatible CPU
- **Software Dependencies**:
  - git
  - curl
  - make
  - For specific dependencies, see platform sections below

## ⬇️ Installation

### Docker Installation (recommended)

The easiest way to get started is using Docker, which provides a clean, isolated environment with all dependencies included.

#### Prerequisites

- Docker and Docker Compose installed on your system
- Your Monero wallet address

#### Quick Docker Setup

1. **Clone the repository:**

   ```bash
   git clone https://github.com/MorganKryze/Monero-miner-setup.git
   cd Monero-miner-setup
   ```

2. **Create your environment configuration:**

```bash
cp docker/.env.example docker/.env
```

3. **Edit the configuration file:**

```bash
# Edit docker/.env with your wallet address and preferences
nano docker/.env
```

4. **Start mining:**

```bash
cd docker
docker-compose up -d
```

5. **Monitor your miner:**

```bash
docker-compose logs -f
```

#### Docker Environment Configuration

Edit `docker/.env` with your settings:

```plaintext
# Required: Your Monero wallet address

WALLET_ADDRESS=your_wallet_address_here

# Optional: CPU and resource limits

CPU_COUNT=2
CPU_PERCENT=75
MAX_THREADS_PERCENT=75
MEMORY_LIMIT=1g

# Optional: Mining pool and worker settings

POOL_URL=gulf.moneroocean.stream
WORKER_NAME=my_docker_miner
DONATE_LEVEL=0

# Optional: Mining behavior

PAUSE_ON_BATTERY=false
PAUSE_ON_ACTIVE=false
```

#### Docker Management Commands

```bash
# Start the miner
docker-compose up -d
# Stop the miner
docker-compose down
# View logs
docker-compose logs -f
# Check status
docker-compose ps
# Restart the miner
docker-compose restart
# Update and rebuild
docker-compose down
docker-compose build --no-cache
docker-compose up -d
```

### Native Installation (Advanced)

For users who prefer native installation or need custom system integration:

#### Quick Installation

```bash
bash <(curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh) -w YOUR_MONERO_WALLET_ADDRESS
```

Replace `YOUR_MONERO_WALLET_ADDRESS` with your actual Monero wallet address.

#### Advanced Installation Options

```bash
bash <(curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh) \
 -w YOUR_MONERO_WALLET_ADDRESS \
 -t 75 \
 -p gulf.moneroocean.stream:10128 \
 --name my_mining_rig \
 --pause-battery \
 --pause-active
```

#### Available parameters

- `-w, --wallet WALLET` - Your Monero wallet address **(required)**
- `-d, --dir DIR` - Base directory for installation (defaults to HOME)
- `-t, --threads PERCENT` - Max CPU threads hint (1-100, default: 75)
- `--donate PERCENT` - Donation level (0-5, default: 0)
- `-p, --pool URL` - Mining pool URL (default: gulf.moneroocean.stream)
- `--name STRING` - Display name for the mining worker
- `--pause-active` - Pause mining when computer is in active use
- `--pause-battery` - Pause mining when computer is on battery
- `--only-manual` - Do not set up any service, only manual operation
- `--autostart` - Start mining service immediately after installation

#### Manual Installation

1. Clone the repository:

```bash
git clone https://github.com/MorganKryze/Monero-miner-setup.git
cd Monero-miner-setup
```

2. Install dependencies (platform-specific):

**macOS**:

```bash
make deps-macos
```

**Debian/Ubuntu**:

```bash
make deps-debian
```

3. Build XMRig:

```bash
make build
```

4. Create configuration:

Edit `templates/config.json.template` with your wallet address and mining preferences.

5. Set up as a service:

```bash
make service-setup
```

## 🚀 Usage

### Docker Usage

If you installed using Docker, use these commands:

```bash

# Start mining

cd docker && docker-compose up -d

# Stop mining

docker-compose down

# Check status and logs

docker-compose logs -f

# Update configuration

# Edit docker/.env, then restart:

docker-compose restart
```

### Native Installation Usage

If you used native installation, manage the mining service using these commands:

#### Service Management Commands

Start the mining service

```bash
make start
```

Stop the mining service

```bash
make stop
```

Restart the mining service

```bash
make restart
```

Check the service status

```bash
make status
```

#### Testing and Maintenance Commands

Run XMRig in the foreground (for testing)

```bash
make test
```

Disable and remove the mining service

```bash
make service-disable
```

Clean build files

```bash
make clean-build
```

Clean configuration files

```bash
make clean-configs
```

Complete wipe (build, configs, and service)

```bash
make wipe
```

Update XMRig and the repository (keeps your config)

```bash
make update
```

## ⚙️ Configuration

The miner configuration is stored in two main files:

- `config.json` - Used for foreground testing
- `config_background.json` - Used by the service for background mining

### Key Configuration Options

- **CPU Threads**: Control how many CPU cores/threads to use (max-threads-hint)
- **Donation Level**: Set donation percentage to XMRig developers
- **Mining Pool**: Configure which pool to mine with
- **Worker Name**: Set custom name for your mining rig
- **Pause Settings**: Configure when mining should pause

To adjust these settings after installation, edit the files in the `configs/` directory.

## 🔄 Service Management

### Status Checking

The `make status` command shows:

- If the service is running
- Process IDs and resource usage
- Last lines of log files

### Service Persistence

The miner is configured as a system service:

- On macOS: Uses launchd
- On Linux: Uses systemd
- Service automatically starts after system reboots
- Service can recover from crashes

### Disabling the Service

To completely remove the service:

```bash
make service-disable
```

## ⚠️ Limitations & Considerations

### Resource Usage

- Mining uses significant CPU resources by default (75% of cores)
- May cause system slowdowns during intensive operations
- Consider reducing thread usage (`-t` parameter) for better system responsiveness
- Monitor system temperatures to prevent overheating

### Platform Support

- macOS: Full support (tested on 14.7+)
- Debian/Ubuntu: Full support
- Other Linux: Limited support, may require manual steps
- FreeBSD: Limited support, requires manual configuration
- Windows: Not supported natively (use WSL)

### Security Considerations

- Some antivirus software may flag mining tools
- Running with minimum privileges is recommended
- Verify downloaded scripts before execution
- Do not run as root unless necessary

### Mining Performance

- Performance varies greatly by hardware
- Older CPUs may have poor mining efficiency
- Consider power costs versus potential earnings
- MoneroOcean pool auto-switches to most profitable algorithm

## 🔍 Troubleshooting

### Common Issues

1. **Service won't start**:

   - Check logs with `make status`
   - Ensure wallet address is valid
   - Verify permissions on executable: `chmod +x xmrig`

2. **Low hashrate**:

   - Enable MSR modifications if supported
   - Use huge pages if available
   - Adjust thread count to match your CPU

3. **Service restarts after stopping**:

   - Use `make service-disable` instead of just `make stop`
   - On macOS, unload the service: `launchctl unload -w ~/Library/LaunchAgents/com.moneroocean.xmrig.plist`

4. **Build failures**:
   - Install missing dependencies
   - Ensure your system meets minimum requirements
   - Try manual build steps from XMRig documentation

### Default Log Locations

- macOS: `/Users/your_user/Monero-miner-setup/main/logs/`
- Linux: `/home/your_user/Monero-miner-setup/main/logs/`

## 📄 License

This project is licensed under the MIT License. See the [LICENSE](./LICENSE) file for details.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a pull request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📚 Resources

- [XMRig Official Documentation](https://xmrig.com/docs)
- [XMRig configuration wizard](https://xmrig.com/wizard#start)
- [Monero Project Website](https://www.getmonero.org/)
- [MoneroOcean Pool](https://moneroocean.stream/)

---

**Project by Yann M. Vidamment © 2025**
_Neither endorsed by Monero nor MoneroOcean team_
