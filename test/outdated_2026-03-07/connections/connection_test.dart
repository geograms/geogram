// Connection Test Suite: BLE, LAN, Internet (Station)
// Tests connectivity between two Android devices via three transport methods.
//
// Run with: dart run tests/connections/connection_test.dart [DEVICE_A_IP:PORT] [DEVICE_B_IP:PORT]
// Default devices:
//   Device A: 192.168.178.36:3456
//   Device B: 192.168.178.28:3456

import 'dart:convert';
import 'dart:io';

int testsPassed = 0;
int testsFailed = 0;
List<String> failures = [];

void pass(String message) {
  testsPassed++;
  print('  [PASS] $message');
}

void fail(String message, [String? details]) {
  testsFailed++;
  failures.add(message);
  print('  [FAIL] $message');
  if (details != null) print('         Details: $details');
}

void info(String message) {
  print('[INFO] $message');
}

void section(String title) {
  print('');
  print('━' * 70);
  print('  $title');
  print('━' * 70);
}

Future<Map<String, dynamic>?> httpGet(String host, int port, String path) async {
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    final request = await client.get(host, port, path);
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await response.transform(utf8.decoder).join();
    client.close();
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (e) {
    return null;
  }
}

Future<Map<String, dynamic>?> debugAction(
  String host,
  int port,
  String action, [
  Map<String, dynamic>? extraParams,
]) async {
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    final request = await client.post(host, port, '/api/debug');
    request.headers.contentType = ContentType.json;
    final payload = <String, dynamic>{'action': action};
    if (extraParams != null) payload.addAll(extraParams);
    request.write(jsonEncode(payload));
    final response = await request.close().timeout(const Duration(seconds: 30));
    final body = await response.transform(utf8.decoder).join();
    client.close();
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (e) {
    return null;
  }
}

(String host, int port) parseAddress(String address) {
  final parts = address.split(':');
  final host = parts[0];
  final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 3456 : 3456;
  return (host, port);
}

void main(List<String> args) async {
  final addressA = args.isNotEmpty ? args[0] : '192.168.178.36:3456';
  final addressB = args.length > 1 ? args[1] : '192.168.178.28:3456';
  final (hostA, portA) = parseAddress(addressA);
  final (hostB, portB) = parseAddress(addressB);

  print('');
  print('=' * 70);
  print('         Connection Test Suite: BLE, LAN, Internet');
  print('=' * 70);
  print('');
  info('Device A: $hostA:$portA');
  info('Device B: $hostB:$portB');

  // ── Phase 1: LAN Reachability ──────────────────────────────

  section('PHASE 1: LAN Reachability');

  final statusA = await httpGet(hostA, portA, '/api/status');
  final callsignA = statusA?['callsign'] as String?;
  if (callsignA != null && callsignA.isNotEmpty) {
    pass('Device A reachable: $callsignA');
  } else {
    fail('Cannot reach Device A at $hostA:$portA');
    print('Make sure Device A is running Geogram with HTTP API enabled.');
    exit(1);
  }

  final statusB = await httpGet(hostB, portB, '/api/status');
  final callsignB = statusB?['callsign'] as String?;
  if (callsignB != null && callsignB.isNotEmpty) {
    pass('Device B reachable: $callsignB');
  } else {
    fail('Cannot reach Device B at $hostB:$portB');
    print('Make sure Device B is running Geogram with HTTP API enabled.');
    exit(1);
  }

  info('Callsigns: A=$callsignA, B=$callsignB');

  // ── Phase 2: Device Discovery ──────────────────────────────

  section('PHASE 2: Device Discovery');

  info('Triggering local_scan on both devices...');
  await Future.wait([
    debugAction(hostA, portA, 'local_scan'),
    debugAction(hostB, portB, 'local_scan'),
  ]);
  await Future.delayed(const Duration(seconds: 3));

  // Check A knows B
  final devicesA = await debugAction(hostA, portA, 'list_devices');
  final deviceListA = devicesA?['devices'] as List<dynamic>? ?? [];
  final aKnowsB = deviceListA.any((d) => d['callsign'] == callsignB);
  if (aKnowsB) {
    pass('Device A knows Device B ($callsignB)');
  } else {
    info('Device A does not know $callsignB — attempting add_device');
    final addResult = await debugAction(hostA, portA, 'add_device', {
      'callsign': callsignB,
      'url': 'http://$hostB:$portB',
    });
    if (addResult?['success'] == true) {
      pass('Added Device B to Device A');
    } else {
      fail('Could not add Device B to Device A', addResult?['error']?.toString());
    }
  }

  // Check B knows A
  final devicesB = await debugAction(hostB, portB, 'list_devices');
  final deviceListB = devicesB?['devices'] as List<dynamic>? ?? [];
  final bKnowsA = deviceListB.any((d) => d['callsign'] == callsignA);
  if (bKnowsA) {
    pass('Device B knows Device A ($callsignA)');
  } else {
    info('Device B does not know $callsignA — attempting add_device');
    final addResult = await debugAction(hostB, portB, 'add_device', {
      'callsign': callsignA,
      'url': 'http://$hostA:$portA',
    });
    if (addResult?['success'] == true) {
      pass('Added Device A to Device B');
    } else {
      fail('Could not add Device A to Device B', addResult?['error']?.toString());
    }
  }

  // ── Phase 3: BLE Discovery ─────────────────────────────────

  section('PHASE 3: BLE Discovery');

  info('Triggering ble_scan on both devices...');
  await Future.wait([
    debugAction(hostA, portA, 'ble_scan'),
    debugAction(hostB, portB, 'ble_scan'),
  ]);

  info('Waiting 10s for BLE discovery...');
  await Future.delayed(const Duration(seconds: 10));

  // Re-check device lists for BLE transport availability
  final pingBleCheckA = await debugAction(hostA, portA, 'device_ping', {
    'callsign': callsignB,
    'transport': 'ble',
  });
  final bleAvailA = pingBleCheckA?['available_transports'] as List<dynamic>? ?? [];
  if (bleAvailA.contains('ble')) {
    pass('BLE transport available on Device A for $callsignB');
  } else {
    fail('BLE transport not available on Device A for $callsignB', 'Available: $bleAvailA');
  }

  // ── Phase 4: Station Connectivity ──────────────────────────

  section('PHASE 4: Station Connectivity');

  final stationA = await debugAction(hostA, portA, 'station_status');
  final stationConnectedA = stationA?['connected'] == true;
  final stationUrlA = stationA?['station_url'] ?? 'unknown';
  info('Device A station: connected=$stationConnectedA url=$stationUrlA');

  final stationB = await debugAction(hostB, portB, 'station_status');
  final stationConnectedB = stationB?['connected'] == true;
  final stationUrlB = stationB?['station_url'] ?? 'unknown';
  info('Device B station: connected=$stationConnectedB url=$stationUrlB');

  if (stationConnectedA) {
    pass('Device A connected to station');
  } else {
    fail('Device A not connected to station');
  }
  if (stationConnectedB) {
    pass('Device B connected to station');
  } else {
    fail('Device B not connected to station');
  }

  // ── Phase 5: Transport-Specific Pings ──────────────────────

  section('PHASE 5: Transport-Specific Pings');

  for (final transport in ['lan', 'ble', 'station', 'all']) {
    info('--- transport: $transport ---');

    // A → B
    final resultAB = await debugAction(hostA, portA, 'device_ping', {
      'callsign': callsignB,
      'transport': transport,
    });
    final successAB = resultAB?['success'] == true;
    final transportUsedAB = resultAB?['transport_used'] ?? 'none';
    final latencyAB = resultAB?['latency_ms'] ?? '?';
    final errorAB = resultAB?['error'];

    if (successAB) {
      pass('A→B [$transport]: ${latencyAB}ms via $transportUsedAB');
    } else {
      fail('A→B [$transport] ping failed', errorAB?.toString());
    }

    // B → A
    final resultBA = await debugAction(hostB, portB, 'device_ping', {
      'callsign': callsignA,
      'transport': transport,
    });
    final successBA = resultBA?['success'] == true;
    final transportUsedBA = resultBA?['transport_used'] ?? 'none';
    final latencyBA = resultBA?['latency_ms'] ?? '?';
    final errorBA = resultBA?['error'];

    if (successBA) {
      pass('B→A [$transport]: ${latencyBA}ms via $transportUsedBA');
    } else {
      fail('B→A [$transport] ping failed', errorBA?.toString());
    }
  }

  // ── Summary ────────────────────────────────────────────────

  print('');
  print('=' * 70);
  final total = testsPassed + testsFailed;
  if (testsFailed == 0) {
    print('         ALL TESTS PASSED! ($testsPassed/$total)');
  } else {
    print('         TESTS: $testsPassed passed, $testsFailed failed ($total total)');
    print('');
    print('  Failures:');
    for (final f in failures) {
      print('    - $f');
    }
  }
  print('=' * 70);
  print('');

  exit(testsFailed > 0 ? 1 : 0);
}
