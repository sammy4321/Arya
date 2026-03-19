SHELL := /bin/bash

.PHONY: help install run clean doctor

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
DEFAULT_DESKTOP_DEVICE := macos
else ifeq ($(UNAME_S),Linux)
DEFAULT_DESKTOP_DEVICE := linux
else
DEFAULT_DESKTOP_DEVICE := windows
endif

RUN_DEVICE ?= $(DEFAULT_DESKTOP_DEVICE)

help:
	@echo "Available targets:"
	@echo "  make install  - Install Flutter frontend dependencies"
	@echo "  make run      - Run Arya desktop app"
	@echo "  make clean    - Clean build artifacts"
	@echo "  make doctor   - Environment checks"
	@echo ""
	@echo "Optional overrides:"
	@echo "  RUN_DEVICE=<id>  - Flutter device id (default: $(RUN_DEVICE))"

install:
	@$(MAKE) -C frontend install

run:
	@$(MAKE) -C frontend run RUN_DEVICE=$(RUN_DEVICE)

clean:
	@$(MAKE) -C frontend clean

doctor:
	@$(MAKE) -C frontend doctor
