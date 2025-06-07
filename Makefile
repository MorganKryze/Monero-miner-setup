# Color definitions for logging
GREEN := $(shell tput setaf 2)
BLUE := $(shell tput setaf 4)
RED := $(shell tput setaf 1)
ORANGE := $(shell tput setaf 3)
RESET := $(shell tput sgr0)

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

	$(call log-info,"Creating build directory and entering it...")
	@mkdir -p build && cd build || { $(call log-error,"Failed to create build directory"); exit 1; }

	$(call log-info,"Running CMake configuration...")
	@cd build && cmake .. || { $(call log-error,"CMake configuration failed"); exit 1; }

	$(call log-info,"Building the project...")
	@cd build && make || { $(call log-error,"Build failed"); exit 1; }

	$(call log-success,"Installation complete.")

install-fedora:
	$(call log-info,"Installing on Fedora/RHEL-based system...")
	$(call log-warning,"This target is not yet implemented.")
	$(call log-success,"Installation complete.")

install-linux:
	$(call log-info,"Installing on generic Linux...")
	$(call log-warning,"This target is not yet implemented.")
	$(call log-success,"Installation complete.")

install-macos:
	$(call log-info,"Installing on macOS...")
	$(call log-warning,"This target is not yet implemented.")
	$(call log-success,"Installation complete.")

install-freebsd:
	$(call log-info,"Installing on FreeBSD...")
	$(call log-warning,"This target is not yet implemented.")
	$(call log-success,"Installation complete.")
