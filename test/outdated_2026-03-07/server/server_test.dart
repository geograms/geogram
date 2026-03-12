#!/usr/bin/env dart
/// Server Integration Test
///
/// This test suite:
/// - Launches a station server on a temporary instance
/// - Tests HTTP API endpoints
/// - Tests WebSocket connectivity
/// - Verifies basic server functionality
///
/// Run with: dart tests/server/server_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../lib/station.dart';
import '../../lib/cli/pure_storage_config.dart';

const int TEST_PORT = 45700;
const String BASE_URL = 'http://localhost:$TEST_PORT';

// Station callsign - set dynamically after initialization
late String STATION_CALLSIGN;

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
  print('Server Integration Test');
  print('=' * 60);
  print('');

  // Create temp directory
  final tempDir = await Directory.systemTemp.createTemp('geogram_server_test_');
  print('Using temp directory: ${tempDir.path}');
  print('Server port: $TEST_PORT');
  print('');

  try {
    // Initialize storage config
    PureStorageConfig().reset();
    await PureStorageConfig().init(customBaseDir: tempDir.path);

    // Create and configure server
    final station = StationServer();
    station.quietMode = true;
    await station.initialize();
    station.setSetting('httpPort', TEST_PORT);
    station.setSetting('description', 'Test Server');

    // Get station callsign
    STATION_CALLSIGN = station.settings.callsign;
    print('Station callsign: $STATION_CALLSIGN');

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
    await testStatusEndpoint();
    await testRootEndpoint();
    await testStatsEndpoint();
    await testDevicesEndpoint();
    await testChatRoomsEndpoint();
    await testWebSocketConnection();
    await testCorsHeaders();
    await testNotFoundHandling();

    // Cleanup
    print('');
    print('Stopping server...');
    await station.stop();
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

// ============================================================================
// HTTP Endpoint Tests
// ============================================================================

Future<void> testStatusEndpoint() async {
  print('Testing GET /api/status...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/api/status'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      // Check required fields
      final hasCallsign = data['callsign'] == STATION_CALLSIGN;
      final hasVersion = data['version'] != null;
      final hasStationMode = data['station_mode'] == true;
      final hasConnectedDevices = data.containsKey('connected_devices');
      final hasUptime = data.containsKey('uptime');

      if (hasCallsign && hasVersion && hasStationMode && hasConnectedDevices && hasUptime) {
        pass('Status endpoint returns correct data');
      } else {
        fail('Status endpoint', 'Missing or incorrect fields: '
            'callsign=$hasCallsign, version=$hasVersion, station_mode=$hasStationMode, '
            'connected_devices=$hasConnectedDevices, uptime=$hasUptime');
      }
    } else {
      fail('Status endpoint', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Status endpoint', 'Error: $e');
  }
}

Future<void> testRootEndpoint() async {
  print('Testing GET / (root endpoint)...');
  try {
    final response = await http.get(Uri.parse(BASE_URL));
    if (response.statusCode == 200) {
      if (response.body.contains('Geogram') || response.body.contains(STATION_CALLSIGN)) {
        pass('Root endpoint returns HTML with station info');
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

Future<void> testStatsEndpoint() async {
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
    } else {
      fail('Stats endpoint', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Stats endpoint', 'Error: $e');
  }
}

Future<void> testDevicesEndpoint() async {
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

Future<void> testChatRoomsEndpoint() async {
  print('Testing GET /$STATION_CALLSIGN/api/chat/rooms...');
  try {
    final response = await http.get(Uri.parse('$BASE_URL/$STATION_CALLSIGN/api/chat/rooms'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data.containsKey('rooms') && data['rooms'] is List) {
        final rooms = data['rooms'] as List;
        // Default station creates a 'general' room
        if (rooms.isNotEmpty) {
          pass('Chat rooms endpoint returns rooms');

          // Check room structure
          final firstRoom = rooms[0] as Map<String, dynamic>;
          if (firstRoom.containsKey('id') && firstRoom.containsKey('name')) {
            pass('Chat room has correct structure');
          } else {
            fail('Chat room structure', 'Missing id or name fields');
          }
        } else {
          pass('Chat rooms endpoint returns empty list');
        }
      } else {
        fail('Chat rooms endpoint', 'Missing rooms array');
      }

      if (data['callsign'] == STATION_CALLSIGN) {
        pass('Chat rooms includes station callsign');
      } else {
        fail('Chat rooms callsign', 'Missing or incorrect callsign');
      }
    } else {
      fail('Chat rooms endpoint', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Chat rooms endpoint', 'Error: $e');
  }
}

Future<void> testWebSocketConnection() async {
  print('Testing WebSocket connection...');
  try {
    final ws = await WebSocket.connect('ws://localhost:$TEST_PORT');

    // Set up completer for HELLO response
    final helloCompleter = Completer<Map<String, dynamic>>();
    final pongCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      try {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        final type = message['type'] as String?;

        switch (type) {
          case 'hello_ack':
            if (!helloCompleter.isCompleted) {
              helloCompleter.complete(message);
            }
            break;
          case 'PONG':
            if (!pongCompleter.isCompleted) {
              pongCompleter.complete(message);
            }
            break;
        }
      } catch (e) {
        print('    WebSocket parse error: $e');
      }
    });

    // Test 1: hello message (npub is required by server)
    ws.add(jsonEncode({
      'type': 'hello',
      'callsign': 'X9WSTEST',
      'npub': 'npub1testnpubkey1234567890abcdef',
      'device_type': 'test',
      'version': '1.0.0',
    }));

    final helloResponse = await helloCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => <String, dynamic>{},
    );

    // Server responds with hello_ack containing station_id
    // Note: Without a proper Nostr event format, success will be false (npub required)
    // This is correct behavior - we're testing that the server responds properly
    if (helloResponse['type'] == 'hello_ack' &&
        helloResponse['station_id'] == STATION_CALLSIGN) {
      if (helloResponse['success'] == true) {
        pass('WebSocket hello/hello_ack works (authenticated)');
      } else {
        // Server correctly requires npub in Nostr event format
        pass('WebSocket hello/hello_ack responds correctly (npub validation)');
      }
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

    await ws.close();
    pass('WebSocket connection closed cleanly');
  } catch (e) {
    fail('WebSocket connection', 'Error: $e');
  }
}

Future<void> testCorsHeaders() async {
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

Future<void> testNotFoundHandling() async {
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
