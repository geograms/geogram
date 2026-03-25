/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'log_service.dart';

// ============================================================================
// Linux USB AOA Host Implementation using libc and usbdevfs
// ============================================================================
// This is a pure-Dart implementation using FFI to call libc functions
// and kernel usbdevfs ioctls. No external libraries required.
// ============================================================================

// -----------------------------------------------------------------------------
// Constants from fcntl.h
// -----------------------------------------------------------------------------
const O_RDWR = 0x0002;

// -----------------------------------------------------------------------------
// Constants from linux/usbdevice_fs.h
// -----------------------------------------------------------------------------
// IOCTL numbers for USB device operations (Linux x86_64)
// These are calculated using _IOWR/_IOR macros from asm-generic/ioctl.h
const USBDEVFS_CONTROL =
    0xC0185500; // _IOWR('U', 0, struct usbdevfs_ctrltransfer)
const USBDEVFS_BULK = 0xC0185502; // _IOWR('U', 2, struct usbdevfs_bulktransfer)
const USBDEVFS_CLAIMINTERFACE = 0x8004550F; // _IOR('U', 15, unsigned int)
const USBDEVFS_RELEASEINTERFACE = 0x80045510; // _IOR('U', 16, unsigned int)
const USBDEVFS_SETINTERFACE =
    0x80085504; // _IOR('U', 4, struct usbdevfs_setinterface)
const USBDEVFS_CLEAR_HALT = 0x80045515; // _IOR('U', 21, unsigned int)

// USB transfer direction flags (bmRequestType)
const USB_DIR_OUT = 0x00;
const USB_DIR_IN = 0x80;
const USB_TYPE_VENDOR = 0x40;
const USB_RECIP_DEVICE = 0x00;

// -----------------------------------------------------------------------------
// AOA Protocol Constants
// -----------------------------------------------------------------------------
// AOA vendor requests
const AOA_GET_PROTOCOL = 51; // Get AOA protocol version
const AOA_SEND_STRING = 52; // Send identification string
const AOA_START = 53; // Start accessory mode

// Google AOA VID/PID after accessory mode switch
const AOA_VID = 0x18D1; // Google's USB VID
const AOA_PID_ACCESSORY = 0x2D00; // AOA mode without ADB
const AOA_PID_ACCESSORY_ADB = 0x2D01; // AOA mode with ADB

// AOA string indices
const AOA_STRING_MANUFACTURER = 0;
const AOA_STRING_MODEL = 1;
const AOA_STRING_DESCRIPTION = 2;
const AOA_STRING_VERSION = 3;
const AOA_STRING_URI = 4;
const AOA_STRING_SERIAL = 5;

// Default AOA identification strings
const AOA_MANUFACTURER = "Geogram";
const AOA_MODEL = "Geogram Device";
const AOA_DESCRIPTION = "Geogram USB Link";
const AOA_VERSION = "1.0";
const AOA_URI = "https://geogram.radio";
const AOA_SERIAL = "geogram-linux";

// Known Android USB VIDs (for device discovery)
const _androidVids = <int>{
  0x18D1, // Google
  0x04E8, // Samsung
  0x22B8, // Motorola
  0x0BB4, // HTC
  0x12D1, // Huawei
  0x2717, // Xiaomi
  0x1949, // OnePlus
  0x0FCE, // Sony
  0x2A70, // OnePlus (alternate)
  0x05C6, // Qualcomm (used by many)
  0x1004, // LG
  0x2916, // Realme
  0x2B4C, // Vivo
  0x1782, // Spreadtrum
};

// -----------------------------------------------------------------------------
// FFI Structures
// -----------------------------------------------------------------------------

/// usbdevfs_ctrltransfer structure for control transfers
/// Matches: struct usbdevfs_ctrltransfer from linux/usbdevice_fs.h
final class UsbCtrlTransfer extends Struct {
  @Uint8()
  external int bRequestType; // Request type bitmap

  @Uint8()
  external int bRequest; // Specific request

  @Uint16()
  external int wValue; // Value parameter

  @Uint16()
  external int wIndex; // Index parameter

  @Uint16()
  external int wLength; // Data length

  @Uint32()
  external int timeout; // Timeout in milliseconds

  external Pointer<Void> data; // Data buffer
}

/// usbdevfs_bulktransfer structure for bulk transfers
/// Matches: struct usbdevfs_bulktransfer from linux/usbdevice_fs.h
final class UsbBulkTransfer extends Struct {
  @Uint32()
  external int ep; // Endpoint address

  @Uint32()
  external int len; // Data length

  @Uint32()
  external int timeout; // Timeout in milliseconds

  external Pointer<Void> data; // Data buffer
}

// -----------------------------------------------------------------------------
// FFI Function Signatures
// -----------------------------------------------------------------------------

typedef OpenNative = Int32 Function(Pointer<Utf8> path, Int32 flags);
typedef OpenDart = int Function(Pointer<Utf8> path, int flags);

typedef CloseNative = Int32 Function(Int32 fd);
typedef CloseDart = int Function(int fd);

typedef ReadNative =
    IntPtr Function(Int32 fd, Pointer<Uint8> buf, IntPtr count);
typedef ReadDart = int Function(int fd, Pointer<Uint8> buf, int count);

typedef WriteNative =
    IntPtr Function(Int32 fd, Pointer<Uint8> buf, IntPtr count);
typedef WriteDart = int Function(int fd, Pointer<Uint8> buf, int count);

// ioctl with pointer argument
typedef IoctlPtrNative =
    Int32 Function(Int32 fd, Uint64 request, Pointer<Void> arg);
typedef IoctlPtrDart = int Function(int fd, int request, Pointer<Void> arg);

// ioctl with int argument
typedef IoctlIntNative =
    Int32 Function(Int32 fd, Uint64 request, Pointer<Int32> arg);
typedef IoctlIntDart = int Function(int fd, int request, Pointer<Int32> arg);

// Poll for events
// errno access
typedef ErrnoLocNative = Pointer<Int32> Function();
typedef ErrnoLocDart = Pointer<Int32> Function();

// -----------------------------------------------------------------------------
// USB Device Info
// -----------------------------------------------------------------------------

/// Information about a discovered USB device
class UsbDeviceInfo {
  final int vid;
  final int pid;
  final String devPath; // e.g., /dev/bus/usb/001/005
  final String sysPath; // e.g., /sys/bus/usb/devices/1-1
  final String? manufacturer;
  final String? product;
  final String? serial;

  const UsbDeviceInfo({
    required this.vid,
    required this.pid,
    required this.devPath,
    required this.sysPath,
    this.manufacturer,
    this.product,
    this.serial,
  });

  String get vidHex =>
      '0x${vid.toRadixString(16).toUpperCase().padLeft(4, '0')}';
  String get pidHex =>
      '0x${pid.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  bool get isAndroidDevice => _androidVids.contains(vid);
  bool get isAoaDevice =>
      vid == AOA_VID &&
      (pid == AOA_PID_ACCESSORY || pid == AOA_PID_ACCESSORY_ADB);

  @override
  String toString() => 'UsbDevice($vidHex:$pidHex $devPath)';
}

// -----------------------------------------------------------------------------
// USB AOA Linux Implementation
// -----------------------------------------------------------------------------

/// Linux host-side USB AOA implementation using libc FFI
class UsbAoaLinux {
  static DynamicLibrary? _lib;
  static bool _initialized = false;

  // FFI function pointers
  static late OpenDart _open;
  static late CloseDart _close;
  static late IoctlPtrDart _ioctlPtr;
  static late IoctlIntDart _ioctlInt;
  static late ErrnoLocDart _errnoLoc;

  // Connection state
  int? _fd;
  UsbDeviceInfo? _connectedDevice;
  int? _epIn; // IN endpoint address
  int? _epOut; // OUT endpoint address
  bool _isConnected = false;

  // Streams
  final _connectionController =
      StreamController<UsbAoaConnectionEvent>.broadcast();
  final _dataController = StreamController<Uint8List>.broadcast();
  final _channelReadyController = StreamController<void>.broadcast();

  // Read thread control
  bool _isReading = false;

  // Poll timeout counter for periodic logging
  int _pollTimeoutCount = 0;

  /// Stream of connection events
  Stream<UsbAoaConnectionEvent> get connectionStream =>
      _connectionController.stream;

  /// Stream of incoming data
  Stream<Uint8List> get dataStream => _dataController.stream;

  /// Stream that fires when channel is ready (Android has opened accessory)
  Stream<void> get channelReadyStream => _channelReadyController.stream;

  /// Whether currently connected to an AOA device
  bool get isConnected => _isConnected;

  /// Whether the read loop is currently active
  bool get isReading => _isReading;

  /// Poll timeout count (for debugging)
  int get pollTimeoutCount => _pollTimeoutCount;

  /// Information about the connected device
  UsbDeviceInfo? get connectedDevice => _connectedDevice;

  /// Check if USB AOA is available on Linux
  static bool get isAvailable {
    if (!Platform.isLinux) return false;
    try {
      _loadLibrary();
      return true;
    } catch (e) {
      return false;
    }
  }

  static void _loadLibrary() {
    if (_lib != null) return;

    // libc.so.6 is present on every Linux system
    final paths = ['libc.so.6', 'libc.so'];
    for (final path in paths) {
      try {
        _lib = DynamicLibrary.open(path);
        return;
      } catch (e) {
        continue;
      }
    }
    throw UnsupportedError('Could not load libc');
  }

  static void _initializeFfi() {
    if (_initialized) return;
    _loadLibrary();

    _open = _lib!.lookupFunction<OpenNative, OpenDart>('open');
    _close = _lib!.lookupFunction<CloseNative, CloseDart>('close');
    _ioctlPtr = _lib!.lookupFunction<IoctlPtrNative, IoctlPtrDart>('ioctl');
    _ioctlInt = _lib!.lookupFunction<IoctlIntNative, IoctlIntDart>('ioctl');
    _errnoLoc = _lib!.lookupFunction<ErrnoLocNative, ErrnoLocDart>(
      '__errno_location',
    );

    _initialized = true;
  }

  /// Initialize the USB AOA host
  Future<void> initialize() async {
    _initializeFfi();
    LogService().log('UsbAoaLinux: Initialized');
  }

  /// Get the current errno value
  int get _errno => _errnoLoc().value;

  /// List connected USB devices that may support AOA
  ///
  /// Uses async file I/O to avoid blocking the UI thread.
  Future<List<UsbDeviceInfo>> listDevices() async {
    _initializeFfi();

    final devices = <UsbDeviceInfo>[];
    final sysDir = Directory('/sys/bus/usb/devices');

    if (!await sysDir.exists()) {
      LogService().log('UsbAoaLinux: /sys/bus/usb/devices not found');
      return devices;
    }

    // Use async iteration to avoid blocking the UI thread
    await for (final entry in sysDir.list()) {
      // Yield control periodically to keep UI responsive
      await Future.delayed(Duration.zero);

      if (entry is! Directory) continue;

      final name = entry.path.split('/').last;
      // Skip interface entries (e.g., 1-1:1.0), we want device entries (e.g., 1-1)
      if (name.contains(':')) continue;

      try {
        final vidFile = File('${entry.path}/idVendor');
        final pidFile = File('${entry.path}/idProduct');

        if (!await vidFile.exists() || !await pidFile.exists()) continue;

        final vid = int.tryParse(
          (await vidFile.readAsString()).trim(),
          radix: 16,
        );
        final pid = int.tryParse(
          (await pidFile.readAsString()).trim(),
          radix: 16,
        );

        if (vid == null || pid == null) continue;

        // Check if this is an Android device or AOA accessory
        final isAndroid = _androidVids.contains(vid);
        final isAoa =
            vid == AOA_VID &&
            (pid == AOA_PID_ACCESSORY || pid == AOA_PID_ACCESSORY_ADB);

        if (!isAndroid && !isAoa) continue;

        // Get device path
        final busnumFile = File('${entry.path}/busnum');
        final devnumFile = File('${entry.path}/devnum');

        if (!await busnumFile.exists() || !await devnumFile.exists()) continue;

        final busnum =
            int.tryParse((await busnumFile.readAsString()).trim()) ?? 0;
        final devnum =
            int.tryParse((await devnumFile.readAsString()).trim()) ?? 0;

        final devPath =
            '/dev/bus/usb/${busnum.toString().padLeft(3, '0')}/${devnum.toString().padLeft(3, '0')}';

        // Read optional info (async)
        String? manufacturer;
        String? product;
        String? serial;

        final mfFile = File('${entry.path}/manufacturer');
        if (await mfFile.exists()) {
          manufacturer = (await mfFile.readAsString()).trim();
        }

        final prodFile = File('${entry.path}/product');
        if (await prodFile.exists()) {
          product = (await prodFile.readAsString()).trim();
        }

        final serialFile = File('${entry.path}/serial');
        if (await serialFile.exists()) {
          serial = (await serialFile.readAsString()).trim();
        }

        devices.add(
          UsbDeviceInfo(
            vid: vid,
            pid: pid,
            devPath: devPath,
            sysPath: entry.path,
            manufacturer: manufacturer,
            product: product,
            serial: serial,
          ),
        );
      } catch (e) {
        // Skip devices with read errors
        continue;
      }
    }

    return devices;
  }

  /// Connect to an Android device using AOA protocol
  ///
  /// This performs the full AOA handshake:
  /// 1. Open the device
  /// 2. Check AOA protocol support
  /// 3. Send identification strings
  /// 4. Switch to accessory mode
  /// 5. Wait for re-enumeration
  /// 6. Open the AOA device for bulk I/O
  Future<bool> connect(UsbDeviceInfo device) async {
    if (_isConnected) {
      LogService().log('UsbAoaLinux: Already connected');
      return false;
    }

    LogService().log('UsbAoaLinux: Connecting to ${device.devPath}');

    // If already in AOA mode, just open for I/O
    if (device.isAoaDevice) {
      return await _openAoaDevice(device);
    }

    // Perform AOA handshake
    final pathPtr = device.devPath.toNativeUtf8();
    int? fd;

    try {
      fd = _open(pathPtr, O_RDWR);
      if (fd < 0) {
        final err = _errno;
        LogService().log('UsbAoaLinux: Failed to open device, errno=$err');
        if (err == 13) {
          // EACCES
          LogService().log(
            'UsbAoaLinux: Permission denied. Run with sudo or add udev rules.',
          );
        }
        return false;
      }

      // Check AOA protocol version
      final version = await _getProtocolVersion(fd);
      if (version < 1) {
        LogService().log(
          'UsbAoaLinux: Device does not support AOA (version=$version)',
        );
        _close(fd);
        return false;
      }
      LogService().log('UsbAoaLinux: AOA protocol version: $version');

      // Send identification strings
      if (!await _sendIdentificationStrings(fd)) {
        LogService().log('UsbAoaLinux: Failed to send identification strings');
        _close(fd);
        return false;
      }

      // Start accessory mode
      if (!await _startAccessoryMode(fd)) {
        LogService().log('UsbAoaLinux: Failed to start accessory mode');
        _close(fd);
        return false;
      }

      // Close the device - it will re-enumerate
      _close(fd);
      fd = null;

      LogService().log('UsbAoaLinux: Device switching to AOA mode...');

      // Wait for re-enumeration and find the AOA device
      // Use 20 second timeout to handle slow devices that take 16+ seconds to re-enumerate
      final aoaDevice = await _waitForAoaDevice(timeout: Duration(seconds: 20));
      if (aoaDevice == null) {
        LogService().log(
          'UsbAoaLinux: Device did not re-enumerate in AOA mode',
        );
        return false;
      }

      LogService().log('UsbAoaLinux: Found AOA device at ${aoaDevice.devPath}');

      // Open the AOA device for bulk I/O
      return await _openAoaDevice(aoaDevice);
    } finally {
      calloc.free(pathPtr);
      if (fd != null && fd >= 0) {
        _close(fd);
      }
    }
  }

  /// Get AOA protocol version from device
  Future<int> _getProtocolVersion(int fd) async {
    final buffer = calloc<Uint8>(2);
    final ctrl = calloc<UsbCtrlTransfer>();

    try {
      ctrl.ref.bRequestType = USB_DIR_IN | USB_TYPE_VENDOR | USB_RECIP_DEVICE;
      ctrl.ref.bRequest = AOA_GET_PROTOCOL;
      ctrl.ref.wValue = 0;
      ctrl.ref.wIndex = 0;
      ctrl.ref.wLength = 2;
      ctrl.ref.timeout = 1000;
      ctrl.ref.data = buffer.cast();

      final result = _ioctlPtr(fd, USBDEVFS_CONTROL, ctrl.cast());
      if (result < 0) {
        LogService().log('UsbAoaLinux: GET_PROTOCOL failed, errno=$_errno');
        return -1;
      }

      // Version is little-endian 16-bit
      return buffer[0] | (buffer[1] << 8);
    } finally {
      calloc.free(buffer);
      calloc.free(ctrl);
    }
  }

  /// Send AOA identification strings
  Future<bool> _sendIdentificationStrings(int fd) async {
    final strings = [
      AOA_MANUFACTURER, // Index 0
      AOA_MODEL, // Index 1
      AOA_DESCRIPTION, // Index 2
      AOA_VERSION, // Index 3
      AOA_URI, // Index 4
      AOA_SERIAL, // Index 5
    ];

    for (var i = 0; i < strings.length; i++) {
      if (!await _sendString(fd, i, strings[i])) {
        return false;
      }
    }

    return true;
  }

  /// Send a single AOA identification string
  Future<bool> _sendString(int fd, int index, String value) async {
    final bytes = Uint8List.fromList(value.codeUnits);
    final buffer = calloc<Uint8>(bytes.length + 1); // +1 for null terminator
    final ctrl = calloc<UsbCtrlTransfer>();

    try {
      // Copy string with null terminator
      for (var i = 0; i < bytes.length; i++) {
        buffer[i] = bytes[i];
      }
      buffer[bytes.length] = 0;

      ctrl.ref.bRequestType = USB_DIR_OUT | USB_TYPE_VENDOR | USB_RECIP_DEVICE;
      ctrl.ref.bRequest = AOA_SEND_STRING;
      ctrl.ref.wValue = 0;
      ctrl.ref.wIndex = index;
      ctrl.ref.wLength = bytes.length + 1;
      ctrl.ref.timeout = 1000;
      ctrl.ref.data = buffer.cast();

      final result = _ioctlPtr(fd, USBDEVFS_CONTROL, ctrl.cast());
      if (result < 0) {
        LogService().log(
          'UsbAoaLinux: SEND_STRING[$index] failed, errno=$_errno',
        );
        return false;
      }

      return true;
    } finally {
      calloc.free(buffer);
      calloc.free(ctrl);
    }
  }

  /// Send the START command to switch to accessory mode
  Future<bool> _startAccessoryMode(int fd) async {
    final ctrl = calloc<UsbCtrlTransfer>();

    try {
      ctrl.ref.bRequestType = USB_DIR_OUT | USB_TYPE_VENDOR | USB_RECIP_DEVICE;
      ctrl.ref.bRequest = AOA_START;
      ctrl.ref.wValue = 0;
      ctrl.ref.wIndex = 0;
      ctrl.ref.wLength = 0;
      ctrl.ref.timeout = 1000;
      ctrl.ref.data = nullptr;

      final result = _ioctlPtr(fd, USBDEVFS_CONTROL, ctrl.cast());
      if (result < 0) {
        LogService().log('UsbAoaLinux: START failed, errno=$_errno');
        return false;
      }

      return true;
    } finally {
      calloc.free(ctrl);
    }
  }

  /// Wait for device to re-enumerate in AOA mode
  Future<UsbDeviceInfo?> _waitForAoaDevice({required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      // Yield control to keep UI responsive before each iteration
      await Future.delayed(Duration(milliseconds: 500));

      final devices = await listDevices();
      final aoaDevice = devices.where((d) => d.isAoaDevice).firstOrNull;
      if (aoaDevice != null) {
        return aoaDevice;
      }
    }

    return null;
  }

  /// Open an AOA device for bulk I/O
  Future<bool> _openAoaDevice(UsbDeviceInfo device) async {
    if (!device.isAoaDevice) {
      LogService().log('UsbAoaLinux: Device is not in AOA mode');
      return false;
    }

    final pathPtr = device.devPath.toNativeUtf8();

    try {
      final fd = _open(pathPtr, O_RDWR);
      if (fd < 0) {
        LogService().log(
          'UsbAoaLinux: Failed to open AOA device, errno=$_errno',
        );
        return false;
      }

      // Find bulk endpoints by parsing the device descriptor
      final endpoints = await _findBulkEndpoints(device.sysPath);
      if (endpoints == null) {
        LogService().log('UsbAoaLinux: Failed to find bulk endpoints');
        _close(fd);
        return false;
      }

      // Claim the interface (usually 0 for AOA)
      final interfaceNum = calloc<Int32>();
      interfaceNum.value = 0;

      final claimResult = _ioctlInt(fd, USBDEVFS_CLAIMINTERFACE, interfaceNum);
      if (claimResult < 0) {
        LogService().log(
          'UsbAoaLinux: Failed to claim interface, errno=$_errno',
        );
        calloc.free(interfaceNum);
        _close(fd);
        return false;
      }
      calloc.free(interfaceNum);

      _fd = fd;
      _connectedDevice = device;
      _epIn = endpoints.$1;
      _epOut = endpoints.$2;
      _isConnected = true;

      LogService().log(
        'UsbAoaLinux: Connected to AOA device (IN=0x${_epIn!.toRadixString(16)}, OUT=0x${_epOut!.toRadixString(16)})',
      );

      // Notify connection
      _connectionController.add(UsbAoaConnectionEvent.connected(device));

      // Start reading immediately. The timed bulk-read loop will declare the
      // channel ready only after actual bytes arrive from Android.
      // Add a small delay to let Android prepare after USB mode switch
      LogService().log('UsbAoaLinux: Waiting 1s for Android to prepare...');
      await Future.delayed(Duration(seconds: 1));
      LogService().log(
        'UsbAoaLinux: Starting read loop (waiting for actual data)',
      );
      _startReadLoop();

      return true;
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Find bulk IN and OUT endpoints from sysfs
  ///
  /// Uses async file I/O to avoid blocking the UI thread.
  Future<(int, int)?> _findBulkEndpoints(String sysPath) async {
    // Look for interface 0
    final interfaceDir = Directory(sysPath);
    if (!await interfaceDir.exists()) return null;

    int? epIn;
    int? epOut;

    // Find interface 0 subdirectory (e.g., 1-1:1.0)
    // In AOA+ADB mode (0x2D01), interface 0 is AOA, interface 1 is ADB
    // We must use interface 0 for AOA communication
    await for (final entry in interfaceDir.list()) {
      if (entry is! Directory) continue;
      final name = entry.path.split('/').last;
      if (!name.contains(':')) continue;

      // Only use interface 0 (ends with .0)
      if (!name.endsWith('.0')) continue;

      LogService().log('UsbAoaLinux: Checking interface $name for endpoints');

      // Look for endpoint directories (ep_XX)
      await for (final ep in entry.list()) {
        // Yield control to keep UI responsive
        await Future.delayed(Duration.zero);

        if (ep is! Directory) continue;
        final epName = ep.path.split('/').last;
        if (!epName.startsWith('ep_')) continue;

        try {
          final typeFile = File('${ep.path}/type');
          if (!await typeFile.exists()) continue;
          final type = (await typeFile.readAsString()).trim();
          if (type != 'Bulk') continue;

          final directionFile = File('${ep.path}/direction');
          if (!await directionFile.exists()) continue;
          final direction = (await directionFile.readAsString()).trim();

          final addrFile = File('${ep.path}/bEndpointAddress');
          if (!await addrFile.exists()) continue;
          final addr = int.tryParse(
            (await addrFile.readAsString()).trim().replaceFirst('0x', ''),
            radix: 16,
          );

          if (addr == null) continue;

          if (direction == 'in') {
            epIn = addr;
          } else if (direction == 'out') {
            epOut = addr;
          }
        } catch (e) {
          continue;
        }
      }
    }

    // Use defaults if not found in sysfs
    // Standard AOA endpoints: EP1 IN (0x81), EP1 OUT (0x01)
    epIn ??= 0x81;
    epOut ??= 0x01;

    return (epIn, epOut);
  }

  /// Start the read loop
  void _startReadLoop() {
    if (_isReading) return;
    _isReading = true;

    // Run read loop in a separate isolate/thread would be better,
    // but for simplicity we use Timer.periodic
    _readLoopAsync();
  }

  /// Async read loop
  Future<void> _readLoopAsync() async {
    LogService().log(
      'UsbAoaLinux: _readLoopAsync() ENTERED, _isReading=$_isReading, _isConnected=$_isConnected, _fd=$_fd',
    );

    const bufferSize = 16384;
    final buffer = calloc<Uint8>(bufferSize);
    final bulk = calloc<UsbBulkTransfer>();

    // Clear any stall condition on the IN endpoint before starting
    // This can help recover from previous failed transfers
    if (_fd != null && _epIn != null) {
      final epInPtr = calloc<Uint32>();
      epInPtr.value = _epIn!;
      final clearResult = _ioctlPtr(_fd!, USBDEVFS_CLEAR_HALT, epInPtr.cast());
      if (clearResult < 0) {
        final err = _errno;
        LogService().log(
          'UsbAoaLinux: Clear halt on IN endpoint returned errno=$err (may be ok)',
        );
      } else {
        LogService().log('UsbAoaLinux: Cleared halt on IN endpoint');
      }
      calloc.free(epInPtr);
    }

    int consecutiveErrors = 0;
    int interruptedCount = 0;
    const maxConsecutiveErrors = 20;
    bool androidConnected = false;
    _pollTimeoutCount = 0;
    int readAttemptCounter = 0;

    LogService().log('UsbAoaLinux: Read loop starting main loop');

    try {
      while (_isReading && _isConnected && _fd != null) {
        readAttemptCounter++;
        await Future.delayed(Duration.zero);

        bulk.ref.ep = _epIn!;
        bulk.ref.len = bufferSize;
        bulk.ref.timeout = 250;
        bulk.ref.data = buffer.cast();

        final bytesRead = _ioctlPtr(_fd!, USBDEVFS_BULK, bulk.cast());

        if (bytesRead > 0) {
          LogService().log('UsbAoaLinux: Received $bytesRead bytes from USB');
          final data = Uint8List(bytesRead);
          for (var i = 0; i < bytesRead; i++) {
            data[i] = buffer[i];
          }
          _dataController.add(data);
          if (!androidConnected) {
            androidConnected = true;
            _pollTimeoutCount = 0;
            _channelReadyController.add(null);
            LogService().log('UsbAoaLinux: Channel ready (data received)');
          }
          consecutiveErrors = 0;
          interruptedCount = 0;
          continue;
        }

        final err = _errno;
        if (bytesRead == 0 || err == 110 || err == 11 || err == 16) {
          _pollTimeoutCount++;
          consecutiveErrors = 0;
          if (_pollTimeoutCount % 20 == 0) {
            LogService().log(
              'UsbAoaLinux: Still waiting for USB data ($_pollTimeoutCount timeouts, androidConnected=$androidConnected)',
            );
          }
          continue;
        }

        if (err == 4) {
          interruptedCount++;
          if (interruptedCount == 1 || interruptedCount % 100 == 0) {
            LogService().log(
              'UsbAoaLinux: Bulk read interrupted (#$interruptedCount)',
            );
          }
          continue;
        }

        consecutiveErrors++;
        if (consecutiveErrors == 1 || consecutiveErrors % 5 == 0) {
          LogService().log(
            'UsbAoaLinux: Bulk read error, errno=$err (error #$consecutiveErrors, androidConnected=$androidConnected)',
          );
        }
        if (consecutiveErrors >= maxConsecutiveErrors) {
          LogService().log(
            'UsbAoaLinux: Too many consecutive bulk read errors ($consecutiveErrors), exiting',
          );
          break;
        }
      }

      // Log why the loop exited
      LogService().log(
        'UsbAoaLinux: Read loop exited: _isReading=$_isReading, _isConnected=$_isConnected, fd=${_fd != null}, iterations=$readAttemptCounter',
      );
    } finally {
      calloc.free(buffer);
      calloc.free(bulk);
    }

    _isReading = false;

    // If we exited unexpectedly while connected, handle disconnect
    if (_isConnected) {
      await disconnect();
    }
  }

  /// Write data to the connected AOA device
  Future<bool> write(Uint8List data, {int retries = 3}) async {
    if (!_isConnected || _fd == null || _epOut == null) {
      LogService().log('UsbAoaLinux: Cannot write - not connected');
      return false;
    }

    final buffer = calloc<Uint8>(data.length);
    final bulk = calloc<UsbBulkTransfer>();

    try {
      // Copy data to native buffer
      for (var i = 0; i < data.length; i++) {
        buffer[i] = data[i];
      }

      bulk.ref.ep = _epOut!;
      bulk.ref.len = data.length;
      bulk.ref.timeout = 1000;
      bulk.ref.data = buffer.cast();

      for (var attempt = 0; attempt < retries; attempt++) {
        final bytesWritten = _ioctlPtr(_fd!, USBDEVFS_BULK, bulk.cast());

        if (bytesWritten >= 0) {
          return bytesWritten == data.length;
        }

        final err = _errno;
        // EBUSY (16) or EAGAIN (11) - retry after delay
        if (err == 16 || err == 11) {
          LogService().log(
            'UsbAoaLinux: Write busy/again (errno=$err), retry ${attempt + 1}/$retries',
          );
          await Future.delayed(Duration(milliseconds: 100 * (attempt + 1)));
          continue;
        }

        LogService().log('UsbAoaLinux: Bulk write error, errno=$err');
        return false;
      }

      LogService().log('UsbAoaLinux: Write failed after $retries retries');
      return false;
    } finally {
      calloc.free(buffer);
      calloc.free(bulk);
    }
  }

  /// Disconnect from the AOA device
  Future<void> disconnect() async {
    if (!_isConnected) return;

    LogService().log('UsbAoaLinux: Disconnecting...');

    _isReading = false;
    _isConnected = false;

    final device = _connectedDevice;

    if (_fd != null) {
      // Release interface
      final interfaceNum = calloc<Int32>();
      interfaceNum.value = 0;
      _ioctlInt(_fd!, USBDEVFS_RELEASEINTERFACE, interfaceNum);
      calloc.free(interfaceNum);

      _close(_fd!);
      _fd = null;
    }

    _connectedDevice = null;
    _epIn = null;
    _epOut = null;

    if (device != null) {
      _connectionController.add(UsbAoaConnectionEvent.disconnected(device));
    }

    LogService().log('UsbAoaLinux: Disconnected');
  }

  /// Dispose resources
  Future<void> dispose() async {
    await disconnect();
    await _connectionController.close();
    await _dataController.close();
    await _channelReadyController.close();
  }
}

// -----------------------------------------------------------------------------
// Connection Event
// -----------------------------------------------------------------------------

/// Event for USB AOA connection state changes
class UsbAoaConnectionEvent {
  final bool connected;
  final UsbDeviceInfo device;

  UsbAoaConnectionEvent._({required this.connected, required this.device});

  factory UsbAoaConnectionEvent.connected(UsbDeviceInfo device) =>
      UsbAoaConnectionEvent._(connected: true, device: device);

  factory UsbAoaConnectionEvent.disconnected(UsbDeviceInfo device) =>
      UsbAoaConnectionEvent._(connected: false, device: device);
}
