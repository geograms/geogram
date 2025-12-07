#!/usr/bin/env dart
/// Alert Sharing Test
///
/// This test suite:
/// - Launches a relay server on port 45691
/// - Creates a mock client with NOSTR keys
/// - Sends an alert event to the relay
/// - Verifies the relay stores it correctly
/// - Verifies the OK acknowledgment
///
/// Run with: dart bin/alert_sharing_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/cli/pure_relay.dart';
import '../lib/cli/pure_storage_config.dart';
import '../lib/util/nostr_event.dart';
import '../lib/util/nostr_crypto.dart';
import '../lib/util/nostr_key_generator.dart';
import '../lib/util/event_bus.dart';

const int TEST_PORT = 45691;
const String WS_URL = 'ws://localhost:$TEST_PORT';

// Test results tracking
int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

void pass(String test) {
  _passed++;
  print('  [PASS] $test');
}

void fail(String test, String reason) {
  _failed++;
  _failures.add('$test: $reason');
  print('  [FAIL] $test - $reason');
}

Future<void> main() async {
  print('');
  print('=' * 60);
  print('Geogram Alert Sharing Test Suite');
  print('=' * 60);
  print('');
  print('Test server port: $TEST_PORT');
  print('');

  // Setup temp directory for test data
  final tempDir = await Directory.systemTemp.createTemp('geogram_alert_test_');
  print('Using temp directory: ${tempDir.path}');

  PureRelayServer? relay;
  WebSocket? ws;

  try {
    // Initialize storage config
    PureStorageConfig().reset();
    await PureStorageConfig().init(customBaseDir: tempDir.path);

    // Create and initialize the relay server
    relay = PureRelayServer();
    relay.quietMode = true; // Suppress log output during tests
    await relay.initialize();

    // Configure relay settings
    relay.setSetting('httpPort', TEST_PORT);
    relay.setSetting('description', 'Alert Test Relay Server');

    // Get the relay callsign
    final relayCallsign = relay.settings.callsign;
    print('Relay callsign: $relayCallsign');

    // Start the server
    final started = await relay.start();
    if (!started) {
      print('ERROR: Failed to start relay server on port $TEST_PORT');
      exit(1);
    }
    print('Relay server started on port $TEST_PORT');
    print('');

    // Wait for server to be fully ready
    await Future.delayed(const Duration(milliseconds: 500));

    // Subscribe to AlertReceivedEvent
    AlertReceivedEvent? receivedAlert;
    final alertSubscription = EventBus().on<AlertReceivedEvent>((event) {
      receivedAlert = event;
      print('  EventBus received alert: ${event.folderName}');
    });

    // Run alert tests
    print('─' * 60);
    print('Testing Alert Sharing');
    print('─' * 60);

    // Generate test client keys
    final clientKeys = NostrKeyGenerator.generateKeyPair();
    final clientCallsign = NostrKeyGenerator.deriveCallsign(clientKeys.npub);
    print('Test client callsign: $clientCallsign');
    print('');

    // Test 1: Connect WebSocket
    print('Test 1: WebSocket Connection');
    try {
      ws = await WebSocket.connect(WS_URL);
      pass('WebSocket connected');
    } catch (e) {
      fail('WebSocket connection', e.toString());
      exit(1);
    }

    // Test 2: Send hello
    print('Test 2: Hello Handshake');
    final helloCompleter = Completer<Map<String, dynamic>>();
    final okCompleter = Completer<List<dynamic>>();

    // Single listener for all messages
    ws!.listen((data) {
      if (data is String) {
        // Check for JSON response
        if (data.startsWith('{')) {
          try {
            final msg = jsonDecode(data) as Map<String, dynamic>;
            if (msg['type'] == 'hello_response' || msg['type'] == 'hello_ack') {
              if (!helloCompleter.isCompleted) {
                helloCompleter.complete(msg);
              }
            }
          } catch (_) {}
        }
        // Check for OK response (array format)
        else if (data.startsWith('[')) {
          try {
            final arr = jsonDecode(data) as List<dynamic>;
            if (arr.isNotEmpty && arr[0] == 'OK') {
              print('  Received OK: eventId=${arr[1]}, success=${arr[2]}, message=${arr[3]}');
              if (!okCompleter.isCompleted) {
                okCompleter.complete(arr);
              }
            }
          } catch (_) {}
        }
      }
    });

    final helloEvent = NostrEvent.createHello(
      npub: clientKeys.npub,
      callsign: clientCallsign,
    );
    helloEvent.calculateId();
    helloEvent.signWithNsec(clientKeys.nsec);

    ws.add(jsonEncode({
      'type': 'hello',
      'event': helloEvent.toJson(),
    }));

    try {
      final helloResponse = await helloCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Hello response timeout'),
      );
      if (helloResponse['type'] == 'hello_response' || helloResponse['type'] == 'hello_ack') {
        pass('Hello acknowledged');
      } else {
        fail('Hello handshake', 'Unexpected response type: ${helloResponse['type']}');
      }
    } catch (e) {
      fail('Hello handshake', e.toString());
    }

    // Test 3: Send alert event
    print('Test 3: Send Alert Event');

    // Create a mock report content
    final reportContent = '''
# REPORT: Test Broken Sidewalk Alert

CREATED: 2025-12-06 10:30_00
AUTHOR: $clientCallsign
COORDINATES: 38.7223,-9.1393
SEVERITY: attention
TYPE: sidewalk-damage
STATUS: open
ADDRESS: Rua Test 123, Lisbon

This is a test alert for the sidewalk damage.
The sidewalk has a large crack that needs repair.

--> npub: ${clientKeys.npub}
''';

    // Create the alert NOSTR event manually (since we don't have Report model in CLI)
    final alertEvent = NostrEvent(
      pubkey: NostrCrypto.decodeNpub(clientKeys.npub),
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.applicationSpecificData,
      tags: [
        ['d', '38.7223_-9.1393_test-broken-sidewalk'],
        ['g', '38.7223,-9.1393'],
        ['t', 'alert'],
        ['severity', 'attention'],
        ['status', 'open'],
        ['type', 'sidewalk-damage'],
      ],
      content: reportContent,
    );
    alertEvent.calculateId();
    alertEvent.signWithNsec(clientKeys.nsec);

    print('  Alert event ID: ${alertEvent.id}');
    print('  Alert signed: ${alertEvent.sig != null}');

    // Send the alert event
    final nostrEventMessage = {
      'nostr_event': ['EVENT', alertEvent.toJson()],
    };
    ws.add(jsonEncode(nostrEventMessage));

    try {
      final okResponse = await okCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('OK response timeout'),
      );

      final eventId = okResponse[1] as String;
      final success = okResponse[2] as bool;
      final message = okResponse[3] as String;

      if (success && eventId == alertEvent.id) {
        pass('Alert sent and acknowledged (OK: $message)');
      } else {
        fail('Alert acknowledgment', 'success=$success, eventId match=${eventId == alertEvent.id}, message=$message');
      }
    } catch (e) {
      fail('Alert send', e.toString());
    }

    // Wait a bit for event processing
    await Future.delayed(const Duration(milliseconds: 500));

    // Test 4: Verify EventBus received the alert
    print('Test 4: EventBus Alert Event');
    if (receivedAlert != null) {
      if (receivedAlert!.eventId == alertEvent.id &&
          receivedAlert!.senderCallsign == clientCallsign &&
          receivedAlert!.severity == 'attention') {
        pass('EventBus received correct alert');
      } else {
        fail('EventBus alert', 'Alert data mismatch');
      }
    } else {
      fail('EventBus alert', 'No alert received on EventBus');
    }

    // Test 5: Verify alert stored on disk
    print('Test 5: Alert Storage');
    final devicesDir = PureStorageConfig().devicesDir;
    final alertFile = File('$devicesDir/$clientCallsign/alerts/38.7223_-9.1393_test-broken-sidewalk/report.txt');

    if (await alertFile.exists()) {
      final storedContent = await alertFile.readAsString();
      if (storedContent.contains('Test Broken Sidewalk Alert') &&
          storedContent.contains('SEVERITY: attention')) {
        pass('Alert stored correctly on disk');
        print('  Stored at: ${alertFile.path}');
      } else {
        fail('Alert storage', 'Content mismatch');
      }
    } else {
      fail('Alert storage', 'File not found: ${alertFile.path}');
    }

    // Cleanup
    alertSubscription.cancel();
    await ws.close();

    // Print summary
    print('');
    print('=' * 60);
    print('Test Summary');
    print('=' * 60);
    print('Passed: $_passed');
    print('Failed: $_failed');

    if (_failures.isNotEmpty) {
      print('');
      print('Failures:');
      for (final f in _failures) {
        print('  - $f');
      }
    }
    print('');

  } catch (e, st) {
    print('');
    print('FATAL ERROR: $e');
    print(st);
  } finally {
    // Cleanup
    await ws?.close();
    await relay?.stop();

    // Clean up temp directory
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }

  exit(_failed > 0 ? 1 : 0);
}
