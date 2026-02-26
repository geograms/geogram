# Repository Guidelines

## Project Structure & Module Organization

- `lib/` holds the Flutter application code and shared UI/business logic.
- `bin/` contains CLI utilities and standalone Dart test runners (e.g., `station_api_test.dart`).
- `tests/` includes integration-style Dart tests and shell scripts for multi-device scenarios.
- Platform targets live in `android/`, `ios/`, `linux/`, `macos/`, `windows/`, and `web/`.
- Assets and data live in `assets/`, `languages/`, `themes/`, `tiles/`, and `games/`.
- Build and operational scripts are in the repo root and `scripts/`.

## Build, Test, and Development Commands

```bash
./launch-desktop.sh         # Run desktop with version checks
./launch-android.sh         # Run Android target
./server-deploy.sh          # Deploy a new server station and see credentials
```

## Do not forget

- Always run the compiler on your code changes to make sure they compile
- Don't say that code is "working" until you wrote debug API (see ./docs/API.md) to test by yourself that a feature is implemented
- always commit your code changes after each task
- do an end-to-end planning and verification of the functionalities, don't wait for the user to tell you each step that needs to be implemented
- always run ./launch-desktop.sh to launch the linux instance


## Commit & Pull Request Guidelines

- Commit subjects are short, sentence-case, and descriptive; examples in history include
  `Fix remote chat messaging...`, `Optimize: ...`, and `Release vX.Y.Z - ...`.
- PRs should include a clear summary, test commands run, and platform notes.
- For UI changes, include screenshots or short clips. Link related issues or tasks.

## Docs & References

- Build docs live under `docs/` (platform install, release, and build guides).
- See `README.md` for quick-start setup and platform prerequisites.
