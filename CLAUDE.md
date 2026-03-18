# Repository Memory

`AGENTS.md` is the canonical source for repository workflow, verification, release rules, architecture constraints, and collaboration safety.
Keep this file limited to Claude compatibility notes and compact technical context that is not already maintained in `AGENTS.md`.

## Memory Layout

- `CLAUDE.local.md` is the working-memory file. Keep it short and focused on session-specific or behavior-changing context that is not already encoded elsewhere.
- `.claude/rules/total-recall.md` defines the memory protocol.
- `memory/registers/*.md` hold durable structured memory.
- `memory/daily/*.md` hold append-only session captures.

## Technical Context

- `ProfileStorage` has two implementations: `FilesystemProfileStorage` and `EncryptedProfileStorage`.
- `AppService().profileStorage` returns the correct storage for the current profile.
- Mirror sync operations accept an optional `ProfileStorage? storage` and fall back to the raw filesystem when `null`.
- `StorageEntry` paths returned by `listDirectory()` are relative to the storage base.
- Station entry points are `lib/cli/pure_station.dart` and `lib/station.dart`.
- Shared station behavior belongs in reusable code such as `lib/server/mixins/`.
- `EmailHandlerMixin` provides shared email methods for both station implementations.
- Existing shared mixins include `RateLimitMixin`, `HealthWatchdogMixin`, `SmtpMixin`, `SslMixin`, and `StunMixin`.

## Others

+ Always commit after doing code changes
+ Always test your code changes with real data or in a deployment before saying it is done
