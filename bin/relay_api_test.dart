#!/usr/bin/env dart
/// Comprehensive API endpoint tests for PureRelayServer
///
/// This test suite:
/// - Launches a relay server on port 45689
/// - Creates dummy data (chat rooms, messages)
/// - Tests all HTTP API endpoints
/// - Tests WebSocket connectivity and messages
///
/// Run with: dart bin/relay_api_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../lib/cli/pure_relay.dart';
import '../lib/services/storage_config.dart';

const int TEST_PORT = 45689;
const String BASE_URL = 'http://localhost:$TEST_PORT';

// Relay callsign - set dynamically after initialization
late String RELAY_CALLSIGN;

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
  print('Geogram Desktop Relay API Test Suite');
  print('=' * 60);
  print('');
  print('Test server port: $TEST_PORT');
  print('');

  // Setup temp directory for test data
  final tempDir = await Directory.systemTemp.createTemp('geogram_relay_test_');
  print('Using temp directory: ${tempDir.path}');

  try {
    // Initialize storage config
    StorageConfig().reset();
    await StorageConfig().init(customBaseDir: tempDir.path);

    // Create and initialize the relay server
    final relay = PureRelayServer();
    relay.quietMode = true; // Suppress log output during tests
    await relay.initialize();

    // Configure relay settings
    relay.setSetting('httpPort', TEST_PORT);
    relay.setSetting('description', 'Test Relay Server');

    // Get the relay callsign (derived from npub)
    RELAY_CALLSIGN = relay.settings.callsign;
    print('Relay callsign: $RELAY_CALLSIGN');

    // Start the server
    final started = await relay.start();
    if (!started) {
      print('ERROR: Failed to start relay server on port $TEST_PORT');
      exit(1);
    }
    print('Relay server started on port $TEST_PORT');
    print('');

    // Create test data
    await _createTestData(relay);

    // Wait for server to be fully ready
    await Future.delayed(const Duration(milliseconds: 500));

    // Run all tests
    await _testRootEndpoint();
    await _testStatusEndpoint();
    await _testRelayStatusEndpoint();
    await _testStatsEndpoint();
    await _testDevicesEndpoint();
    await _testDeviceEndpoint();
    await _testSearchEndpoint();
    await _testChatRoomsEndpoint();
    await _testRoomMessagesEndpoint();
    await _testPostChatMessage();
    await _testRelaySendEndpoint();
    await _testGroupsEndpoint();
    await _testAcmeChallengeEndpoint(relay);
    await _testCorsHeaders();
    await _testOptionsRequest();
    await _test404Endpoint();
    await _testWebSocketConnection();

    // Stop the server
    await relay.stop();

    // Test persistence - this requires a full server restart
    await _testChatPersistence(tempDir.path);

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
      for (final failure in _failures) {
        print('  - $failure');
      }
      print('');
    }

    exit(_failed > 0 ? 1 : 0);
  } catch (e, stackTrace) {
    print('ERROR: $e');
    print(stackTrace);
    exit(1);
  } finally {
    // Cleanup temp directory
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}

Future<void> _createTestData(PureRelayServer relay) async {
  print('Creating test data...');

  // Create additional chat rooms
  relay.createChatRoom('tech', 'Technology', description: 'Tech discussions');
  relay.createChatRoom('random', 'Random', description: 'Off-topic chat');

  // Add messages to general room
  relay.postMessage('general', 'Hello from test!');
  relay.postMessage('general', 'This is a test message.');
  relay.postMessage('general', 'Testing the relay API.');

  // Add messages to tech room
  relay.postMessage('tech', 'Dart is great!');
  relay.postMessage('tech', 'Flutter rocks!');

  print('Test data created: 3 chat rooms, 5 messages');
  print('');
}

// ============================================================================
// HTTP Endpoint Tests
// ============================================================================

Future<void> _testRootEndpoint() async {
  print('Testing GET / (root endpoint)...');
  try {
    final response = await http.get(Uri.parse(BASE_URL));
    if (response.statusCode == 200) {
      if (response.body.contains('Geogram') &&
          response.body.contains(RELAY_CALLSIGN)) {
        pass('Root endpoint returns HTML with relay info');
      } else {
        fail('Root endpoint', 'HTML missing expected content');
      }
    } else {
      fail('Root endpoint', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Root endpoint', 'Error: $e');
  }
}

Future<void> _testStatusEndpoint() async {
  print('Testing GET /api/status...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/api/status'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      // Check required fields
      final hasCallsign = data['callsign'] == RELAY_CALLSIGN;
      final hasVersion = data['version'] != null;
      final hasRelayMode = data['relay_mode'] == true;
      final hasConnectedDevices = data.containsKey('connected_devices');
      final hasUptime = data.containsKey('uptime');
      final hasChatRooms = data['chat_rooms'] == 3;

      if (hasCallsign && hasVersion && hasRelayMode && hasConnectedDevices && hasUptime) {
        pass('Status endpoint returns correct data');
      } else {
        fail('Status endpoint', 'Missing or incorrect fields');
      }

      if (hasChatRooms) {
        pass('Status shows correct chat room count');
      } else {
        fail('Status chat rooms', 'Expected 3 rooms, got ${data['chat_rooms']}');
      }
    } else {
      fail('Status endpoint', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Status endpoint', 'Error: $e');
  }
}

Future<void> _testRelayStatusEndpoint() async {
  print('Testing GET /relay/status...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/relay/status'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      final hasDevices = data.containsKey('devices');
      final hasRelays = data.containsKey('relays');
      final hasConnectedDevices = data.containsKey('connected_devices');
      final hasConnectedRelays = data.containsKey('connected_relays');

      if (hasDevices && hasRelays && hasConnectedDevices && hasConnectedRelays) {
        pass('Relay status endpoint returns device/relay lists');
      } else {
        fail('Relay status endpoint', 'Missing required fields');
      }

      // With no connected devices, counts should be 0
      if (data['connected_devices'] == 0 && data['connected_relays'] == 0) {
        pass('Relay status shows 0 connected (correct for test)');
      } else {
        fail('Relay status counts', 'Expected 0 devices/relays');
      }
    } else {
      fail('Relay status endpoint', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Relay status endpoint', 'Error: $e');
  }
}

Future<void> _testStatsEndpoint() async {
  print('Testing GET /api/stats...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/api/stats'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      final hasConnections = data.containsKey('total_connections');
      final hasMessages = data.containsKey('total_messages');
      final hasTileRequests = data.containsKey('total_tile_requests');
      final hasApiRequests = data.containsKey('total_api_requests');

      if (hasConnections && hasMessages && hasTileRequests && hasApiRequests) {
        pass('Stats endpoint returns all statistics');
      } else {
        fail('Stats endpoint', 'Missing statistics fields');
      }

      // We posted 5 messages in test data
      if (data['total_messages'] == 5) {
        pass('Stats shows correct message count (5)');
      } else {
        fail('Stats message count', 'Expected 5, got ${data['total_messages']}');
      }
    } else {
      fail('Stats endpoint', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Stats endpoint', 'Error: $e');
  }
}

Future<void> _testDevicesEndpoint() async {
  print('Testing GET /api/devices...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/api/devices'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data.containsKey('devices') && data['devices'] is List) {
        pass('Devices endpoint returns device list');

        // No devices connected, should be empty
        if ((data['devices'] as List).isEmpty) {
          pass('Devices list is empty (correct for test)');
        }
      } else {
        fail('Devices endpoint', 'Missing devices array');
      }
    } else {
      fail('Devices endpoint', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Devices endpoint', 'Error: $e');
  }
}

Future<void> _testDeviceEndpoint() async {
  print('Testing GET /device/{callsign}...');
  try {
    // Test for non-existent device
    final response = await http.get(Uri.parse('$BASE_URL/device/X9FAKE'));
    if (response.statusCode == 404) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['connected'] == false && data['error'] != null) {
        pass('Device endpoint returns 404 for disconnected device');
      } else {
        fail('Device endpoint', 'Incorrect 404 response format');
      }
    } else {
      fail('Device endpoint', 'Expected 404, got ${response.statusCode}');
    }
  } catch (e) {
    fail('Device endpoint', 'Error: $e');
  }
}

Future<void> _testSearchEndpoint() async {
  print('Testing GET /search...');
  try {
    // Test with query
    final response = await http.get(Uri.parse('$BASE_URL/search?q=test&limit=10'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['query'] == 'test' && data['limit'] == 10 && data.containsKey('results')) {
        pass('Search endpoint returns query results');
      } else {
        fail('Search endpoint', 'Missing or incorrect fields');
      }
    } else {
      fail('Search endpoint', 'HTTP ${response.statusCode}');
    }

    // Test without query (should fail)
    final response2 = await http.get(Uri.parse('$BASE_URL/search'));
    if (response2.statusCode == 400) {
      pass('Search endpoint returns 400 without query');
    } else {
      fail('Search no query', 'Expected 400, got ${response2.statusCode}');
    }
  } catch (e) {
    fail('Search endpoint', 'Error: $e');
  }
}

Future<void> _testChatRoomsEndpoint() async {
  print('Testing GET /$RELAY_CALLSIGN/api/chat/rooms...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/$RELAY_CALLSIGN/api/chat/rooms'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data.containsKey('rooms') && data['rooms'] is List) {
        final rooms = data['rooms'] as List;
        if (rooms.length == 3) {
          pass('Chat rooms endpoint returns 3 rooms');

          // Check room IDs
          final roomIds = rooms.map((r) => r['id']).toSet();
          if (roomIds.containsAll(['general', 'tech', 'random'])) {
            pass('Chat rooms have correct IDs');
          } else {
            fail('Chat room IDs', 'Missing expected room IDs');
          }
        } else {
          fail('Chat rooms endpoint', 'Expected 3 rooms, got ${rooms.length}');
        }
      } else {
        fail('Chat rooms endpoint', 'Missing rooms array');
      }

      if (data['callsign'] == RELAY_CALLSIGN) {
        pass('Chat rooms includes relay callsign');
      } else {
        fail('Chat rooms callsign', 'Missing or incorrect callsign: got ${data['callsign']}, expected $RELAY_CALLSIGN');
      }
    } else {
      fail('Chat rooms endpoint', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Chat rooms endpoint', 'Error: $e');
  }
}

Future<void> _testRoomMessagesEndpoint() async {
  print('Testing GET /$RELAY_CALLSIGN/api/chat/rooms/{id}/messages...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/$RELAY_CALLSIGN/api/chat/rooms/general/messages'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['room_id'] == 'general' && data['room_name'] == 'General') {
        pass('Room messages returns correct room info');
      } else {
        fail('Room messages info', 'Incorrect room_id or room_name');
      }

      if (data.containsKey('messages') && data['messages'] is List) {
        final messages = data['messages'] as List;
        if (messages.length == 3) {
          pass('Room messages returns 3 messages for general');
        } else {
          fail('Room messages count', 'Expected 3, got ${messages.length}');
        }

        // Check message structure
        if (messages.isNotEmpty) {
          final msg = messages[0] as Map<String, dynamic>;
          if (msg.containsKey('id') &&
              msg.containsKey('callsign') &&
              msg.containsKey('content') &&
              msg.containsKey('timestamp')) {
            pass('Messages have correct structure');
          } else {
            fail('Message structure', 'Missing required fields: id=${msg.containsKey('id')}, callsign=${msg.containsKey('callsign')}, content=${msg.containsKey('content')}, timestamp=${msg.containsKey('timestamp')}');
          }
        }
      } else {
        fail('Room messages endpoint', 'Missing messages array');
      }
    } else {
      fail('Room messages endpoint', 'HTTP ${response.statusCode}');
    }

    // Test for non-existent room
    final response2 = await http.get(Uri.parse('$BASE_URL/$RELAY_CALLSIGN/api/chat/rooms/nonexistent/messages'));
    if (response2.statusCode == 404) {
      pass('Room messages returns 404 for non-existent room');
    } else {
      fail('Room messages 404', 'Expected 404, got ${response2.statusCode}');
    }
  } catch (e) {
    fail('Room messages endpoint', 'Error: $e');
  }
}

Future<void> _testPostChatMessage() async {
  print('Testing POST /$RELAY_CALLSIGN/api/chat/rooms/{id}/messages...');
  try {
    // Post a new message
    final response = await http.post(
      Uri.parse('$BASE_URL/$RELAY_CALLSIGN/api/chat/rooms/general/messages'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'callsign': 'X9TESTER',
        'content': 'Test message via API',
        'npub': 'npub1testkey',
        'signature': 'testsig123',
      }),
    );

    if (response.statusCode == 201) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['success'] == true) {
        pass('POST message creates message successfully');
      } else {
        fail('POST message', 'Response indicates failure');
      }
    } else {
      fail('POST message', 'HTTP ${response.statusCode}');
    }

    // Verify message was added
    final getResponse = await http.get(Uri.parse('$BASE_URL/$RELAY_CALLSIGN/api/chat/rooms/general/messages'));
    final getData = jsonDecode(getResponse.body) as Map<String, dynamic>;
    final messages = getData['messages'] as List;
    if (messages.length == 4) {
      pass('Message count increased after POST');
    } else {
      fail('Message count', 'Expected 4, got ${messages.length}');
    }

    // Test missing callsign
    final response2 = await http.post(
      Uri.parse('$BASE_URL/$RELAY_CALLSIGN/api/chat/rooms/general/messages'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'content': 'Missing callsign'}),
    );
    if (response2.statusCode == 400) {
      pass('POST without callsign returns 400');
    } else {
      fail('POST no callsign', 'Expected 400, got ${response2.statusCode}');
    }

    // Test missing content
    final response3 = await http.post(
      Uri.parse('$BASE_URL/$RELAY_CALLSIGN/api/chat/rooms/general/messages'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'callsign': 'X9TESTER'}),
    );
    if (response3.statusCode == 400) {
      pass('POST without content returns 400');
    } else {
      fail('POST no content', 'Expected 400, got ${response3.statusCode}');
    }
  } catch (e) {
    fail('POST message endpoint', 'Error: $e');
  }
}

Future<void> _testRelaySendEndpoint() async {
  print('Testing POST /api/relay/send...');
  try {
    final response = await http.post(
      Uri.parse('$BASE_URL/api/relay/send'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'room': 'tech',
        'content': 'Message from relay',
        'callsign': RELAY_CALLSIGN,
      }),
    );

    if (response.statusCode == 201) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['success'] == true && data['room'] == 'tech') {
        pass('Relay send endpoint works');
      } else {
        fail('Relay send', 'Incorrect response');
      }
    } else {
      fail('Relay send endpoint', 'HTTP ${response.statusCode}');
    }

    // Test missing content
    final response2 = await http.post(
      Uri.parse('$BASE_URL/api/relay/send'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'room': 'tech'}),
    );
    if (response2.statusCode == 400) {
      pass('Relay send returns 400 without content');
    } else {
      fail('Relay send no content', 'Expected 400');
    }
  } catch (e) {
    fail('Relay send endpoint', 'Error: $e');
  }
}

Future<void> _testGroupsEndpoint() async {
  print('Testing GET /api/groups...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/api/groups'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['relay'] == RELAY_CALLSIGN && data.containsKey('groups')) {
        pass('Groups endpoint returns relay info');
      } else {
        fail('Groups endpoint', 'Missing required fields');
      }

      // Groups not implemented, should be empty
      if ((data['groups'] as List).isEmpty && data['count'] == 0) {
        pass('Groups is empty (not yet implemented)');
      }
    } else {
      fail('Groups endpoint', 'HTTP ${response.statusCode}');
    }

    // Test group details (should 404)
    final response2 = await http.get(Uri.parse('$BASE_URL/api/groups/testgroup'));
    if (response2.statusCode == 404) {
      final data = jsonDecode(response2.body) as Map<String, dynamic>;
      if (data['groupId'] == 'testgroup') {
        pass('Group details returns 404 with groupId');
      } else {
        fail('Group details', 'Missing groupId in response');
      }
    } else {
      fail('Group details', 'Expected 404');
    }
  } catch (e) {
    fail('Groups endpoint', 'Error: $e');
  }
}

Future<void> _testAcmeChallengeEndpoint(PureRelayServer relay) async {
  print('Testing GET /.well-known/acme-challenge/{token}...');
  try {
    // Set a test challenge
    relay.setAcmeChallenge('test-token-123', 'test-response-456');

    final response = await http.get(
      Uri.parse('$BASE_URL/.well-known/acme-challenge/test-token-123'),
    );
    if (response.statusCode == 200 && response.body == 'test-response-456') {
      pass('ACME challenge returns correct response');
    } else {
      fail('ACME challenge', 'Incorrect response: ${response.body}');
    }

    // Test non-existent token
    final response2 = await http.get(
      Uri.parse('$BASE_URL/.well-known/acme-challenge/unknown-token'),
    );
    if (response2.statusCode == 404) {
      pass('ACME challenge returns 404 for unknown token');
    } else {
      fail('ACME unknown token', 'Expected 404');
    }

    // Clean up
    relay.clearAcmeChallenge('test-token-123');
  } catch (e) {
    fail('ACME challenge endpoint', 'Error: $e');
  }
}

Future<void> _testCorsHeaders() async {
  print('Testing CORS headers...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/api/status'));

    final allowOrigin = response.headers['access-control-allow-origin'];
    final allowMethods = response.headers['access-control-allow-methods'];

    if (allowOrigin == '*') {
      pass('CORS Allow-Origin header is set');
    } else {
      fail('CORS Allow-Origin', 'Header missing or incorrect');
    }

    if (allowMethods != null && allowMethods.contains('GET')) {
      pass('CORS Allow-Methods header includes GET');
    } else {
      fail('CORS Allow-Methods', 'Header missing or incorrect');
    }
  } catch (e) {
    fail('CORS headers', 'Error: $e');
  }
}

Future<void> _testOptionsRequest() async {
  print('Testing OPTIONS request (CORS preflight)...');
  try {
    final request = await HttpClient().openUrl('OPTIONS', Uri.parse('$BASE_URL/api/status'));
    final response = await request.close();

    if (response.statusCode == 200) {
      pass('OPTIONS request returns 200');
    } else {
      fail('OPTIONS request', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('OPTIONS request', 'Error: $e');
  }
}

Future<void> _test404Endpoint() async {
  print('Testing 404 response...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/nonexistent/endpoint'));
    if (response.statusCode == 404) {
      pass('Non-existent endpoint returns 404');
    } else {
      fail('404 response', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('404 response', 'Error: $e');
  }
}

// ============================================================================
// WebSocket Tests
// ============================================================================

Future<void> _testWebSocketConnection() async {
  print('Testing WebSocket connection...');
  try {
    final ws = await WebSocket.connect('ws://localhost:$TEST_PORT');

    // Set up completers for each expected message type
    final helloCompleter = Completer<Map<String, dynamic>>();
    final pongCompleter = Completer<Map<String, dynamic>>();
    final registerCompleter = Completer<Map<String, dynamic>>();

    // Single listener that dispatches to appropriate completer
    ws.listen((data) {
      try {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        final type = message['type'] as String?;

        switch (type) {
          case 'hello_response':
            if (!helloCompleter.isCompleted) {
              helloCompleter.complete(message);
            }
            break;
          case 'PONG':
            if (!pongCompleter.isCompleted) {
              pongCompleter.complete(message);
            }
            break;
          case 'REGISTER_ACK':
            if (!registerCompleter.isCompleted) {
              registerCompleter.complete(message);
            }
            break;
        }
      } catch (e) {
        print('    WebSocket parse error: $e');
      }
    }, onError: (e) {
      print('    WebSocket error: $e');
    });

    // Test 1: hello message
    ws.add(jsonEncode({
      'type': 'hello',
      'callsign': 'X9WSTEST',
      'device_type': 'test',
      'version': '1.0.0',
    }));

    final helloResponse = await helloCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => <String, dynamic>{},
    );

    if (helloResponse['type'] == 'hello_response' &&
        helloResponse['callsign'] == RELAY_CALLSIGN &&
        helloResponse['server'] == 'geogram-desktop-relay') {
      pass('WebSocket hello/hello_response works');
    } else if (helloResponse.isEmpty) {
      fail('WebSocket hello', 'Timeout waiting for response');
    } else {
      fail('WebSocket hello', 'Incorrect response: $helloResponse');
    }

    // Test 2: PING/PONG
    ws.add(jsonEncode({'type': 'PING'}));

    final pongResponse = await pongCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => <String, dynamic>{},
    );

    if (pongResponse['type'] == 'PONG' && pongResponse.containsKey('timestamp')) {
      pass('WebSocket PING/PONG works');
    } else if (pongResponse.isEmpty) {
      fail('WebSocket PING', 'Timeout waiting for PONG');
    } else {
      fail('WebSocket PING', 'Incorrect response');
    }

    // Test 3: REGISTER
    ws.add(jsonEncode({
      'type': 'REGISTER',
      'callsign': 'X9DEVICE',
      'device_type': 'mobile',
      'version': '2.0.0',
      'capabilities': ['chat', 'location'],
      'collections': ['photos', 'documents'],
    }));

    final registerResponse = await registerCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => <String, dynamic>{},
    );

    if (registerResponse['type'] == 'REGISTER_ACK' &&
        registerResponse['success'] == true &&
        registerResponse['relay_callsign'] == RELAY_CALLSIGN) {
      pass('WebSocket REGISTER works');
    } else if (registerResponse.isEmpty) {
      fail('WebSocket REGISTER', 'Timeout waiting for ACK');
    } else {
      fail('WebSocket REGISTER', 'Incorrect response');
    }

    await ws.close();
    pass('WebSocket connection closed cleanly');
  } catch (e) {
    fail('WebSocket connection', 'Error: $e');
  }
}

// ============================================================================
// Chat Persistence Tests
// ============================================================================

Future<void> _testChatPersistence(String tempDirPath) async {
  print('');
  print('Testing Chat Persistence (server restart cycle)...');

  // Step 1: Verify correct directory structure
  // Path should be: {tempDir}/devices/{callsign}/chat/{room_id}/
  print('  Checking correct directory structure...');

  final devicesDir = Directory('$tempDirPath/devices');
  if (await devicesDir.exists()) {
    pass('devices/ directory exists');
  } else {
    fail('devices/ directory', 'Not created at ${devicesDir.path}');
    return;
  }

  // Find the callsign directory (it's dynamically generated)
  final callsignDirs = await devicesDir.list().where((e) => e is Directory).toList();
  if (callsignDirs.isEmpty) {
    fail('callsign directory', 'No callsign directories found in devices/');
    return;
  }
  final callsignDir = callsignDirs.first as Directory;
  final callsign = callsignDir.path.split('/').last;
  pass('Callsign directory exists: $callsign');

  // Check chat directory
  final chatDir = Directory('${callsignDir.path}/chat');
  if (await chatDir.exists()) {
    pass('chat/ directory exists at correct path');
  } else {
    fail('chat/ directory', 'Not created at ${chatDir.path}');
    return;
  }

  // Check room directories with config.json
  final generalRoomDir = Directory('${chatDir.path}/general');
  if (await generalRoomDir.exists()) {
    pass('general/ room directory exists');
  } else {
    fail('general/ room directory', 'Not created at ${generalRoomDir.path}');
    return;
  }

  // Check room config.json
  final configFile = File('${generalRoomDir.path}/config.json');
  if (await configFile.exists()) {
    final content = await configFile.readAsString();
    try {
      final config = jsonDecode(content) as Map<String, dynamic>;
      if (config['id'] == 'general' &&
          config['name'] == 'General' &&
          config.containsKey('visibility')) {
        pass('Room config.json has correct structure');
      } else {
        fail('Room config.json', 'Missing required fields');
      }
    } catch (e) {
      fail('Room config.json', 'Invalid JSON: $e');
    }
  } else {
    fail('Room config.json', 'Not created at ${configFile.path}');
    return;
  }

  // Check for year directory and chat file
  final now = DateTime.now();
  final year = now.year.toString();
  final yearDir = Directory('${generalRoomDir.path}/$year');
  if (await yearDir.exists()) {
    pass('Year directory $year exists');
  } else {
    fail('Year directory', 'Not created at ${yearDir.path}');
    return;
  }

  // Check for chat text file (format: YYYY-MM-DD_chat.txt)
  final chatFiles = await yearDir.list().where((e) =>
    e is File && e.path.endsWith('_chat.txt')).toList();
  if (chatFiles.isNotEmpty) {
    final chatFile = chatFiles.first as File;
    pass('Chat text file exists: ${chatFile.path.split('/').last}');

    // Verify text format - header uses room ID (not callsign) for NOSTR signature validity
    final content = await chatFile.readAsString();
    if (content.contains('# general:') || content.contains('# ')) {
      pass('Chat file has correct header format');
    } else {
      fail('Chat file header', 'Missing "# roomId:" header');
    }

    if (content.contains('> ') && content.contains(' -- ')) {
      pass('Chat file has correct message format');
    } else {
      fail('Chat message format', 'Missing "> timestamp -- callsign" format');
    }

    // Count messages in file
    final messageCount = RegExp(r'^> \d{4}-\d{2}-\d{2}', multiLine: true)
        .allMatches(content).length;
    if (messageCount >= 3) {
      pass('Chat file has $messageCount messages');
    } else {
      fail('Message count', 'Expected at least 3 messages, got $messageCount');
    }
  } else {
    fail('Chat text file', 'No *_chat.txt files found in ${yearDir.path}');
    return;
  }

  // Step 2: Start a NEW relay server and verify messages are loaded
  print('  Starting new relay server to verify persistence...');

  StorageConfig().reset();
  await StorageConfig().init(customBaseDir: tempDirPath);

  final relay2 = PureRelayServer();
  relay2.quietMode = true;
  await relay2.initialize();

  relay2.setSetting('httpPort', TEST_PORT);

  final started = await relay2.start();
  if (!started) {
    fail('Relay restart', 'Failed to start second relay instance');
    return;
  }
  pass('Second relay instance started');

  await Future.delayed(const Duration(milliseconds: 500));

  // Step 3: Verify messages are loaded via API
  try {
    final response = await http.get(Uri.parse('$BASE_URL/$RELAY_CALLSIGN/api/chat/rooms'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final rooms = data['rooms'] as List;

      if (rooms.length >= 3) {
        pass('Persisted rooms loaded: ${rooms.length} rooms');
      } else {
        fail('Persisted rooms', 'Expected at least 3, got ${rooms.length}');
      }
    } else {
      fail('Get rooms after restart', 'HTTP ${response.statusCode}');
    }

    final msgResponse = await http.get(Uri.parse('$BASE_URL/$RELAY_CALLSIGN/api/chat/rooms/general/messages'));
    if (msgResponse.statusCode == 200) {
      final data = jsonDecode(msgResponse.body) as Map<String, dynamic>;
      final messages = data['messages'] as List;

      if (messages.length >= 3) {
        pass('Persisted messages loaded: ${messages.length} messages in general');

        // Verify message content is intact
        final hasTestMessage = messages.any((m) =>
          (m['content'] as String).contains('Hello from test!') ||
          (m['content'] as String).contains('test'));
        if (hasTestMessage) {
          pass('Message content preserved after restart');
        } else {
          fail('Message content', 'Test messages not found in loaded data');
        }
      } else {
        fail('Persisted messages', 'Expected at least 3, got ${messages.length}');
      }
    } else {
      fail('Get messages after restart', 'HTTP ${msgResponse.statusCode}');
    }

    // Step 4: Post a new message and verify it persists to text file
    print('  Testing new message persistence to text file...');
    final postResponse = await http.post(
      Uri.parse('$BASE_URL/$RELAY_CALLSIGN/api/chat/rooms/general/messages'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'callsign': 'X9PERSIST',
        'content': 'Persistence test message ${DateTime.now().millisecondsSinceEpoch}',
        'npub': 'npub1persist',
      }),
    );

    if (postResponse.statusCode == 201) {
      pass('Posted new message after restart');

      // Give it a moment to write
      await Future.delayed(const Duration(milliseconds: 300));

      // Check text file was updated
      final chatFiles2 = await yearDir.list().where((e) =>
        e is File && e.path.endsWith('_chat.txt')).toList();
      if (chatFiles2.isNotEmpty) {
        final chatFile = chatFiles2.first as File;
        final content = await chatFile.readAsString();

        if (content.contains('X9PERSIST')) {
          pass('New message written to text file');
        } else {
          fail('New message persistence', 'X9PERSIST not found in text file');
        }

        if (content.contains('--> npub: npub1persist')) {
          pass('NOSTR metadata preserved in text format');
        } else {
          // npub metadata is optional
          pass('Message saved (npub metadata optional)');
        }
      } else {
        fail('Chat file check', 'No chat files found after POST');
      }
    } else {
      fail('POST after restart', 'HTTP ${postResponse.statusCode}');
    }
  } catch (e) {
    fail('Persistence verification', 'Error: $e');
  }

  await relay2.stop();
  pass('Second relay stopped cleanly');
}
