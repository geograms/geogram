/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Raw FFI bindings for the WASM bridge JSON client interface.
 * Mirrors signal_ffi.dart — same 5 C functions: create, send, receive, execute, destroy.
 */

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import '../../services/log_service.dart';

// --- Native function type signatures ---

typedef WasmJsonClientCreateNative = Pointer<Void> Function();
typedef WasmJsonClientCreate = Pointer<Void> Function();

typedef WasmJsonClientSendNative = Void Function(
    Pointer<Void> client, Pointer<Utf8> request);
typedef WasmJsonClientSend = void Function(
    Pointer<Void> client, Pointer<Utf8> request);

typedef WasmJsonClientReceiveNative = Pointer<Utf8> Function(
    Pointer<Void> client, Double timeout);
typedef WasmJsonClientReceive = Pointer<Utf8> Function(
    Pointer<Void> client, double timeout);

typedef WasmJsonClientExecuteNative = Pointer<Utf8> Function(
    Pointer<Void> client, Pointer<Utf8> request);
typedef WasmJsonClientExecute = Pointer<Utf8> Function(
    Pointer<Void> client, Pointer<Utf8> request);

typedef WasmJsonClientDestroyNative = Void Function(Pointer<Void> client);
typedef WasmJsonClientDestroy = void Function(Pointer<Void> client);

/// Raw FFI bindings to libwasm_bridge.
class WasmFfi {
  static DynamicLibrary? _lib;

  late final WasmJsonClientCreate create;
  late final WasmJsonClientSend send;
  late final WasmJsonClientReceive receive;
  late final WasmJsonClientExecute execute;
  late final WasmJsonClientDestroy destroy;

  WasmFfi() {
    _loadLibrary();
    _bindFunctions();
  }

  /// Check if libwasm_bridge is available on this platform.
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

    final paths = [
      'libwasm_bridge.so',
      'lib/libwasm_bridge.so',
      '/usr/lib/libwasm_bridge.so',
      '/usr/local/lib/libwasm_bridge.so',
    ];

    for (final path in paths) {
      try {
        _lib = DynamicLibrary.open(path);
        LogService().log('WasmFfi: Loaded library from $path');
        return;
      } catch (e) {
        continue;
      }
    }

    throw UnsupportedError(
        'Could not load libwasm_bridge. Ensure libwasm_bridge.so is built and accessible.');
  }

  void _bindFunctions() {
    final lib = _lib!;

    create = lib.lookupFunction<WasmJsonClientCreateNative, WasmJsonClientCreate>(
        'wasm_json_client_create');

    send = lib.lookupFunction<WasmJsonClientSendNative, WasmJsonClientSend>(
        'wasm_json_client_send');

    receive = lib.lookupFunction<WasmJsonClientReceiveNative, WasmJsonClientReceive>(
        'wasm_json_client_receive');

    execute = lib.lookupFunction<WasmJsonClientExecuteNative, WasmJsonClientExecute>(
        'wasm_json_client_execute');

    destroy = lib.lookupFunction<WasmJsonClientDestroyNative, WasmJsonClientDestroy>(
        'wasm_json_client_destroy');
  }
}
