# Color definitions for logging
GREEN := $(shell tput setaf 2)
BLUE := $(shell tput setaf 4)
RED := $(shell tput setaf 1)
ORANGE := $(shell tput setaf 3)
RESET := $(shell tput sgr0)

# Build directory outside the repo
BUILD_DIR := build-xmrig
CONFIG_DIR := configs

.PHONY: install-debian install-fedora install-macos install-freebsd install-linux \
		deps-debian deps-fedora deps-macos deps-freebsd deps-linux \
		build clean update

# Logging macros
define log-info
	@echo "[$(BLUE)  INFO   $(RESET)] $(BLUE)$(1)$(RESET)"
endef

define log-success
	@echo "[$(GREEN) SUCCESS $(RESET)] $(GREEN)$(1)$(RESET)"
endef

define log-warning
	@echo "[$(ORANGE) WARNING $(RESET)] $(ORANGE)$(1)$(RESET)"
endef

define log-error
	@echo "[$(RED)  ERROR  $(RESET)] $(RED)$(1)$(RESET)"
endef

test:
	$(call log-info,"Starting XMRig in the foreground...")
	@./xmrig --config $(CONFIG_DIR)/config.json || { $(call log-error,"Failed to start XMRig in the foreground"); exit 1; }

# Clean target - removes build directory
clean:
	$(call log-info,"Cleaning build artifacts...")
	@rm -rf $(BUILD_DIR) || { $(call log-error,"Failed to clean build directory"); exit 1; }
	@rm -f xmrig || { $(call log-error,"Failed to remove symbolic link"); exit 1; }
	$(call log-success,"Cleanup complete.")

# Build target - only compiles the project
build:
	$(call log-info,"Creating build directory...")
	@mkdir -p $(BUILD_DIR) || { $(call log-error,"Failed to create build directory"); exit 1; }
	
	$(call log-info,"Configuring CMake...")
	@cd $(BUILD_DIR) && cmake $(CURDIR)/dependencies/xmrig || { $(call log-error,"CMake configuration failed"); exit 1; }
	
	$(call log-info,"Building XMRig...")
	@cd $(BUILD_DIR) && make || { $(call log-error,"Build failed"); exit 1; }
	
	$(call log-info,"Creating symbolic link to the built executable...")
	@ln -sf $(BUILD_DIR)/xmrig $(CURDIR)/xmrig || { $(call log-error,"Failed to create symbolic link"); exit 1; }
	
	$(call log-success,"XMRig built successfully.")

# Update target - pulls latest repo changes, updates submodules, then cleans and rebuilds
update:
	$(call log-info,"Pulling latest changes from repository...")
	@git pull || { $(call log-error,"Failed to pull latest changes"); exit 1; }
	
	$(call log-info,"Updating git submodules...")
	@git submodule update --remote || { $(call log-error,"Failed to update submodules"); exit 1; }
	
	$(call log-info,"Cleaning old build...")
	@$(MAKE) clean
	
	$(call log-info,"Building updated version...")
	@$(MAKE) build
	
	$(call log-success,"Repository updated and rebuilt successfully.")

# Debian-specific dependencies
deps-debian:
	$(call log-info,"Updating package lists and upgrading system...")
	@sudo apt update && sudo apt upgrade -y || { $(call log-error,"Failed to update packages"); exit 1; }

	$(call log-info,"Installing required packages...")
	@sudo apt install -y \
		build-essential \
		cmake \
		libuv1-dev \
		libssl-dev \
		libhwloc-dev || { $(call log-error,"Failed to install packages"); exit 1; }

# macOS-specific dependencies
deps-macos:
	$(call log-info,"Installing dependencies for macOS...")
	
	$(call log-info,"Installing dependencies using Homebrew...")
	@if command -v brew >/dev/null 2>&1; then \
		brew install cmake libuv openssl hwloc || { $(call log-error,"Failed to install dependencies with Homebrew"); exit 1; }; \
	else \
		$(call log-warning,"Homebrew not found. Installing Homebrew..."); \
		/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || { $(call log-error,"Failed to install Homebrew"); exit 1; }; \
		brew install cmake libuv openssl hwloc || { $(call log-error,"Failed to install dependencies with Homebrew"); exit 1; }; \
	fi

# Fedora-specific dependencies
deps-fedora:
	$(call log-info,"Installing dependencies for Fedora/RHEL-based systems...")
	# @sudo dnf install -y \
	# 	gcc-c++ \
	# 	cmake \
	# 	libuv-devel \
	# 	openssl-devel \
	# 	hwloc-devel || { $(call log-error,"Failed to install packages"); exit 1; }
	${call log-warning,"Fedora dependencies are not implemented yet. Please install manually."}
	@exit 1

# FreeBSD-specific dependencies
deps-freebsd:
	$(call log-info,"Installing dependencies for FreeBSD...")
	# @pkg install -y \
	# 	cmake \
	# 	git \
	# 	hwloc2 \
	# 	libuv \
	# 	openssl || { $(call log-error,"Failed to install packages"); exit 1; }
	${call log-warning,"FreeBSD dependencies are not implemented yet. Please install manually."}
	@exit 1

# Combined targets (for backward compatibility)
install-debian: deps-debian build
	$(call log-success,"Installation complete.")

install-macos: deps-macos build
	$(call log-success,"XMRig built successfully for macOS.")

install-fedora: deps-fedora build
	$(call log-success,"Installation complete.")

install-freebsd: deps-freebsd build
	$(call log-success,"Installation complete.")
