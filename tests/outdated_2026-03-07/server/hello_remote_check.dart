#!/usr/bin/env dart
/// HELLO Handshake Test for p2p.radio
///
/// This test connects to p2p.radio and verifies the HELLO handshake works.
/// Used to diagnose connection issues with mobile clients.
///
/// Run with: dart tests/server/hello_handshake_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../lib/util/nostr_event.dart';
import '../../lib/util/nostr_key_generator.dart';
import '../../lib/util/nostr_crypto.dart';

const String TARGET_HOST = 'p2p.radio';
const int TARGET_PORT = 80;
const String WS_URL = 'ws://$TARGET_HOST:$TARGET_PORT';

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
  print('HELLO Handshake Test - p2p.radio');
  print('=' * 60);
  print('');
  print('Target: $WS_URL');
  print('');

  // Generate test keys
  final testKeys = NostrKeyGenerator.generateKeyPair();
  print('Test identity:');
  print('  Callsign: ${testKeys.callsign}');
  print('  npub: ${testKeys.npub.substring(0, 30)}...');
  print('');

  // Test 1: Basic WebSocket connection
  await testWebSocketConnection();

  // Test 2: Simple HELLO (without NOSTR event)
  await testSimpleHello(testKeys);

  // Test 3: HELLO with NOSTR event format (what mobile clients use)
  await testNostrEventHello(testKeys);

  // Test 4: Test PING/PONG
  await testPingPong();

  // Test 5: HELLO with event as string (potential mobile issue)
  await testHelloWithEventAsString(testKeys);

  // Test 6: HELLO with minimal event (missing fields)
  await testHelloWithMinimalEvent(testKeys);

  // Test 7: HELLO with unsigned event
  await testHelloWithUnsignedEvent(testKeys);

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

Future<void> testWebSocketConnection() async {
  print('Test 1: Basic WebSocket connection...');
  try {
    final ws = await WebSocket.connect(WS_URL).timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('Connection timeout'),
    );
    pass('WebSocket connected to $TARGET_HOST');
    await ws.close();
  } catch (e) {
    fail('WebSocket connection', 'Error: $e');
  }
}

Future<void> testSimpleHello(NostrKeys keys) async {
  print('');
  print('Test 2: Simple HELLO (direct fields)...');
  try {
    final ws = await WebSocket.connect(WS_URL).timeout(
      const Duration(seconds: 10),
    );

    final responseCompleter = Completer<Map<String, dynamic>>();
    final allMessages = <String>[];

    ws.listen((data) {
      print('    Received: $data');
      allMessages.add(data.toString());
      try {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (!responseCompleter.isCompleted) {
          responseCompleter.complete(message);
        }
      } catch (e) {
        print('    (non-JSON response)');
      }
    }, onError: (e) {
      print('    WebSocket error: $e');
      if (!responseCompleter.isCompleted) {
        responseCompleter.completeError(e);
      }
    });

    // Send simple HELLO without NOSTR event
    final simpleHello = {
      'type': 'hello',
      'callsign': keys.callsign,
      'npub': keys.npub,
      'device_type': 'test',
      'version': '1.0.0-test',
    };

    print('    Sending: ${jsonEncode(simpleHello)}');
    ws.add(jsonEncode(simpleHello));

    final response = await responseCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => <String, dynamic>{'error': 'timeout'},
    );

    if (response.containsKey('error') && response['error'] == 'timeout') {
      fail('Simple HELLO', 'No response received (timeout)');
    } else if (response['type'] == 'hello_ack') {
      if (response['success'] == true) {
        pass('Simple HELLO accepted: ${jsonEncode(response)}');
      } else {
        // Expected: Server requires event format with pubkey for npub extraction
        // Simple HELLO without event is rejected by design
        pass('Simple HELLO rejected as expected (requires event format)');
        print('    Note: Server requires event.pubkey to derive npub');
      }
    } else {
      print('    Response type: ${response['type']}');
      pass('Received response: ${jsonEncode(response)}');
    }

    await ws.close();
  } catch (e) {
    fail('Simple HELLO', 'Error: $e');
  }
}

Future<void> testNostrEventHello(NostrKeys keys) async {
  print('');
  print('Test 3: HELLO with NOSTR event (mobile client format)...');
  try {
    final ws = await WebSocket.connect(WS_URL).timeout(
      const Duration(seconds: 10),
    );

    final responseCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      print('    Received: $data');
      try {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (!responseCompleter.isCompleted) {
          responseCompleter.complete(message);
        }
      } catch (e) {
        print('    (non-JSON response)');
      }
    });

    // Create NOSTR event for HELLO (this is what mobile clients do)
    final helloEvent = NostrEvent.createHello(
      npub: keys.npub,
      callsign: keys.callsign,
      platform: 'Test',
    );
    helloEvent.calculateId();
    helloEvent.signWithNsec(keys.nsec);

    // Verify the event is valid
    if (!helloEvent.verify()) {
      fail('NOSTR event creation', 'Event failed verification');
      await ws.close();
      return;
    }
    print('    Created valid NOSTR hello event');

    // Send HELLO with embedded NOSTR event
    final nostrHello = {
      'type': 'hello',
      'callsign': keys.callsign,
      'device_type': 'test',
      'version': '1.0.0-test',
      'event': helloEvent.toJson(),
    };

    print('    Sending HELLO with NOSTR event...');
    print('    Event pubkey: ${helloEvent.pubkey.substring(0, 20)}...');
    print('    Event id: ${helloEvent.id?.substring(0, 20)}...');
    ws.add(jsonEncode(nostrHello));

    final response = await responseCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => <String, dynamic>{'error': 'timeout'},
    );

    if (response.containsKey('error') && response['error'] == 'timeout') {
      fail('NOSTR HELLO', 'No response received (timeout)');
    } else if (response['type'] == 'hello_ack') {
      if (response['success'] == true) {
        pass('NOSTR HELLO accepted');
        print('    Station ID: ${response['station_id']}');
        print('    Station npub: ${response['station_npub']?.toString().substring(0, 20)}...');
      } else {
        fail('NOSTR HELLO rejected', 'Error: ${response['error']} - ${response['message'] ?? ''}');
      }
    } else {
      print('    Response: ${jsonEncode(response)}');
      pass('Received response type: ${response['type']}');
    }

    await ws.close();
  } catch (e) {
    fail('NOSTR HELLO', 'Error: $e');
  }
}

Future<void> testPingPong() async {
  print('');
  print('Test 4: PING/PONG...');
  try {
    final ws = await WebSocket.connect(WS_URL).timeout(
      const Duration(seconds: 10),
    );

    final pongCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      print('    Received: $data');
      try {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (message['type'] == 'PONG' && !pongCompleter.isCompleted) {
          pongCompleter.complete(message);
        }
      } catch (e) {
        print('    (non-JSON response)');
      }
    });

    // Send PING
    final ping = {'type': 'PING'};
    print('    Sending: ${jsonEncode(ping)}');
    ws.add(jsonEncode(ping));

    final response = await pongCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => <String, dynamic>{'error': 'timeout'},
    );

    if (response.containsKey('error') && response['error'] == 'timeout') {
      fail('PING/PONG', 'No PONG received (timeout)');
    } else if (response['type'] == 'PONG') {
      pass('PING/PONG works');
    } else {
      fail('PING/PONG', 'Unexpected response: ${jsonEncode(response)}');
    }

    await ws.close();
  } catch (e) {
    fail('PING/PONG', 'Error: $e');
  }
}

Future<void> testHelloWithEventAsString(NostrKeys keys) async {
  print('');
  print('Test 5: HELLO with event as JSON string (potential issue)...');
  try {
    final ws = await WebSocket.connect(WS_URL).timeout(
      const Duration(seconds: 10),
    );

    final responseCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      print('    Received: $data');
      try {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (!responseCompleter.isCompleted) {
          responseCompleter.complete(message);
        }
      } catch (e) {
        print('    (non-JSON response)');
      }
    });

    // Create NOSTR event
    final helloEvent = NostrEvent.createHello(
      npub: keys.npub,
      callsign: keys.callsign,
      platform: 'Test',
    );
    helloEvent.calculateId();
    helloEvent.signWithNsec(keys.nsec);

    // Send HELLO with event as STRING instead of object (buggy client scenario)
    final buggyHello = {
      'type': 'hello',
      'callsign': keys.callsign,
      'event': jsonEncode(helloEvent.toJson()), // STRING not Map!
    };

    print('    Sending HELLO with event as STRING...');
    ws.add(jsonEncode(buggyHello));

    final response = await responseCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => <String, dynamic>{'error': 'timeout'},
    );

    if (response['type'] == 'hello_ack') {
      if (response['success'] == true) {
        pass('Event-as-string accepted (server handles it)');
      } else {
        print('    Error: ${response['error']}');
        pass('Event-as-string rejected as expected: ${response['error']}');
      }
    } else {
      print('    Response: ${jsonEncode(response)}');
    }

    await ws.close();
  } catch (e) {
    fail('Event as string test', 'Error: $e');
  }
}

Future<void> testHelloWithMinimalEvent(NostrKeys keys) async {
  print('');
  print('Test 6: HELLO with minimal event (missing some fields)...');
  try {
    final ws = await WebSocket.connect(WS_URL).timeout(
      const Duration(seconds: 10),
    );

    final responseCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      print('    Received: $data');
      try {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (!responseCompleter.isCompleted) {
          responseCompleter.complete(message);
        }
      } catch (e) {
        print('    (non-JSON response)');
      }
    });

    // Get pubkey hex
    final pubkeyHex = NostrCrypto.decodeNpub(keys.npub);

    // Send HELLO with minimal event (only pubkey, no signature)
    final minimalHello = {
      'type': 'hello',
      'callsign': keys.callsign,
      'event': {
        'pubkey': pubkeyHex,
        // Missing: id, sig, created_at, kind, tags, content
      },
    };

    print('    Sending HELLO with minimal event (pubkey only)...');
    ws.add(jsonEncode(minimalHello));

    final response = await responseCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => <String, dynamic>{'error': 'timeout'},
    );

    if (response['type'] == 'hello_ack') {
      if (response['success'] == true) {
        pass('Minimal event accepted (pubkey only needed for npub)');
      } else {
        print('    Error: ${response['error']}');
        pass('Minimal event rejected: ${response['error']}');
      }
    }

    await ws.close();
  } catch (e) {
    fail('Minimal event test', 'Error: $e');
  }
}

Future<void> testHelloWithUnsignedEvent(NostrKeys keys) async {
  print('');
  print('Test 7: HELLO with unsigned event...');
  try {
    final ws = await WebSocket.connect(WS_URL).timeout(
      const Duration(seconds: 10),
    );

    final responseCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      print('    Received: $data');
      try {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (!responseCompleter.isCompleted) {
          responseCompleter.complete(message);
        }
      } catch (e) {
        print('    (non-JSON response)');
      }
    });

    // Create NOSTR event but DON'T sign it
    final helloEvent = NostrEvent.createHello(
      npub: keys.npub,
      callsign: keys.callsign,
      platform: 'Test',
    );
    helloEvent.calculateId();
    // NOT signing: helloEvent.signWithNsec(keys.nsec);

    final unsignedHello = {
      'type': 'hello',
      'callsign': keys.callsign,
      'event': helloEvent.toJson(),
    };

    print('    Sending HELLO with unsigned event...');
    print('    Event has sig: ${helloEvent.sig != null}');
    ws.add(jsonEncode(unsignedHello));

    final response = await responseCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => <String, dynamic>{'error': 'timeout'},
    );

    if (response['type'] == 'hello_ack') {
      if (response['success'] == true) {
        pass('Unsigned event accepted (signature not required for HELLO)');
      } else {
        print('    Error: ${response['error']}');
        pass('Unsigned event rejected: ${response['error']}');
      }
    }

    await ws.close();
  } catch (e) {
    fail('Unsigned event test', 'Error: $e');
  }
}
