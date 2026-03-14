# Geogram WASM — top-level Makefile
#
# Targets:
#   make             — build all modules
#   make clean       — clean all modules
#   make install-sdk — install wasi-sdk
#   make hello_world — build one module
#   make echo_lib    — build one module

WASI_SDK_PATH ?= $(HOME)/wasi-sdk

export WASI_SDK_PATH

MODULES := $(notdir $(wildcard modules/*/Makefile))
MODULE_DIRS := $(patsubst %/Makefile,%,$(wildcard modules/*/Makefile))
MODULE_NAMES := $(notdir $(MODULE_DIRS))

.PHONY: all clean install-sdk $(MODULE_NAMES)

all:
	@./build-all.sh

clean:
	@./build-all.sh clean

install-sdk:
	@./install-wasi-sdk.sh

# Build individual modules by name
$(MODULE_NAMES):
	@$(MAKE) -C modules/$@ --no-print-directory
