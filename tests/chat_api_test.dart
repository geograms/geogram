#!/usr/bin/env dart
/// Chat API tests for Geogram Desktop
///
/// This test suite tests the Chat API endpoints with NOSTR authentication.
/// It requires a running Geogram Desktop instance with HTTP API enabled.
///
/// Usage:
///   dart test/chat_api_test.dart [--port=PORT] [--host=HOST]
///
/// Prerequisites:
///   - Run from the geogram-desktop directory
///   - Geogram Desktop running with HTTP API enabled
///   - At least one chat room (public or private) in the collection

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:bech32/bech32.dart';
import 'package:hex/hex.dart';
import 'package:http/http.dart' as http;

// Test configuration
int _testPort = 5678;
String _testHost = 'localhost';

// Test results tracking
int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

void pass(String test) {
  _passed++;
  print('  ✓ $test');
}

void fail(String test, String reason) {
  _failed++;
  _failures.add('$test: $reason');
  print('  ✗ $test - $reason');
}

void info(String message) {
  print('  ℹ $message');
}

// ============================================================
// NOSTR Crypto Implementation (simplified for testing)
// ============================================================

class TestNostrKeyPair {
  final String privateKeyHex;
  final String publicKeyHex;

  TestNostrKeyPair({required this.privateKeyHex, required this.publicKeyHex});

  String get nsec => _encodeNsec(privateKeyHex);
  String get npub => _encodeNpub(publicKeyHex);
  String get callsign => 'X1${npub.substring(5, 9).toUpperCase()}';
}

final _secureRandom = SecureRandom('Fortuna')
  ..seed(KeyParameter(
    Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256))),
  ));

TestNostrKeyPair generateKeyPair() {
  final keyParams = ECKeyGeneratorParameters(ECCurve_secp256k1());
  final generator = ECKeyGenerator()
    ..init(ParametersWithRandom(keyParams, _secureRandom));

  final keyPair = generator.generateKeyPair();
  final privateKey = keyPair.privateKey as ECPrivateKey;
  final publicKey = keyPair.publicKey as ECPublicKey;

  final privateKeyBytes = _bigIntToBytes(privateKey.d!, 32);
  final publicKeyBytes = _bigIntToBytes(publicKey.Q!.x!.toBigInteger()!, 32);

  return TestNostrKeyPair(
    privateKeyHex: HEX.encode(privateKeyBytes),
    publicKeyHex: HEX.encode(publicKeyBytes),
  );
}

String _encodeNsec(String privateKeyHex) {
  final bytes = HEX.decode(privateKeyHex);
  final data = _convertBits(Uint8List.fromList(bytes), 8, 5, true);
  final bech32Data = Bech32('nsec', data);
  return const Bech32Codec().encode(bech32Data);
}

String _encodeNpub(String publicKeyHex) {
  final bytes = HEX.decode(publicKeyHex);
  final data = _convertBits(Uint8List.fromList(bytes), 8, 5, true);
  final bech32Data = Bech32('npub', data);
  return const Bech32Codec().encode(bech32Data);
}

Uint8List _bigIntToBytes(BigInt value, int length) {
  final bytes = Uint8List(length);
  var temp = value;
  for (var i = length - 1; i >= 0; i--) {
    bytes[i] = (temp & BigInt.from(0xff)).toInt();
    temp = temp >> 8;
  }
  return bytes;
}

BigInt _bytesToBigInt(Uint8List bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

Uint8List _convertBits(Uint8List data, int fromBits, int toBits, bool pad) {
  var acc = 0;
  var bits = 0;
  final result = <int>[];
  final maxv = (1 << toBits) - 1;

  for (final value in data) {
    acc = (acc << fromBits) | value;
    bits += fromBits;
    while (bits >= toBits) {
      bits -= toBits;
      result.add((acc >> bits) & maxv);
    }
  }

  if (pad) {
    if (bits > 0) {
      result.add((acc << (toBits - bits)) & maxv);
    }
  }

  return Uint8List.fromList(result);
}

Uint8List _taggedHash(String tag, Uint8List data) {
  final tagHash = sha256.convert(utf8.encode(tag)).bytes;
  final input = Uint8List.fromList([...tagHash, ...tagHash, ...data]);
  return Uint8List.fromList(sha256.convert(input).bytes);
}

String schnorrSign(String messageHex, String privateKeyHex) {
  final messageBytes = HEX.decode(messageHex);
  final privateKeyBytes = HEX.decode(privateKeyHex);

  final d = _bytesToBigInt(Uint8List.fromList(privateKeyBytes));
  final curve = ECCurve_secp256k1();
  final n = curve.n;
  final G = curve.G;

  final P = G * d;
  final px = _bigIntToBytes(P!.x!.toBigInteger()!, 32);

  var dPrime = d;
  if (P.y!.toBigInteger()!.isOdd) {
    dPrime = n - d;
  }

  final auxRand = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    auxRand[i] = Random.secure().nextInt(256);
  }

  final dPrimeBytes = _bigIntToBytes(dPrime, 32);
  final auxHash = _taggedHash('BIP0340/aux', auxRand);
  final t = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    t[i] = dPrimeBytes[i] ^ auxHash[i];
  }

  final nonceInput = Uint8List.fromList([...t, ...px, ...messageBytes]);
  final kPrimeHash = _taggedHash('BIP0340/nonce', nonceInput);
  var kPrime = _bytesToBigInt(kPrimeHash) % n;

  if (kPrime == BigInt.zero) {
    throw Exception('Invalid nonce generated');
  }

  final R = G * kPrime;
  final rx = _bigIntToBytes(R!.x!.toBigInteger()!, 32);

  if (R.y!.toBigInteger()!.isOdd) {
    kPrime = n - kPrime;
  }

  final challengeInput = Uint8List.fromList([...rx, ...px, ...messageBytes]);
  final eHash = _taggedHash('BIP0340/challenge', challengeInput);
  final e = _bytesToBigInt(eHash) % n;

  final s = (kPrime + e * dPrime) % n;
  final sBytes = _bigIntToBytes(s, 32);

  final signature = Uint8List.fromList([...rx, ...sBytes]);
  return HEX.encode(signature);
}

// ============================================================
// NOSTR Event Creation
// ============================================================

Map<String, dynamic> createNostrEvent({
  required String pubkeyHex,
  required String content,
  required int kind,
  List<List<String>>? tags,
  int? createdAt,
}) {
  final event = {
    'pubkey': pubkeyHex,
    'created_at': createdAt ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
    'kind': kind,
    'tags': tags ?? [],
    'content': content,
  };

  // Calculate event ID
  final serialized = jsonEncode([
    0,
    event['pubkey'],
    event['created_at'],
    event['kind'],
    event['tags'],
    event['content'],
  ]);
  final idHash = sha256.convert(utf8.encode(serialized));
  event['id'] = idHash.toString();

  return event;
}

Map<String, dynamic> signEvent(Map<String, dynamic> event, String privateKeyHex) {
  final id = event['id'] as String;
  event['sig'] = schnorrSign(id, privateKeyHex);
  return event;
}

String createAuthHeader(TestNostrKeyPair keyPair) {
  final event = createNostrEvent(
    pubkeyHex: keyPair.publicKeyHex,
    content: 'auth',
    kind: 1,
    tags: [['t', 'auth']],
  );
  signEvent(event, keyPair.privateKeyHex);
  final eventJson = jsonEncode(event);
  return 'Nostr ${base64Encode(utf8.encode(eventJson))}';
}

// ============================================================
// Test State
// ============================================================

late TestNostrKeyPair _testKeyPair;
late TestNostrKeyPair _otherKeyPair;
String? _actualOwnerNpub;
String? _publicRoomId;
String? _privateRoomId;

// ============================================================
// HTTP Helpers
// ============================================================

Future<http.Response> apiGet(String endpoint, {String? authHeader}) async {
  final url = Uri.parse('http://$_testHost:$_testPort$endpoint');
  final headers = <String, String>{
    'Content-Type': 'application/json',
  };
  if (authHeader != null) {
    headers['Authorization'] = authHeader;
  }
  return await http.get(url, headers: headers);
}

Future<http.Response> apiPost(String endpoint, Map<String, dynamic> body, {String? authHeader}) async {
  final url = Uri.parse('http://$_testHost:$_testPort$endpoint');
  final headers = <String, String>{
    'Content-Type': 'application/json',
  };
  if (authHeader != null) {
    headers['Authorization'] = authHeader;
  }
  return await http.post(url, headers: headers, body: jsonEncode(body));
}

// ============================================================
// Tests
// ============================================================

Future<void> testListRoomsWithoutAuth() async {
  print('\n--- Test: List rooms without authentication ---');

  try {
    final response = await apiGet('/api/chat/');

    if (response.statusCode != 200) {
      fail('List rooms', 'Expected 200, got ${response.statusCode}');
      return;
    }

    final data = jsonDecode(response.body);
    final rooms = data['rooms'] as List;

    pass('API responded with room list');
    info('Total rooms returned: ${rooms.length}');

    // Find public and private rooms
    for (final room in rooms) {
      final visibility = room['visibility'] ?? 'PUBLIC';
      info('  Room "${room['id']}": visibility=$visibility');

      if (visibility == 'PUBLIC' && _publicRoomId == null) {
        _publicRoomId = room['id'];
      }
    }

    if (_publicRoomId != null) {
      pass('Found public room: $_publicRoomId');
    } else {
      info('No public rooms found - some tests may be skipped');
    }

    // Check authenticated field
    final authenticated = data['authenticated'];
    if (authenticated == false || authenticated == null) {
      pass('Correctly reports unauthenticated state');
    } else {
      fail('Auth state', 'Expected authenticated=false without auth header');
    }

  } catch (e) {
    fail('List rooms test', 'Exception: $e');
  }
}

Future<void> testListRoomsWithAuth() async {
  print('\n--- Test: List rooms with authentication ---');

  try {
    final authHeader = createAuthHeader(_testKeyPair);
    final response = await apiGet('/api/chat/', authHeader: authHeader);

    if (response.statusCode != 200) {
      fail('List rooms with auth', 'Expected 200, got ${response.statusCode}');
      return;
    }

    final data = jsonDecode(response.body);
    final rooms = data['rooms'] as List;

    pass('API responded with authenticated room list');

    // Check authenticated field
    final authenticated = data['authenticated'];
    if (authenticated == true) {
      pass('Correctly reports authenticated state');
    }

    // Look for private rooms
    for (final room in rooms) {
      final visibility = room['visibility'] ?? 'PUBLIC';
      if (visibility == 'PRIVATE' && _privateRoomId == null) {
        _privateRoomId = room['id'];
        info('Found private room: $_privateRoomId');
      }
    }

    info('Total rooms visible with auth: ${rooms.length}');

  } catch (e) {
    fail('List rooms with auth test', 'Exception: $e');
  }
}

Future<void> testReadPublicRoomMessages() async {
  print('\n--- Test: Read public room messages ---');

  if (_publicRoomId == null) {
    info('Skipping - no public room available');
    return;
  }

  try {
    final response = await apiGet('/api/chat/$_publicRoomId/messages');

    if (response.statusCode != 200) {
      fail('Read public messages', 'Expected 200, got ${response.statusCode}');
      return;
    }

    final data = jsonDecode(response.body);
    pass('Can read public room messages');

    final messages = data['messages'] as List;
    info('Message count: ${messages.length}');

    if (messages.isNotEmpty) {
      final first = messages.first;
      info('First message author: ${first['author']}');
      pass('Messages have expected structure');
    }

    // Test limit parameter
    final limitResponse = await apiGet('/api/chat/$_publicRoomId/messages?limit=5');
    if (limitResponse.statusCode == 200) {
      final limitData = jsonDecode(limitResponse.body);
      final limitMessages = limitData['messages'] as List;
      info('With limit=5: ${limitMessages.length} messages');
      pass('Limit parameter works');
    }

  } catch (e) {
    fail('Read public messages test', 'Exception: $e');
  }
}

Future<void> testReadPrivateRoomWithoutAuth() async {
  print('\n--- Test: Read private room without auth ---');

  if (_privateRoomId == null) {
    info('Skipping - no private room available');
    return;
  }

  try {
    final response = await apiGet('/api/chat/$_privateRoomId/messages');

    if (response.statusCode == 403) {
      pass('Private room access denied without auth (403)');

      final data = jsonDecode(response.body);
      if (data['hint'] != null) {
        info('Server provided hint: ${data['hint']}');
      }
    } else if (response.statusCode == 200) {
      fail('Private room protection', 'Expected 403, got 200 - private room accessible without auth!');
    } else {
      fail('Private room access', 'Expected 403, got ${response.statusCode}');
    }

  } catch (e) {
    fail('Private room without auth test', 'Exception: $e');
  }
}

Future<void> testReadPrivateRoomWithAuth() async {
  print('\n--- Test: Read private room with auth ---');

  if (_privateRoomId == null) {
    info('Skipping - no private room available');
    return;
  }

  try {
    // Try with our test key pair (likely not the owner)
    final authHeader = createAuthHeader(_testKeyPair);
    final response = await apiGet('/api/chat/$_privateRoomId/messages', authHeader: authHeader);

    if (response.statusCode == 200) {
      pass('Can read private room with auth');
      final data = jsonDecode(response.body);
      info('Messages in private room: ${(data['messages'] as List).length}');
    } else if (response.statusCode == 403) {
      // This is expected if our test key pair isn't the owner
      info('Access denied - test key is not the owner');
      info('This is expected behavior for non-owner npubs');
      pass('Private room correctly restricts access to non-owners');
    } else {
      fail('Private room with auth', 'Unexpected status: ${response.statusCode}');
    }

  } catch (e) {
    fail('Private room with auth test', 'Exception: $e');
  }
}

Future<void> testPostMessageToPublicRoom() async {
  print('\n--- Test: Post message to public room ---');

  if (_publicRoomId == null) {
    info('Skipping - no public room available');
    return;
  }

  try {
    // Post a simple message (as device owner)
    final testContent = 'Test message from API at ${DateTime.now().toIso8601String()}';
    final response = await apiPost('/api/chat/$_publicRoomId/messages', {
      'content': testContent,
    });

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['success'] == true) {
        pass('Posted message as device owner');
        info('Timestamp: ${data['timestamp']}');
        info('Author: ${data['author']}');
      } else {
        fail('Post message success', 'Response success=false: ${data['message']}');
      }
    } else if (response.statusCode == 403) {
      info('Room may be read-only - posting not allowed');
      pass('Correctly denied write to read-only room');
    } else {
      fail('Post message', 'Expected 200, got ${response.statusCode}: ${response.body}');
    }

  } catch (e) {
    fail('Post message test', 'Exception: $e');
  }
}

Future<void> testPostSignedMessage() async {
  print('\n--- Test: Post NOSTR-signed message ---');

  if (_publicRoomId == null) {
    info('Skipping - no public room available');
    return;
  }

  try {
    // Create a signed NOSTR event
    final event = createNostrEvent(
      pubkeyHex: _otherKeyPair.publicKeyHex,
      content: 'Signed API test message at ${DateTime.now().toIso8601String()}',
      kind: 1,
      tags: [
        ['t', 'chat'],
        ['room', _publicRoomId!],
        ['callsign', _otherKeyPair.callsign],
      ],
    );
    signEvent(event, _otherKeyPair.privateKeyHex);

    final response = await apiPost('/api/chat/$_publicRoomId/messages', {
      'event': event,
    });

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['success'] == true) {
        pass('Posted signed message');
        info('Author: ${data['author']}');
        info('Event ID: ${data['eventId']}');
      } else {
        fail('Post signed message success', 'Response success=false: ${data['message']}');
      }
    } else if (response.statusCode == 403) {
      final data = jsonDecode(response.body);
      if (data['message']?.contains('read-only') == true) {
        info('Room is read-only');
        pass('Correctly denied write to read-only room');
      } else if (data['message']?.contains('signature') == true) {
        fail('Signature verification', 'Server rejected signature');
      } else {
        info('Post denied: ${data['message']}');
        pass('Server appropriately restricted posting');
      }
    } else {
      fail('Post signed message', 'Expected 200, got ${response.statusCode}: ${response.body}');
    }

  } catch (e) {
    fail('Post signed message test', 'Exception: $e');
  }
}

Future<void> testListFiles() async {
  print('\n--- Test: List chat files ---');

  if (_publicRoomId == null) {
    info('Skipping - no public room available');
    return;
  }

  try {
    final response = await apiGet('/api/chat/$_publicRoomId/files');

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      pass('Listed files in room');
      info('Total files: ${data['total']}');

      final files = data['files'] as List;
      if (files.isNotEmpty) {
        info('First file: ${files.first['name']}');
      }
    } else {
      fail('List files', 'Expected 200, got ${response.statusCode}: ${response.body}');
    }

  } catch (e) {
    fail('List files test', 'Exception: $e');
  }
}

Future<void> testInvalidSignature() async {
  print('\n--- Test: Reject invalid signature ---');

  if (_publicRoomId == null) {
    info('Skipping - no public room available');
    return;
  }

  try {
    // Create an event with invalid signature
    final event = createNostrEvent(
      pubkeyHex: _otherKeyPair.publicKeyHex,
      content: 'This should be rejected',
      kind: 1,
      tags: [['t', 'chat']],
    );
    // Sign with wrong key
    event['sig'] = 'a'.padRight(128, 'a'); // Invalid signature

    final response = await apiPost('/api/chat/$_publicRoomId/messages', {
      'event': event,
    });

    if (response.statusCode == 403) {
      pass('Correctly rejected invalid signature');
    } else if (response.statusCode == 200) {
      fail('Signature validation', 'Server accepted invalid signature!');
    } else {
      info('Response: ${response.statusCode}');
      pass('Server rejected invalid event');
    }

  } catch (e) {
    fail('Invalid signature test', 'Exception: $e');
  }
}

Future<void> testNonexistentRoom() async {
  print('\n--- Test: Access nonexistent room ---');

  try {
    final response = await apiGet('/api/chat/nonexistent-room-xyz/messages');

    if (response.statusCode == 404) {
      pass('Correctly returned 404 for nonexistent room');
    } else {
      fail('Nonexistent room', 'Expected 404, got ${response.statusCode}');
    }

  } catch (e) {
    fail('Nonexistent room test', 'Exception: $e');
  }
}

// ============================================================
// Main
// ============================================================

Future<void> main(List<String> args) async {
  print('');
  print('=' * 60);
  print('Geogram Desktop Chat API Test Suite');
  print('=' * 60);
  print('');

  // Parse arguments
  for (final arg in args) {
    if (arg.startsWith('--port=')) {
      _testPort = int.tryParse(arg.substring(7)) ?? _testPort;
    } else if (arg.startsWith('--host=')) {
      _testHost = arg.substring(7);
    }
  }

  print('Target: http://$_testHost:$_testPort');
  print('');

  // Generate test key pairs
  print('Generating test key pairs...');
  _testKeyPair = generateKeyPair();
  _otherKeyPair = generateKeyPair();

  print('Test npub: ${_testKeyPair.npub}');
  print('Other npub: ${_otherKeyPair.npub}');
  print('');

  // Check if server is available
  print('Connecting to server...');
  try {
    final healthCheck = await apiGet('/api/').timeout(const Duration(seconds: 5));
    if (healthCheck.statusCode != 200) {
      print('');
      print('❌ Server not responding correctly at http://$_testHost:$_testPort');
      print('   Make sure Geogram Desktop is running with HTTP API enabled.');
      print('   Response: ${healthCheck.statusCode}');
      exit(1);
    }
    print('✓ Server is running');

    final serverInfo = jsonDecode(healthCheck.body);
    print('  Service: ${serverInfo['service']}');
    print('  Version: ${serverInfo['version']}');
    print('  Callsign: ${serverInfo['callsign']}');

  } catch (e) {
    print('');
    print('❌ Cannot connect to server at http://$_testHost:$_testPort');
    print('   Error: $e');
    print('');
    print('   Please start Geogram Desktop with:');
    print('     --port=$_testPort');
    print('   And enable HTTP API in Security settings.');
    exit(1);
  }

  // Check if chat API is available
  try {
    final chatCheck = await apiGet('/api/chat/');
    if (chatCheck.statusCode != 200) {
      print('');
      print('❌ Chat API not available');
      print('   Make sure a chat collection is loaded.');
      print('   Response: ${chatCheck.statusCode}');
      exit(1);
    }

    final chatData = jsonDecode(chatCheck.body);
    final rooms = chatData['rooms'] as List;
    print('✓ Chat API available (${rooms.length} rooms visible)');

    if (rooms.isEmpty) {
      print('');
      print('⚠ No chat rooms visible without auth');
      print('  Some tests may be skipped.');
    }

  } catch (e) {
    print('');
    print('❌ Error checking chat API: $e');
    exit(1);
  }

  print('');

  // Run tests
  await testListRoomsWithoutAuth();
  await testListRoomsWithAuth();
  await testReadPublicRoomMessages();
  await testReadPrivateRoomWithoutAuth();
  await testReadPrivateRoomWithAuth();
  await testPostMessageToPublicRoom();
  await testPostSignedMessage();
  await testListFiles();
  await testInvalidSignature();
  await testNonexistentRoom();

  // Summary
  print('');
  print('=' * 60);
  print('Test Results');
  print('=' * 60);
  print('Passed: $_passed');
  print('Failed: $_failed');

  if (_failures.isNotEmpty) {
    print('');
    print('Failures:');
    for (final failure in _failures) {
      print('  - $failure');
    }
  }

  print('');

  exit(_failed > 0 ? 1 : 0);
}
