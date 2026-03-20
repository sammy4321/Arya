<p align="center">
  <img src="./logo.png" alt="Arya logo" width="180" />
</p>

<h1 align="center">Arya</h1>

<p align="center">
  A desktop AI workspace built with Flutter.
</p>

---

## Overview

Arya is a cross-platform desktop application focused on AI-assisted workflows.  
The app includes a chat-first assistant experience, local settings persistence, and support for multimodal inputs such as images, PDFs, and text files.

## Tech Stack

- **App framework:** Flutter (Dart)
- **Platforms:** macOS, Linux, Windows
- **Storage:** Local SQLite (via `sqflite_common_ffi`)
- **AI providers:** OpenRouter (chat/model access), Tavily (web search)
- **Build tooling:** `make`

## Prerequisites

- Flutter SDK (stable): [Install guide](https://docs.flutter.dev/get-started/install)
- A configured Flutter desktop environment (`flutter doctor`)
- `make` available in your shell

## Quick Start

From the repository root:

```bash
make install
make run
```

By default, the app runs on your OS desktop target:
- macOS -> `macos`
- Linux -> `linux`
- Windows -> `windows`

Override the target device when needed:

```bash
make run RUN_DEVICE=macos
```

## Make Targets

| Command | Description |
|---|---|
| `make install` | Verifies Flutter setup and fetches dependencies (`flutter pub get`) |
| `make run` | Launches Arya on the selected desktop device |
| `make clean` | Cleans Flutter artifacts and removes local app DB artifacts |
| `make doctor` | Runs Flutter environment diagnostics |

## Configuration

Arya stores AI settings locally (no backend required). In the app settings, configure:

- OpenRouter API key
- OpenRouter model
- Tavily API key (optional, for web search enhancement)

Settings are persisted to a local SQLite database in your OS application support directory.

## Repository Structure

```text
.
├── frontend/          # Flutter desktop application
├── logo.png           # Project logo
├── Makefile           # Root developer commands
└── README.md
```

## Development Notes

- Root `Makefile` delegates to `frontend/Makefile`.
- `make clean` also removes local `arya_file_vault.db` artifacts from common OS data paths.
- No backend service is required for local development.

## License

This project is licensed under the terms in [LICENSE](./LICENSE).
