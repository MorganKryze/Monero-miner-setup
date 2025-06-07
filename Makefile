# Color definitions for logging
GREEN := $(shell tput setaf 2)
BLUE := $(shell tput setaf 4)
RED := $(shell tput setaf 1)
ORANGE := $(shell tput setaf 3)
RESET := $(shell tput sgr0)

# Build directory outside the repo
BUILD_DIR := build-xmrig

.PHONY: install-debian install-fedora install-macos install-freebsd install-linux

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

install-debian:
	$(call log-info,"Updating package lists and upgrading system...")
	@sudo apt update && sudo apt upgrade -y || { $(call log-error,"Failed to update packages"); exit 1; }

	$(call log-info,"Installing required packages...")
	@sudo apt install -y \
		build-essential \
		cmake \
		libuv1-dev \
		libssl-dev \
		libhwloc-dev || { $(call log-error,"Failed to install packages"); exit 1; }

	$(call log-info,"Creating build directory outside the repository...")
	@mkdir -p $(BUILD_DIR) || { $(call log-error,"Failed to create build directory"); exit 1; }

	$(call log-info,"Running CMake configuration from external build directory...")
	@cd $(BUILD_DIR) && cmake $(CURDIR)/dependencies/xmrig || { $(call log-error,"CMake configuration failed"); exit 1; }

	$(call log-info,"Building the project...")
	@cd $(BUILD_DIR) && make || { $(call log-error,"Build failed"); exit 1; }

	$(call log-info,"Creating symbolic link to the built executable...")
	@ln -sf $(BUILD_DIR)/xmrig $(CURDIR)/xmrig || { $(call log-error,"Failed to create symbolic link"); exit 1; }

	$(call log-success,"Installation complete.")

install-macos:
	$(call log-info,"Installing on macOS...")
	
	$(call log-info,"Installing dependencies using Homebrew...")
	@if command -v brew >/dev/null 2>&1; then \
		brew install cmake libuv openssl hwloc || { $(call log-error,"Failed to install dependencies with Homebrew"); exit 1; }; \
	else \
		$(call log-warning,"Homebrew not found. Installing Homebrew..."); \
		/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || { $(call log-error,"Failed to install Homebrew"); exit 1; }; \
		brew install cmake libuv openssl hwloc || { $(call log-error,"Failed to install dependencies with Homebrew"); exit 1; }; \
	fi
	
	$(call log-info,"Creating build directory outside the repository...")
	@mkdir -p $(BUILD_DIR) || { $(call log-error,"Failed to create build directory"); exit 1; }
	
	$(call log-info,"Configuring CMake for macOS...")
	@cd $(BUILD_DIR) && cmake $(CURDIR)/dependencies/xmrig \
		-DOPENSSL_ROOT_DIR=$(shell brew --prefix openssl) \
		-DOPENSSL_LIBRARIES=$(shell brew --prefix openssl)/lib \
		|| { $(call log-error,"CMake configuration failed"); exit 1; }
	
	$(call log-info,"Building XMRig...")
	@cd $(BUILD_DIR) && make || { $(call log-error,"Build failed"); exit 1; }
	
	$(call log-info,"Creating symbolic link to the built executable...")
	@ln -sf $(BUILD_DIR)/xmrig $(CURDIR)/xmrig || { $(call log-error,"Failed to create symbolic link"); exit 1; }
	
	$(call log-success,"XMRig built successfully for macOS.")

install-fedora:
	$(call log-info,"Installing on Fedora/RHEL-based system...")
	$(call log-warning,"This target is not yet implemented.")
	$(call log-success,"Installation complete.")

install-freebsd:
	$(call log-info,"Installing on FreeBSD...")
	$(call log-warning,"This target is not yet implemented.")
	$(call log-success,"Installation complete.")

install-linux:
	$(call log-info,"Installing on generic Linux...")
	$(call log-warning,"This target is not yet implemented.")
	$(call log-success,"Installation complete.")