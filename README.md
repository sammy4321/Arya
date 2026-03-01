# Arya

Flutter base project with a minimal UI (single floating action button).

## Prerequisites

1. Install Flutter (stable): https://docs.flutter.dev/get-started/install
2. Ensure `flutter` is on your `PATH`.
3. Verify setup:

```bash
flutter doctor
```

If `make install` fails with "Flutter is not installed or not on PATH", complete the steps above and rerun.

## Usage

Install project dependencies:

```bash
make install
```

Run the app:

```bash
make run
```

By default `make run` targets desktop on your host OS (`macos`/`linux`/`windows`).
Override target device if needed:

```bash
make run RUN_DEVICE=chrome
```

Clean generated artifacts:

```bash
make clean
```

Environment diagnostics:

```bash
make doctor
```
