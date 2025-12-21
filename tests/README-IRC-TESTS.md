# IRC Bridge Test Automation

## Overview

The IRC bridge tests are **fully automated** - they spawn their own Geogram instance with IRC server enabled, run tests, and clean up afterward.

## How It Works

### 1. Instance Management

The test suite (`bridge-irc_test.dart`) automatically:

**Launches:**
- Geogram CLI station with IRC server enabled
- API server on port 17000
- IRC server on port 17001
- Temporary data directory: `/tmp/geogram-irc-test`

**Configures:**
```bash
--port=17000
--irc-server
--irc-port=17001
--http-api
--debug-api
--new-identity
--identity-type=station
```

**Waits:**
- Up to 15 seconds for API server to be ready
- Up to 15 seconds for IRC server to accept connections

**Cleans up:**
- Kills station process (SIGTERM, then SIGKILL if needed)
- Deletes temporary data directory
- Handles Ctrl+C gracefully

### 2. Test Execution

The test suite runs these IRC protocol tests:

1. **IRC Server Available** - TCP connection test
2. **NICK/USER Registration** - IRC authentication flow
3. **PING/PONG** - Keep-alive mechanism
4. **LIST Channels** - Channel discovery
5. **JOIN Channel** - Channel membership
6. **Send Message (IRC → Geogram)** - Verifies messages are stored via API
7. **Receive Message (Geogram → IRC)** - Posts via API, verifies IRC delivery
8. **Channel Naming** - Validates station (#main) and device (#X1ABCD-main) formats
9. **Nick Collision** - Multiple clients with same nick

### 3. Integration with Test Launcher

The `launch_app_tests.sh` script runs **both** test suites:

```bash
./tests/launch_app_tests.sh
```

**Behavior:**
- Runs app alert tests first
- Runs IRC bridge tests second
- Shows summary for each suite
- **Exits with code 1 if ANY test fails**

Example output:
```
Running app alert tests...
✓ All app alert tests passed

Running IRC bridge tests...
✓ All IRC bridge tests passed

Test Suite Summary:
  App Alert Tests:    PASSED
  IRC Bridge Tests:   PASSED

==============================================
  All tests passed!
==============================================
```

If IRC tests fail:
```
Test Suite Summary:
  App Alert Tests:    PASSED
  IRC Bridge Tests:   FAILED

==============================================
  Some tests failed!
==============================================
```

The script exits with **non-zero exit code**, which will:
- Fail CI/CD pipelines
- Alert developers to IRC bridge issues
- Preserve test data for debugging

## Running Tests

### Prerequisites

Build the CLI (only needed once):
```bash
./launch-cli.sh --build-only
```

### Run All Tests

```bash
./tests/launch_app_tests.sh
```

### Run IRC Tests Only

```bash
dart run tests/bridge-irc_test.dart
```

Or with executable permission:
```bash
./tests/bridge-irc_test.dart
```

## CI/CD Integration

The test suite is designed for automated CI/CD:

**GitHub Actions Example:**
```yaml
- name: Build CLI
  run: ./launch-cli.sh --build-only

- name: Run Tests
  run: ./tests/launch_app_tests.sh
```

**Exit codes:**
- `0` - All tests passed
- `1` - At least one test failed

**Cleanup:**
- Automatic cleanup on success
- Automatic cleanup on failure
- Automatic cleanup on Ctrl+C
- Test data in `/tmp/geogram-irc-test` (for debugging failures)

## Debugging Failed Tests

If tests fail, the suite will show:

1. **Which test failed** - Specific test name and reason
2. **Station logs** - All stdout/stderr from the station process
3. **Failure summary** - List of all failures at the end

**Check test data:**
```bash
ls -la /tmp/geogram-irc-test
```

**Re-run with verbose output:**
The station logs are automatically printed during test execution.

## Test Isolation

Each test run:
- Uses isolated data directory (`/tmp/geogram-irc-test`)
- Generates new NOSTR identity
- Uses unique ports (17000, 17001)
- Cleans up completely after

Tests can run in parallel on different machines without conflicts (different ports/paths).

## Future Enhancements

- [ ] Parallel test execution
- [ ] Test coverage reporting
- [ ] Performance benchmarks
- [ ] Load testing (multiple IRC clients)
- [ ] Integration with existing chat data

## Troubleshooting

### "CLI build not found"
```bash
./launch-cli.sh --build-only
```

### "Services did not start within timeout"
- Check station logs in test output
- Ensure ports 17000-17001 are not in use
- Verify IRC server code is implemented

### "IRC server connection failed"
- Ensure IRC server is implemented in station code
- Check `--irc-server` flag is working
- Verify port 17001 is accessible

### Test data not cleaned up
The test should auto-cleanup, but if it doesn't:
```bash
rm -rf /tmp/geogram-irc-test
```

---

**Test Status**: ✅ Ready (waiting for IRC server implementation)

Once the IRC server is implemented, these tests will verify:
- Protocol compliance
- Message translation
- Channel management
- NOSTR identity generation
- Bidirectional sync
