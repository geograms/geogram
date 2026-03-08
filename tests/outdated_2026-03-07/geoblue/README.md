# GeoBlue Linux CLI Test

This folder contains a standalone, non-Flutter test harness for the `geoblue` Dart library.

## Scripts

```bash
cd tests/geoblue
./run_hello_test.sh
```

Optional target address:

```bash
./run_hello_test.sh --address AA:BB:CC:DD:EE:FF
```

Forward unicast round-trip integrity/timing test (~1000-byte text payload):

```bash
./run_unicast_large_test.sh
```

Reverse unicast round-trip integrity/timing test (~1000-byte text payload):

```bash
./run_unicast_reverse_test.sh
```

Broadcast distribution test (desktop sender -> ESP32 listener receipt over BLE):

```bash
./run_broadcast_test.sh
```

All scripts accept `--address AA:BB:CC:DD:EE:FF` to force one target device.

## What Each Script Validates

For `run_hello_test.sh`:

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

For `run_unicast_reverse_test.sh`:

1. Performs HELLO handshake with capability `geoblue_reverse_unicast_test`.
2. Waits for ESP32-initiated unicast payload on `geoblue_reverse_unicast_test`.
3. Verifies payload matches `tests/geoblue/data/payload_1000.txt`.
4. Echoes it back on `geoblue_reverse_unicast_test_echo`.
5. Waits for ESP32 validation result on `geoblue_reverse_unicast_test_result`.

For `run_broadcast_test.sh`:

1. Sends one BLE `broadcast` frame from desktop with a unique token.
2. Waits for ESP32 to confirm listener delivery on channel `geoblue_broadcast_receipt`.
3. Prints pass/fail with delivery timing.
