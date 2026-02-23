/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Raw FFI bindings for TDLib's JSON client interface.
 * Only 5 C functions are needed: create, send, receive, execute, destroy.
 */

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import '../../services/log_service.dart';

// --- Native function type signatures ---

typedef TdJsonClientCreateNative = Pointer<Void> Function();
typedef TdJsonClientCreate = Pointer<Void> Function();

typedef TdJsonClientSendNative = Void Function(
    Pointer<Void> client, Pointer<Utf8> request);
typedef TdJsonClientSend = void Function(
    Pointer<Void> client, Pointer<Utf8> request);

typedef TdJsonClientReceiveNative = Pointer<Utf8> Function(
    Pointer<Void> client, Double timeout);
typedef TdJsonClientReceive = Pointer<Utf8> Function(
    Pointer<Void> client, double timeout);

typedef TdJsonClientExecuteNative = Pointer<Utf8> Function(
    Pointer<Void> client, Pointer<Utf8> request);
typedef TdJsonClientExecute = Pointer<Utf8> Function(
    Pointer<Void> client, Pointer<Utf8> request);

typedef TdJsonClientDestroyNative = Void Function(Pointer<Void> client);
typedef TdJsonClientDestroy = void Function(Pointer<Void> client);

/// Raw FFI bindings to libtdjson.
class TdlibFfi {
  static DynamicLibrary? _lib;

  late final TdJsonClientCreate create;
  late final TdJsonClientSend send;
  late final TdJsonClientReceive receive;
  late final TdJsonClientExecute execute;
  late final TdJsonClientDestroy destroy;

  TdlibFfi() {
    _loadLibrary();
    _bindFunctions();
  }

  /// Check if libtdjson is available on this platform.
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
      'lib/libtdjson.so',
      'libtdjson.so',
      'libtdjson.so.1',
      '/usr/lib/libtdjson.so',
      '/usr/local/lib/libtdjson.so',
    ];

    for (final path in paths) {
      try {
        _lib = DynamicLibrary.open(path);
        LogService().log('TdlibFfi: Loaded library from $path');
        return;
      } catch (e) {
        continue;
      }
    }

    throw UnsupportedError(
        'Could not load libtdjson. Place libtdjson.so in linux/tdlib/{arch}/');
  }

  void _bindFunctions() {
    final lib = _lib!;

    create = lib.lookupFunction<TdJsonClientCreateNative, TdJsonClientCreate>(
        'td_json_client_create');

    send = lib.lookupFunction<TdJsonClientSendNative, TdJsonClientSend>(
        'td_json_client_send');

    receive =
        lib.lookupFunction<TdJsonClientReceiveNative, TdJsonClientReceive>(
            'td_json_client_receive');

    execute =
        lib.lookupFunction<TdJsonClientExecuteNative, TdJsonClientExecute>(
            'td_json_client_execute');

    destroy =
        lib.lookupFunction<TdJsonClientDestroyNative, TdJsonClientDestroy>(
            'td_json_client_destroy');
  }
}
