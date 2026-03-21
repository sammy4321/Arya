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
	@echo "  make install  - Verify Flutter is installed and fetch dependencies"
	@echo "  make run      - Run on desktop (override with RUN_DEVICE=<id>)"
	@echo "  make clean    - Remove project build artifacts and dependency caches"
	@echo "  make doctor   - Run flutter doctor for environment diagnostics"

check-flutter:
	@command -v flutter >/dev/null 2>&1 || ( \
		echo "Error: Flutter is not installed or not on PATH."; \
		echo ""; \
		echo "Install Flutter (stable): https://docs.flutter.dev/get-started/install"; \
		echo "Then add Flutter to PATH, for example:"; \
		echo "  export PATH=\"\$$PATH:<path-to-flutter>/bin\""; \
		echo ""; \
		echo "After install, run: flutter doctor"; \
		exit 1 \
	)

install: check-flutter
	@echo "Fetching Flutter dependencies..."
	@flutter pub get
	@echo ""
	@echo "Base setup complete."
	@echo "If device/toolchain setup is missing, run: make doctor"

run: check-flutter
	@echo "Running on device: $(RUN_DEVICE)"
	@flutter run -d $(RUN_DEVICE)

clean: check-flutter
	@flutter clean
	@rm -rf .dart_tool build
	@rm -f "$$HOME/Library/Application Support/Arya/arya.db"
	@rm -f "$$HOME/.local/share/Arya/arya.db"
	@if [ -n "$$APPDATA" ]; then rm -f "$$APPDATA/Arya/arya.db"; fi
	@rm -f "$$HOME/Library/Application Support/Arya/arya_ai_settings.db"
	@rm -f "$$HOME/Library/Application Support/Arya/arya_file_vault.db"
	@rm -f "$$HOME/Library/Application Support/arya_file_vault.db"
	@find "$$HOME/Library/Application Support" -maxdepth 4 -name "arya_file_vault.db" -delete 2>/dev/null || true
	@rm -f "$$HOME/.local/share/Arya/arya_ai_settings.db"
	@rm -f "$$HOME/.local/share/Arya/arya_file_vault.db"
	@rm -f "$$HOME/.local/share/arya_file_vault.db"
	@find "$$HOME/.local/share" -maxdepth 4 -name "arya_file_vault.db" -delete 2>/dev/null || true
	@if [ -n "$$APPDATA" ]; then rm -f "$$APPDATA/Arya/arya_ai_settings.db"; fi
	@if [ -n "$$APPDATA" ]; then rm -f "$$APPDATA/Arya/arya_file_vault.db"; fi
	@if [ -n "$$APPDATA" ]; then find "$$APPDATA" -maxdepth 4 -name "arya_file_vault.db" -delete 2>/dev/null || true; fi
	@echo "Project artifacts cleaned."

doctor: check-flutter
	@flutter doctor
