# Command Line Switches

Geogram Desktop supports various command line arguments for configuration and testing.

---

## Quick Reference

```bash
geogram_desktop [options]

Options:
  --port=PORT, -p PORT       API server port (default: 3456)
  --data-dir=PATH, -d PATH   Data directory path
  --cli                      Run in CLI mode (no GUI)
  --http-api                 Enable HTTP API on startup
  --debug-api                Enable Debug API on startup
  --new-identity             Create a new identity on startup
  --identity-type=TYPE       Identity type: 'client' (default) or 'station'
  --nickname=NAME            Nickname for the new identity
  --skip-intro               Skip intro/welcome screen on first launch
  --scan-localhost=RANGE     Scan localhost ports for other instances (e.g., 5000-6000)
  --verbose                  Enable verbose logging
  --help, -h                 Show help message
  --version, -v              Show version information
```

---

## Options

### --port, -p

Sets the API server port. Default is 3456.

```bash
# Long form
geogram_desktop --port=3457

# Short form
geogram_desktop -p 3457
```

**Use cases:**
- Running multiple instances for testing
- Avoiding port conflicts with other services
- Test automation with different ports per instance

### --data-dir, -d

Sets the data directory where all app data is stored.

```bash
# Long form
geogram_desktop --data-dir=/tmp/geogram-test

# Short form
geogram_desktop -d /tmp/geogram-test

# Using home directory expansion
geogram_desktop --data-dir=~/.geogram-instance2
```

**Default locations:**
- Linux: `~/.local/share/geogram-desktop`
- macOS: `~/.local/share/geogram-desktop`
- Windows: `%LOCALAPPDATA%\geogram-desktop`
- Mobile: App's documents directory

**Directory structure:**
```
{data-dir}/
├── config.json              # Main configuration
├── station_config.json      # Station settings
├── devices/                 # Device data by callsign
│   └── {CALLSIGN}/
│       └── collections/
├── tiles/                   # Cached map tiles
├── ssl/                     # SSL certificates
└── logs/                    # Log files
```

### --cli

Run in CLI (Command Line Interface) mode without the GUI.

```bash
geogram_desktop --cli
```

### --http-api

Enable the HTTP API server on startup. By default, the HTTP API is disabled and must be enabled manually via the GUI or this flag.

```bash
geogram_desktop --http-api

# Combined with custom port
geogram_desktop --http-api --port=5678

# For automated testing
geogram_desktop --http-api --debug-api --data-dir=/tmp/test
```

**Use cases:**
- Automated testing and CI/CD pipelines
- Headless operation with API access
- Remote device control and monitoring

### --debug-api

Enable the Debug API on startup. The Debug API provides additional endpoints for testing and automation, including:
- Device discovery and BLE operations
- Navigation control
- Direct message testing
- Toast notifications

```bash
geogram_desktop --debug-api

# Typically used with --http-api
geogram_desktop --http-api --debug-api
```

**Security note:** The Debug API should only be enabled in trusted environments as it allows remote control of the application.

### --new-identity

Create a new identity on startup. This clears any existing profile and generates a new NOSTR keypair and callsign. Useful for testing scenarios where you need fresh, temporary identities.

```bash
# Create a new client identity (default)
geogram_desktop --new-identity

# Create with a custom nickname
geogram_desktop --new-identity --nickname="Test User"

# Create a new station identity
geogram_desktop --new-identity --identity-type=station --nickname="Test Station"
```

**Use cases:**
- Automated testing with temporary identities
- Running multiple instances with different identities
- CI/CD pipelines that need fresh state
- Testing device-to-device communication

### --identity-type

Specifies the type of identity to create when using `--new-identity`.

**Values:**
- `client` (default): Creates a client identity with X1 prefix callsign
- `station`: Creates a station identity with X3 prefix callsign

```bash
# Client identity (X1 prefix)
geogram_desktop --new-identity --identity-type=client

# Station identity (X3 prefix)
geogram_desktop --new-identity --identity-type=station
```

**Differences between client and station:**
- **Client (X1)**: Regular user device, connects to stations, participates in chat
- **Station (X3)**: Server mode, can host connections, relay messages, cache tiles

### --nickname

Sets the nickname for the new identity when using `--new-identity`.

```bash
geogram_desktop --new-identity --nickname="Alice"
geogram_desktop --new-identity --identity-type=station --nickname="HQ Station"
```

### --skip-intro

Skip the intro/welcome screen on first launch. This is useful for automated testing scenarios where you don't want to manually dismiss the welcome dialog.

```bash
# Skip intro when creating a new test identity
geogram_desktop --new-identity --skip-intro --data-dir=/tmp/test

# Combined with HTTP API for automated testing
geogram_desktop --new-identity --skip-intro --http-api --debug-api --port=5678
```

**Use cases:**
- Automated testing and CI/CD pipelines
- Running multiple test instances without manual interaction
- Script-based testing where human intervention is not possible

### --scan-localhost

Scan a range of localhost ports for other Geogram instances running on the same machine. This enables discovery of parallel test instances without requiring network scanning.

```bash
# Scan ports 5000-6000 for other instances
geogram_desktop --scan-localhost=5000-6000

# Full testing setup with two instances
# Terminal 1:
geogram_desktop --port=5577 --data-dir=/tmp/instance-a --scan-localhost=5500-5600

# Terminal 2:
geogram_desktop --port=5588 --data-dir=/tmp/instance-b --scan-localhost=5500-5600
```

**Format:** `--scan-localhost=START-END` where START and END are port numbers (1-65535).

**Use cases:**
- Testing device-to-device communication on a single machine
- Development with multiple local instances
- CI/CD pipelines running parallel test instances
- Debugging DM and chat functionality locally

**Note:** The standard ports (3456, 8080, 80, 8081, 3000, 5000) are always scanned on localhost regardless of this flag. This flag adds an additional port range to scan.

### --verbose

Enable verbose logging for debugging.

```bash
geogram_desktop --verbose
geogram_desktop --verbose --port=3457
```

### --help, -h

Display help message and exit.

```bash
geogram_desktop --help
geogram_desktop -h
```

### --version, -v

Display version information and exit.

```bash
geogram_desktop --version
geogram_desktop -v
```

---

## Environment Variables

Environment variables can be used as an alternative to CLI arguments. CLI arguments take precedence over environment variables.

| Variable | Description | Example |
|----------|-------------|---------|
| `GEOGRAM_PORT` | API server port | `export GEOGRAM_PORT=3457` |
| `GEOGRAM_DATA_DIR` | Data directory | `export GEOGRAM_DATA_DIR=/tmp/geogram` |

---

## Testing Scenarios

### Running Multiple Instances

For BLE testing between two instances on the same machine:

```bash
# Terminal 1: First instance
geogram_desktop --port=3456 --data-dir=~/.geogram-instance1

# Terminal 2: Second instance
geogram_desktop --port=3457 --data-dir=~/.geogram-instance2
```

### Automated Testing

Run tests against specific ports:

```bash
# Start app on test port with API enabled
geogram_desktop --port=3460 --data-dir=/tmp/geogram-test --http-api --debug-api &

# Run tests
curl http://localhost:3460/api/debug
curl http://localhost:3460/api/devices

# Cleanup
kill %1
rm -rf /tmp/geogram-test
```

### Device-to-Device DM Testing

Test direct messaging between two instances:

```bash
# Use the provided test script
./test/run_dm_test.sh

# Or manually run two instances
geogram_desktop --port=5678 --data-dir=/tmp/instance1 --http-api --debug-api &
geogram_desktop --port=5679 --data-dir=/tmp/instance2 --http-api --debug-api &

# Send a message from instance 1 to instance 2's callsign
curl -X POST http://localhost:5678/api/dm/X2TEST/messages \
    -H "Content-Type: application/json" \
    -d '{"content": "Hello from instance 1!"}'
```

### Clean Environment Testing

Test with a fresh data directory:

```bash
# Create temp directory and run
TMPDIR=$(mktemp -d)
geogram_desktop --data-dir="$TMPDIR" --port=3456

# After testing, cleanup
rm -rf "$TMPDIR"
```

### CI/CD Integration

```bash
#!/bin/bash
# ci-test.sh

# Start two instances for BLE testing
geogram_desktop --port=3456 --data-dir=/tmp/test1 &
PID1=$!
geogram_desktop --port=3457 --data-dir=/tmp/test2 &
PID2=$!

# Wait for startup
sleep 5

# Run tests
dart run test/ble_api_test.dart \
    --device1=localhost:3456 \
    --device2=localhost:3457

# Cleanup
kill $PID1 $PID2
rm -rf /tmp/test1 /tmp/test2
```

---

## Debug API

When running, the app exposes a debug API on the configured port:

```bash
# Check status
curl http://localhost:3456/api/status

# View logs
curl "http://localhost:3456/log?filter=BLE&limit=50"

# Trigger BLE scan
curl -X POST http://localhost:3456/api/debug \
    -H "Content-Type: application/json" \
    -d '{"action": "ble_scan"}'
```

See `docs/BLE.md` for more debug API documentation.

---

## Troubleshooting

### Port Already in Use

```
Error: Address already in use
```

Solution: Use a different port or kill the existing process:
```bash
# Find process using port
lsof -i :3456

# Kill it
kill <PID>

# Or use a different port
geogram_desktop --port=3457
```

### Permission Denied on Data Directory

```
Error: Cannot create directory
```

Solution: Ensure write permissions or use a different directory:
```bash
# Check permissions
ls -la ~/.local/share/

# Use a directory you can write to
geogram_desktop --data-dir=/tmp/geogram
```

### Arguments Not Being Parsed

For Flutter desktop apps, arguments may need to be passed after `--`:

```bash
# Direct binary execution
./build/linux/x64/release/bundle/geogram_desktop --port=3457

# Via flutter run (for development)
flutter run -- --port=3457
```
