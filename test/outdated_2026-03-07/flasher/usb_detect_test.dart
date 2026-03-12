#!/usr/bin/env dart
/// USB Serial Port Detection Test
///
/// Tests detection of USB serial devices like ESP32 using flutter_libserialport.
///
/// Requirements:
/// - libserialport must be installed on the system
/// - On Linux: sudo apt install libserialport0 libserialport-dev
/// - On macOS: brew install libserialport
/// - On Windows: libserialport.dll must be in PATH
///
/// Run with: dart tests/flasher/usb_detect_test.dart

import 'dart:io';

import '../../lib/flasher/serial/serial_port.dart';
import '../../lib/flasher/services/flasher_storage_service.dart';
import '../../lib/services/profile_storage.dart';

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

void info(String message) {
  print('  [INFO] $message');
}

Future<void> main() async {
  print('');
  print('=' * 60);
  print('USB Serial Port Detection Test');
  print('=' * 60);
  print('');
  print('Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  print('');

  // Test 1: Detect serial ports
  print('Test 1: Serial Port Detection (flutter_libserialport)');
  print('-' * 40);

  List<PortInfo> ports = [];
  try {
    ports = await SerialPort.listPorts();

    if (ports.isEmpty) {
      fail('Port detection', 'No serial ports found');
      print('');
      print('  Troubleshooting:');
      print('  - Make sure a USB device is connected');
      print('  - Check if your user is in the dialout group: groups \$(whoami)');
      print('  - Try: sudo usermod -a -G dialout \$(whoami) && logout');
      print('  - Ensure libserialport is installed:');
      print('    Linux: sudo apt install libserialport0 libserialport-dev');
      print('    macOS: brew install libserialport');
    } else {
      pass('Port detection - found ${ports.length} port(s)');

      print('');
      print('  Detected ports:');
      for (final port in ports) {
        print('  +-----------------------------------------');
        print('  | Path: ${port.path}');
        if (port.vid != null) {
          print('  | VID:  0x${port.vid!.toRadixString(16).toUpperCase().padLeft(4, '0')}');
        }
        if (port.pid != null) {
          print('  | PID:  0x${port.pid!.toRadixString(16).toUpperCase().padLeft(4, '0')}');
        }
        if (port.manufacturer != null) {
          print('  | Manufacturer: ${port.manufacturer}');
        }
        if (port.product != null) {
          print('  | Product: ${port.product}');
        }
        if (port.serialNumber != null) {
          print('  | Serial: ${port.serialNumber}');
        }
        print('  +-----------------------------------------');
      }
    }
  } catch (e, stack) {
    fail('Port detection', 'Exception: $e');
    print('');
    print('  This may indicate libserialport is not installed.');
    print('  Linux: sudo apt install libserialport0 libserialport-dev');
    print('  macOS: brew install libserialport');
    print('');
    print('  Stack trace: $stack');
  }

  print('');

  // Test 2: Check for ESP32 devices using Esp32UsbIdentifiers
  print('Test 2: ESP32 Device Detection');
  print('-' * 40);

  try {
    final esp32Ports = await Esp32UsbIdentifiers.findEsp32Ports();

    if (esp32Ports.isEmpty) {
      if (ports.isEmpty) {
        fail('ESP32 detection', 'No serial ports found');
      } else {
        fail('ESP32 detection', 'No ESP32-compatible devices found');
        print('');
        print('  Found ports but none match known ESP32 VID/PID:');
        for (final port in ports) {
          if (port.vid != null) {
            print('  - ${port.path}: VID=0x${port.vid!.toRadixString(16).toUpperCase()} PID=0x${port.pid?.toRadixString(16).toUpperCase() ?? "?"}');
          } else {
            print('  - ${port.path}: (no USB info available)');
          }
        }
      }
    } else {
      pass('ESP32 detection - found ${esp32Ports.length} ESP32-compatible device(s)');
      for (final (port, desc) in esp32Ports) {
        info('Found $desc at ${port.path}');
      }
    }
  } catch (e) {
    fail('ESP32 detection', 'Exception: $e');
  }

  print('');

  // Test 3: Load device definitions
  print('Test 3: Device Definition Loading');
  print('-' * 40);

  FlasherStorageService? storage;
  try {
    // Find the flasher directory
    final scriptDir = File(Platform.script.toFilePath()).parent.parent.parent;
    final flasherPath = '${scriptDir.path}/flasher';

    if (!await Directory(flasherPath).exists()) {
      fail('Device definitions', 'flasher/ directory not found at $flasherPath');
    } else {
      storage = FlasherStorageService(flasherPath, FilesystemProfileStorage(flasherPath));

      // Load metadata
      final metadata = await storage.loadMetadata();
      if (metadata != null) {
        pass('Loaded metadata: ${metadata.name}');
        info('Families: ${metadata.families.map((f) => f.id).join(", ")}');
      } else {
        fail('Load metadata', 'Failed to load metadata.json');
      }

      // Load devices
      final devices = await storage.loadAllDevices();
      if (devices.isNotEmpty) {
        pass('Loaded ${devices.length} device definition(s)');
        for (final device in devices) {
          info('- ${device.title} (${device.chip}) - protocol: ${device.flash.protocol}');
        }
      } else {
        fail('Load devices', 'No device definitions found');
      }
    }
  } catch (e) {
    fail('Device definitions', 'Exception: $e');
  }

  print('');

  // Test 4: Match connected devices to definitions
  print('Test 4: Device Matching');
  print('-' * 40);

  try {
    if (storage == null) {
      fail('Device matching', 'Storage not initialized');
    } else {
      final devices = await storage.loadAllDevices();

      var matched = 0;
      for (final port in ports) {
        if (port.vid == null || port.pid == null) continue;

        for (final device in devices) {
          if (device.usb == null) continue;

          if (device.usb!.vidInt == port.vid && device.usb!.pidInt == port.pid) {
            pass('Matched ${port.path} -> ${device.title}');
            matched++;
          }
        }
      }

      if (matched == 0) {
        if (ports.isEmpty) {
          fail('Device matching', 'No ports to match');
        } else {
          info('No ports matched device definitions');
          info('This is expected if your device VID/PID is not in the definitions');

          // Suggest adding the device
          for (final port in ports) {
            if (port.vid != null && port.pid != null) {
              print('');
              info('To add your device, create a definition with:');
              print('    "usb": {');
              print('      "vid": "0x${port.vid!.toRadixString(16).toUpperCase()}",');
              print('      "pid": "0x${port.pid!.toRadixString(16).toUpperCase()}",');
              print('      "description": "${port.product ?? "USB Serial"}"');
              print('    }');
            }
          }
        }
      }
    }
  } catch (e) {
    fail('Device matching', 'Exception: $e');
  }

  print('');

  // Test 5: Port permissions check
  print('Test 5: Port Permissions');
  print('-' * 40);

  if (Platform.isLinux) {
    try {
      for (final port in ports) {
        // Try to actually open the port for reading to test permissions
        try {
          final file = File(port.path);
          final raf = await file.open(mode: FileMode.read);
          await raf.close();
          pass('${port.path} is readable');
        } catch (e) {
          // Check if user is in dialout group
          final groups = await Process.run('groups', []);
          final inDialout = groups.stdout.toString().contains('dialout');

          fail('${port.path} permissions', 'Cannot open for reading');
          if (!inDialout) {
            print('  Fix: sudo usermod -a -G dialout \$(whoami) && logout');
          } else {
            print('  You are in dialout group but still cannot access.');
            print('  Try: sudo chmod 666 ${port.path}');
          }
        }
      }

      if (ports.isEmpty) {
        info('No ports to check permissions for');
      }
    } catch (e) {
      fail('Permission check', 'Exception: $e');
    }
  } else {
    info('Permission check skipped (not Linux)');
  }

  // Summary
  print('');
  print('=' * 60);
  print('Test Summary');
  print('=' * 60);
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
  exit(_failed > 0 ? 1 : 0);
}
