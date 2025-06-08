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

## 📋 Features

- Easy installation across multiple platforms (macOS, Debian/Ubuntu)
- Automatic system-specific configuration
- Systemd/launchd service management for background operation
- CPU thread management and power optimization
- Configurable mining pools
- Low maintenance configuration

## 🔧 Requirements

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

### Quick Installation (recommended)

```bash
bash <(curl -s https://raw.githubusercontent.com/MorganKryze/Monero-miner-setup/main/scripts/install.sh) -w YOUR_MONERO_WALLET_ADDRESS
```

Replace `YOUR_MONERO_WALLET_ADDRESS` with your actual Monero wallet address.

### Advanced Installation Options

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

### Manual Installation

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

Once installed, you can manage the mining service using the following commands:

### Starting and Stopping

```bash

# Start the mining service

make start

# Stop the mining service

make stop

# Restart the mining service

make restart

# Check the status

make status
```

### Testing and Configuration

```bash

# Run XMRig in the foreground (for testing)

make test

# Disable and remove the mining service

make service-disable

# Clean build files

make clean-build

# Clean configuration files

make clean-configs

# Complete wipe (build, configs, and service)

make wipe

# Update XMRig to the latest version

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
