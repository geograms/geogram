# E2E Tests

End-to-end tests that talk to the running desktop app via the debug API (`localhost:3456/api/debug`).

## Prerequisites

The desktop app must be running:

```bash
./launch-desktop.sh
```

## Usage

```bash
# Run all suites
./tests/run-tests.sh

# Run a specific suite
./tests/run-tests.sh karma
```

## Structure

```
tests/
  run-tests.sh              # Test runner (auto-discovers suites)
  karma/                     # Karma suite
    karma_chat_e2e_test.sh   # Chat message karma recording + UI updates
```

## Adding a new suite

1. Create a folder under `tests/` (e.g. `tests/chat/`)
2. Add test scripts ending in `_test.sh` (e.g. `chat_room_test.sh`)
3. The runner discovers them automatically

## Adding a new test to an existing suite

Add a `*_test.sh` script to the suite folder. It will be picked up on the next run.

## Conventions

- Each test script uses `set -euo pipefail` and exits non-zero on failure.
- Tests use the shared debug API helper: `post() { curl -sf -X POST "$API" ... }`.
- The `outdated_*` directories are skipped by the runner.
- Debug API actions are documented in `docs/API.md`. If an action doesn't exist, create one.
