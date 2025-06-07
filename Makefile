# Color definitions for logging
GREEN := $(shell tput setaf 2)
BLUE := $(shell tput setaf 4)
RED := $(shell tput setaf 1)
ORANGE := $(shell tput setaf 3)
RESET := $(shell tput sgr0)

# Build directory outside the repo
BUILD_DIR := build-xmrig

.PHONY: install-debian install-fedora install-macos install-freebsd \
		deps-debian deps-fedora deps-macos deps-freebsd \
		build clean-build clean-configs clean-service wipe test update \
		start stop restart status service-setup service-disable

# Logging macros
define log-info
	echo "[$(BLUE)  INFO   $(RESET)] $(BLUE)$(1)$(RESET)"
endef

define log-success
	echo "[$(GREEN) SUCCESS $(RESET)] $(GREEN)$(1)$(RESET)"
endef

define log-warning
	echo "[$(ORANGE) WARNING $(RESET)] $(ORANGE)$(1)$(RESET)"
endef

define log-error
	echo "[$(RED)  ERROR  $(RESET)] $(RED)$(1)$(RESET)"
endef

start:
	@$(call log-info,"Starting XMRig service...")
	@if [ -f /etc/systemd/system/xmrig.service ]; then \
		sudo systemctl start xmrig; \
		if [ $$? -ne 0 ]; then \
			$(call log-error,"Failed to start XMRig service"); \
			exit 1; \
		fi; \
		$(call log-success,"XMRig service started."); \
	elif [ -f $(HOME)/Library/LaunchAgents/com.moneroocean.xmrig.plist ]; then \
		launchctl start com.moneroocean.xmrig; \
		if [ $$? -ne 0 ]; then \
			$(call log-error,"Failed to start XMRig service"); \
			exit 1; \
		fi; \
		$(call log-success,"XMRig service started."); \
	elif [ -f /usr/local/etc/rc.d/xmrig ]; then \
		sudo service xmrig start; \
		if [ $$? -ne 0 ]; then \
			$(call log-error,"Failed to start XMRig service"); \
			exit 1; \
		fi; \
		$(call log-success,"XMRig service started."); \
	else \
		$(call log-error,"No service configuration found. Run 'make service-setup' first"); \
		exit 1; \
	fi

stop:
	@$(call log-info,"Stopping XMRig service...")
	@if [ -f /etc/systemd/system/xmrig.service ]; then \
		sudo systemctl stop xmrig 2>/dev/null || true; \
		$(call log-success,"XMRig service stopped."); \
	elif [ -f $(HOME)/Library/LaunchAgents/com.moneroocean.xmrig.plist ]; then \
		launchctl stop com.moneroocean.xmrig 2>/dev/null || true; \
		$(call log-success,"XMRig service stopped."); \
	elif [ -f /usr/local/etc/rc.d/xmrig ]; then \
		sudo service xmrig stop 2>/dev/null || true; \
		$(call log-success,"XMRig service stopped."); \
	elif pgrep -x xmrig >/dev/null; then \
		$(call log-info,"Found running XMRig process, stopping it..."); \
		pkill -15 xmrig 2>/dev/null || true; \
		sleep 1; \
		pkill -9 xmrig 2>/dev/null || true; \
		if pgrep -x xmrig >/dev/null; then \
			$(call log-error,"Failed to stop XMRig processes"); \
			exit 1; \
		fi; \
		$(call log-success,"XMRig processes stopped."); \
	else \
		$(call log-warning,"No XMRig service or running processes found."); \
	fi

restart: stop start
	@$(call log-success,"XMRig service restarted.")

status:
	@$(call log-info,"Checking XMRig service status...")
	@if [ -f /etc/systemd/system/xmrig.service ]; then \
		sudo systemctl status xmrig; \
	elif [ -f $(HOME)/Library/LaunchAgents/com.moneroocean.xmrig.plist ]; then \
		launchctl list | grep com.moneroocean.xmrig || echo "XMRig service is not running."; \
	elif [ -f /usr/local/etc/rc.d/xmrig ]; then \
		sudo service xmrig status; \
	elif pgrep -x xmrig >/dev/null; then \
		echo "XMRig is running with the following PIDs:"; \
		pgrep -x xmrig | tr '\n' ' '; \
		echo ""; \
		if [ "$(shell uname)" = "Darwin" ]; then \
			ps -p `pgrep -x xmrig | tr '\n' ','` -c; \
		else \
			ps -p `pgrep -x xmrig | tr '\n' ','` -o pid,%cpu,%mem,cmd; \
		fi; \
	else \
		$(call log-warning,"No XMRig service or process found."); \
	fi

service-setup:
	@$(call log-info,"Setting up XMRig service...")
	@if [ -f /etc/debian_version ]; then \
		bash ./scripts/setup_service_debian.sh; \
		if [ $$? -ne 0 ]; then \
			$(call log-error,"Failed to setup service on Debian"); \
			exit 1; \
		fi; \
	elif [ "$(shell uname)" = "Darwin" ]; then \
		bash ./scripts/setup_service_macos.sh; \
		if [ $$? -ne 0 ]; then \
			$(call log-error,"Failed to setup service on macOS"); \
			exit 1; \
		fi; \
	elif [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ]; then \
		$(call log-warning,"Service setup not implemented for Fedora/RHEL yet"); \
		exit 1; \
	elif [ "$(shell uname)" = "FreeBSD" ]; then \
		$(call log-warning,"Service setup not implemented for FreeBSD yet"); \
		exit 1; \
	else \
		$(call log-warning,"Service setup not implemented for this OS"); \
		exit 1; \
	fi
	@$(call log-success,"XMRig service setup complete. Use 'make start' to start mining.")

service-disable:
	@$(call log-info,"Disabling and removing XMRig service...")
	@if [ -f /etc/systemd/system/xmrig.service ]; then \
		sudo systemctl stop xmrig 2>/dev/null || true; \
		sudo systemctl disable xmrig 2>/dev/null || true; \
		sudo rm -f /etc/systemd/system/xmrig.service; \
		sudo systemctl daemon-reload; \
		$(call log-success,"XMRig systemd service disabled and removed."); \
	elif [ -f $(HOME)/Library/LaunchAgents/com.moneroocean.xmrig.plist ]; then \
		launchctl stop com.moneroocean.xmrig 2>/dev/null || true; \
		launchctl unload -w $(HOME)/Library/LaunchAgents/com.moneroocean.xmrig.plist 2>/dev/null || true; \
		rm -f $(HOME)/Library/LaunchAgents/com.moneroocean.xmrig.plist; \
		$(call log-success,"XMRig launchd service disabled and removed."); \
	elif [ -f /usr/local/etc/rc.d/xmrig ]; then \
		sudo service xmrig stop 2>/dev/null || true; \
		sudo rm -f /usr/local/etc/rc.d/xmrig; \
		$(call log-success,"XMRig rc.d service disabled and removed."); \
	else \
		if pgrep -x xmrig >/dev/null; then \
			pkill -15 xmrig; \
			sleep 1; \
			pkill -9 xmrig 2>/dev/null || true; \
			$(call log-success,"Running XMRig processes terminated."); \
		else \
			$(call log-info,"No XMRig service configuration or running processes found."); \
		fi; \
	fi

test:
	@$(call log-info,"Starting XMRig in the foreground...")
	@./xmrig --config config.json; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to start XMRig in the foreground"); \
		exit 1; \
	fi

# Clean target - removes build directory
clean-build:
	@$(call log-info,"Cleaning build artifacts...")
	@rm -rf $(BUILD_DIR); \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to clean build directory"); \
		exit 1; \
	fi
	@rm -f xmrig; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to remove symbolic link"); \
		exit 1; \
	fi
	@$(call log-success,"Cleanup complete.")

clean-configs:
	@$(call log-info,"Cleaning configuration files...")
	@rm -f config.json; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to remove config.json"); \
		exit 1; \
	fi
	@rm -f config_background.json; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to remove config_background.json"); \
		exit 1; \
	fi
	@rm -rf configs/; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to remove configs/ directory."); \
		exit 1; \
	fi
	@$(call log-success,"Configuration cleanup complete.")

wipe: clean-build clean-configs service-disable
	@$(call log-success,"All build artifacts, configurations, and services have been cleaned.")

# Build target - only compiles the project
build:
	@$(call log-info,"Creating build directory...")
	@mkdir -p $(BUILD_DIR); \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to create build directory"); \
		exit 1; \
	fi
	
	@$(call log-info,"Configuring CMake...")
	@cd $(BUILD_DIR) && cmake $(CURDIR)/dependencies/xmrig; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"CMake configuration failed"); \
		exit 1; \
	fi
	
	@$(call log-info,"Building XMRig...")
	@cd $(BUILD_DIR) && make; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Build failed"); \
		exit 1; \
	fi
	
	@$(call log-info,"Creating symbolic link to the built executable...")
	@ln -sf $(BUILD_DIR)/xmrig $(CURDIR)/xmrig; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to create symbolic link"); \
		exit 1; \
	fi
	
	@$(call log-success,"XMRig built successfully.")

# Update target - pulls latest repo changes, updates submodules, then cleans and rebuilds
update:
	@$(call log-info,"Pulling latest changes from repository...")
	@git pull; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to pull latest changes"); \
		exit 1; \
	fi
	
	@$(call log-info,"Updating git submodules...")
	@git submodule update --remote; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to update submodules"); \
		exit 1; \
	fi
	
	@$(call log-info,"Cleaning old build...")
	@$(MAKE) clean-build clean-service
	
	@$(call log-info,"Building updated version...")
	@$(MAKE) build
	
	@$(call log-success,"Repository updated and rebuilt successfully.")

# Debian-specific dependencies
deps-debian:
	@$(call log-info,"Updating package lists and upgrading system...")
	@sudo apt update && sudo apt upgrade -y; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to update packages"); \
		exit 1; \
	fi

	@$(call log-info,"Installing required packages...")
	@sudo apt install -y \
		build-essential \
		cmake \
		libuv1-dev \
		libssl-dev \
		libhwloc-dev; \
	if [ $$? -ne 0 ]; then \
		$(call log-error,"Failed to install packages"); \
		exit 1; \
	fi

# macOS-specific dependencies
deps-macos:
	@$(call log-info,"Installing dependencies for macOS...")
	
	@$(call log-info,"Installing dependencies using Homebrew...")
	@if command -v brew >/dev/null 2>&1; then \
		brew install cmake libuv openssl hwloc; \
		if [ $$? -ne 0 ]; then \
			$(call log-error,"Failed to install dependencies with Homebrew"); \
			exit 1; \
		fi; \
	else \
		$(call log-warning,"Homebrew not found. Installing Homebrew..."); \
		/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; \
		if [ $$? -ne 0 ]; then \
			$(call log-error,"Failed to install Homebrew"); \
			exit 1; \
		fi; \
		brew install cmake libuv openssl hwloc; \
		if [ $$? -ne 0 ]; then \
			$(call log-error,"Failed to install dependencies with Homebrew"); \
			exit 1; \
		fi; \
	fi

# Fedora-specific dependencies
deps-fedora:
	@$(call log-info,"Installing dependencies for Fedora/RHEL-based systems...")
	# @sudo dnf install -y \
	# 	gcc-c++ \
	# 	cmake \
	# 	libuv-devel \
	# 	openssl-devel \
	# 	hwloc-devel || { $(call log-error,"Failed to install packages"); exit 1; }
	@$(call log-warning,"Fedora dependencies are not implemented yet. Please install manually.")
	@exit 1

# FreeBSD-specific dependencies
deps-freebsd:
	@$(call log-info,"Installing dependencies for FreeBSD...")
	# @pkg install -y \
	# 	cmake \
	# 	git \
	# 	hwloc2 \
	# 	libuv \
	# 	openssl || { $(call log-error,"Failed to install packages"); exit 1; }
	@$(call log-warning,"FreeBSD dependencies are not implemented yet. Please install manually.")
	@exit 1

# Combined targets (for backward compatibility)
install-debian: deps-debian build
	@$(call log-success,"Installation complete.")

install-macos: deps-macos build
	@$(call log-success,"XMRig built successfully for macOS.")

install-fedora: deps-fedora build
	@$(call log-success,"Installation complete.")

install-freebsd: deps-freebsd build
	@$(call log-success,"Installation complete.")