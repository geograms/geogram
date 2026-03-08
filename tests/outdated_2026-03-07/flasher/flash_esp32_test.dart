#!/usr/bin/env dart
/// ESP32 Flash Test
///
/// Tests flashing firmware to an ESP32-C3-mini device using the esptool protocol.
///
/// Requirements:
/// - ESP32-C3-mini connected via USB
/// - User must be in dialout group (Linux)
///
/// Run with: dart tests/flasher/flash_esp32_test.dart
///
/// WARNING: This test will overwrite the firmware on the connected ESP32!

import 'dart:io';
import 'dart:typed_data';

import '../../lib/flasher/models/device_definition.dart';
import '../../lib/flasher/models/flash_progress.dart';
import '../../lib/flasher/protocols/esptool_protocol.dart';
import '../../lib/flasher/serial/serial_port.dart';

// Test state
int _passed = 0;
int _failed = 0;
final List<String> _failures = [];
DateTime? _startTime;

void pass(String test) {
  _passed++;
  print('  [PASS] $test');
}

void fail(String test, String reason) {
  _failed++;
  _failures.add('$test: $reason');
  print('  [FAIL] $test - $reason');
}

void info(String message) {
  print('  [INFO] $message');
}

void progress(FlashProgress p) {
  final elapsed = _startTime != null
      ? DateTime.now().difference(_startTime!).inSeconds
      : 0;

  switch (p.status) {
    case FlashStatus.connecting:
      print('  [....] Connecting to device...');
    case FlashStatus.syncing:
      print('  [....] Syncing with bootloader...');
    case FlashStatus.erasing:
      print('  [${(p.progress * 100).toInt().toString().padLeft(3)}%] Erasing flash...');
    case FlashStatus.writing:
      final pct = (p.progress * 100).toInt();
      final speed = elapsed > 0 ? (p.bytesWritten / elapsed / 1024).toStringAsFixed(1) : '---';
      print(
        '  [${pct.toString().padLeft(3)}%] Writing: ${_formatBytes(p.bytesWritten)} / ${_formatBytes(p.totalBytes)} '
        '(${p.currentChunk}/${p.totalChunks} chunks) @ $speed KB/s',
      );
    case FlashStatus.verifying:
      print('  [${(p.progress * 100).toInt().toString().padLeft(3)}%] Verifying...');
    case FlashStatus.reading:
      print('  [${(p.progress * 100).toInt().toString().padLeft(3)}%] Reading flash...');
    case FlashStatus.resetting:
      print('  [....] Resetting device...');
    case FlashStatus.completed:
      print('  [DONE] Flash completed in ${p.formattedElapsed}');
    case FlashStatus.error:
      print('  [ERR!] ${p.error}');
    case FlashStatus.idle:
      break;
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

Future<void> main(List<String> args) async {
  print('');
  print('=' * 70);
  print('ESP32 Flash Test');
  print('=' * 70);
  print('');
  print('Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  print('');

  // Parse arguments
  final dryRun = args.contains('--dry-run');
  final portArg = args.where((a) => a.startsWith('--port=')).firstOrNull;
  final specifiedPort = portArg?.substring(7);

  if (dryRun) {
    print('*** DRY RUN MODE - Will not actually flash ***');
    print('');
  }

  // Find firmware file
  final scriptDir = File(Platform.script.toFilePath()).parent;
  final firmwarePath = '${scriptDir.path}/geogram-ESP32C3-mini.bin';
  final firmwareFile = File(firmwarePath);

  print('Test 1: Firmware File');
  print('-' * 40);

  if (!await firmwareFile.exists()) {
    fail('Firmware file', 'Not found at $firmwarePath');
    _printSummary();
    exit(1);
  }

  final firmwareBytes = await firmwareFile.readAsBytes();
  pass('Firmware file found: ${_formatBytes(firmwareBytes.length)}');
  info('Path: $firmwarePath');

  print('');

  // Detect ESP32 device
  print('Test 2: Device Detection');
  print('-' * 40);

  PortInfo? targetPort;

  if (specifiedPort != null) {
    // Use specified port
    final ports = await SerialPort.listPorts();
    targetPort = ports.where((p) => p.path == specifiedPort).firstOrNull;
    if (targetPort == null) {
      fail('Specified port', 'Port $specifiedPort not found');
      info('Available ports:');
      for (final p in ports) {
        info('  - ${p.path}');
      }
      _printSummary();
      exit(1);
    }
    pass('Using specified port: $specifiedPort');
  } else {
    // Auto-detect ESP32
    final esp32Ports = await Esp32UsbIdentifiers.findEsp32Ports();

    if (esp32Ports.isEmpty) {
      fail('ESP32 detection', 'No ESP32-compatible devices found');

      // Show available ports
      final allPorts = await SerialPort.listPorts();
      if (allPorts.isNotEmpty) {
        info('Available serial ports:');
        for (final port in allPorts) {
          info('  - ${port.path} (VID=${port.vidHex ?? "?"}, PID=${port.pidHex ?? "?"})');
        }
        info('');
        info('To use a specific port: dart ${Platform.script.toFilePath()} --port=/dev/ttyACM0');
      } else {
        info('No serial ports found. Is the device connected?');
      }

      _printSummary();
      exit(1);
    }

    pass('Found ${esp32Ports.length} ESP32-compatible device(s)');

    // Use first ESP32 port
    final (port, desc) = esp32Ports.first;
    targetPort = port;
    info('Using: ${port.path} - $desc');
  }

  // Show device info
  info('VID: ${targetPort.vidHex ?? "unknown"}');
  info('PID: ${targetPort.pidHex ?? "unknown"}');
  if (targetPort.manufacturer != null) {
    info('Manufacturer: ${targetPort.manufacturer}');
  }
  if (targetPort.product != null) {
    info('Product: ${targetPort.product}');
  }

  print('');

  // Check permissions
  print('Test 3: Port Permissions');
  print('-' * 40);

  if (Platform.isLinux) {
    try {
      final file = File(targetPort.path);
      final raf = await file.open(mode: FileMode.read);
      await raf.close();
      pass('Port ${targetPort.path} is accessible');
    } catch (e) {
      fail('Port permissions', 'Cannot access ${targetPort.path}');
      info('Try: sudo usermod -a -G dialout \$(whoami) && logout');
      _printSummary();
      exit(1);
    }
  } else {
    info('Permission check skipped (not Linux)');
  }

  print('');

  if (dryRun) {
    print('Test 4: Flash Operation (DRY RUN)');
    print('-' * 40);
    pass('Dry run - skipping actual flash');
    info('Firmware size: ${_formatBytes(firmwareBytes.length)}');
    info('Target port: ${targetPort.path}');
    info('Estimated chunks: ${(firmwareBytes.length / 1024).ceil()}');
    _printSummary();
    exit(0);
  }

  // Flash the device
  print('Test 4: Flash Operation');
  print('-' * 40);
  print('');
  print('  WARNING: This will overwrite the firmware on the ESP32!');
  print('  Press Ctrl+C within 3 seconds to abort...');
  print('');

  await Future.delayed(const Duration(seconds: 3));

  final protocol = EspToolProtocol();
  final serialPort = SerialPort();

  try {
    // Connect
    info('Opening serial port...');
    final opened = await serialPort.open(targetPort.path, 115200);
    if (!opened) {
      fail('Open port', 'Failed to open ${targetPort.path}');
      _printSummary();
      exit(1);
    }
    pass('Serial port opened');

    info('Connecting to ESP32 bootloader...');
    _startTime = DateTime.now();

    final connected = await protocol.connect(
      serialPort,
      baudRate: 115200,
      onProgress: progress,
    );

    if (!connected) {
      fail('Connect', 'Failed to connect to ESP32 bootloader');
      await serialPort.close();
      _printSummary();
      exit(1);
    }

    pass('Connected to bootloader');
    info('Chip detected: ${protocol.chipInfo ?? "unknown"}');

    print('');
    print('  Flashing ${_formatBytes(firmwareBytes.length)}...');
    print('');

    // Flash
    final flashConfig = FlashConfig(
      protocol: 'esptool',
      baudRate: 921600, // Use high baud rate for faster flashing
    );

    await protocol.flash(
      firmwareBytes,
      flashConfig,
      onProgress: progress,
    );

    pass('Firmware written successfully');

    // Verify
    info('Verifying...');
    final verified = await protocol.verify(onProgress: progress);
    if (verified) {
      pass('Firmware verified');
    } else {
      fail('Verify', 'Verification failed');
    }

    // Reset
    info('Resetting device...');
    await protocol.reset();
    pass('Device reset');

    final elapsed = DateTime.now().difference(_startTime!);
    final speed = (firmwareBytes.length / elapsed.inSeconds / 1024).toStringAsFixed(1);
    print('');
    info('Flash completed in ${elapsed.inSeconds}s (avg: $speed KB/s)');

  } catch (e, stack) {
    fail('Flash', 'Exception: $e');
    print('');
    print('  Stack trace:');
    print('  $stack');
  } finally {
    await protocol.disconnect();
    await serialPort.close();
  }

  _printSummary();
  exit(_failed > 0 ? 1 : 0);
}

void _printSummary() {
  print('');
  print('=' * 70);
  print('Test Summary');
  print('=' * 70);
  print('Passed: $_passed');
  print('Failed: $_failed');

  if (_failures.isNotEmpty) {
    print('');
    print('Failures:');
    for (final f in _failures) {
      print('  - $f');
    }
  }

  print('');
}
