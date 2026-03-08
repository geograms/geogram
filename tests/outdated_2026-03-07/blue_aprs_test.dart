/*
 * BlueAPRS integration test — tests BLE ↔ APRS-IS bridge via debug API.
 *
 * Usage:
 *   dart run tests/blue_aprs_test.dart [--host localhost] [--port 3456]
 *
 * Requires a running geogram instance with APRS enabled.
 * Uses simulated BLE clients (no real Bluetooth needed).
 *
 * Tests:
 *   1. iGate TX — BLE client sends message through APRS-IS
 *   2. iGate RX — APRS-IS message routed to BLE client
 *   3. BLE-to-BLE repeater
 */

import 'dart:convert';
import 'dart:io';

Future<Map<String, dynamic>> apiCall(
  HttpClient client,
  String host,
  int port,
  Map<String, dynamic> body,
) async {
  final request = await client.postUrl(Uri.parse('http://$host:$port/api/debug'));
  request.headers.set('content-type', 'application/json');
  request.write(jsonEncode(body));
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return jsonDecode(responseBody) as Map<String, dynamic>;
}

void assert_(bool condition, String message) {
  if (!condition) {
    print('  FAIL: $message');
    exitCode = 1;
  } else {
    print('  PASS: $message');
  }
}

void main(List<String> args) async {
  String host = 'localhost';
  int port = 3456;

  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--host' && i + 1 < args.length) {
      host = args[i + 1];
      i++;
    } else if (args[i] == '--port' && i + 1 < args.length) {
      port = int.tryParse(args[i + 1]) ?? port;
      i++;
    }
  }

  print('BlueAPRS Integration Test');
  print('Target: http://$host:$port');
  print('---');

  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 10);

  try {
    // Pre-check: APRS must be enabled
    print('\n[Pre-check] Verifying APRS is enabled...');
    final aprsStatus = await apiCall(client, host, port, {'action': 'aprs_status'});
    assert_(aprsStatus['success'] == true, 'APRS status query');
    if (aprsStatus['enabled'] != true) {
      print('  APRS is not enabled. Attempting to enable...');
      final enableResult = await apiCall(client, host, port, {'action': 'aprs_enable'});
      if (enableResult['success'] != true) {
        print('  ERROR: Could not enable APRS: ${enableResult['error']}');
        print('  Make sure location is set first (aprs_set_location)');
        exit(1);
      }
      print('  APRS enabled successfully');
      // Wait for connection
      await Future.delayed(const Duration(seconds: 3));
    }
    print('  APRS is enabled and ${aprsStatus['connected'] == true ? 'connected' : 'connecting'}');

    // =========================================================================
    // Test 1: iGate TX — BLE client sends through APRS-IS
    // =========================================================================
    print('\n[Test 1] iGate TX — BLE client sends through APRS-IS');

    // Register simulated BLE client
    final reg1 = await apiCall(client, host, port, {
      'action': 'blue_aprs_register_client',
      'deviceId': 'sim-ble-1',
      'callsign': 'BLE1-5',
    });
    assert_(reg1['success'] == true, 'Register simulated client BLE1-5');

    // Check status
    final status1 = await apiCall(client, host, port, {'action': 'blue_aprs_status'});
    assert_(status1['success'] == true, 'BlueAPRS status query');
    assert_(status1['active'] == true, 'BlueAPRS bridge is active');
    final clients1 = status1['bleClients'] as List;
    assert_(
      clients1.any((c) => c['callsign'] == 'BLE1-5' && c['deviceId'] == 'sim-ble-1'),
      'BLE1-5 appears in bleClients',
    );

    // Inject BLE geochat message
    final injectGeo = await apiCall(client, host, port, {
      'action': 'blue_aprs_inject_ble',
      'callsign': 'BLE1-5',
      'type': 'geochat',
      'text': 'BLE station reachable via BlueAPRS iGate',
      'lat': 38.7223,
      'lon': -9.1393,
    });
    assert_(injectGeo['success'] == true, 'Inject BLE geochat');
    assert_(injectGeo['forwarded'] == true, 'Geochat forwarded to APRS-IS');

    // Inject BLE directed message
    final injectMsg = await apiCall(client, host, port, {
      'action': 'blue_aprs_inject_ble',
      'callsign': 'BLE1-5',
      'to': 'N0CALL',
      'text': 'Hello from BlueAPRS',
      'type': 'message',
    });
    assert_(injectMsg['success'] == true, 'Inject BLE directed message');
    assert_(injectMsg['forwarded'] == true, 'Directed message forwarded');

    // Verify stats
    final status1b = await apiCall(client, host, port, {'action': 'blue_aprs_status'});
    final stats1 = status1b['stats'] as Map<String, dynamic>;
    assert_((stats1['txCount'] as int) >= 2, 'txCount >= 2 after 2 iGate TX ops');

    print('  Test 1 complete');

    // =========================================================================
    // Test 2: iGate RX — APRS-IS message routed to BLE client
    // =========================================================================
    print('\n[Test 2] iGate RX — APRS-IS message routed to BLE client');

    // Inject an APRS-IS packet addressed to our BLE client
    final injectAprs = await apiCall(client, host, port, {
      'action': 'blue_aprs_inject_aprs',
      'from': 'W5XYZ-9',
      'to': 'BLE1-5',
      'text': 'Reply from the APRS network',
      'lat': 40.0,
      'lon': -105.0,
    });
    assert_(injectAprs['success'] == true, 'Inject APRS-IS packet');
    assert_(injectAprs['routedToBle'] == true, 'Packet routed to BLE');
    assert_(injectAprs['targetDeviceId'] == 'sim-ble-1', 'Correct target device');

    // Check simulated client inbox
    final inbox1 = await apiCall(client, host, port, {
      'action': 'blue_aprs_client_inbox',
      'deviceId': 'sim-ble-1',
    });
    assert_(inbox1['success'] == true, 'Client inbox query');
    final msgs1 = inbox1['messages'] as List;
    assert_(msgs1.isNotEmpty, 'Inbox has messages');
    assert_(
      msgs1.any((m) => m['from'] == 'W5XYZ-9' && m['text'] == 'Reply from the APRS network'),
      'Inbox contains message from W5XYZ-9',
    );

    // Verify RX stats
    final status2 = await apiCall(client, host, port, {'action': 'blue_aprs_status'});
    final stats2 = status2['stats'] as Map<String, dynamic>;
    assert_((stats2['rxCount'] as int) >= 1, 'rxCount >= 1 after iGate RX');

    print('  Test 2 complete');

    // =========================================================================
    // Test 3: BLE-to-BLE repeater
    // =========================================================================
    print('\n[Test 3] BLE-to-BLE repeater');

    // Register second simulated BLE client
    final reg2 = await apiCall(client, host, port, {
      'action': 'blue_aprs_register_client',
      'deviceId': 'sim-ble-2',
      'callsign': 'BLE2-7',
    });
    assert_(reg2['success'] == true, 'Register simulated client BLE2-7');

    // First BLE client sends a message to second BLE client
    final injectRepeat = await apiCall(client, host, port, {
      'action': 'blue_aprs_inject_ble',
      'callsign': 'BLE1-5',
      'to': 'BLE2-7',
      'text': 'Hello neighbor via repeater',
      'type': 'message',
    });
    assert_(injectRepeat['success'] == true, 'Inject BLE-to-BLE message');

    // Check sim-ble-2 inbox for the repeated message
    final inbox2 = await apiCall(client, host, port, {
      'action': 'blue_aprs_client_inbox',
      'deviceId': 'sim-ble-2',
    });
    assert_(inbox2['success'] == true, 'Second client inbox query');
    final msgs2 = inbox2['messages'] as List;
    assert_(
      msgs2.any((m) => m['text'] == 'Hello neighbor via repeater'),
      'Second client received repeated message',
    );

    // Verify repeat stats
    final status3 = await apiCall(client, host, port, {'action': 'blue_aprs_status'});
    final stats3 = status3['stats'] as Map<String, dynamic>;
    assert_((stats3['repeatCount'] as int) >= 1, 'repeatCount >= 1 after repeat');

    print('  Test 3 complete');

    // =========================================================================
    // Test 4: BlueAPRS enable/disable and beacon
    // =========================================================================
    print('\n[Test 4] BlueAPRS enable/disable and beacon');

    // Enable BlueAPRS via debug API
    final enableResult = await apiCall(client, host, port, {
      'action': 'blue_aprs_enable',
      'enabled': true,
    });
    assert_(enableResult['success'] == true, 'BlueAPRS enable via API');
    assert_(enableResult['blueAprsEnabled'] == true, 'blueAprsEnabled is true');

    // Enable beacon
    final beaconResult = await apiCall(client, host, port, {
      'action': 'blue_aprs_beacon',
      'enabled': true,
      'intervalSec': 60,
    });
    assert_(beaconResult['success'] == true, 'Beacon enable via API');
    assert_(beaconResult['beaconEnabled'] == true, 'beaconEnabled is true');
    assert_(beaconResult['beaconIntervalSec'] == 60, 'beaconIntervalSec is 60');

    // Verify status reflects beacon
    final status4 = await apiCall(client, host, port, {'action': 'blue_aprs_status'});
    assert_(status4['beaconEnabled'] == true, 'Status shows beacon enabled');
    assert_(status4['beaconIntervalSec'] == 60, 'Status shows beacon interval 60');

    // Disable beacon
    final beaconOff = await apiCall(client, host, port, {
      'action': 'blue_aprs_beacon',
      'enabled': false,
    });
    assert_(beaconOff['beaconEnabled'] == false, 'Beacon disabled');

    // Disable BlueAPRS
    final disableResult = await apiCall(client, host, port, {
      'action': 'blue_aprs_enable',
      'enabled': false,
    });
    assert_(disableResult['blueAprsEnabled'] == false, 'BlueAPRS disabled');

    // Re-enable for other tests to continue working
    await apiCall(client, host, port, {
      'action': 'blue_aprs_enable',
      'enabled': true,
    });

    print('  Test 4 complete');

    // =========================================================================
    // Summary
    // =========================================================================
    print('\n---');
    if (exitCode == 0) {
      print('ALL TESTS PASSED');
    } else {
      print('SOME TESTS FAILED');
    }
  } catch (e, stackTrace) {
    print('ERROR: $e');
    print(stackTrace);
    exitCode = 1;
  } finally {
    client.close();
  }
}
