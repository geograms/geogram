import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../util/managed_http_client.dart';
import '../models/device_definition.dart';
import '../models/flash_progress.dart';
import '../protocols/esptool_protocol.dart';
import '../protocols/flash_protocol.dart';
import '../protocols/protocol_registry.dart';
import '../serial/serial_port.dart';
import 'flasher_storage_service.dart';
import '../../services/profile_storage.dart';

/// Main flasher service
///
/// Orchestrates the complete flashing process including:
/// - Device discovery
/// - Firmware download
/// - Protocol selection
/// - Flash execution
/// - Progress reporting
class FlasherService {
  final FlasherStorageService _storage;
  final ProfileStorage _profileStorage;

  FlashProtocol? _currentProtocol;
  SerialPort? _currentPort;
  StreamController<FlashProgress>? _progressController;
  bool _isCancelled = false;

  FlasherService(this._storage, this._profileStorage);

  /// Create with storage
  factory FlasherService.withStorage(String basePath, ProfileStorage storage) {
    return FlasherService(FlasherStorageService(basePath, storage), storage);
  }

  /// Create with default filesystem storage path
  factory FlasherService.withPath(String basePath) {
    final storage = FilesystemProfileStorage(basePath);
    return FlasherService(FlasherStorageService(basePath, storage), storage);
  }

  /// Get storage service
  FlasherStorageService get storage => _storage;

  /// Progress stream for current operation
  Stream<FlashProgress>? get progressStream => _progressController?.stream;

  /// List available serial ports
  ///
  /// Uses native platform APIs (Android USB Host API, Linux libc termios).
  Future<List<PortInfo>> listPorts() async {
    return SerialPort.listPorts();
  }

  /// Find ports matching a device definition
  Future<List<PortInfo>> findMatchingPorts(DeviceDefinition device) async {
    if (device.usb == null) return [];

    final ports = await listPorts();
    final vid = device.usb!.vidInt;
    final pid = device.usb!.pidInt;

    return ports.where((p) => p.vid == vid && p.pid == pid).toList();
  }

  /// Auto-detect connected device
  Future<DeviceDefinition?> autoDetectDevice() async {
    final ports = await listPorts();

    for (final port in ports) {
      if (port.vid != null && port.pid != null) {
        final device = await _storage.findDeviceByUsb(port.vid!, port.pid!);
        if (device != null) {
          return device;
        }
      }
    }

    return null;
  }

  /// Download firmware from URL
  Future<Uint8List> downloadFirmware(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    return await withHttpClient((client) async {
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw FlashException('Failed to download firmware: HTTP ${response.statusCode}');
      }

      final contentLength = response.contentLength ?? 0;
      final bytes = <int>[];
      var received = 0;

      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        received += chunk.length;

        if (contentLength > 0 && onProgress != null) {
          onProgress(received / contentLength);
        }
      }

      return Uint8List.fromList(bytes);
    });
  }

  /// Load firmware from file
  ///
  /// For encrypted storage, paths within the collection are read via ProfileStorage.
  /// For external files (e.g., user-selected files), direct filesystem access is used.
  Future<Uint8List> loadFirmwareFromFile(String path) async {
    // Check if this is a path within the collection (starts with basePath)
    if (_profileStorage.isEncrypted && path.startsWith(_storage.basePath)) {
      // Extract relative path and read via storage
      var relativePath = path.substring(_storage.basePath.length);
      if (relativePath.startsWith('/')) {
        relativePath = relativePath.substring(1);
      }
      final bytes = await _storage.readFirmwareBytes(relativePath);
      if (bytes == null) {
        throw FlashException('Firmware file not found: $path');
      }
      return Uint8List.fromList(bytes);
    }

    // External file - use direct filesystem access
    final file = File(path);
    if (!await file.exists()) {
      throw FlashException('Firmware file not found: $path');
    }

    return file.readAsBytes();
  }

  /// Flash device with firmware
  ///
  /// [device] - Device definition with flash configuration
  /// [portPath] - Serial port path (e.g., /dev/ttyUSB0)
  /// [firmware] - Firmware binary data (or null to download from device.flash.firmwareUrl)
  /// [firmwarePath] - Local firmware file path (alternative to [firmware])
  /// [onProgress] - Progress callback
  Future<bool> flashDevice({
    required DeviceDefinition device,
    required String portPath,
    Uint8List? firmware,
    String? firmwarePath,
    FlashProgressCallback? onProgress,
  }) async {
    _progressController = StreamController<FlashProgress>.broadcast();
    final startTime = DateTime.now();

    void reportProgress(FlashProgress progress) {
      onProgress?.call(progress);
      _progressController?.add(progress);
    }

    try {
      // Load firmware
      Uint8List firmwareData;
      if (firmware != null) {
        firmwareData = firmware;
      } else if (firmwarePath != null) {
        reportProgress(FlashProgress(
          status: FlashStatus.idle,
          message: 'Loading firmware...',
        ));
        firmwareData = await loadFirmwareFromFile(firmwarePath);
      } else if (device.flash.firmwareUrl != null) {
        reportProgress(FlashProgress(
          status: FlashStatus.idle,
          message: 'Downloading firmware...',
        ));
        firmwareData = await downloadFirmware(
          device.flash.firmwareUrl!,
          onProgress: (progress) {
            reportProgress(FlashProgress(
              status: FlashStatus.idle,
              progress: progress,
              message: 'Downloading firmware...',
            ));
          },
        );
      } else {
        throw FlashException('No firmware source specified');
      }

      // Create protocol
      _currentProtocol = ProtocolRegistry.create(device.flash.protocol);
      if (_currentProtocol == null) {
        throw FlashException('Unsupported protocol: ${device.flash.protocol}');
      }

      // Create and open serial port using native platform APIs
      _currentPort = SerialPort();
      final portOpened = await _currentPort!.open(portPath, device.flash.baudRate);
      if (!portOpened) {
        throw ConnectionException('Failed to open serial port: $portPath');
      }

      // Connect protocol to the open port
      final connected = await _currentProtocol!.connect(
        _currentPort!,
        baudRate: device.flash.baudRate,
        onProgress: reportProgress,
      );

      if (!connected) {
        throw ConnectionException('Failed to connect to device');
      }

      // Chip compatibility check: compare firmware target chip vs detected hardware
      final detectedChip = _currentProtocol!.chipInfo;
      final firmwareTargetChip = EspToolProtocol.parseFirmwareTargetChip(firmwareData);
      if (detectedChip != null && firmwareTargetChip != null &&
          detectedChip != firmwareTargetChip) {
        throw ChipMismatchException(
          firmwareChip: firmwareTargetChip,
          detectedChip: detectedChip,
        );
      }

      // Flash
      await _currentProtocol!.flash(
        firmwareData,
        device.flash,
        onProgress: reportProgress,
      );

      // Verify
      final verified = await _currentProtocol!.verify(onProgress: reportProgress);
      if (!verified) {
        throw VerifyException('Firmware verification failed');
      }

      // Reset to run new firmware
      reportProgress(FlashProgress.resetting());
      await _currentProtocol!.reset();

      // Complete
      reportProgress(FlashProgress.completed(
        DateTime.now().difference(startTime),
      ));

      return true;
    } catch (e) {
      reportProgress(FlashProgress.error(e.toString()));
      rethrow;
    } finally {
      await _cleanup();
    }
  }

  /// Cancel current flash/read operation
  Future<void> cancel() async {
    _isCancelled = true;
    await _cleanup();
    _progressController?.add(FlashProgress.error('Operation cancelled by user'));
  }

  /// Read firmware from connected ESP32 device
  ///
  /// [portPath] - Serial port path (e.g., /dev/ttyUSB0)
  /// [flashSize] - Flash size in bytes (null = auto-detect)
  /// [onProgress] - Progress callback
  ///
  /// Returns the firmware binary data read from the device.
  Future<Uint8List> readFirmwareFromDevice({
    required String portPath,
    int? flashSize,
    FlashProgressCallback? onProgress,
  }) async {
    _progressController = StreamController<FlashProgress>.broadcast();
    _isCancelled = false;

    void reportProgress(FlashProgress progress) {
      onProgress?.call(progress);
      _progressController?.add(progress);
    }

    try {
      // Create EspToolProtocol directly (reading is ESP32-specific)
      final protocol = EspToolProtocol();

      // Use high baud rate for faster reading (same as writing)
      const readBaudRate = 921600;

      // Create and open serial port
      _currentPort = SerialPort();
      final portOpened = await _currentPort!.open(portPath, readBaudRate);
      if (!portOpened) {
        throw ConnectionException('Failed to open serial port: $portPath');
      }

      // Connect to bootloader
      final connected = await protocol.connect(
        _currentPort!,
        baudRate: readBaudRate,
        onProgress: reportProgress,
      );

      if (!connected) {
        throw ConnectionException('Failed to connect to device bootloader');
      }

      // Detect flash size if not provided
      int size = flashSize ?? 0;
      if (size == 0) {
        reportProgress(const FlashProgress(
          status: FlashStatus.syncing,
          message: 'Detecting flash size...',
        ));
        size = await protocol.detectFlashSize();
      }

      // Read flash
      final firmware = await protocol.readFlash(
        offset: 0,
        length: size,
        onProgress: reportProgress,
        isCancelled: () => _isCancelled,
      );

      // Disconnect
      await protocol.disconnect();
      await _currentPort!.close();
      _currentPort = null;

      return firmware;
    } catch (e) {
      reportProgress(FlashProgress.error(e.toString()));
      rethrow;
    } finally {
      await _progressController?.close();
      _progressController = null;
      if (_currentPort != null) {
        await _currentPort!.close();
        _currentPort = null;
      }
    }
  }

  /// Clean up resources
  Future<void> _cleanup() async {
    if (_currentProtocol != null) {
      await _currentProtocol!.disconnect();
      _currentProtocol = null;
    }

    if (_currentPort != null) {
      await _currentPort!.close();
      _currentPort = null;
    }

    await _progressController?.close();
    _progressController = null;
  }
}
