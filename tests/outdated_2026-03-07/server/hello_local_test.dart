#!/usr/bin/env dart
/// Local HELLO Handshake Test
///
/// Comprehensive tests for the HELLO handshake protocol.
/// Tests all supported event formats and edge cases.
///
/// Run with: dart tests/server/hello_local_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../lib/station.dart';
import '../../lib/cli/pure_storage_config.dart';
import '../../lib/util/nostr_event.dart';
import '../../lib/util/nostr_key_generator.dart';
import '../../lib/util/nostr_crypto.dart';

const int TEST_PORT = 45702;
const String WS_URL = 'ws://localhost:$TEST_PORT';

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
  print('Local HELLO Handshake Test');
  print('=' * 60);
  print('');

  // Create temp directory
  final tempDir = await Directory.systemTemp.createTemp('geogram_hello_test_');
  print('Using temp directory: ${tempDir.path}');
  print('Server port: $TEST_PORT');
  print('');

  late StationServer station;
  late NostrKeys testKeys;
  late String stationCallsign;

  try {
    // Initialize storage config
    PureStorageConfig().reset();
    await PureStorageConfig().init(customBaseDir: tempDir.path);

    // Create and configure server
    station = StationServer();
    station.quietMode = true;
    await station.initialize();
    station.setSetting('httpPort', TEST_PORT);

    // Generate test keys
    testKeys = NostrKeyGenerator.generateKeyPair();
    stationCallsign = station.settings.callsign;
    print('Test identity: ${testKeys.callsign}');
    print('Station: $stationCallsign');

    // Start server
    print('Starting server...');
    final started = await station.start();
    if (!started) {
      print('ERROR: Failed to start station server');
      exit(1);
    }
    await Future.delayed(const Duration(milliseconds: 500));
    print('Server started successfully');
    print('');

    // Run tests
    await testHelloWithSignedEvent(testKeys, stationCallsign);
    await testHelloWithEventAsMap(testKeys, stationCallsign);
    await testHelloWithEventAsString(testKeys, stationCallsign);
    await testHelloWithEventAsDynamicMap(testKeys, stationCallsign);
    await testHelloWithMinimalEvent(testKeys, stationCallsign);
    await testHelloWithUnsignedEvent(testKeys, stationCallsign);
    await testHelloWithoutEvent(testKeys, stationCallsign);
    await testHelloWithEmptyEvent(testKeys, stationCallsign);
    await testHelloWithInvalidEventString(testKeys, stationCallsign);
    await testPingPong();
    await testMultipleHellos(testKeys, stationCallsign);

    // Cleanup
    print('');
    print('Stopping server...');
    await station.stop();
  } catch (e, stackTrace) {
    print('ERROR: $e');
    print(stackTrace);
    exit(1);
  } finally {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }

  // Print summary
  print('');
  print('=' * 60);
  print('Test Summary');
  print('=' * 60);
  print('');
  print('Passed: $_passed');
  print('Failed: $_failed');
  print('Total:  ${_passed + _failed}');
  print('');

  if (_failures.isNotEmpty) {
    print('Failures:');
    for (final f in _failures) {
      print('  - $f');
    }
    print('');
  }

  exit(_failed > 0 ? 1 : 0);
}

/// Helper to send HELLO and get response
Future<Map<String, dynamic>> sendHello(Map<String, dynamic> hello) async {
  final ws = await WebSocket.connect(WS_URL);
  final responseCompleter = Completer<Map<String, dynamic>>();

  ws.listen((data) {
    try {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      if (message['type'] == 'hello_ack' && !responseCompleter.isCompleted) {
        responseCompleter.complete(message);
      }
    } catch (_) {}
  });

  ws.add(jsonEncode(hello));

  final response = await responseCompleter.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => {'error': 'timeout', 'type': 'timeout'},
  );

  await ws.close();
  return response;
}

// ============================================================================
// Test: Signed NOSTR Event (standard mobile/desktop client format)
// ============================================================================

Future<void> testHelloWithSignedEvent(NostrKeys keys, String stationCallsign) async {
  print('Test: HELLO with signed NOSTR event (standard format)...');
  try {
    // Create and sign event
    final helloEvent = NostrEvent.createHello(
      npub: keys.npub,
      callsign: keys.callsign,
      platform: 'Test',
    );
    helloEvent.calculateId();
    helloEvent.signWithNsec(keys.nsec);

    // Verify event is valid
    if (!helloEvent.verify()) {
      fail('Signed event', 'Event verification failed before sending');
      return;
    }

    final response = await sendHello({
      'type': 'hello',
      'callsign': keys.callsign,
      'event': helloEvent.toJson(),
    });

    if (response['type'] == 'hello_ack' && response['success'] == true) {
      if (response['station_id'] == stationCallsign) {
        pass('Signed event accepted with correct station_id');
      } else {
        fail('Signed event', 'Wrong station_id: ${response['station_id']}');
      }
    } else {
      fail('Signed event', 'Error: ${response['error'] ?? 'unknown'}');
    }
  } catch (e) {
    fail('Signed event', 'Error: $e');
  }
}

// ============================================================================
// Test: Event as Map (normal JSON parsing result)
// ============================================================================

Future<void> testHelloWithEventAsMap(NostrKeys keys, String stationCallsign) async {
  print('Test: HELLO with event as Map<String, dynamic>...');
  try {
    final helloEvent = NostrEvent.createHello(
      npub: keys.npub,
      callsign: keys.callsign,
      platform: 'Test',
    );
    helloEvent.calculateId();
    helloEvent.signWithNsec(keys.nsec);

    final response = await sendHello({
      'type': 'hello',
      'callsign': keys.callsign,
      'event': helloEvent.toJson(), // Map<String, dynamic>
    });

    if (response['type'] == 'hello_ack' && response['success'] == true) {
      pass('Event as Map accepted');
    } else {
      fail('Event as Map', 'Error: ${response['error'] ?? 'unknown'}');
    }
  } catch (e) {
    fail('Event as Map', 'Error: $e');
  }
}

// ============================================================================
// Test: Event as String (double-encoded - the bug we fixed)
// ============================================================================

Future<void> testHelloWithEventAsString(NostrKeys keys, String stationCallsign) async {
  print('Test: HELLO with event as String (double-encoded fix)...');
  try {
    final helloEvent = NostrEvent.createHello(
      npub: keys.npub,
      callsign: keys.callsign,
      platform: 'Test',
    );
    helloEvent.calculateId();
    helloEvent.signWithNsec(keys.nsec);

    // Send event as STRING instead of Map (the bug scenario)
    final response = await sendHello({
      'type': 'hello',
      'callsign': keys.callsign,
      'event': jsonEncode(helloEvent.toJson()), // STRING not Map!
    });

    if (response['type'] == 'hello_ack' && response['success'] == true) {
      pass('Event as String accepted (double-encode fix works)');
    } else if (response['error'] == 'timeout') {
      fail('Event as String', 'Timeout - double-encode fix not working');
    } else {
      fail('Event as String', 'Error: ${response['error'] ?? 'unknown'}');
    }
  } catch (e) {
    fail('Event as String', 'Error: $e');
  }
}

// ============================================================================
// Test: Event as dynamic Map (some JSON parsers produce this)
// ============================================================================

Future<void> testHelloWithEventAsDynamicMap(NostrKeys keys, String stationCallsign) async {
  print('Test: HELLO with event as Map<dynamic, dynamic>...');
  try {
    final pubkeyHex = NostrCrypto.decodeNpub(keys.npub);

    // Create a dynamic map (simulates some JSON parser outputs)
    final dynamicEvent = <dynamic, dynamic>{
      'pubkey': pubkeyHex,
      'tags': [['callsign', keys.callsign]],
      'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'kind': 1,
      'content': 'Hello from Test',
    };

    final response = await sendHello({
      'type': 'hello',
      'callsign': keys.callsign,
      'event': dynamicEvent,
    });

    if (response['type'] == 'hello_ack' && response['success'] == true) {
      pass('Dynamic Map event accepted');
    } else {
      fail('Dynamic Map event', 'Error: ${response['error'] ?? 'unknown'}');
    }
  } catch (e) {
    fail('Dynamic Map event', 'Error: $e');
  }
}

// ============================================================================
// Test: Minimal event (pubkey only - minimum required for npub)
// ============================================================================

Future<void> testHelloWithMinimalEvent(NostrKeys keys, String stationCallsign) async {
  print('Test: HELLO with minimal event (pubkey only)...');
  try {
    final pubkeyHex = NostrCrypto.decodeNpub(keys.npub);

    final response = await sendHello({
      'type': 'hello',
      'callsign': keys.callsign,
      'event': {'pubkey': pubkeyHex},
    });

    if (response['type'] == 'hello_ack' && response['success'] == true) {
      pass('Minimal event accepted (pubkey sufficient for npub)');
    } else {
      fail('Minimal event', 'Error: ${response['error'] ?? 'unknown'}');
    }
  } catch (e) {
    fail('Minimal event', 'Error: $e');
  }
}

// ============================================================================
// Test: Unsigned event (signature not required for HELLO)
// ============================================================================

Future<void> testHelloWithUnsignedEvent(NostrKeys keys, String stationCallsign) async {
  print('Test: HELLO with unsigned event...');
  try {
    final helloEvent = NostrEvent.createHello(
      npub: keys.npub,
      callsign: keys.callsign,
      platform: 'Test',
    );
    helloEvent.calculateId();
    // NOT signing the event

    final response = await sendHello({
      'type': 'hello',
      'callsign': keys.callsign,
      'event': helloEvent.toJson(),
    });

    if (response['type'] == 'hello_ack' && response['success'] == true) {
      pass('Unsigned event accepted');
    } else {
      fail('Unsigned event', 'Error: ${response['error'] ?? 'unknown'}');
    }
  } catch (e) {
    fail('Unsigned event', 'Error: $e');
  }
}

// ============================================================================
// Test: HELLO without event (should fail - npub required)
// ============================================================================

Future<void> testHelloWithoutEvent(NostrKeys keys, String stationCallsign) async {
  print('Test: HELLO without event (should be rejected)...');
  try {
    final response = await sendHello({
      'type': 'hello',
      'callsign': keys.callsign,
      'npub': keys.npub, // npub at top level is ignored
      'device_type': 'test',
    });

    if (response['type'] == 'hello_ack' && response['success'] == false) {
      if (response['error']?.toString().contains('npub') == true) {
        pass('HELLO without event rejected (npub required via event)');
      } else {
        pass('HELLO without event rejected: ${response['error']}');
      }
    } else if (response['success'] == true) {
      fail('HELLO without event', 'Should have been rejected');
    } else {
      pass('HELLO without event handled: ${response['error'] ?? 'rejected'}');
    }
  } catch (e) {
    fail('HELLO without event', 'Error: $e');
  }
}

// ============================================================================
// Test: HELLO with empty event object
// ============================================================================

Future<void> testHelloWithEmptyEvent(NostrKeys keys, String stationCallsign) async {
  print('Test: HELLO with empty event (should be rejected)...');
  try {
    final response = await sendHello({
      'type': 'hello',
      'callsign': keys.callsign,
      'event': {}, // Empty event - no pubkey
    });

    if (response['type'] == 'hello_ack' && response['success'] == false) {
      pass('Empty event rejected (no pubkey)');
    } else if (response['success'] == true) {
      fail('Empty event', 'Should have been rejected');
    } else {
      pass('Empty event handled');
    }
  } catch (e) {
    fail('Empty event', 'Error: $e');
  }
}

// ============================================================================
// Test: HELLO with invalid event string (malformed JSON)
// ============================================================================

Future<void> testHelloWithInvalidEventString(NostrKeys keys, String stationCallsign) async {
  print('Test: HELLO with invalid event string...');
  try {
    final response = await sendHello({
      'type': 'hello',
      'callsign': keys.callsign,
      'event': '{invalid json}', // Malformed JSON string
    });

    if (response['type'] == 'hello_ack' && response['success'] == false) {
      pass('Invalid event string rejected');
    } else if (response['success'] == true) {
      fail('Invalid event string', 'Should have been rejected');
    } else if (response['error'] == 'timeout') {
      fail('Invalid event string', 'Server timed out (should respond with error)');
    } else {
      pass('Invalid event string handled: ${response['error'] ?? 'rejected'}');
    }
  } catch (e) {
    fail('Invalid event string', 'Error: $e');
  }
}

// ============================================================================
// Test: PING/PONG (basic WebSocket health check)
// ============================================================================

Future<void> testPingPong() async {
  print('Test: PING/PONG...');
  try {
    final ws = await WebSocket.connect(WS_URL);
    final pongCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      try {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (message['type'] == 'PONG' && !pongCompleter.isCompleted) {
          pongCompleter.complete(message);
        }
      } catch (_) {}
    });

    ws.add(jsonEncode({'type': 'PING'}));

    final response = await pongCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => {'error': 'timeout'},
    );

    await ws.close();

    if (response['type'] == 'PONG' && response.containsKey('timestamp')) {
      pass('PING/PONG works');
    } else if (response['error'] == 'timeout') {
      fail('PING/PONG', 'No PONG received');
    } else {
      fail('PING/PONG', 'Unexpected response');
    }
  } catch (e) {
    fail('PING/PONG', 'Error: $e');
  }
}

// ============================================================================
// Test: Multiple HELLO messages (reconnection scenario)
// ============================================================================

Future<void> testMultipleHellos(NostrKeys keys, String stationCallsign) async {
  print('Test: Multiple HELLO messages (reconnection)...');
  try {
    final ws = await WebSocket.connect(WS_URL);
    var helloCount = 0;

    ws.listen((data) {
      try {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (message['type'] == 'hello_ack' && message['success'] == true) {
          helloCount++;
        }
      } catch (_) {}
    });

    // Create event
    final pubkeyHex = NostrCrypto.decodeNpub(keys.npub);

    // Send multiple HELLOs
    for (var i = 0; i < 3; i++) {
      ws.add(jsonEncode({
        'type': 'hello',
        'callsign': keys.callsign,
        'event': {'pubkey': pubkeyHex},
      }));
      await Future.delayed(const Duration(milliseconds: 100));
    }

    await Future.delayed(const Duration(milliseconds: 500));
    await ws.close();

    if (helloCount >= 3) {
      pass('Multiple HELLOs accepted ($helloCount responses)');
    } else {
      fail('Multiple HELLOs', 'Only $helloCount responses received');
    }
  } catch (e) {
    fail('Multiple HELLOs', 'Error: $e');
  }
}
