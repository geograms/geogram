#!/usr/bin/env dart
/// Geogram Desktop Alert App Test Suite
///
/// This test file is designed for incrementally testing Alert app functionality.
/// It launches:
///   - A station instance (CLI) at /tmp/geogram-alert-station (port 16000)
///   - A client instance (GUI) at /tmp/geogram-alert-clientA (port 16100)
///
/// The test can be extended incrementally to verify:
///   - Alert creation
///   - Alert sharing
///   - Alert synchronization
///   - Photo upload/download
///   - Points and comments
///   - And more...
///
/// Usage:
///   ./tests/launch_app_tests.sh
///   # or directly:
///   dart run tests/app_alert_test.dart
///
/// Prerequisites:
///   - Build CLI: ./launch-cli.sh --build-only
///   - Build desktop: flutter build linux --release
///   - Run from the geogram-desktop directory

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

// ============================================================
// Configuration
// ============================================================

/// Fixed temp directories for easy debugging and inspection
const String stationDataDir = '/tmp/geogram-alert-station';
const String clientADataDir = '/tmp/geogram-alert-clientA';
const String clientBDataDir = '/tmp/geogram-alert-clientB';

/// Ports for the instances
/// Note: Station HTTP API and WebSocket are on the same port
const int stationPort = 16000;
const int clientAPort = 16100;
const int clientBPort = 16200;

/// Timing configuration
const Duration startupWait = Duration(seconds: 12);
const Duration connectionWait = Duration(seconds: 3);
const Duration apiWait = Duration(seconds: 2);

// ============================================================
// Test State
// ============================================================

/// Test results tracking
int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

/// Process handles for cleanup
Process? _stationProcess;
Process? _clientAProcess;
Process? _clientBProcess;

/// Instance information
String? _stationCallsign;
String? _clientACallsign;
String? _clientBCallsign;

// ============================================================
// Output Helpers
// ============================================================

void pass(String test) {
  _passed++;
  print('  \x1B[32m✓\x1B[0m $test');
}

void fail(String test, String reason) {
  _failed++;
  _failures.add('$test: $reason');
  print('  \x1B[31m✗\x1B[0m $test - $reason');
}

void info(String message) {
  print('  \x1B[36mℹ\x1B[0m $message');
}

void warn(String message) {
  print('  \x1B[33m⚠\x1B[0m $message');
}

void section(String title) {
  print('\n\x1B[1m=== $title ===\x1B[0m');
}

// ============================================================
// Instance Management
// ============================================================

/// Launch the geogram-cli for station mode
Future<Process?> launchStationCli({
  required int port,
  required String dataDir,
  String? nickname,
}) async {
  // Find the CLI executable
  final executable = File('build/geogram-cli');
  if (!await executable.exists()) {
    print('ERROR: CLI build not found at ${executable.path}');
    print('Please run: ./launch-cli.sh --build-only');
    return null;
  }

  final args = [
    '--port=$port',
    '--data-dir=$dataDir',
    '--new-identity',
    '--identity-type=station',
    '--skip-intro',
    if (nickname != null) '--nickname=$nickname',
  ];

  info('Starting Station CLI on port $port...');
  info('Data directory: $dataDir');
  info('Args: ${args.join(' ')}');

  final process = await Process.start(
    executable.path,
    args,
    mode: ProcessStartMode.normal,
  );

  // Log output for debugging
  process.stdout.transform(utf8.decoder).listen((data) {
    if (data.trim().isNotEmpty) {
      for (final line in data.trim().split('\n')) {
        print('  [Station] $line');
      }
    }
  });

  process.stderr.transform(utf8.decoder).listen((data) {
    if (data.trim().isNotEmpty) {
      print('  [Station STDERR] ${data.trim()}');
    }
  });

  return process;
}

/// Send a command to the CLI process stdin
Future<void> sendCliCommand(Process process, String command) async {
  process.stdin.writeln(command);
  await process.stdin.flush();
}

/// Launch a geogram-desktop client instance
Future<Process?> launchClientInstance({
  required String name,
  required int port,
  required String dataDir,
  String? scanLocalhostRange,
}) async {
  // Find the executable
  final executable = File('build/linux/x64/release/bundle/geogram_desktop');
  if (!await executable.exists()) {
    print('ERROR: Build not found at ${executable.path}');
    print('Please run: flutter build linux --release');
    return null;
  }

  final args = [
    '--port=$port',
    '--data-dir=$dataDir',
    '--new-identity',
    '--skip-intro',
    '--http-api',
    '--debug-api',
    '--no-update',
    '--identity-type=client',
    '--nickname=$name',
  ];

  if (scanLocalhostRange != null) {
    args.add('--scan-localhost=$scanLocalhostRange');
  }

  info('Starting $name on port $port...');
  info('Data directory: $dataDir');

  final process = await Process.start(
    executable.path,
    args,
    mode: ProcessStartMode.detachedWithStdio,
  );

  // Log errors for debugging
  process.stderr.transform(utf8.decoder).listen((data) {
    if (data.trim().isNotEmpty) {
      print('  [$name STDERR] ${data.trim()}');
    }
  });

  return process;
}

/// Wait for an instance to be ready (API responding)
Future<bool> waitForReady(String name, int port,
    {Duration timeout = const Duration(seconds: 60)}) async {
  final stopwatch = Stopwatch()..start();
  // Station uses /api/status, client uses /api/ - try both
  final urls = [
    'http://localhost:$port/api/status',
    'http://localhost:$port/api/',
  ];

  while (stopwatch.elapsed < timeout) {
    for (final url in urls) {
      try {
        final response =
            await http.get(Uri.parse(url)).timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          info('$name ready (${data['callsign']})');
          return true;
        }
      } catch (e) {
        // Not ready yet
      }
    }
    await Future.delayed(const Duration(milliseconds: 500));
  }

  return false;
}

/// Get callsign from instance
Future<String?> getCallsign(int port) async {
  // Try both endpoints - station uses /api/status, client uses /api/
  for (final path in ['/api/status', '/api/']) {
    try {
      final response = await http.get(Uri.parse('http://localhost:$port$path'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['callsign'] as String?;
      }
    } catch (e) {
      // Try next
    }
  }
  return null;
}

/// Send debug API action
Future<Map<String, dynamic>?> debugAction(
    int port, Map<String, dynamic> action) async {
  try {
    final response = await http
        .post(
          Uri.parse('http://localhost:$port/api/debug'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(action),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      try {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } catch (e) {
        info('DEBUG API JSON parse error: $e');
        return null;
      }
    } else {
      info('DEBUG API Error (${response.statusCode}): ${response.body}');
      try {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } catch (e) {
        return {'success': false, 'error': 'HTTP ${response.statusCode}'};
      }
    }
  } catch (e) {
    info('DEBUG API Exception: $e');
    return {'success': false, 'error': 'Exception: $e'};
  }
}

/// Connect a client to the station
Future<bool> connectToStation(int clientPort) async {
  final result = await debugAction(clientPort, {
    'action': 'station_connect',
    'url': 'ws://localhost:$stationPort',
  });
  info('Connection result: ${result?['message'] ?? 'unknown'}');
  return result?['success'] == true || result?['connected'] == true;
}

/// Wait for at least N clients to be connected to station
Future<bool> waitForClients(int minClients,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final stopwatch = Stopwatch()..start();

  while (stopwatch.elapsed < timeout) {
    try {
      final response = await http
          .get(Uri.parse('http://localhost:$stationPort/api/clients'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final count = data['count'] as int? ?? 0;
        if (count >= minClients) {
          info('$count client(s) connected to station');
          return true;
        }
      }
    } catch (e) {
      // Not ready yet
    }
    await Future.delayed(const Duration(seconds: 1));
  }

  return false;
}

// ============================================================
// Setup and Cleanup
// ============================================================

/// Prepare temp directories (clean and create)
Future<void> prepareDirectories() async {
  for (final path in [stationDataDir, clientADataDir, clientBDataDir]) {
    // Use shell rm -rf for reliable cleanup (handles permission issues, etc.)
    final rmResult = await Process.run('rm', ['-rf', path]);
    if (rmResult.exitCode != 0) {
      warn('Failed to remove $path: ${rmResult.stderr}');
    } else {
      info('Removed existing directory: $path');
    }

    // Create fresh directory
    final dir = Directory(path);
    await dir.create(recursive: true);
    info('Created directory: $path');
  }
}

/// Cleanup all processes
Future<void> cleanup() async {
  section('Cleanup');

  // Stop clients first
  if (_clientBProcess != null) {
    info('Stopping Client B...');
    _clientBProcess!.kill(ProcessSignal.sigterm);
  }

  if (_clientAProcess != null) {
    info('Stopping Client A...');
    _clientAProcess!.kill(ProcessSignal.sigterm);
  }

  // Stop station CLI gracefully by sending quit command
  if (_stationProcess != null) {
    info('Stopping Station CLI...');
    try {
      await sendCliCommand(_stationProcess!, 'quit');
      await Future.delayed(const Duration(seconds: 2));
    } catch (e) {
      // Ignore stdin errors if process already dead
    }
    _stationProcess!.kill(ProcessSignal.sigterm);
  }

  // Wait a moment for processes to exit
  await Future.delayed(const Duration(seconds: 2));

  // Force kill if needed
  _clientBProcess?.kill(ProcessSignal.sigkill);
  _clientAProcess?.kill(ProcessSignal.sigkill);
  _stationProcess?.kill(ProcessSignal.sigkill);

  // Always keep directories for inspection after test run
  // (directories are cleaned at the start of each run)
  info('Keeping directories for inspection:');
  info('  Station: $stationDataDir');
  info('  Client A: $clientADataDir');
  info('  Client B: $clientBDataDir');
}

// ============================================================
// Test Functions
// ============================================================

Future<void> testSetup() async {
  section('Setup');

  // Check if build exists
  final executable = File('build/linux/x64/release/bundle/geogram_desktop');
  if (!await executable.exists()) {
    print('\x1B[31mERROR: Build not found at ${executable.path}\x1B[0m');
    print('\nPlease build first:');
    print('  flutter build linux --release');
    exit(1);
  }
  pass('Build found');

  // Prepare temp directories
  await prepareDirectories();
  pass('Directories prepared');
}

Future<bool> testLaunchStation() async {
  section('Launch Station (CLI)');

  _stationProcess = await launchStationCli(
    port: stationPort,
    dataDir: stationDataDir,
    nickname: 'AlertTestStation',
  );

  if (_stationProcess == null) {
    fail('Launch station', 'Failed to start process');
    return false;
  }

  // Wait for CLI to initialize and create profile
  info('Waiting for CLI to initialize...');
  await Future.delayed(const Duration(seconds: 5));

  // Send station start command
  info('Starting station server...');
  await sendCliCommand(_stationProcess!, 'station start');
  await Future.delayed(startupWait);

  // The station server runs on the configured port (stationPort)
  // After station start, the HTTP API is available on that port
  if (!await waitForReady('Station', stationPort, timeout: const Duration(seconds: 30))) {
    fail('Station ready', 'Station server did not become ready on port $stationPort');
    return false;
  }

  _stationCallsign = await getCallsign(stationPort);
  if (_stationCallsign == null) {
    fail('Get station callsign', 'Could not get callsign');
    return false;
  }

  pass('Station CLI launched: $_stationCallsign (server on port $stationPort)');
  return true;
}

Future<bool> testLaunchClientA() async {
  section('Launch Client A');

  _clientAProcess = await launchClientInstance(
    name: 'ClientA',
    port: clientAPort,
    dataDir: clientADataDir,
    scanLocalhostRange: '$stationPort-$stationPort',
  );

  if (_clientAProcess == null) {
    fail('Launch client A', 'Failed to start process');
    return false;
  }

  await Future.delayed(startupWait);

  if (!await waitForReady('Client A', clientAPort)) {
    fail('Client A ready', 'Client A did not become ready');
    return false;
  }

  _clientACallsign = await getCallsign(clientAPort);
  if (_clientACallsign == null) {
    fail('Get client A callsign', 'Could not get callsign');
    return false;
  }

  pass('Client A launched: $_clientACallsign');
  return true;
}

Future<bool> testConnectClientToStation() async {
  section('Connect Client A to Station');

  await connectToStation(clientAPort);
  await Future.delayed(connectionWait);

  // Wait for client to be connected
  if (!await waitForClients(1)) {
    fail('Client connection', 'Client A did not connect to station');
    return false;
  }

  pass('Client A connected to station');
  return true;
}

Future<void> testVerifySetup() async {
  section('Verify Setup');

  // Verify station API is accessible
  try {
    final response =
        await http.get(Uri.parse('http://localhost:$stationPort/api/status'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      pass('Station API accessible (callsign: ${data['callsign']})');
    } else {
      fail('Station API', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Station API', 'Exception: $e');
  }

  // Verify client A API is accessible
  try {
    final response =
        await http.get(Uri.parse('http://localhost:$clientAPort/api/status'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      pass('Client A API accessible (callsign: ${data['callsign']})');
    } else {
      fail('Client A API', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Client A API', 'Exception: $e');
  }

  // Verify station server /api/clients endpoint is accessible
  try {
    final response =
        await http.get(Uri.parse('http://localhost:$stationPort/api/clients'));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      pass('Station server accessible (${data['count']} client(s) connected)');
    } else {
      fail('Station server', 'HTTP ${response.statusCode}');
    }
  } catch (e) {
    fail('Station server', 'Exception: $e');
  }
}

// ============================================================
// Alert Tests
// ============================================================

/// Created alert details for verification
String? _createdAlertId;
String? _createdAlertFolderName;

/// Photo names used in the test (now in images/ subfolder with sequential naming)
const String photo1Name = 'images/photo1.png';
const String photo2Name = 'images/photo2.png';

/// Test creating an alert with two photos on the client
Future<bool> testCreateAlertWithPhotos() async {
  section('Create Alert with Photos on Client');

  // Step 1: Create an alert with the first photo
  info('Creating alert with first photo...');
  final result = await debugAction(clientAPort, {
    'action': 'alert_create',
    'title': 'Test Alert with Photos',
    'description': 'This is a test alert with two photos created by the automated test suite.',
    'latitude': 38.7223,
    'longitude': -9.1393,
    'severity': 'attention',
    'type': 'test',
    'status': 'open',
    'photo': true,  // Creates test_photo.png
  });

  if (result == null || result['success'] != true) {
    fail('Create alert', 'Failed to create alert: ${result?['error'] ?? 'unknown error'}');
    return false;
  }

  _createdAlertId = result['alert_id'] as String?;
  _createdAlertFolderName = result['folder_name'] as String?;

  if (_createdAlertId == null) {
    fail('Create alert', 'No alert_id returned');
    return false;
  }

  info('Created alert: $_createdAlertId');
  info('Folder name: $_createdAlertFolderName');
  info('First photo: $photo1Name');

  // Step 2: Add a second photo to the alert
  info('Adding second photo to alert...');
  final addPhotoResult = await debugAction(clientAPort, {
    'action': 'alert_add_photo',
    'alert_id': _createdAlertId,
    'name': photo2Name,
    // No URL = creates a test placeholder image
  });

  if (addPhotoResult == null || addPhotoResult['success'] != true) {
    fail('Add second photo', 'Failed to add photo: ${addPhotoResult?['error'] ?? 'unknown error'}');
    return false;
  }

  info('Second photo added: $photo2Name');

  // Step 3: Verify both photos exist locally on the client
  await Future.delayed(const Duration(seconds: 1));

  // Search for the alert folder (now uses timestamp-based folder name in active/{region}/)
  final alertPath = await _findAlertPath(clientADataDir, _clientACallsign!, _createdAlertFolderName!);

  if (alertPath == null) {
    // List what exists for debugging
    info('Alert folder not found. Listing directory structure:');
    final alertsDir = Directory('$clientADataDir/devices/$_clientACallsign/alerts');
    if (await alertsDir.exists()) {
      await for (final entity in alertsDir.list(recursive: true)) {
        info('  ${entity.path}');
      }
    }
    fail('Verify local photos', 'Alert folder not found: $_createdAlertFolderName');
    return false;
  }

  info('Alert path: $alertPath');

  // Check images/ subfolder exists
  final imagesDir = Directory('$alertPath/images');
  if (!await imagesDir.exists()) {
    fail('Verify local photos', 'images/ subfolder not found');
    return false;
  }
  info('images/ subfolder exists');

  // Check first photo (photo1Name includes 'images/' prefix)
  final photo1File = File('$alertPath/$photo1Name');
  if (!await photo1File.exists()) {
    // List what's in images folder for debugging
    info('Files in images folder:');
    await for (final file in imagesDir.list()) {
      info('  ${file.path.split('/').last}');
    }
    fail('Verify local photos', 'First photo not found: $photo1Name');
    return false;
  }
  final photo1Size = await photo1File.length();
  info('First photo exists locally: $photo1Name ($photo1Size bytes)');

  // Check second photo
  final photo2File = File('$alertPath/$photo2Name');
  if (!await photo2File.exists()) {
    info('Files in images folder:');
    await for (final file in imagesDir.list()) {
      info('  ${file.path.split('/').last}');
    }
    fail('Verify local photos', 'Second photo not found: $photo2Name');
    return false;
  }
  final photo2Size = await photo2File.length();
  info('Second photo exists locally: $photo2Name ($photo2Size bytes)');

  pass('Alert created with 2 photos in images/ subfolder');
  return true;
}

/// Test sharing the alert to the station
Future<bool> testShareAlertToStation() async {
  section('Share Alert to Station');

  if (_createdAlertId == null) {
    fail('Share alert', 'No alert to share (create test must run first)');
    return false;
  }

  // Share the alert to the station via debug API
  final result = await debugAction(clientAPort, {
    'action': 'alert_share',
    'alert_id': _createdAlertId,
  });

  if (result == null) {
    fail('Share alert', 'No response from debug API');
    return false;
  }

  if (result['success'] != true) {
    info('Full share result: $result');
    fail('Share alert', 'Failed to share: ${result['error'] ?? result['message'] ?? 'unknown error'}');
    return false;
  }

  final confirmed = result['confirmed'] as int? ?? 0;
  info('Alert shared to $confirmed station(s)');
  info('Event ID: ${result['event_id']}');

  if (confirmed == 0) {
    fail('Share alert', 'Alert was not confirmed by any station');
    return false;
  }

  pass('Alert shared to station');

  // Wait for the station to process and store the alert
  await Future.delayed(const Duration(seconds: 2));
  return true;
}

/// Verify the alert and both photos were uploaded to the station
Future<bool> testVerifyAlertAndPhotosOnStation() async {
  section('Verify Alert and Photos on Station');

  if (_createdAlertFolderName == null || _stationCallsign == null) {
    fail('Verify alert', 'Missing folder name or station callsign');
    return false;
  }

  // The station stores alerts at: {dataDir}/devices/{clientCallsign}/alerts/{folderName}/
  // We need to find the alert in the station's data directory
  final stationAlertsDir = Directory('$stationDataDir/devices');

  if (!await stationAlertsDir.exists()) {
    fail('Verify alert', 'Station devices directory not found');
    return false;
  }

  // Find alert folders in the station's data
  // Station stores client alerts under the client's callsign subfolder
  bool alertFound = false;
  String? foundAlertPath;

  // Search recursively for the alert folder
  final folderName = _createdAlertFolderName!;
  await for (final entity in stationAlertsDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final reportFile = File('${entity.path}/report.txt');
      if (await reportFile.exists()) {
        alertFound = true;
        foundAlertPath = entity.path;
        break;
      }
    }
  }

  if (!alertFound) {
    // Let's list what's in the station's devices directory for debugging
    info('Listing station devices directory contents:');
    await for (final entity in stationAlertsDir.list(recursive: true)) {
      info('  ${entity.path}');
    }
    fail('Verify alert', 'Alert folder not found on station: $folderName');
    return false;
  }

  info('Found alert at: $foundAlertPath');

  // Read the report.txt to verify content
  final reportFile = File('$foundAlertPath/report.txt');
  final reportContent = await reportFile.readAsString();

  // Verify the report contains expected content
  if (!reportContent.contains('Test Alert with Photos')) {
    fail('Verify alert', 'Report does not contain expected title');
    return false;
  }

  if (!reportContent.contains('two photos created by the automated test suite')) {
    fail('Verify alert', 'Report does not contain expected description');
    return false;
  }

  info('Report content verified');
  pass('Alert report verified on station');

  // Verify images/ subfolder exists on station
  final stationImagesDir = Directory('$foundAlertPath/images');
  if (!await stationImagesDir.exists()) {
    // List files in alert folder for debugging
    info('Files in station alert folder:');
    final alertDir = Directory(foundAlertPath!);
    await for (final file in alertDir.list(recursive: true)) {
      info('  ${file.path.replaceFirst(foundAlertPath!, '')}');
    }
    fail('Verify images folder', 'images/ subfolder not found on station');
    return false;
  }
  info('images/ subfolder exists on station');

  // Verify first photo exists on station (photo1Name includes 'images/' prefix)
  final photo1OnStation = File('$foundAlertPath/$photo1Name');
  if (!await photo1OnStation.exists()) {
    // List files in images folder for debugging
    info('Files in station images folder:');
    await for (final file in stationImagesDir.list()) {
      info('  ${file.path.split('/').last}');
    }
    fail('Verify photo 1', 'First photo not found on station: $photo1Name');
    return false;
  }
  final photo1StationSize = await photo1OnStation.length();
  info('First photo exists on station: $photo1Name ($photo1StationSize bytes)');
  pass('Photo 1 ($photo1Name) transferred to station');

  // Verify second photo exists on station
  final photo2OnStation = File('$foundAlertPath/$photo2Name');
  if (!await photo2OnStation.exists()) {
    info('Files in station images folder:');
    await for (final file in stationImagesDir.list()) {
      info('  ${file.path.split('/').last}');
    }
    fail('Verify photo 2', 'Second photo not found on station: $photo2Name');
    return false;
  }
  final photo2StationSize = await photo2OnStation.length();
  info('Second photo exists on station: $photo2Name ($photo2StationSize bytes)');
  pass('Photo 2 ($photo2Name) transferred to station');

  return true;
}

/// Test fetching alerts from station API
Future<bool> testFetchAlertsFromStation() async {
  section('Fetch Alerts from Station API');

  try {
    final response = await http.get(
      Uri.parse('http://localhost:$stationPort/api/alerts'),
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      fail('Fetch alerts', 'HTTP ${response.statusCode}');
      return false;
    }

    final data = jsonDecode(response.body);
    final alerts = data['alerts'] as List? ?? [];

    info('Station has ${alerts.length} alert(s)');

    // Find our test alert
    bool foundTestAlert = false;
    for (final alert in alerts) {
      final title = alert['title'] as String? ?? '';
      if (title.contains('Test Alert with Photos')) {
        foundTestAlert = true;
        info('Found test alert: ${alert['id']}');
        break;
      }
    }

    if (!foundTestAlert) {
      fail('Fetch alerts', 'Test alert not found in station API response');
      return false;
    }

    pass('Alerts fetched from station API');
    return true;
  } catch (e) {
    fail('Fetch alerts', 'Exception: $e');
    return false;
  }
}

// ============================================================
// Client B Tests - Sync Alerts from Station
// ============================================================

/// Launch Client B
Future<bool> testLaunchClientB() async {
  section('Launch Client B');

  _clientBProcess = await launchClientInstance(
    name: 'ClientB',
    port: clientBPort,
    dataDir: clientBDataDir,
    scanLocalhostRange: '$stationPort-$stationPort',
  );

  if (_clientBProcess == null) {
    fail('Launch client B', 'Failed to start process');
    return false;
  }

  await Future.delayed(startupWait);

  if (!await waitForReady('Client B', clientBPort)) {
    fail('Client B ready', 'Client B did not become ready');
    return false;
  }

  _clientBCallsign = await getCallsign(clientBPort);
  if (_clientBCallsign == null) {
    fail('Get client B callsign', 'Could not get callsign');
    return false;
  }

  pass('Client B launched: $_clientBCallsign');
  return true;
}

/// Connect Client B to the station
Future<bool> testConnectClientBToStation() async {
  section('Connect Client B to Station');

  await connectToStation(clientBPort);
  await Future.delayed(connectionWait);

  // Wait for client to be connected (now should have 2 clients)
  if (!await waitForClients(2)) {
    fail('Client B connection', 'Client B did not connect to station');
    return false;
  }

  pass('Client B connected to station');
  return true;
}

/// Sync alerts from station to Client B using debug API
/// This simulates what happens when a user navigates to the Alerts app
Future<bool> testSyncAlertsToClientB() async {
  section('Sync Alerts to Client B');

  // Use the alert_sync debug action to fetch alerts from the station
  // This is equivalent to opening the Alerts app in the UI
  final result = await debugAction(clientBPort, {
    'action': 'alert_sync',
  });

  if (result == null) {
    fail('Sync alerts', 'No response from debug API');
    return false;
  }

  if (result['success'] != true) {
    fail('Sync alerts', 'Failed to sync: ${result['error'] ?? result['message'] ?? 'unknown error'}');
    return false;
  }

  final alertCount = result['alert_count'] as int? ?? 0;
  info('Synced $alertCount alert(s) from station');
  info('Station: ${result['station_name']} (${result['station_callsign']})');

  if (alertCount == 0) {
    fail('Sync alerts', 'No alerts synced from station');
    return false;
  }

  // Check if our test alert was synced
  final alerts = result['alerts'] as List? ?? [];
  bool foundTestAlert = false;
  for (final alert in alerts) {
    final title = alert['title'] as String? ?? '';
    if (title.contains('Test Alert with Photos')) {
      foundTestAlert = true;
      info('Found test alert: ${alert['folder_name']}');
      break;
    }
  }

  if (!foundTestAlert) {
    fail('Sync alerts', 'Test alert not found in synced alerts');
    return false;
  }

  pass('Alerts synced to Client B');

  // Wait for photo downloads to complete
  await Future.delayed(const Duration(seconds: 3));
  return true;
}

/// Verify the alert and photos were downloaded to Client B
Future<bool> testVerifyAlertAndPhotosOnClientB() async {
  section('Verify Alert and Photos on Client B');

  if (_createdAlertFolderName == null || _clientBCallsign == null || _clientACallsign == null) {
    fail('Verify alert', 'Missing folder name or callsigns');
    return false;
  }

  // Client B stores synced alerts under the original author's callsign (Client A)
  // Path: {dataDir}/devices/{authorCallsign}/alerts/{folderName}/
  final clientBAlertsDir = Directory('$clientBDataDir/devices');

  if (!await clientBAlertsDir.exists()) {
    fail('Verify alert', 'Client B devices directory not found');
    return false;
  }

  // Search recursively for the alert folder
  bool alertFound = false;
  String? foundAlertPath;
  final folderName = _createdAlertFolderName!;

  await for (final entity in clientBAlertsDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final reportFile = File('${entity.path}/report.txt');
      if (await reportFile.exists()) {
        alertFound = true;
        foundAlertPath = entity.path;
        break;
      }
    }
  }

  if (!alertFound) {
    // List directory structure for debugging
    info('Listing Client B devices directory contents:');
    await for (final entity in clientBAlertsDir.list(recursive: true)) {
      info('  ${entity.path}');
    }
    fail('Verify alert', 'Alert folder not found on Client B: $folderName');
    return false;
  }

  info('Found alert at: $foundAlertPath');

  // Verify report content
  final reportFile = File('$foundAlertPath/report.txt');
  final reportContent = await reportFile.readAsString();

  if (!reportContent.contains('Test Alert with Photos')) {
    fail('Verify alert', 'Report does not contain expected title');
    return false;
  }

  info('Report content verified');
  pass('Alert report synced to Client B');

  // Verify images/ subfolder exists on Client B
  final clientBImagesDir = Directory('$foundAlertPath/images');
  if (!await clientBImagesDir.exists()) {
    info('Files in Client B alert folder:');
    final alertDir = Directory(foundAlertPath!);
    await for (final file in alertDir.list(recursive: true)) {
      info('  ${file.path.replaceFirst(foundAlertPath!, '')}');
    }
    fail('Verify images folder', 'images/ subfolder not found on Client B');
    return false;
  }
  info('images/ subfolder exists on Client B');

  // Verify first photo was downloaded (photo1Name includes 'images/' prefix)
  final photo1OnClientB = File('$foundAlertPath/$photo1Name');
  if (!await photo1OnClientB.exists()) {
    info('Files in Client B images folder:');
    await for (final file in clientBImagesDir.list()) {
      info('  ${file.path.split('/').last}');
    }
    fail('Verify photo 1', 'First photo not found on Client B: $photo1Name');
    return false;
  }
  final photo1ClientBSize = await photo1OnClientB.length();
  info('First photo exists on Client B: $photo1Name ($photo1ClientBSize bytes)');
  pass('Photo 1 ($photo1Name) downloaded to Client B');

  // Verify second photo was downloaded
  final photo2OnClientB = File('$foundAlertPath/$photo2Name');
  if (!await photo2OnClientB.exists()) {
    info('Files in Client B images folder:');
    await for (final file in clientBImagesDir.list()) {
      info('  ${file.path.split('/').last}');
    }
    fail('Verify photo 2', 'Second photo not found on Client B: $photo2Name');
    return false;
  }
  final photo2ClientBSize = await photo2OnClientB.length();
  info('Second photo exists on Client B: $photo2Name ($photo2ClientBSize bytes)');
  pass('Photo 2 ($photo2Name) downloaded to Client B');

  return true;
}

/// Test Client B pointing an alert and verify report.txt sync with station
Future<bool> testPointAlertFromClientB() async {
  section('Point Alert from Client B');

  if (_createdAlertId == null || _createdAlertFolderName == null) {
    fail('Point alert', 'Missing alert ID or folder name');
    return false;
  }

  // Step 1: Point the alert from Client B using debug API
  info('Pointing alert from Client B...');
  final result = await debugAction(clientBPort, {
    'action': 'alert_point',
    'alert_id': _createdAlertId,
  });

  if (result == null) {
    fail('Point alert', 'No response from debug API');
    return false;
  }

  if (result['success'] != true) {
    fail('Point alert', 'Failed to point: ${result['error'] ?? result['message'] ?? 'unknown error'}');
    return false;
  }

  final pointed = result['pointed'] as bool? ?? false;
  final pointCount = result['point_count'] as int? ?? 0;
  final pointedBy = result['pointed_by'] as List? ?? [];

  info('Alert ${pointed ? "pointed" : "unpointed"} by Client B');
  info('Point count: $pointCount');
  info('Pointed by: $pointedBy');

  if (!pointed) {
    fail('Point alert', 'Expected alert to be pointed, but it was unpointed');
    return false;
  }

  pass('Alert pointed from Client B');

  // Step 2: Wait for station sync to complete
  info('Waiting for station sync...');
  await Future.delayed(const Duration(seconds: 3));

  // Step 3: Find and read the report.txt from both Client B and Station
  final clientBAlertsDir = Directory('$clientBDataDir/devices');
  final stationAlertsDir = Directory('$stationDataDir/devices');
  final folderName = _createdAlertFolderName!;

  // Find Client B's report.txt
  String? clientBReportPath;
  await for (final entity in clientBAlertsDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final reportFile = File('${entity.path}/report.txt');
      if (await reportFile.exists()) {
        clientBReportPath = reportFile.path;
        break;
      }
    }
  }

  if (clientBReportPath == null) {
    fail('Compare reports', 'Client B report.txt not found');
    return false;
  }

  // Find Station's report.txt
  String? stationReportPath;
  await for (final entity in stationAlertsDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final reportFile = File('${entity.path}/report.txt');
      if (await reportFile.exists()) {
        stationReportPath = reportFile.path;
        break;
      }
    }
  }

  if (stationReportPath == null) {
    fail('Compare reports', 'Station report.txt not found');
    return false;
  }

  // Step 4: Read both report.txt files
  final clientBReport = await File(clientBReportPath).readAsString();
  final stationReport = await File(stationReportPath).readAsString();

  info('Client B report path: $clientBReportPath');
  info('Station report path: $stationReportPath');

  // Step 5: Read points from points.txt files and LAST_MODIFIED from report.txt
  final clientBAlertPath = clientBReportPath.replaceAll('/report.txt', '');
  final stationAlertPath = stationReportPath.replaceAll('/report.txt', '');

  // Verify points.txt files exist
  final clientBPointsFile = File('$clientBAlertPath/points.txt');
  final stationPointsFile = File('$stationAlertPath/points.txt');

  if (!await clientBPointsFile.exists()) {
    fail('Verify points.txt', 'Client B points.txt file does not exist at: ${clientBPointsFile.path}');
    return false;
  }
  pass('Client B points.txt file exists');

  if (!await stationPointsFile.exists()) {
    fail('Verify points.txt', 'Station points.txt file does not exist at: ${stationPointsFile.path}');
    return false;
  }
  pass('Station points.txt file exists');

  final clientBPointedByList = await _readPointsFile(clientBAlertPath);
  final stationPointedByList = await _readPointsFile(stationAlertPath);
  final stationLastModified = _extractField(stationReport, 'LAST_MODIFIED');

  info('Client B points.txt: $clientBPointedByList');
  info('Station points.txt: $stationPointedByList');
  info('Station LAST_MODIFIED: $stationLastModified');

  // Verify we have exactly 1 point (the one we just added)
  if (clientBPointedByList.length != 1) {
    fail('Verify point count', 'Expected 1 point in Client B points.txt, got: ${clientBPointedByList.length}');
    return false;
  }
  pass('Client B has exactly 1 point');

  // Verify the npub is valid format
  final npubInFile = clientBPointedByList.first;
  if (!npubInFile.startsWith('npub1')) {
    fail('Verify npub format', 'Invalid npub format in points.txt: $npubInFile');
    return false;
  }
  pass('Point npub has valid format: ${npubInFile.substring(0, 15)}...');

  // Step 6: Verify LAST_MODIFIED is present on station after receiving point
  if (stationLastModified.isEmpty) {
    fail('Verify LAST_MODIFIED', 'Station report.txt is missing LAST_MODIFIED field after receiving point');
    return false;
  }

  // Verify it's a valid ISO 8601 timestamp
  try {
    DateTime.parse(stationLastModified);
    pass('Station LAST_MODIFIED is present and valid: $stationLastModified');
  } catch (e) {
    fail('Verify LAST_MODIFIED', 'Station LAST_MODIFIED is not a valid ISO 8601 timestamp: $stationLastModified');
    return false;
  }

  // Step 7: Verify the point counts match
  if (clientBPointedByList.length != stationPointedByList.length) {
    fail('Compare points.txt', 'Point count mismatch: Client B=${clientBPointedByList.length}, Station=${stationPointedByList.length}');
    return false;
  }

  // Check all entries match (order-independent)
  final clientBSet = clientBPointedByList.toSet();
  final stationSet = stationPointedByList.toSet();

  if (!clientBSet.containsAll(stationSet) || !stationSet.containsAll(clientBSet)) {
    fail('Compare points.txt', 'Points entries mismatch: Client B=$clientBPointedByList, Station=$stationPointedByList');
    return false;
  }

  pass('Point count matches: ${clientBPointedByList.length}');
  pass('Points.txt matches: $clientBPointedByList');
  pass('Points are synchronized');

  return true;
}

/// Extract a field value from report.txt content
String _extractField(String content, String fieldName) {
  final regex = RegExp('^$fieldName: (.*)?\$', multiLine: true);
  final match = regex.firstMatch(content);
  return match?.group(1)?.trim() ?? '';
}

/// Find alert path by searching recursively
Future<String?> _findAlertPath(String dataDir, String callsign, String folderName) async {
  final alertsDir = Directory('$dataDir/devices/$callsign/alerts');
  if (!await alertsDir.exists()) return null;

  await for (final entity in alertsDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith('/$folderName')) {
      final reportFile = File('${entity.path}/report.txt');
      if (await reportFile.exists()) {
        return entity.path;
      }
    }
  }
  return null;
}

/// Parse POINTED_BY field value as a list of npubs (legacy format)
List<String> _parsePointedBy(String value) {
  if (value.isEmpty) return [];
  // Format is typically: npub1..., npub2..., ...
  return value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}

/// Read points from points.txt file (one npub per line)
Future<List<String>> _readPointsFile(String alertPath) async {
  final pointsFile = File('$alertPath/points.txt');
  if (!await pointsFile.exists()) return [];

  final content = await pointsFile.readAsString();
  return content.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
}

/// Test Client A syncing alerts from station and receiving the updated report.txt
/// This verifies that Client A gets the point added by Client B
Future<bool> testSyncAlertsToClientA() async {
  section('Sync Alerts to Client A (receive updates)');

  if (_createdAlertFolderName == null) {
    fail('Sync alerts', 'Missing alert folder name');
    return false;
  }

  // Step 1: Record the current state of Client A's report.txt before sync
  final clientAAlertsDir = Directory('$clientADataDir/devices');
  final folderName = _createdAlertFolderName!;

  String? clientAReportPathBefore;
  await for (final entity in clientAAlertsDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final reportFile = File('${entity.path}/report.txt');
      if (await reportFile.exists()) {
        clientAReportPathBefore = reportFile.path;
        break;
      }
    }
  }

  if (clientAReportPathBefore == null) {
    fail('Sync alerts', 'Client A report.txt not found before sync');
    return false;
  }

  // Read state before sync
  final clientAAlertPathBefore = clientAReportPathBefore.replaceAll('/report.txt', '');
  final pointsBeforeSync = await _readPointsFile(clientAAlertPathBefore);
  final reportBeforeSync = await File(clientAReportPathBefore).readAsString();
  final lastModifiedBefore = _extractField(reportBeforeSync, 'LAST_MODIFIED');

  info('Before sync - Point count: ${pointsBeforeSync.length}, LAST_MODIFIED: $lastModifiedBefore');

  // Step 2: Trigger alert sync on Client A using debug API
  info('Syncing alerts to Client A...');
  final result = await debugAction(clientAPort, {
    'action': 'alert_sync',
    'use_since': false,  // Force full sync to get all updates
  });

  if (result == null) {
    fail('Sync alerts', 'No response from debug API');
    return false;
  }

  if (result['success'] != true) {
    fail('Sync alerts', 'Failed to sync: ${result['error'] ?? result['message'] ?? 'unknown error'}');
    return false;
  }

  final alertCount = result['alert_count'] as int? ?? 0;
  info('Synced $alertCount alert(s) from station');
  pass('Alerts synced to Client A');

  // Wait for sync to complete
  await Future.delayed(const Duration(seconds: 2));

  // Step 3: Verify points.txt file was created/synced on Client A
  final clientAPointsFile = File('$clientAAlertPathBefore/points.txt');
  if (!await clientAPointsFile.exists()) {
    fail('Verify sync', 'Client A points.txt file does not exist after sync at: ${clientAPointsFile.path}');
    return false;
  }
  pass('Client A points.txt file exists after sync');

  // Read Client A's points.txt after sync
  final clientAPointedByList = await _readPointsFile(clientAAlertPathBefore);
  final reportAfterSync = await File(clientAReportPathBefore).readAsString();
  final lastModifiedAfter = _extractField(reportAfterSync, 'LAST_MODIFIED');

  info('After sync - Point count: ${clientAPointedByList.length}, LAST_MODIFIED: $lastModifiedAfter');
  info('After sync - Points: $clientAPointedByList');

  // Step 4: Verify Client A now has the updated point count (1 point)
  if (clientAPointedByList.length != 1) {
    fail('Verify sync', 'Expected 1 point after sync, got: ${clientAPointedByList.length}');
    return false;
  }

  pass('Client A received updated point count: ${clientAPointedByList.length}');

  // Verify the npub is valid format
  final syncedNpub = clientAPointedByList.first;
  if (!syncedNpub.startsWith('npub1')) {
    fail('Verify npub format', 'Invalid npub format in synced points.txt: $syncedNpub');
    return false;
  }
  pass('Synced npub has valid format: ${syncedNpub.substring(0, 15)}...');

  // Step 5: Verify LAST_MODIFIED is present
  if (lastModifiedAfter.isEmpty) {
    fail('Verify sync', 'LAST_MODIFIED is missing after sync');
    return false;
  }

  pass('Client A received LAST_MODIFIED: $lastModifiedAfter');

  // Step 6: Compare Client A's points.txt with Station's points.txt
  final stationAlertsDir = Directory('$stationDataDir/devices');
  String? stationAlertPath;

  await for (final entity in stationAlertsDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final reportFile = File('${entity.path}/report.txt');
      if (await reportFile.exists()) {
        stationAlertPath = entity.path;
        break;
      }
    }
  }

  if (stationAlertPath == null) {
    fail('Verify sync', 'Station alert folder not found');
    return false;
  }

  final stationPointedByList = await _readPointsFile(stationAlertPath);
  final stationReport = await File('$stationAlertPath/report.txt').readAsString();
  final stationLastModified = _extractField(stationReport, 'LAST_MODIFIED');

  // Verify point counts match
  if (clientAPointedByList.length != stationPointedByList.length) {
    fail('Verify sync', 'Point count mismatch: Client A=${clientAPointedByList.length}, Station=${stationPointedByList.length}');
    return false;
  }

  // Verify points.txt entries match (order-independent)
  final clientASet = clientAPointedByList.toSet();
  final stationSet = stationPointedByList.toSet();

  if (!clientASet.containsAll(stationSet) || !stationSet.containsAll(clientASet)) {
    fail('Verify sync', 'Points entries mismatch: Client A=$clientAPointedByList, Station=$stationPointedByList');
    return false;
  }

  pass('Client A point count matches Station: ${clientAPointedByList.length}');
  pass('Client A points.txt matches Station: $clientAPointedByList');

  // Verify LAST_MODIFIED matches
  if (lastModifiedAfter != stationLastModified) {
    fail('Verify sync', 'LAST_MODIFIED mismatch: Client A=$lastModifiedAfter, Station=$stationLastModified');
    return false;
  }

  pass('Client A LAST_MODIFIED matches Station: $lastModifiedAfter');
  pass('Client A synchronized with Station');

  return true;
}

/// Test Client B adding a comment to an alert and verify it syncs to station
Future<bool> testCommentAlertFromClientB() async {
  section('Comment Alert from Client B');

  if (_createdAlertId == null || _createdAlertFolderName == null) {
    fail('Comment alert', 'Missing alert ID or folder name');
    return false;
  }

  final commentContent = 'This is a test comment from Client B confirming the issue.';

  // Debug: List alerts on Client B before commenting
  info('Debug: Listing alerts on Client B before comment...');
  final listResult = await debugAction(clientBPort, {
    'action': 'alert_list',
  });
  if (listResult != null && listResult['success'] == true) {
    final alerts = listResult['alerts'] as List? ?? [];
    info('Client B has ${alerts.length} alert(s)');
    for (final alert in alerts) {
      info('  - Alert ID: ${alert['id']}, Folder: ${alert['folder_name']}, Title: ${alert['title']}');
    }
  } else {
    info('Failed to list alerts: ${listResult?['error'] ?? 'unknown'}');
  }

  info('Using alert_id: $_createdAlertId');
  info('Using folder_name: $_createdAlertFolderName');

  // Step 1: Add comment from Client B using debug API
  info('Adding comment from Client B...');
  final result = await debugAction(clientBPort, {
    'action': 'alert_comment',
    'alert_id': _createdAlertId,
    'content': commentContent,
  });

  if (result == null) {
    fail('Comment alert', 'No response from debug API');
    return false;
  }

  if (result['success'] != true) {
    fail('Comment alert', 'Failed to add comment: ${result['error'] ?? result['message'] ?? 'unknown error'}');
    return false;
  }

  final commentFile = result['comment_file'] as String?;
  final author = result['author'] as String?;
  final created = result['created'] as String?;

  info('Comment added by $author');
  info('Comment file: $commentFile');
  info('Created: $created');

  pass('Comment added from Client B');

  // Step 2: Wait for station sync to complete
  info('Waiting for station sync...');
  await Future.delayed(const Duration(seconds: 3));

  // Step 3: Verify comment exists on station
  final stationAlertsDir = Directory('$stationDataDir/devices');
  final folderName = _createdAlertFolderName!;

  String? stationCommentsDir;
  await for (final entity in stationAlertsDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final commentsPath = '${entity.path}/comments';
      if (await Directory(commentsPath).exists()) {
        stationCommentsDir = commentsPath;
        break;
      }
    }
  }

  if (stationCommentsDir == null) {
    fail('Verify comment on station', 'Comments directory not found on station');
    return false;
  }

  // Find the comment file on station
  final stationComments = await Directory(stationCommentsDir).list().toList();
  final txtFiles = stationComments.where((e) => e.path.endsWith('.txt')).toList();

  if (txtFiles.isEmpty) {
    fail('Verify comment on station', 'No comment files found on station');
    return false;
  }

  info('Station has ${txtFiles.length} comment(s)');

  // Read and verify the comment content on station
  final stationCommentFile = txtFiles.first as File;
  final stationCommentContent = await stationCommentFile.readAsString();

  if (!stationCommentContent.contains(commentContent)) {
    fail('Verify comment content', 'Comment content not found on station');
    return false;
  }

  pass('Comment synced to station');
  info('Station comment path: ${stationCommentFile.path}');

  // Step 4: Verify Client B has the comment locally
  final clientBAlertsDir = Directory('$clientBDataDir/devices');
  String? clientBCommentsDir;

  await for (final entity in clientBAlertsDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final commentsPath = '${entity.path}/comments';
      if (await Directory(commentsPath).exists()) {
        clientBCommentsDir = commentsPath;
        break;
      }
    }
  }

  if (clientBCommentsDir == null) {
    fail('Verify comment on Client B', 'Comments directory not found on Client B');
    return false;
  }

  final clientBComments = await Directory(clientBCommentsDir).list().toList();
  final clientBTxtFiles = clientBComments.where((e) => e.path.endsWith('.txt')).toList();

  if (clientBTxtFiles.isEmpty) {
    fail('Verify comment on Client B', 'No comment files found on Client B');
    return false;
  }

  info('Client B has ${clientBTxtFiles.length} comment(s)');
  pass('Comment verified on Client B');

  // Step 5: Verify LAST_MODIFIED was updated on station
  String? stationReportPath;
  await for (final entity in stationAlertsDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final reportFile = File('${entity.path}/report.txt');
      if (await reportFile.exists()) {
        stationReportPath = reportFile.path;
        break;
      }
    }
  }

  if (stationReportPath != null) {
    final stationReport = await File(stationReportPath).readAsString();
    final stationLastModified = _extractField(stationReport, 'LAST_MODIFIED');

    if (stationLastModified.isNotEmpty) {
      pass('Station LAST_MODIFIED updated: $stationLastModified');
    } else {
      info('Warning: Station LAST_MODIFIED not found');
    }
  }

  pass('Comment flow verified: Client B -> Station');

  return true;
}

/// Test Client A syncing to receive the comment from station
Future<bool> testSyncCommentToClientA() async {
  section('Sync Comment to Client A');

  if (_createdAlertFolderName == null) {
    fail('Sync comment', 'Missing alert folder name');
    return false;
  }

  final folderName = _createdAlertFolderName!;

  // Step 1: Trigger alert sync on Client A
  info('Syncing alerts to Client A (to get comment)...');
  final result = await debugAction(clientAPort, {
    'action': 'alert_sync',
    'use_since': false,
  });

  if (result == null || result['success'] != true) {
    fail('Sync alerts', 'Failed to sync alerts to Client A');
    return false;
  }

  pass('Alerts synced to Client A');

  // Wait for sync to complete
  await Future.delayed(const Duration(seconds: 2));

  // Step 2: Verify Client A has the comment
  final clientAAlertsDir = Directory('$clientADataDir/devices');
  String? clientACommentsDir;

  await for (final entity in clientAAlertsDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final commentsPath = '${entity.path}/comments';
      if (await Directory(commentsPath).exists()) {
        clientACommentsDir = commentsPath;
        break;
      }
    }
  }

  if (clientACommentsDir == null) {
    fail('Verify comment on Client A', 'Comments directory not found on Client A');
    return false;
  }

  final clientAComments = await Directory(clientACommentsDir).list().toList();
  final clientATxtFiles = clientAComments.where((e) => e.path.endsWith('.txt')).toList();

  if (clientATxtFiles.isEmpty) {
    fail('Verify comment on Client A', 'No comment files found on Client A');
    return false;
  }

  info('Client A has ${clientATxtFiles.length} comment(s)');

  // Read and verify the comment content
  final clientACommentFile = clientATxtFiles.first as File;
  final clientACommentContent = await clientACommentFile.readAsString();

  if (!clientACommentContent.contains('test comment from Client B')) {
    fail('Verify comment content on Client A', 'Expected comment content not found');
    return false;
  }

  pass('Comment downloaded to Client A');
  info('Client A comment path: ${clientACommentFile.path}');

  // Step 3: Compare comment files between station and Client A
  final stationAlertsDir = Directory('$stationDataDir/devices');
  String? stationCommentPath;

  await for (final entity in stationAlertsDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final commentsDir = Directory('${entity.path}/comments');
      if (await commentsDir.exists()) {
        final comments = await commentsDir.list().toList();
        final txtFiles = comments.where((e) => e.path.endsWith('.txt')).toList();
        if (txtFiles.isNotEmpty) {
          stationCommentPath = txtFiles.first.path;
        }
        break;
      }
    }
  }

  if (stationCommentPath != null) {
    final stationComment = await File(stationCommentPath).readAsString();

    // Verify both have the same AUTHOR field
    final stationAuthor = _extractField(stationComment, 'AUTHOR');
    final clientAAuthor = _extractField(clientACommentContent, 'AUTHOR');

    if (stationAuthor == clientAAuthor) {
      pass('Comment AUTHOR matches: $stationAuthor');
    } else {
      fail('Compare comments', 'AUTHOR mismatch: Station=$stationAuthor, Client A=$clientAAuthor');
      return false;
    }
  }

  pass('Comment synchronized: Station -> Client A');
  pass('Full comment flow verified: Client B -> Station -> Client A');

  return true;
}

// ============================================================
// Folder Structure Consistency Test
// ============================================================

/// Test that all three instances have the same folder structure after sync
Future<bool> testVerifyFolderStructureConsistency() async {
  section('Verify Folder Structure Consistency');

  if (_createdAlertFolderName == null) {
    fail('Verify structure', 'Missing alert folder name');
    return false;
  }

  final folderName = _createdAlertFolderName!;

  // Find alert paths on all three instances
  String? clientAAlertPath;
  String? stationAlertPath;
  String? clientBAlertPath;

  // Find Client A alert path
  final clientADir = Directory('$clientADataDir/devices');
  await for (final entity in clientADir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final reportFile = File('${entity.path}/report.txt');
      if (await reportFile.exists()) {
        clientAAlertPath = entity.path;
        break;
      }
    }
  }

  // Find Station alert path
  final stationDir = Directory('$stationDataDir/devices');
  await for (final entity in stationDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final reportFile = File('${entity.path}/report.txt');
      if (await reportFile.exists()) {
        stationAlertPath = entity.path;
        break;
      }
    }
  }

  // Find Client B alert path
  final clientBDir = Directory('$clientBDataDir/devices');
  await for (final entity in clientBDir.list(recursive: true)) {
    if (entity is Directory && entity.path.endsWith(folderName)) {
      final reportFile = File('${entity.path}/report.txt');
      if (await reportFile.exists()) {
        clientBAlertPath = entity.path;
        break;
      }
    }
  }

  if (clientAAlertPath == null || stationAlertPath == null || clientBAlertPath == null) {
    fail('Find alert paths', 'Could not find alert on all instances: '
        'ClientA=${clientAAlertPath != null}, Station=${stationAlertPath != null}, ClientB=${clientBAlertPath != null}');
    return false;
  }

  info('Client A path: $clientAAlertPath');
  info('Station path: $stationAlertPath');
  info('Client B path: $clientBAlertPath');

  // Get relative folder structure for each instance (relative to {callsign}/alerts/)
  final clientARelPath = _extractRelativeAlertPath(clientAAlertPath);
  final stationRelPath = _extractRelativeAlertPath(stationAlertPath);
  final clientBRelPath = _extractRelativeAlertPath(clientBAlertPath);

  info('Client A relative path: $clientARelPath');
  info('Station relative path: $stationRelPath');
  info('Client B relative path: $clientBRelPath');

  // Verify all have same structure: active/{regionFolder}/{folderName}
  if (clientARelPath != stationRelPath || stationRelPath != clientBRelPath) {
    fail('Verify path consistency', 'Relative paths differ: ClientA=$clientARelPath, Station=$stationRelPath, ClientB=$clientBRelPath');
    return false;
  }

  pass('Alert path structure consistent: $clientARelPath');

  // Verify folder name uses timestamp format (YYYY-MM-DD_HH-MM_*)
  final timestampPattern = RegExp(r'^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}_');
  if (!timestampPattern.hasMatch(folderName)) {
    fail('Verify folder naming', 'Folder name does not use timestamp format: $folderName');
    return false;
  }
  pass('Folder uses timestamp format: $folderName');

  // Verify region folder format (e.g., 38.7_-9.1)
  final regionPattern = RegExp(r'active/(-?\d+\.?\d*)_(-?\d+\.?\d*)/$folderName');
  if (!regionPattern.hasMatch(clientARelPath)) {
    // Check if it at least has the active/{something}/{folderName} structure
    if (!clientARelPath.startsWith('active/') || !clientARelPath.endsWith('/$folderName')) {
      fail('Verify region folder', 'Path structure incorrect: $clientARelPath');
      return false;
    }
  }
  pass('Region folder structure correct');

  // Verify internal folder contents match across all instances
  final clientAContents = await _getAlertFolderContents(clientAAlertPath);
  final stationContents = await _getAlertFolderContents(stationAlertPath);
  final clientBContents = await _getAlertFolderContents(clientBAlertPath);

  info('Client A contents: $clientAContents');
  info('Station contents: $stationContents');
  info('Client B contents: $clientBContents');

  // All should have these essential items (points.txt is created after pointing test)
  final requiredItems = ['report.txt', 'points.txt', 'images/', 'images/photo1.png', 'images/photo2.png', 'comments/'];

  for (final item in requiredItems) {
    if (!clientAContents.contains(item)) {
      fail('Verify Client A contents', 'Missing: $item');
      return false;
    }
    if (!stationContents.contains(item)) {
      fail('Verify Station contents', 'Missing: $item');
      return false;
    }
    if (!clientBContents.contains(item)) {
      fail('Verify Client B contents', 'Missing: $item');
      return false;
    }
  }

  pass('All instances have required items: ${requiredItems.join(', ')}');

  // Verify points.txt content matches across all instances
  final clientAPoints = await _readPointsFile(clientAAlertPath);
  final stationPoints = await _readPointsFile(stationAlertPath);
  final clientBPoints = await _readPointsFile(clientBAlertPath);

  info('Client A points: $clientAPoints');
  info('Station points: $stationPoints');
  info('Client B points: $clientBPoints');

  // All should have the same points
  final clientAPointSet = clientAPoints.toSet();
  final stationPointSet = stationPoints.toSet();
  final clientBPointSet = clientBPoints.toSet();

  if (clientAPointSet.length != stationPointSet.length ||
      stationPointSet.length != clientBPointSet.length) {
    fail('Verify points.txt consistency', 'Point count mismatch: ClientA=${clientAPoints.length}, Station=${stationPoints.length}, ClientB=${clientBPoints.length}');
    return false;
  }

  if (!clientAPointSet.containsAll(stationPointSet) || !stationPointSet.containsAll(clientBPointSet)) {
    fail('Verify points.txt consistency', 'Points content mismatch across instances');
    return false;
  }

  pass('Points.txt content consistent across all instances: ${clientAPoints.length} point(s)');

  // Verify comments directory has at least one comment with correct naming format
  final commentPattern = RegExp(r'comments/\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_[A-Z0-9]{6}\.txt');

  bool clientAHasComment = clientAContents.any((item) => commentPattern.hasMatch(item));
  bool stationHasComment = stationContents.any((item) => commentPattern.hasMatch(item));
  bool clientBHasComment = clientBContents.any((item) => commentPattern.hasMatch(item));

  if (!clientAHasComment || !stationHasComment || !clientBHasComment) {
    fail('Verify comment files', 'Not all instances have properly named comment files: '
        'ClientA=$clientAHasComment, Station=$stationHasComment, ClientB=$clientBHasComment');
    return false;
  }

  pass('Comment files use correct naming format (YYYY-MM-DD_HH-MM-SS_XXXXXX.txt)');

  // Count comment files - should be the same across all
  final clientACommentCount = clientAContents.where((item) => commentPattern.hasMatch(item)).length;
  final stationCommentCount = stationContents.where((item) => commentPattern.hasMatch(item)).length;
  final clientBCommentCount = clientBContents.where((item) => commentPattern.hasMatch(item)).length;

  if (clientACommentCount != stationCommentCount || stationCommentCount != clientBCommentCount) {
    warn('Comment count mismatch: ClientA=$clientACommentCount, Station=$stationCommentCount, ClientB=$clientBCommentCount');
  } else {
    pass('Comment count consistent: $clientACommentCount');
  }

  pass('Folder structure is consistent across Client A, Station, and Client B');
  return true;
}

/// Extract relative alert path from full path (e.g., active/38.7_-9.1/2025-12-14_15-32_test)
String _extractRelativeAlertPath(String fullPath) {
  // Find "alerts/" in the path and return everything after it
  final alertsIndex = fullPath.indexOf('/alerts/');
  if (alertsIndex == -1) return fullPath;
  return fullPath.substring(alertsIndex + '/alerts/'.length);
}

/// Get list of items in alert folder (files and directories with relative paths)
Future<List<String>> _getAlertFolderContents(String alertPath) async {
  final contents = <String>[];
  final alertDir = Directory(alertPath);

  await for (final entity in alertDir.list(recursive: true)) {
    // Get relative path
    var relativePath = entity.path.substring(alertPath.length);
    if (relativePath.startsWith('/')) relativePath = relativePath.substring(1);

    if (entity is Directory) {
      contents.add('$relativePath/');
    } else {
      contents.add(relativePath);
    }
  }

  contents.sort();
  return contents;
}

// ============================================================
// Main Entry Point
// ============================================================

Future<void> main() async {
  print('');
  print('\x1B[1m' + '=' * 60 + '\x1B[0m');
  print('\x1B[1mGeogram Desktop Alert App Test Suite\x1B[0m');
  print('\x1B[1m' + '=' * 60 + '\x1B[0m');

  try {
    await testSetup();

    // Launch instances
    if (!await testLaunchStation()) {
      await cleanup();
      exit(1);
    }

    if (!await testLaunchClientA()) {
      await cleanup();
      exit(1);
    }

    if (!await testConnectClientToStation()) {
      await cleanup();
      exit(1);
    }

    await testVerifySetup();

    // ==========================================================
    // Alert Tests with Photos
    // ==========================================================

    if (!await testCreateAlertWithPhotos()) {
      await cleanup();
      exit(1);
    }

    if (!await testShareAlertToStation()) {
      await cleanup();
      exit(1);
    }

    if (!await testVerifyAlertAndPhotosOnStation()) {
      await cleanup();
      exit(1);
    }

    if (!await testFetchAlertsFromStation()) {
      await cleanup();
      exit(1);
    }

    // ==========================================================
    // Client B Tests - Sync and Download from Station
    // ==========================================================

    if (!await testLaunchClientB()) {
      await cleanup();
      exit(1);
    }

    if (!await testConnectClientBToStation()) {
      await cleanup();
      exit(1);
    }

    if (!await testSyncAlertsToClientB()) {
      await cleanup();
      exit(1);
    }

    if (!await testVerifyAlertAndPhotosOnClientB()) {
      await cleanup();
      exit(1);
    }

    if (!await testPointAlertFromClientB()) {
      await cleanup();
      exit(1);
    }

    if (!await testSyncAlertsToClientA()) {
      await cleanup();
      exit(1);
    }

    // ==========================================================
    // Comment Tests - Client B adds comment, Client A syncs
    // ==========================================================

    if (!await testCommentAlertFromClientB()) {
      await cleanup();
      exit(1);
    }

    if (!await testSyncCommentToClientA()) {
      await cleanup();
      exit(1);
    }

    // ==========================================================
    // Folder Structure Consistency Test
    // ==========================================================

    if (!await testVerifyFolderStructureConsistency()) {
      await cleanup();
      exit(1);
    }

    // ==========================================================
    // ADD MORE TESTS HERE INCREMENTALLY
    // ==========================================================

    // Summary
    print('');
    print('\x1B[1m' + '=' * 60 + '\x1B[0m');
    print('\x1B[1mTest Results\x1B[0m');
    print('\x1B[1m' + '=' * 60 + '\x1B[0m');
    print('\x1B[32mPassed: $_passed\x1B[0m');
    if (_failed > 0) {
      print('\x1B[31mFailed: $_failed\x1B[0m');
      print('');
      print('Failures:');
      for (final failure in _failures) {
        print('  - $failure');
      }
    }
    print('');

    info('Station callsign: $_stationCallsign');
    info('Client A callsign: $_clientACallsign');
    info('Client B callsign: $_clientBCallsign');
    print('');
  } finally {
    await cleanup();
  }

  exit(_failed > 0 ? 1 : 0);
}
