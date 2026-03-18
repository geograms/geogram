/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * High-level WASM bridge client wrapper with isolate-based receive loop
 * and async request/response correlation. Mirrors signal_client.dart.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../../models/monitored_task.dart';
import '../../services/log_service.dart';
import '../../util/task_monitor_helpers.dart';
import 'wasm_ffi.dart';

/// High-level WASM module bridge client.
///
/// Runs wasm_json_client_receive() in a separate isolate and exposes
/// incoming updates as a broadcast stream. Requests are correlated
/// with responses via the `@extra` field.
class WasmClient {
  final WasmFfi _ffi;
  Pointer<Void>? _client;
  Isolate? _receiveIsolate;
  ReceivePort? _receivePort;
  int _requestId = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  final StreamController<Map<String, dynamic>> _updateController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of all WASM updates (events not correlated to a request).
  Stream<Map<String, dynamic>> get updates => _updateController.stream;

  bool _running = false;
  MonitoredIsolateHandle? _taskHandle;

  WasmClient() : _ffi = WasmFfi();

  /// Whether the client is currently active.
  bool get isRunning => _running;

  /// Create the native WASM client and start the receive loop.
  void start() {
    if (_running) return;

    _client = _ffi.create();
    if (_client == null || _client == nullptr) {
      throw StateError('Failed to create WASM bridge client');
    }

    _running = true;
    _startReceiveLoop();
    LogService().log('WasmClient: started');
  }

  /// Send a request and wait for the correlated response.
  Future<Map<String, dynamic>> sendRequest(
    Map<String, dynamic> request, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    if (!_running || _client == null) {
      return Future.error(StateError('WASM client not running'));
    }

    final id = 'wasm_${++_requestId}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    final payload = Map<String, dynamic>.from(request);
    payload['@extra'] = id;

    final jsonStr = jsonEncode(payload);
    final nativeStr = jsonStr.toNativeUtf8();
    _ffi.send(_client!, nativeStr);
    malloc.free(nativeStr);

    final reqType = request['@type'] ?? '?';

    return completer.future.timeout(timeout, onTimeout: () {
      _pendingRequests.remove(id);
      stderr.writeln('WasmClient: request $reqType ($id) timed out');
      return <String, dynamic>{
        '@type': 'error',
        'code': 408,
        'message': 'Request timed out: $reqType',
      };
    });
  }

  /// Fire-and-forget send (no response correlation).
  void send(Map<String, dynamic> request) {
    if (!_running || _client == null) return;

    final jsonStr = jsonEncode(request);
    final nativeStr = jsonStr.toNativeUtf8();
    _ffi.send(_client!, nativeStr);
    malloc.free(nativeStr);
  }

  /// Synchronous execute (for queries that don't need the event loop).
  Map<String, dynamic>? execute(Map<String, dynamic> request) {
    if (_client == null) return null;

    final jsonStr = jsonEncode(request);
    final nativeStr = jsonStr.toNativeUtf8();
    final result = _ffi.execute(_client!, nativeStr);
    malloc.free(nativeStr);

    if (result == nullptr) return null;
    final resultStr = result.toDartString();
    if (resultStr.isEmpty) return null;

    return jsonDecode(resultStr) as Map<String, dynamic>;
  }

  /// Stop the receive loop and destroy the native client.
  void stop() {
    if (!_running) return;
    _running = false;

    _taskHandle?.markIdle();
    _taskHandle?.dispose();
    _taskHandle = null;
    _receiveIsolate?.kill(priority: Isolate.immediate);
    _receiveIsolate = null;
    _receivePort?.close();
    _receivePort = null;

    if (_client != null && _client != nullptr) {
      _ffi.destroy(_client!);
      _client = null;
    }

    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('WASM client stopped'));
      }
    }
    _pendingRequests.clear();

    LogService().log('WasmClient: stopped');
  }

  /// Dispose resources.
  void dispose() {
    stop();
    _updateController.close();
  }

  // --- Private ---

  void _startReceiveLoop() {
    _receivePort = ReceivePort();
    _receivePort!.listen(_handleIsolateMessage);

    final params = _ReceiveLoopParams(
      clientAddress: _client!.address,
      sendPort: _receivePort!.sendPort,
    );

    _taskHandle = MonitoredIsolateHandle(
      id: 'wasm.receive_loop',
      name: 'WASM Receiver',
      description: 'WASM FFI receive loop',
      serviceName: 'WasmClient',
      priority: TaskPriority.normal,
    );
    Isolate.spawn(_receiveLoopEntry, params).then((isolate) {
      _receiveIsolate = isolate;
      _taskHandle?.markRunning();
    });
  }

  void _handleIsolateMessage(dynamic message) {
    if (message is! String) return;

    Map<String, dynamic> json;
    try {
      json = jsonDecode(message) as Map<String, dynamic>;
    } catch (e) {
      LogService().error('WasmClient: failed to decode: $e');
      return;
    }

    // Check if this is a response to a pending request.
    final extra = json['@extra'];
    if (extra != null) {
      final key = extra.toString();
      final completer = _pendingRequests.remove(key);
      if (completer != null && !completer.isCompleted) {
        completer.complete(json);
        return;
      }
    }

    // Otherwise it's an update — push to the stream
    if (!_updateController.isClosed) {
      _updateController.add(json);
    }
  }

  /// Isolate entry point — runs the blocking receive loop.
  static void _receiveLoopEntry(_ReceiveLoopParams params) {
    final ffi = WasmFfi();
    final client = Pointer<Void>.fromAddress(params.clientAddress);

    while (true) {
      final result = ffi.receive(client, 1.0);
      if (result == nullptr) continue;

      final str = result.toDartString();
      if (str.isNotEmpty) {
        params.sendPort.send(str);
      }
    }
  }
}

class _ReceiveLoopParams {
  final int clientAddress;
  final SendPort sendPort;

  _ReceiveLoopParams({required this.clientAddress, required this.sendPort});
}
