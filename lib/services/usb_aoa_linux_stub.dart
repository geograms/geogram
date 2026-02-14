/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Stub for usb_aoa_linux.dart — used on web where dart:ffi is unavailable.
 * Provides the same public API surface so usb_aoa_service.dart compiles.
 */

import 'dart:async';
import 'dart:typed_data';

class UsbDeviceInfo {
  final int vid;
  final int pid;
  final String devPath;
  final String sysPath;
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

  String get vidHex => '0x${vid.toRadixString(16).toUpperCase().padLeft(4, '0')}';
  String get pidHex => '0x${pid.toRadixString(16).toUpperCase().padLeft(4, '0')}';

  bool get isAndroidDevice => false;
  bool get isAoaDevice => false;

  @override
  String toString() => 'UsbDevice($vidHex:$pidHex $devPath)';
}

class UsbAoaLinux {
  Stream<UsbAoaConnectionEvent> get connectionStream => const Stream.empty();
  Stream<Uint8List> get dataStream => const Stream.empty();
  Stream<void> get channelReadyStream => const Stream.empty();
  bool get isReading => false;
  int get pollTimeoutCount => 0;

  Future<void> initialize() async {}
  Future<List<UsbDeviceInfo>> listDevices() async => [];
  Future<bool> connect(UsbDeviceInfo device) async => false;
  Future<void> disconnect() async {}
  Future<bool> write(Uint8List data) async => false;
  Future<void> dispose() async {}
}

class UsbAoaConnectionEvent {
  final bool connected;
  final UsbDeviceInfo device;

  UsbAoaConnectionEvent._({required this.connected, required this.device});

  factory UsbAoaConnectionEvent.connected(UsbDeviceInfo device) =>
      UsbAoaConnectionEvent._(connected: true, device: device);

  factory UsbAoaConnectionEvent.disconnected(UsbDeviceInfo device) =>
      UsbAoaConnectionEvent._(connected: false, device: device);
}
