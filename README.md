# Arya

Monorepo with:

- `frontend/`: Flutter app
- `backend/`: FastAPI service (`GET /health`)

## Prerequisites

1. Install Flutter (stable): https://docs.flutter.dev/get-started/install
2. Ensure `flutter` is on your `PATH`
3. Install Python 3 and ensure `python3` is on your `PATH`

## Root Make Targets

Install frontend and backend dependencies:

```bash
make install
```

Run backend + frontend together:

```bash
make run
```

Override defaults if needed:

```bash
make run RUN_DEVICE=chrome BACKEND_HOST=127.0.0.1 BACKEND_PORT=8000
```

Clean frontend + backend artifacts:

```bash
make clean
```

Run toolchain diagnostics for both:

```bash
make doctor
```

## Component Targets

Run only frontend:

```bash
make frontend-run RUN_DEVICE=macos
```

Run only backend:

```bash
make backend-run BACKEND_HOST=127.0.0.1 BACKEND_PORT=8000
```
