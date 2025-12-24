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
./setup.sh                  # Install Flutter + platform deps on Linux
./rebuild-desktop.sh        # Build and run desktop (Linux)
./launch-desktop.sh         # Run desktop with version checks
./launch-web.sh             # Run web target
./launch-android.sh         # Run Android target
```

```bash
flutter pub get             # Install Dart/Flutter dependencies
flutter run -d linux         # Run a specific platform target
flutter build web            # Build web output into build/web/
```

```bash
./run_tests.sh              # Run station API tests (default)
./run_tests.sh all           # Run station + tile + alert tests
```

## Coding Style & Naming Conventions

- Dart/Flutter style with `flutter_lints` (see `analysis_options.yaml`).
- Format with `dart format` (or `flutter format`) before committing.
- Naming: `lower_snake_case.dart` files, `UpperCamelCase` types, `lowerCamelCase` members.
- Indentation follows Dart defaults (2 spaces).

## Testing Guidelines

- Primary test entrypoints are in `bin/*_test.dart` and `tests/`.
- Use `_test.dart` naming; shell helpers in `tests/*.sh`.
- Run `./run_tests.sh station` for station API coverage and `./run_tests.sh all` for broader coverage.
- Widget tests are currently placeholder; prefer API/integration tests when adding coverage.

## Commit & Pull Request Guidelines

- Commit subjects are short, sentence-case, and descriptive; examples in history include
  `Fix remote chat messaging...`, `Optimize: ...`, and `Release vX.Y.Z - ...`.
- PRs should include a clear summary, test commands run, and platform notes.
- For UI changes, include screenshots or short clips. Link related issues or tasks.

## Docs & References

- Build docs live under `docs/` (platform install, release, and build guides).
- See `README.md` for quick-start setup and platform prerequisites.
