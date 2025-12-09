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
# Start app on test port
geogram_desktop --port=3460 --data-dir=/tmp/geogram-test &

# Run tests
./test/ble_linux_linux.sh
curl http://localhost:3460/api/debug

# Cleanup
kill %1
rm -rf /tmp/geogram-test
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
