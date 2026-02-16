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

## What it does

1. Scans for Geogram BLE devices.
2. Connects to the selected device.
3. Sends a `hello` frame.
4. Waits for `hello_ack`.
5. Confirms the peer also sent `hello` (bidirectional HELLO exchange).
