# Encrypted Storage Tests

Tests for the encrypted storage feature that allows storing profile data in an AES-256-GCM encrypted SQLite archive.

## Test Files

| File | Description |
|------|-------------|
| `api_test.sh` | Quick API tests against a running instance |
| `run_test.sh` | Full integration test with temp data directory |
| `encrypted_storage_test.dart` | Dart version of API tests |

## Quick Start

### 1. Start Geogram with Debug API enabled

```bash
# Start Geogram
flutter run -d linux

# In Geogram: Settings > Security > enable "Debug API"
```

### 2. Run API tests

```bash
# Bash version (recommended)
./tests/encryption/api_test.sh --port 3456

# Or Dart version
dart run tests/encryption/encrypted_storage_test.dart --port 3456
```

## What the tests verify

1. **Connectivity** - Instance running with debug API enabled
2. **Prerequisites** - Profile has nsec configured (required for encryption key)
3. **Enable encryption** - Migrates files to encrypted SQLite archive
4. **Status verification** - Archive path and size reported correctly
5. **Idempotency** - Double enable returns `ALREADY_ENCRYPTED`
6. **Disable encryption** - Extracts files back to plaintext folders
7. **Data integrity** - Files restored correctly after round-trip
8. **Idempotency** - Double disable returns `NOT_ENCRYPTED`

## Debug API Endpoints

### Status
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "encrypt_storage_status"}'
```

Response:
```json
{
  "enabled": false,
  "has_nsec": true,
  "archive_path": null
}
```

### Enable Encryption
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "encrypt_storage_enable"}'
```

Response (success):
```json
{
  "success": true,
  "files_processed": 42
}
```

Response (already encrypted):
```json
{
  "success": false,
  "error": "Profile is already using encrypted storage",
  "code": "ALREADY_ENCRYPTED"
}
```

### Disable Encryption
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "encrypt_storage_disable"}'
```

## How Encryption Works

1. **Key derivation**: Password derived from NOSTR nsec using HKDF-SHA256
2. **Encryption**: AES-256-GCM per-file encryption
3. **Storage**: SQLite database with encrypted chunks
4. **Structure**: SQLite tables are browsable, but content is encrypted

```
~/.local/share/geogram/devices/
├── CALLSIGN/           # Plaintext mode (folders)
│   ├── chat/
│   ├── contacts/
│   └── work/
└── CALLSIGN.sqlite     # Encrypted mode (single file)
```

The `.sqlite` file can be opened with any SQLite browser to see the structure, but the actual file content in the `chunks` table is AES-256-GCM encrypted gibberish without the key.
