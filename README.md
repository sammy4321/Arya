<p align="center">
  <img src="./logo.png" alt="Arya" width="200" />
</p>

<h1 align="center">Arya</h1>

<p align="center">
  <strong>Desktop AI assistant and automation workspace</strong><br />
  Built with Flutter for macOS, Linux, and Windows.
</p>

<p align="center">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="License" /></a>
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/Flutter-Desktop-02569B?logo=flutter" alt="Flutter" /></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-3.9+-0175C2?logo=dart&logoColor=white" alt="Dart" /></a>
</p>

---

## Table of contents

- [About](#about)
- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Make targets](#make-targets)
- [Configuration](#configuration)
- [Project structure](#project-structure)
- [Development](#development)
- [Contributing](#contributing)
- [Security & privacy](#security--privacy)
- [License](#license)

---

## About

**Arya** is an open source, cross-platform desktop application that brings AI-assisted chat and on-screen **Take Action** workflows to your machine. It is designed to run locally as a floating assistant: configure your own API keys, keep data on disk under your control, and use models via [OpenRouter](https://openrouter.ai/) with optional web search through [Tavily](https://tavily.com/).

There is **no bundled backend server**—the app talks to providers you configure from your environment.

---

## Features

| Area | Description |
|------|-------------|
| **Chat** | Multi-turn assistant with streaming replies, optional reasoning display, web-grounded answers when search is enabled, and attachments (e.g. images, documents). |
| **Take Action** | Plan-and-execute automation against the foreground app using accessibility context, screenshots where needed, re-planning on failure, and optional strategy caching for similar tasks. |
| **Settings** | Local persistence for API keys and model selection (SQLite). |
| **Desktop UX** | Floating window behavior, drag-and-drop attachments, keyboard-friendly chat input. |

*Exact capabilities depend on your OS, permissions (e.g. accessibility on macOS), and model/provider behavior.*

---

## Architecture

- **Client:** Flutter **desktop** app (`frontend/`).
- **AI:** OpenRouter for chat/completions; Tavily optional for web search context.
- **Persistence:** `sqflite_common_ffi` for settings, file vault, and strategy cache—stored under the OS application data path (e.g. `~/Library/Application Support/Arya` on macOS).
- **Native:** Platform code where required (e.g. clipboard, windowing, accessibility) under `frontend/macos/` (and other desktop embedders as enabled).

---

## Prerequisites

- **[Flutter](https://docs.flutter.dev/get-started/install)** (stable channel) with **desktop** support enabled  
- **`make`** (optional but recommended; the repo root and `frontend/` expose the same workflows)
- A machine that passes `flutter doctor` for your target (macOS / Linux / Windows)

---

## Quick start

From the **repository root**:

```bash
make install
make run
```

The default device matches your OS (`macos`, `linux`, or `windows`). Override if needed:

```bash
make run RUN_DEVICE=macos
```

Equivalent from `frontend/`:

```bash
cd frontend
make install
make run
```

---

## Make targets

| Target | Description |
|--------|-------------|
| `make install` | Verifies Flutter on `PATH` and runs `flutter pub get` |
| `make run` | Runs the app on `RUN_DEVICE` (default: OS-appropriate desktop) |
| `make clean` | `flutter clean` plus removal of known local DB artifacts used in dev |
| `make doctor` | Runs `flutter doctor` |
| `make help` | Lists targets and `RUN_DEVICE` override |

---

## Configuration

Open **Settings** inside the app and set:

| Setting | Purpose |
|---------|---------|
| **OpenRouter API key** | Required for model calls |
| **Model** | Chosen from OpenRouter’s catalog |
| **Tavily API key** | Optional; improves answers when web search is used |

Keys and preferences are stored **locally** in SQLite—no project-hosted backend is involved.

---

## Project structure

```text
.
├── frontend/                 # Flutter desktop application (main codebase)
│   ├── lib/                  # Dart sources (features, services, UI)
│   ├── macos/                # macOS runner & native integrations
│   └── Makefile              # Frontend-specific make targets
├── logo.png                  # Project logo
├── LICENSE                   # Apache License 2.0
├── Makefile                  # Root shortcuts (delegates to frontend/)
└── README.md
```

---

## Development

- **Analyze:** `cd frontend && flutter analyze`
- **Tests:** add or run tests under `frontend/test/` as the project grows (`flutter test`)
- **Clean:** `make clean` from root or `frontend/`—see Makefile for what local DB files are removed during clean

When contributing code, prefer small, focused changes and match existing style in `lib/`.

---

## Contributing

Contributions are welcome.

1. **Fork** the repository and create a **branch** for your change.
2. **Describe** the problem or feature in your PR (what / why).
3. **Keep** changes scoped; run `flutter analyze` before opening a PR when you touch Dart code.
4. **License:** By contributing, you agree your contributions are licensed under the same terms as the project ([Apache 2.0](./LICENSE)).

For larger changes, consider opening an issue first to align on direction.

---

## Security & privacy

- **API keys** are stored only in your local app data directory—**never commit** keys or `.env` files with real secrets.
- **Third-party services** (OpenRouter, Tavily) have their own terms and data policies; review them before use.
- **Automation** can drive the UI of other apps; use least privilege and only on systems and accounts you trust.

If you discover a security issue, please report it responsibly (e.g. via private disclosure to maintainers if available) rather than a public issue.

---

## License

This project is licensed under the **Apache License 2.0**—see [LICENSE](./LICENSE).

---

## Acknowledgments

- [Flutter](https://flutter.dev/) & [Dart](https://dart.dev/)
- [OpenRouter](https://openrouter.ai/) for unified model access
- [Tavily](https://tavily.com/) for optional search augmentation
