/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Raw FFI bindings for the Signal bridge JSON client interface.
 * Mirrors tdlib_ffi.dart — same 5 C functions: create, send, receive, execute, destroy.
 */

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import '../../services/log_service.dart';

// --- Native function type signatures ---

typedef SignalJsonClientCreateNative = Pointer<Void> Function();
typedef SignalJsonClientCreate = Pointer<Void> Function();

typedef SignalJsonClientSendNative = Void Function(
    Pointer<Void> client, Pointer<Utf8> request);
typedef SignalJsonClientSend = void Function(
    Pointer<Void> client, Pointer<Utf8> request);

typedef SignalJsonClientReceiveNative = Pointer<Utf8> Function(
    Pointer<Void> client, Double timeout);
typedef SignalJsonClientReceive = Pointer<Utf8> Function(
    Pointer<Void> client, double timeout);

typedef SignalJsonClientExecuteNative = Pointer<Utf8> Function(
    Pointer<Void> client, Pointer<Utf8> request);
typedef SignalJsonClientExecute = Pointer<Utf8> Function(
    Pointer<Void> client, Pointer<Utf8> request);

typedef SignalJsonClientDestroyNative = Void Function(Pointer<Void> client);
typedef SignalJsonClientDestroy = void Function(Pointer<Void> client);

/// Raw FFI bindings to libsignal_bridge.
class SignalFfi {
  static DynamicLibrary? _lib;

  late final SignalJsonClientCreate create;
  late final SignalJsonClientSend send;
  late final SignalJsonClientReceive receive;
  late final SignalJsonClientExecute execute;
  late final SignalJsonClientDestroy destroy;

  SignalFfi() {
    _loadLibrary();
    _bindFunctions();
  }

  /// Check if libsignal_bridge is available on this platform.
  static bool get isAvailable {
    try {
      _loadLibrary();
      return true;
    } catch (e) {
      return false;
    }
  }

  static void _loadLibrary() {
    if (_lib != null) return;

    // On Android, bare name resolves from APK jniLibs; on Linux, try common paths
    final paths = [
      'libsignal_bridge.so',
      'lib/libsignal_bridge.so',
      '/usr/lib/libsignal_bridge.so',
      '/usr/local/lib/libsignal_bridge.so',
    ];

    for (final path in paths) {
      try {
        _lib = DynamicLibrary.open(path);
        LogService().log('SignalFfi: Loaded library from $path');
        return;
      } catch (e) {
        continue;
      }
    }

    throw UnsupportedError(
        'Could not load libsignal_bridge. Place libsignal_bridge.so in jniLibs/{abi}/ (Android) or linux/signal/{arch}/ (Linux)');
  }

  void _bindFunctions() {
    final lib = _lib!;

    create = lib
        .lookupFunction<SignalJsonClientCreateNative, SignalJsonClientCreate>(
            'signal_json_client_create');

    send = lib.lookupFunction<SignalJsonClientSendNative, SignalJsonClientSend>(
        'signal_json_client_send');

    receive = lib
        .lookupFunction<SignalJsonClientReceiveNative, SignalJsonClientReceive>(
            'signal_json_client_receive');

    execute = lib
        .lookupFunction<SignalJsonClientExecuteNative, SignalJsonClientExecute>(
            'signal_json_client_execute');

    destroy = lib
        .lookupFunction<SignalJsonClientDestroyNative, SignalJsonClientDestroy>(
            'signal_json_client_destroy');
  }
}
