// Test script to verify tile fetching from station
// Run with: dart test/tile_station_test.dart

import 'dart:io';
import 'package:http/http.dart' as http;

const String stationUrl = 'http://localhost:8080';
const String userCallsign = 'X1NZG9';

Future<void> main() async {
  print('=== Tile Relay Test ===\n');

  // Step 1: Check if station is running
  print('1. Checking station status...');
  try {
    final statusResponse = await http.get(Uri.parse('$stationUrl/api/status'));
    if (statusResponse.statusCode == 200) {
      print('   ✓ Station is running at $stationUrl');
    } else {
      print('   ✗ Station returned status ${statusResponse.statusCode}');
      exit(1);
    }
  } catch (e) {
    print('   ✗ Relay not reachable: $e');
    print('   Please start the station first: ./start.sh 8080');
    exit(1);
  }

  // Step 2: Test direct tile request to station
  print('\n2. Testing direct tile request to station...');
  final testTiles = [
    [5, 16, 10],
    [6, 32, 21],
    [7, 65, 42],
    [8, 131, 85],
  ];

  for (final tile in testTiles) {
    final z = tile[0];
    final x = tile[1];
    final y = tile[2];
    final tileUrl = '$stationUrl/tiles/$userCallsign/$z/$x/$y.png';

    print('   Requesting: $tileUrl');
    try {
      final response = await http.get(Uri.parse(tileUrl));
      if (response.statusCode == 200) {
        final isValidPng = response.bodyBytes.length > 8 &&
            response.bodyBytes[0] == 0x89 &&
            response.bodyBytes[1] == 0x50 &&
            response.bodyBytes[2] == 0x4E &&
            response.bodyBytes[3] == 0x47;
        if (isValidPng) {
          print('   ✓ Got valid PNG (${response.bodyBytes.length} bytes)');
        } else {
          print('   ✗ Response is not a valid PNG');
        }
      } else {
        print('   ✗ Status ${response.statusCode}');
      }
    } catch (e) {
      print('   ✗ Error: $e');
    }
  }

  // Step 3: Check station tile cache
  print('\n3. Checking station tile cache directory...');
  final cacheDir = Directory('/home/brito/code/geograms/geogram-station/tiles/$userCallsign');
  if (await cacheDir.exists()) {
    final files = await cacheDir.list(recursive: true).where((e) => e.path.endsWith('.png')).length;
    print('   ✓ Cache directory exists with tiles');
  } else {
    print('   ✗ Cache directory NOT created: ${cacheDir.path}');
    print('   This means the station is NOT caching tiles!');
  }

  // Step 4: Simulate what geogram-desktop MapTileService does
  print('\n4. Simulating MapTileService station URL generation...');
  final wsUrl = 'ws://localhost:8080';
  var httpUrl = wsUrl.replaceFirst('ws://', 'http://');
  if (httpUrl.endsWith('/')) {
    httpUrl = httpUrl.substring(0, httpUrl.length - 1);
  }
  final stationTileUrl = '$httpUrl/tiles/$userCallsign/{z}/{x}/{y}.png';
  print('   Generated URL template: $stationTileUrl');

  // Test with actual coordinates
  final testUrl = stationTileUrl
      .replaceAll('{z}', '5')
      .replaceAll('{x}', '17')
      .replaceAll('{y}', '11');
  print('   Test URL: $testUrl');

  try {
    final response = await http.get(Uri.parse(testUrl));
    print('   Response: ${response.statusCode} (${response.bodyBytes.length} bytes)');
  } catch (e) {
    print('   Error: $e');
  }

  print('\n=== Test Complete ===');
}
