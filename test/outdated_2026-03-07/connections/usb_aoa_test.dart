// USB AOA Connection Test
// Tests the USB AOA implementation for connecting Linux host to Android device
//
// Run with: dart run tests/connections/usb_aoa_test.dart
// Note: Requires Android device connected via USB cable

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:geogram/services/usb_aoa_linux.dart';

void main() async {
  print('');
  print('=' * 60);
  print('USB AOA Connection Test');
  print('=' * 60);
  print('');

  // Check platform
  if (!Platform.isLinux) {
    print('ERROR: This test only works on Linux');
    exit(1);
  }

  // Check if USB AOA is available
  if (!UsbAoaLinux.isAvailable) {
    print('ERROR: USB AOA not available (could not load libc)');
    exit(1);
  }
  print('[OK] USB AOA library available');

  // Create instance
  final usb = UsbAoaLinux();

  // Initialize
  print('\n--- Initializing USB AOA ---');
  final initStopwatch = Stopwatch()..start();
  await usb.initialize();
  initStopwatch.stop();
  print('[OK] Initialized in ${initStopwatch.elapsedMilliseconds}ms');

  // Test 1: List devices (async - should not block)
  print('\n--- Test 1: List Devices (async) ---');
  final listStopwatch = Stopwatch()..start();

  // Run listDevices while also checking UI responsiveness
  int yieldCount = 0;
  bool listComplete = false;
  List<UsbDeviceInfo>? devices;

  // Start the device listing
  final listFuture = usb.listDevices().then((result) {
    devices = result;
    listComplete = true;
  });

  // Simulate UI work - count how many times we can yield while listing runs
  while (!listComplete) {
    await Future.delayed(Duration.zero);
    yieldCount++;
    if (yieldCount > 10000) break; // Safety limit
  }

  await listFuture;
  listStopwatch.stop();

  print('[OK] listDevices() completed in ${listStopwatch.elapsedMilliseconds}ms');
  print('     Yielded $yieldCount times during listing (async working!)');
  print('     Found ${devices!.length} device(s)');

  if (devices!.isEmpty) {
    print('\nERROR: No Android devices found!');
    print('Make sure:');
    print('  1. Android device is connected via USB cable');
    print('  2. USB debugging is enabled on the device');
    print('  3. You have proper permissions (try with sudo or add udev rules)');
    await usb.dispose();
    exit(1);
  }

  // Print device info
  print('\n--- Detected Devices ---');
  for (final device in devices!) {
    final androidTag = device.isAndroidDevice ? ' [ANDROID]' : '';
    final aoaTag = device.isAoaDevice ? ' [AOA MODE]' : '';
    print('  ${device.vidHex}:${device.pidHex}$androidTag$aoaTag');
    print('    Manufacturer: ${device.manufacturer ?? "unknown"}');
    print('    Product: ${device.product ?? "unknown"}');
    print('    Serial: ${device.serial ?? "unknown"}');
    print('    Dev path: ${device.devPath}');
    print('    Sys path: ${device.sysPath}');
    print('');
  }

  // Find the first non-AOA Android device to connect to
  // (if device is already in AOA mode, we can use it directly)
  final targetDevice = devices!.firstWhere(
    (d) => d.isAoaDevice || d.isAndroidDevice,
    orElse: () => devices!.first,
  );

  print('--- Test 2: Connect to ${targetDevice.manufacturer ?? "device"} ---');
  print('Device: ${targetDevice.vidHex}:${targetDevice.pidHex}');
  print('Path: ${targetDevice.devPath}');
  print('');

  // Set up connection listener
  final connectionCompleter = Completer<bool>();
  late StreamSubscription<UsbAoaConnectionEvent> connectionSub;

  connectionSub = usb.connectionStream.listen((event) {
    if (event.connected) {
      print('[EVENT] Connected to ${event.device}');
      if (!connectionCompleter.isCompleted) {
        connectionCompleter.complete(true);
      }
    } else {
      print('[EVENT] Disconnected from ${event.device}');
    }
  });

  // Set up data listener
  final dataBuffer = <Uint8List>[];
  late StreamSubscription<Uint8List> dataSub;

  dataSub = usb.dataStream.listen((data) {
    dataBuffer.add(data);
    final text = utf8.decode(data, allowMalformed: true);
    print('[DATA] Received ${data.length} bytes: ${text.length > 100 ? text.substring(0, 100) + "..." : text}');
  });

  // Connect (async - should not block UI)
  print('Connecting (this may take a few seconds for AOA handshake)...');
  final connectStopwatch = Stopwatch()..start();

  int connectYields = 0;
  bool connectDone = false;
  bool? connectResult;

  final connectFuture = usb.connect(targetDevice).then((result) {
    connectResult = result;
    connectDone = true;
  });

  // Count yields during connection (non-blocking test)
  while (!connectDone) {
    await Future.delayed(Duration(milliseconds: 10));
    connectYields++;
    // Print progress every second
    if (connectYields % 100 == 0) {
      print('  ... still connecting (${connectYields * 10}ms, UI yielded $connectYields times)');
    }
    if (connectYields > 2000) { // 20 second timeout
      print('ERROR: Connection timeout after 20 seconds');
      break;
    }
  }

  await connectFuture;
  connectStopwatch.stop();

  print('');
  print('Connection attempt completed in ${connectStopwatch.elapsedMilliseconds}ms');
  print('Yielded $connectYields times during connection (UI stayed responsive!)');

  if (connectResult != true) {
    print('\nERROR: Failed to connect to device');
    print('Possible causes:');
    print('  1. Permission denied - try with sudo or add udev rules:');
    print('     echo \'SUBSYSTEM=="usb", ATTR{idVendor}=="${targetDevice.vid.toRadixString(16)}", MODE="0666"\' | sudo tee /etc/udev/rules.d/51-android.rules');
    print('     sudo udevadm control --reload-rules && sudo udevadm trigger');
    print('  2. Device does not support AOA protocol');
    print('  3. No Geogram app running on Android to accept connection');
    await connectionSub.cancel();
    await dataSub.cancel();
    await usb.dispose();
    exit(1);
  }

  print('\n[OK] Connected successfully!');
  print('     isConnected: ${usb.isConnected}');
  print('     connectedDevice: ${usb.connectedDevice}');

  // Test 3: Send data
  print('\n--- Test 3: Send Hello Message ---');

  final helloMessage = utf8.encode('{"type":"hello","from":"linux-test","timestamp":${DateTime.now().millisecondsSinceEpoch}}');
  print('Sending: ${utf8.decode(helloMessage)}');

  final writeResult = await usb.write(Uint8List.fromList(helloMessage));
  print('Write result: $writeResult');

  if (writeResult) {
    print('[OK] Message sent successfully');
  } else {
    print('[WARN] Failed to send message (Android may not have opened accessory yet)');
  }

  // Wait for response
  print('\n--- Test 4: Wait for Response (5 seconds) ---');
  print('Waiting for data from Android...');

  await Future.delayed(Duration(seconds: 5));

  if (dataBuffer.isNotEmpty) {
    print('[OK] Received ${dataBuffer.length} message(s) from Android');
    for (var i = 0; i < dataBuffer.length; i++) {
      final text = utf8.decode(dataBuffer[i], allowMalformed: true);
      print('  Message $i: $text');
    }
  } else {
    print('[INFO] No data received (Android app may need to send a response)');
  }

  // Cleanup
  print('\n--- Cleanup ---');
  await connectionSub.cancel();
  await dataSub.cancel();
  await usb.disconnect();
  await usb.dispose();
  print('[OK] Disconnected and disposed');

  // Summary
  print('\n' + '=' * 60);
  print('TEST SUMMARY');
  print('=' * 60);
  print('  listDevices() async:    OK (${listStopwatch.elapsedMilliseconds}ms, $yieldCount yields)');
  print('  connect() async:        ${connectResult == true ? "OK" : "FAILED"} (${connectStopwatch.elapsedMilliseconds}ms, $connectYields yields)');
  print('  write() test:           ${writeResult ? "OK" : "FAILED"}');
  print('  Data received:          ${dataBuffer.isNotEmpty ? "${dataBuffer.length} messages" : "none"}');
  print('  UI blocking:            ${yieldCount > 0 && connectYields > 0 ? "NOT BLOCKED (async working!)" : "MAY BE BLOCKED"}');
  print('');

  exit(connectResult == true ? 0 : 1);
}
