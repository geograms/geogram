#!/usr/bin/env dart
// Test script for relay server functionality

import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;

const int TEST_PORT = 9090;

Future<void> main() async {
  print('Geogram Desktop Relay Server Test');
  print('=' * 40);

  // Start a simple HTTP server to simulate the relay
  final server = await HttpServer.bind(InternetAddress.anyIPv4, TEST_PORT);
  print('Test relay server started on port $TEST_PORT');

  // Handle requests
  server.listen((request) async {
    final path = request.uri.path;

    // CORS headers
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');

    if (path == '/api/status' || path == '/status') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'name': 'Geogram Desktop Relay Test',
        'version': '1.5.3',
        'callsign': 'X3TEST',
        'description': 'Test relay server',
        'connected_devices': 0,
        'uptime': 0,
        'relay_mode': true,
        'tile_server': true,
        'osm_fallback': true,
      }));
    } else if (path == '/') {
      request.response.headers.contentType = ContentType.html;
      request.response.write('''
<!DOCTYPE html>
<html>
<head><title>Geogram Relay Test</title></head>
<body>
  <h1>Geogram Desktop Relay Test</h1>
  <p>Port: $TEST_PORT</p>
  <p>Status: Running</p>
</body>
</html>
''');
    } else if (path.startsWith('/tiles/')) {
      // Return a simple 1x1 transparent PNG for tile requests
      final pngData = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, // IDAT chunk
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, // IEND chunk
        0x42, 0x60, 0x82,
      ];
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(pngData);
    } else {
      request.response.statusCode = 404;
      request.response.write('Not Found');
    }

    await request.response.close();
  });

  // Run tests
  await Future.delayed(Duration(milliseconds: 500));

  print('');
  print('Running tests...');
  print('-' * 40);

  // Test 1: Status endpoint
  try {
    final statusResponse = await http.get(Uri.parse('http://localhost:$TEST_PORT/api/status'));
    if (statusResponse.statusCode == 200) {
      final data = jsonDecode(statusResponse.body);
      print('[PASS] /api/status - Callsign: ${data['callsign']}');
    } else {
      print('[FAIL] /api/status - HTTP ${statusResponse.statusCode}');
    }
  } catch (e) {
    print('[FAIL] /api/status - Error: $e');
  }

  // Test 2: Root endpoint
  try {
    final rootResponse = await http.get(Uri.parse('http://localhost:$TEST_PORT/'));
    if (rootResponse.statusCode == 200 && rootResponse.body.contains('Geogram')) {
      print('[PASS] / - HTML response received');
    } else {
      print('[FAIL] / - Unexpected response');
    }
  } catch (e) {
    print('[FAIL] / - Error: $e');
  }

  // Test 3: Tile endpoint
  try {
    final tileResponse = await http.get(Uri.parse('http://localhost:$TEST_PORT/tiles/TEST/0/0/0.png'));
    if (tileResponse.statusCode == 200 && tileResponse.bodyBytes[0] == 0x89) {
      print('[PASS] /tiles - PNG image received');
    } else {
      print('[FAIL] /tiles - Invalid response');
    }
  } catch (e) {
    print('[FAIL] /tiles - Error: $e');
  }

  print('');
  print('-' * 40);
  print('Tests completed. Server running on port $TEST_PORT');
  print('Press Ctrl+C to stop.');

  // Keep server running for 30 seconds for manual testing
  await Future.delayed(Duration(seconds: 30));

  await server.close();
  print('Server stopped.');
  exit(0);
}
