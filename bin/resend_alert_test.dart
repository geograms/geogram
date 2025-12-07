#!/usr/bin/env dart
/// Relay Connectivity Test
///
/// This test creates a fresh signed alert and sends it to p2p.radio
/// to test relay connectivity.
///
/// Run with: dart bin/resend_alert_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/util/nostr_event.dart';
import '../lib/util/nostr_crypto.dart';
import '../lib/util/nostr_key_generator.dart';

const String WS_URL = 'wss://p2p.radio';

Future<void> main() async {
  print('');
  print('=' * 60);
  print('Relay Connectivity Test');
  print('=' * 60);
  print('');
  print('Relay: $WS_URL');
  print('');

  // Generate fresh keys for this test
  final keys = NostrKeyGenerator.generateKeyPair();
  final callsign = NostrKeyGenerator.deriveCallsign(keys.npub);

  print('Test client:');
  print('  Callsign: $callsign');
  print('  Npub: ${keys.npub.substring(0, 20)}...');
  print('');

  // Create a test alert
  final reportContent = '''# REPORT: Test Alert from CLI

CREATED: 2025-12-06 23:50_00
AUTHOR: $callsign
COORDINATES: 49.651711,8.632715
SEVERITY: info
TYPE: test
STATUS: open

This is a test alert to verify relay connectivity.
--> npub: ${keys.npub}
''';

  // Create the NOSTR event
  final pubkeyHex = NostrCrypto.decodeNpub(keys.npub);
  final alertEvent = NostrEvent(
    pubkey: pubkeyHex,
    createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    kind: NostrEventKind.applicationSpecificData,
    tags: [
      ['d', '49.651711_8.632715_test-alert-from-cli'],
      ['g', '49.651711,8.632715'],
      ['t', 'alert'],
      ['severity', 'info'],
      ['status', 'open'],
      ['type', 'test'],
    ],
    content: reportContent,
  );

  // Calculate ID and sign
  alertEvent.calculateId();
  alertEvent.signWithNsec(keys.nsec);

  print('Event created:');
  print('  ID: ${alertEvent.id}');
  print('  Kind: ${alertEvent.kind}');
  print('  Signed: ${alertEvent.sig != null}');
  print('');

  // Verify our own signature
  print('Verifying signature...');
  final isValid = alertEvent.verify();
  print('Signature valid: $isValid');
  print('');

  if (!isValid) {
    print('ERROR: Self-verification failed!');
    exit(1);
  }

  // Connect to relay
  print('Connecting to $WS_URL...');
  WebSocket? ws;

  try {
    ws = await WebSocket.connect(WS_URL);
    print('Connected!');
    print('');
  } catch (e) {
    print('ERROR: Failed to connect: $e');
    exit(1);
  }

  // Set up response listener
  final okCompleter = Completer<List<dynamic>>();

  ws.listen((data) {
    print('Received: $data');
    if (data is String && data.startsWith('[')) {
      try {
        final arr = jsonDecode(data) as List<dynamic>;
        if (arr.isNotEmpty && arr[0] == 'OK') {
          if (!okCompleter.isCompleted) {
            okCompleter.complete(arr);
          }
        }
      } catch (_) {}
    }
  });

  // Send the alert event
  print('Sending alert event...');
  final nostrEventMessage = {
    'nostr_event': ['EVENT', alertEvent.toJson()],
  };
  ws.add(jsonEncode(nostrEventMessage));

  // Wait for response
  try {
    final okResponse = await okCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('OK response timeout'),
    );

    final respEventId = okResponse[1] as String;
    final success = okResponse[2] as bool;
    final message = okResponse[3] as String;

    print('');
    print('Response received:');
    print('  Event ID: $respEventId');
    print('  Success: $success');
    print('  Message: $message');

    if (success) {
      print('');
      print('✓ Alert successfully sent to relay!');
    } else {
      print('');
      print('✗ Relay rejected the alert: $message');
    }
  } catch (e) {
    print('');
    print('ERROR: $e');
    print('');
    print('The relay may not be receiving or processing our message.');
    print('Check if the relay is running and accepting connections.');
  }

  // Cleanup
  await ws.close();
  print('');
  print('Done.');
}
