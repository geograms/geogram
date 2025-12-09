// Standalone test to verify tile fetching from station vs internet
// Run with: dart test/tile_source_test.dart
//
// This test checks if tiles can be fetched from the station and logs the source

import 'dart:io';
import 'package:http/http.dart' as http;

const String stationUrl = 'http://localhost:8080';
const String userCallsign = 'X1NZG9';

// Test tiles around Germany (lat: 49.683, lon: 8.622)
final testTiles = [
  [5, 16, 10],  // Germany area
  [5, 17, 10],
  [5, 16, 11],
  [6, 33, 21],
  [7, 66, 43],
];

Future<void> main() async {
  print('=== Tile Source Test ===\n');
  print('This test verifies that tiles can be fetched from the station.');
  print('Station URL: $stationUrl');
  print('User callsign: $userCallsign\n');

  // Step 1: Check station status
  print('1. Checking station status...');
  try {
    final statusResponse = await http.get(Uri.parse('$stationUrl/api/status'));
    if (statusResponse.statusCode == 200) {
      print('   PASS: Station is running at $stationUrl');
    } else {
      print('   FAIL: Station returned status ${statusResponse.statusCode}');
      exit(1);
    }
  } catch (e) {
    print('   FAIL: Relay not reachable: $e');
    print('   Please start the station first: cd geogram-station && java -jar target/geogram-station.jar');
    exit(1);
  }

  // Test both standard and satellite tiles
  print('\n2. Testing STANDARD tiles (OSM)...');
  final standardResults = await _testTiles('standard');

  print('\n3. Testing SATELLITE tiles (Esri)...');
  final satelliteResults = await _testTiles('satellite');

  // Summary
  print('\n=== Final Summary ===');
  print('STANDARD tiles: ${standardResults['station']} from station, ${standardResults['internet']} from internet, ${standardResults['failed']} failed');
  print('SATELLITE tiles: ${satelliteResults['station']} from station, ${satelliteResults['internet']} from internet, ${satelliteResults['failed']} failed');

  final totalStation = standardResults['station']! + satelliteResults['station']!;
  final totalInternet = standardResults['internet']! + satelliteResults['internet']!;
  final totalFailed = standardResults['failed']! + satelliteResults['failed']!;

  if (totalStation == 0) {
    print('\nWARNING: No tiles came from station!');
  } else {
    print('\nSUCCESS: $totalStation total tiles fetched from station');
  }

  print('\n=== Test Complete ===');
}

Future<Map<String, int>> _testTiles(String layer) async {
  int stationSuccess = 0;
  int internetSuccess = 0;
  int failed = 0;

  final layerParam = layer == 'satellite' ? '?layer=satellite' : '';
  print('   Station URL template: $stationUrl/tiles/$userCallsign/{z}/{x}/{y}.png$layerParam');

  for (final tile in testTiles) {
    final z = tile[0];
    final x = tile[1];
    final y = tile[2];

    // Try station first (mimicking desktop app behavior)
    final stationTileUrl = '$stationUrl/tiles/$userCallsign/$z/$x/$y.png$layerParam';
    print('\n   Tile [$z/$x/$y] ($layer):');
    print('   -> Trying STATION: $stationTileUrl');

    try {
      final stationResponse = await http.get(Uri.parse(stationTileUrl))
          .timeout(const Duration(seconds: 10));

      if (stationResponse.statusCode == 200 && _isValidImage(stationResponse.bodyBytes)) {
        print('   -> SOURCE: STATION (${stationResponse.bodyBytes.length} bytes)');
        stationSuccess++;
        continue;
      } else {
        print('   -> Station returned ${stationResponse.statusCode}, trying internet...');
      }
    } catch (e) {
      print('   -> Relay failed: $e, trying internet...');
    }

    // Fall back to internet
    String internetUrl;
    if (layer == 'satellite') {
      // Esri uses z/y/x order
      internetUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/$z/$y/$x';
    } else {
      // OSM uses z/x/y order
      internetUrl = 'https://tile.openstreetmap.org/$z/$x/$y.png';
    }
    print('   -> Trying INTERNET: $internetUrl');

    try {
      final response = await http.get(
        Uri.parse(internetUrl),
        headers: {'User-Agent': 'TileSourceTest/1.0'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 && _isValidImage(response.bodyBytes)) {
        print('   -> SOURCE: INTERNET (${response.bodyBytes.length} bytes)');
        internetSuccess++;
      } else {
        print('   -> FAILED: Internet returned ${response.statusCode}');
        failed++;
      }
    } catch (e) {
      print('   -> FAILED: $e');
      failed++;
    }
  }

  return {'station': stationSuccess, 'internet': internetSuccess, 'failed': failed};
}

bool _isValidImage(List<int> bytes) {
  if (bytes.length < 8) return false;
  // PNG signature: 89 50 4E 47
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
    return true;
  }
  // JPEG signature: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return true;
  }
  return false;
}
