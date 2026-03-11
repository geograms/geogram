#!/usr/bin/env dart
/// Place Upload Handler Test
///
/// Verifies that PlaceHandler.uploadFile():
/// - Returns HTTP 201
/// - Fires PlaceCreatedEvent when place.txt is uploaded
/// - Persists file to disk
/// - Does NOT fire PlaceCreatedEvent for non-place.txt files
///
/// This test exercises the shared PlaceHandler directly with a real HTTP server,
/// without needing the full StationServer (avoids sqlite dependency).
///
/// Run with: dart bin/place_upload_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/api/handlers/place_handler.dart';
import '../lib/api/common/station_info.dart';
import '../lib/util/event_bus.dart';

const int TEST_PORT = 45695;
const String BASE_URL = 'http://localhost:$TEST_PORT';
const String TEST_CALLSIGN = 'X3TEST';

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
  print('Geogram Place Upload Handler Test');
  print('=' * 60);
  print('');

  final tempDir = await Directory.systemTemp.createTemp('geogram_place_handler_test_');
  print('Using temp directory: ${tempDir.path}');
  print('');

  // Create devices directory structure
  await Directory('${tempDir.path}/devices/$TEST_CALLSIGN/places').create(recursive: true);

  final handler = PlaceHandler(
    dataDir: tempDir.path,
    stationInfo: StationInfo(
      callsign: TEST_CALLSIGN,
      name: 'Test Station',
    ),
    log: (level, message) => print('  [$level] $message'),
  );

  // Start a minimal HTTP server that routes to PlaceHandler
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, TEST_PORT);
  print('Test HTTP server started on port $TEST_PORT');
  print('');

  server.listen((request) async {
    try {
      final path = request.uri.path;
      final method = request.method;

      if (handler.isFileUploadPath(path) && method == 'POST') {
        await handler.uploadFile(request);
      } else if (handler.isFileUploadPath(path) && method == 'GET') {
        await handler.serveFile(request);
      } else {
        request.response.statusCode = 404;
        request.response.write('Not found');
      }
    } catch (e) {
      request.response.statusCode = 500;
      request.response.write('Error: $e');
    } finally {
      await request.response.close();
    }
  });

  try {
    await _testIsFileUploadPath(handler);
    await _testImageUploadNoEvent();
    await _testPlaceTxtUploadFiresEvent();
    await _testPlaceFilePersistence(tempDir.path);
    await _testPlaceFileServe();
    await _testInvalidPath();

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
    await server.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}

Future<void> _testIsFileUploadPath(PlaceHandler handler) async {
  print('Testing isFileUploadPath()...');

  if (handler.isFileUploadPath('/$TEST_CALLSIGN/api/places/files/my-place/place.txt')) {
    pass('isFileUploadPath recognizes valid place file path');
  } else {
    fail('isFileUploadPath', 'Did not recognize valid path');
  }

  if (!handler.isFileUploadPath('/api/status')) {
    pass('isFileUploadPath rejects non-place path');
  } else {
    fail('isFileUploadPath', 'Incorrectly matched /api/status');
  }

  if (handler.isFileUploadPath('/$TEST_CALLSIGN/api/places/tu-darmstadt/files/place.txt')) {
    pass('isFileUploadPath recognizes nested place file path');
  } else {
    fail('isFileUploadPath nested', 'Did not recognize nested path');
  }
}

Future<void> _testImageUploadNoEvent() async {
  print('Testing image upload does NOT fire PlaceCreatedEvent...');

  var eventFired = false;
  final sub = EventBus().on<PlaceCreatedEvent>((event) {
    eventFired = true;
  });

  final url = '$BASE_URL/$TEST_CALLSIGN/api/places/files/my-place/images/photo.jpg';
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.contentType = ContentType.binary;
    request.add([0xFF, 0xD8, 0xFF, 0xE0]); // fake JPEG header
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode == 201) {
      pass('Image upload returns HTTP 201');
    } else {
      fail('Image upload status', 'Expected 201, got ${response.statusCode}: $body');
    }

    // Give a moment for async event delivery
    await Future.delayed(const Duration(milliseconds: 100));

    if (!eventFired) {
      pass('No PlaceCreatedEvent fired for image upload');
    } else {
      fail('Image upload event', 'PlaceCreatedEvent was incorrectly fired for image upload');
    }
  } finally {
    sub.cancel();
    client.close();
  }
}

Future<void> _testPlaceTxtUploadFiresEvent() async {
  print('Testing place.txt upload fires PlaceCreatedEvent...');

  final completer = Completer<PlaceCreatedEvent>();
  final sub = EventBus().on<PlaceCreatedEvent>((event) {
    if (!completer.isCompleted) {
      completer.complete(event);
    }
  });

  final placeContent = '''Name: TU Darmstadt
Latitude: 49.8728
Longitude: 8.6512
Description: Technical University of Darmstadt campus
''';

  final url = '$BASE_URL/$TEST_CALLSIGN/api/places/files/tu-darmstadt/place.txt';
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.contentType = ContentType.text;
    request.write(placeContent);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode == 201) {
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['success'] == true) {
        pass('place.txt upload returns HTTP 201 with success=true');
      } else {
        fail('place.txt upload response', 'success != true: $body');
      }
    } else {
      fail('place.txt upload status', 'Expected 201, got ${response.statusCode}: $body');
    }

    // Wait for event
    try {
      final event = await completer.future.timeout(const Duration(seconds: 3));
      if (event.placeId == 'tu-darmstadt') {
        pass('PlaceCreatedEvent.placeId = ${event.placeId}');
      } else {
        fail('PlaceCreatedEvent.placeId', 'Expected tu-darmstadt, got ${event.placeId}');
      }
      if (event.author == TEST_CALLSIGN) {
        pass('PlaceCreatedEvent.author = ${event.author}');
      } else {
        fail('PlaceCreatedEvent.author', 'Expected $TEST_CALLSIGN, got ${event.author}');
      }
    } on TimeoutException {
      fail('PlaceCreatedEvent', 'Event not fired within 3 seconds');
    }
  } finally {
    sub.cancel();
    client.close();
  }
}

Future<void> _testPlaceFilePersistence(String tempDir) async {
  print('Testing place file persistence on disk...');

  final placeFile = File('$tempDir/devices/$TEST_CALLSIGN/places/tu-darmstadt/place.txt');
  if (await placeFile.exists()) {
    final content = await placeFile.readAsString();
    if (content.contains('TU Darmstadt')) {
      pass('place.txt persisted to disk with correct content');
    } else {
      fail('place.txt content', 'File exists but missing expected content');
    }
  } else {
    fail('place.txt persistence', 'File not found at ${placeFile.path}');
  }

  final imageFile = File('$tempDir/devices/$TEST_CALLSIGN/places/my-place/images/photo.jpg');
  if (await imageFile.exists()) {
    pass('Image file also persisted to disk');
  } else {
    fail('Image persistence', 'Image file not found at ${imageFile.path}');
  }
}

Future<void> _testPlaceFileServe() async {
  print('Testing GET place file serve...');

  final url = '$BASE_URL/$TEST_CALLSIGN/api/places/files/tu-darmstadt/place.txt';
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode == 200) {
      if (body.contains('TU Darmstadt')) {
        pass('GET place.txt returns correct content');
      } else {
        fail('GET place.txt content', 'Missing expected content in body');
      }
    } else {
      fail('GET place.txt status', 'Expected 200, got ${response.statusCode}');
    }
  } finally {
    client.close();
  }

  // Test serving non-existent file
  final url404 = '$BASE_URL/$TEST_CALLSIGN/api/places/files/nonexistent/place.txt';
  final client2 = HttpClient();
  try {
    final request = await client2.getUrl(Uri.parse(url404));
    final response = await request.close();
    await response.drain<void>();

    if (response.statusCode == 404) {
      pass('GET non-existent file returns 404');
    } else {
      fail('GET non-existent file', 'Expected 404, got ${response.statusCode}');
    }
  } finally {
    client2.close();
  }
}

Future<void> _testInvalidPath() async {
  print('Testing empty file upload rejection...');

  final url = '$BASE_URL/$TEST_CALLSIGN/api/places/files/my-place/empty.txt';
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.contentType = ContentType.text;
    // Send empty body
    final response = await request.close();
    await response.drain<void>();

    if (response.statusCode == 400) {
      pass('Empty file upload returns 400');
    } else {
      fail('Empty file upload', 'Expected 400, got ${response.statusCode}');
    }
  } finally {
    client.close();
  }
}
