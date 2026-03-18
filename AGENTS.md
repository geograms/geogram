# Repository Guidelines

## Project Structure & Module Organization

- `lib/` holds the Flutter application code and shared UI/business logic.
- `bin/` contains CLI utilities and standalone Dart test runners such as `station_api_test.dart`.
- `tests/` includes integration-style Dart tests and shell scripts for multi-device scenarios.
- Platform targets live in `android/`, `ios/`, `linux/`, `macos/`, `windows/`, and `web/`.
- Assets and data live in `assets/`, `languages/`, `themes/`, `tiles/`, and `games/`.
- Build and operational scripts are in the repo root and `scripts/`.

## Core Workflow

- Run the relevant compiler or analyzer after code changes so the edited code is validated.
- Do not claim a feature works until you have verified it yourself.
- Use the debug API in `docs/API.md` for feature verification whenever possible.
- If the required debug API endpoint does not exist, add it, use it to test the feature, and document it in `docs/API.md`.
- For desktop and general client verification, always launch through `./launch-desktop.sh`.
- For Android-specific verification, use `./launch-android.sh`.
- For server-side deployment or validation, use `./server-deploy.sh`.
- Plan and verify end-to-end behavior yourself instead of waiting for the user to list every validation step.
- Commit your changes after each task with a descriptive sentence-case message.
- Mention bug or ticket identifiers in commit messages when the task is tied to a specific issue.
- Never run `git push`, `gh release`, or other publish steps unless the user explicitly asks.
- Never auto-close bug tickets or issues after fixing them; wait for explicit confirmation.

## Architecture Constraints

- When accessing anything inside the `{callsign}` profile folder, always use `ProfileStorage` methods rather than raw `File` or `Directory`.
- Obtain profile storage through `AppService().profileStorage`.
- This rule is mandatory because profile data may live in `EncryptedProfileStorage` backed by SQLite rather than the plain filesystem.
- Do not implement station features separately in CLI and Desktop station classes.
- Put shared station logic in reusable libraries or mixins, especially under `lib/server/mixins/`, and have both station implementations use the same code.
- The two station entry points are `lib/cli/pure_station.dart` and `lib/station.dart`; keep behavior aligned through shared code.
- `EmailHandlerMixin` is the shared email implementation for both station types; extend shared behavior there instead of duplicating email logic.
- The offline ECIES email cache path is intentionally disabled at the moment; reconnect delivery still relies on the pending-email path until encryption is redesigned.
- Prefer Dart libraries that can run from the command line so logic can be reused across platforms.
- Reuse existing components instead of duplicating them, and document new reusable building blocks in `docs/reusable.md`.

## Build, Test, and Development Commands

```bash
./launch-desktop.sh         # Run desktop with version checks
./launch-android.sh         # Run Android target
./server-deploy.sh          # Deploy a server station and print access details
```

## Release Process

1. Bump the version in `pubspec.yaml`.
2. Commit the change. The pre-commit hook updates `lib/version.dart` through `tool/update_version.dart`.
3. Tag the release with `git tag v<version>`.
4. Push tags only when explicitly requested.
5. Create the GitHub release when explicitly requested.

- CI also regenerates `lib/version.dart` from `pubspec.yaml` during release builds. Keep those values aligned to avoid self-updater loops.

### Beta vs Stable Releases

The app supports two update channels. Clients opt in to beta via a toggle in Settings > Updates.

| Channel | Tag format | GitHub release | F-Droid | Client endpoint |
|---------|-----------|---------------|---------|-----------------|
| **Stable** | `v1.36.0` | Normal release | Picked up automatically | `/releases/latest` |
| **Beta** | `v1.36.0-beta.1` | **Pre-release** checkbox checked | Ignored (tag doesn't match version regex) | `/releases?per_page=1` |

**Publishing a beta:**
1. Bump version in `pubspec.yaml` as normal (e.g., `1.36.0+12`).
2. Commit, tag as `v1.36.0-beta.1` (the `-beta.N` suffix ensures F-Droid ignores it).
3. Create GitHub release with **"Set as a pre-release"** checked.

**Publishing stable:**
1. Same or bumped version (e.g., `1.36.0+12`).
2. Tag as `v1.36.0` (no suffix).
3. Create GitHub release as normal (not pre-release).

Stations cache both channels simultaneously and serve them via `?channel=beta|stable` on `/api/updates/latest`.

## Collaboration Safety

- Another agent or developer may be editing this repository at the same time.
- If unrelated changes appear and they interfere with the current task, stop and ask the user how to proceed instead of overwriting them.
- Prefer non-destructive changes and preserve in-progress work you did not create.

## Commit & Pull Request Guidelines

- Commit subjects should be short, sentence-case, and descriptive.
- Example patterns from history include `Fix remote chat messaging...`, `Optimize: ...`, and `Release vX.Y.Z - ...`.
- PRs should include a clear summary, test commands run, and platform notes.
- For UI changes, include screenshots or short clips and link related issues or tasks.

## Docs & References

- Start with `README.md` for setup and platform prerequisites.
- Use `docs/API.md` for the debug API and verification hooks.
- Use `docs/reusable.md` before adding new abstractions so existing reusable code is not duplicated.
- Build, release, and platform notes live under `docs/`.
