# GeoBlue Linux CLI Test

This folder contains a standalone, non-Flutter test harness for the `geoblue` Dart library.

## Run

```bash
cd tests/geoblue
./run_hello_test.sh
```

Optional target address:

```bash
./run_hello_test.sh --address AA:BB:CC:DD:EE:FF
```

Large unicast round-trip integrity/timing test (~1000-byte text payload):

```bash
./run_unicast_large_test.sh
```

## What it does

1. Scans for Geogram BLE devices.
2. Connects to the selected device.
3. Sends a `hello` frame.
4. Waits for `hello_ack`.
5. Confirms the peer also sent `hello` (bidirectional HELLO exchange).

For `run_unicast_large_test.sh`:

1. Performs HELLO handshake.
2. Sends `tests/geoblue/data/payload_1000.txt` to ESP32 via unicast `data` frame.
3. Receives unicast echo from ESP32.
4. Verifies exact content match and prints send/roundtrip times.
