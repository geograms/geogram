# Memory

## Key Decisions

- Always use ProfileStorage methods (not raw File/Directory) when accessing files inside the {callsign} profile folder — the folder may be inside an encrypted SQLite storage. Use AppService().profileStorage to get the storage instance.
- Station code reuse: Never implement feature code on either CLI or Desktop station directly. Always write to shared libraries/mixins (lib/server/mixins/) and have both stations use the same code.

There is a script ./launch-desktop.sh to launch the client on this laptop and ./server-deploy.sh when needed to upload/update the server station.

Always use ./launch-desktop.sh for testing the code and client implementations, don't launch it separately without that script

Read ./docs/API.md for the debug API that automates testing. When a debug API endpoint does not exist, create one.

Never implement code features without testing them yourself first. Do the deployment, test that it works as intended.

Use ./docs/reusable.md to reuse code instead of duplicating functionalities, document new reusable components there

Always commit your changes with a proper change log

Write code that is based on DART and can run from the command line for libraries, so we can reuse it in other platforms

Another claude instance might be running on the same code base, be carefull. When you find code that is breaking your compilation to unrelated changes then ask the human  

## Release Process

1. Bump version in `pubspec.yaml`
2. Commit (pre-commit hook auto-updates `lib/version.dart` via `tool/update_version.dart`)
3. Tag with `git tag v<version>` and push with `git push --tags`
4. Create GitHub release — CI workflows will `sed` pubspec.yaml from the tag and regenerate `version.dart` before building

**Important**: CI workflows automatically sync `version.dart` from pubspec.yaml via `dart run tool/update_version.dart`. This ensures the compiled `appVersion` constant always matches the release tag, preventing self-updater loops.

## Architecture Notes

- ProfileStorage is an abstract class with two implementations: FilesystemProfileStorage (plain files) and EncryptedProfileStorage (encrypted SQLite archive)
- AppService().profileStorage returns the correct instance for the current profile
- Mirror sync service accepts optional ProfileStorage? storage parameter on all operations — falls back to raw filesystem when null
- StorageEntry from listDirectory() has paths relative to the storage base
- Two station implementations: PureStationServer (CLI, lib/cli/pure_station.dart) and StationServer (Desktop, lib/station.dart)
- EmailHandlerMixin (lib/server/mixins/email_handler_mixin.dart) provides shared email methods for both stations
- Other shared mixins in lib/server/mixins/: RateLimitMixin, HealthWatchdogMixin, SmtpMixin, SslMixin, StunMixin