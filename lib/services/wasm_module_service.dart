/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * WASM module lifecycle service — manages loading, running, and stopping
 * WASM modules via the wasm_bridge FFI layer.
 */

import 'dart:async';

import '../models/monitored_task.dart';
import '../teleport/wasm/wasm_client.dart';
import '../teleport/wasm/wasm_ffi.dart';
import '../util/task_monitor_helpers.dart';
import 'log_service.dart';

/// Event types emitted by the WASM module system.
enum WasmEventType {
  moduleLoaded,
  moduleStopped,
  moduleLog,
  moduleMessage,
  moduleEvent,
  moduleError,
  bridgeConnected,
  bridgeDisconnected,
  invokeResult,
  schemaResult,
}

/// An event from the WASM module system.
class WasmEvent {
  final WasmEventType type;
  final String? moduleId;
  final dynamic data;

  const WasmEvent(this.type, {this.moduleId, this.data});

  @override
  String toString() => 'WasmEvent($type${moduleId != null ? ', $moduleId' : ''})';
}

/// Information about a loaded WASM module.
class WasmModuleInfo {
  final String id;
  final String path;
  final bool running;
  final int tickIntervalMs;
  final String kind;
  final Map<String, dynamic>? manifest;

  const WasmModuleInfo({
    required this.id,
    required this.path,
    required this.running,
    required this.tickIntervalMs,
    this.kind = 'app',
    this.manifest,
  });

  bool get isLibrary => kind == 'library';
  bool get isApp => kind == 'app';

  factory WasmModuleInfo.fromJson(Map<String, dynamic> json) {
    return WasmModuleInfo(
      id: json['id'] as String? ?? '',
      path: json['path'] as String? ?? '',
      running: json['running'] as bool? ?? false,
      tickIntervalMs: json['tick_interval_ms'] as int? ?? 1000,
      kind: json['kind'] as String? ?? 'app',
      manifest: json['manifest'] as Map<String, dynamic>?,
    );
  }
}

/// Abstract KV backend for wapp modules.
///
/// Native backend is a pass-through (Rust handles KV via HAL).
/// Future: WebWappKvBackend using IndexedDB with `wapp:{moduleId}:{key}` namespace.
abstract class WappKvBackend {
  Future<List<int>?> get(String moduleId, String key);
  Future<void> set(String moduleId, String key, List<int> value);
  Future<bool> delete(String moduleId, String key);
  Future<List<String>> listKeys(String moduleId, String prefix);
}

/// Native KV backend — pass-through to Rust HAL (KV handled in wasm_bridge).
class NativeWappKvBackend implements WappKvBackend {
  @override
  Future<List<int>?> get(String moduleId, String key) async => null;
  @override
  Future<void> set(String moduleId, String key, List<int> value) async {}
  @override
  Future<bool> delete(String moduleId, String key) async => false;
  @override
  Future<List<String>> listKeys(String moduleId, String prefix) async => [];
}

/// WASM module lifecycle manager.
///
/// Singleton service that owns the WasmClient, manages module lifecycle,
/// and exposes a unified event stream. Modules run inside the Rust-based
/// Wasmer runtime accessed via FFI.
class WasmModuleService {
  static final WasmModuleService _instance = WasmModuleService._internal();
  factory WasmModuleService() => _instance;
  WasmModuleService._internal();

  WasmClient? _client;
  bool _initialized = false;
  StreamSubscription<Map<String, dynamic>>? _updateSub;
  MonitoredPeriodicTimer? _tickTimer;

  /// Currently tracked modules (id -> info).
  final Map<String, WasmModuleInfo> _modules = {};

  final StreamController<WasmEvent> _eventController =
      StreamController<WasmEvent>.broadcast();

  /// Stream of WASM module events.
  Stream<WasmEvent> get events => _eventController.stream;

  /// Whether the bridge is available on this platform.
  static bool get isAvailable => WasmFfi.isAvailable;

  /// Whether the service is initialized and the bridge is running.
  bool get isRunning => _client?.isRunning ?? false;

  /// List of currently loaded modules.
  List<WasmModuleInfo> get modules => List.unmodifiable(_modules.values);

  /// List of loaded library modules only.
  List<WasmModuleInfo> get libraries =>
      List.unmodifiable(_modules.values.where((m) => m.isLibrary));

  /// List of loaded app modules only.
  List<WasmModuleInfo> get apps =>
      List.unmodifiable(_modules.values.where((m) => m.isApp));

  /// Initialize the WASM bridge.
  void initialize() {
    if (_initialized) return;

    if (!isAvailable) {
      LogService().log('WasmModuleService: libwasm_bridge not available');
      return;
    }

    try {
      _client = WasmClient();
      _client!.start();

      _updateSub = _client!.updates.listen(_handleUpdate);
      _initialized = true;

      _emit(WasmEvent(WasmEventType.bridgeConnected));
      LogService().log('WasmModuleService: initialized');
    } catch (e) {
      LogService().error('WasmModuleService: failed to initialize: $e');
    }
  }

  /// Load a WASM module from a file path.
  Future<Map<String, dynamic>> loadModule(String path, {String? id, String? storageDir}) async {
    _ensureRunning();

    final request = <String, dynamic>{
      '@type': 'loadModule',
      'path': path,
    };
    if (id != null) request['id'] = id;
    if (storageDir != null) request['storageDir'] = storageDir;

    final result = await _client!.sendRequest(request);

    if (result['@type'] == 'moduleLoaded') {
      final moduleId = result['id'] as String;
      _modules[moduleId] = WasmModuleInfo(
        id: moduleId,
        path: result['path'] as String? ?? path,
        running: true,
        tickIntervalMs: result['tick_interval_ms'] as int? ?? 1000,
        kind: result['kind'] as String? ?? 'app',
        manifest: result['manifest'] as Map<String, dynamic>?,
      );
      _startTickTimerIfNeeded();
    }

    return result;
  }

  /// Unload (stop) a running module.
  Future<Map<String, dynamic>> unloadModule(String moduleId) async {
    _ensureRunning();

    final result = await _client!.sendRequest({
      '@type': 'unloadModule',
      'id': moduleId,
    });

    if (result['@type'] == 'moduleStopped') {
      _modules.remove(moduleId);
      _stopTickTimerIfEmpty();
    }

    return result;
  }

  /// List all loaded modules from the runtime.
  Future<List<WasmModuleInfo>> listModules() async {
    _ensureRunning();

    final result = await _client!.sendRequest({'@type': 'listModules'});
    final list = (result['modules'] as List<dynamic>?)
            ?.map((m) => WasmModuleInfo.fromJson(m as Map<String, dynamic>))
            .toList() ??
        [];

    // Sync local state
    _modules.clear();
    for (final m in list) {
      _modules[m.id] = m;
    }

    return list;
  }

  /// Get status of a specific module.
  Future<Map<String, dynamic>> moduleStatus(String moduleId) async {
    _ensureRunning();
    return _client!.sendRequest({'@type': 'moduleStatus', 'id': moduleId});
  }

  /// Send a message to a module.
  Future<Map<String, dynamic>> sendMessage(String moduleId, dynamic data) async {
    _ensureRunning();
    return _client!.sendRequest({
      '@type': 'sendMessage',
      'moduleId': moduleId,
      'data': data,
    });
  }

  /// Manually trigger a tick on a module.
  Future<Map<String, dynamic>> tickModule(String moduleId) async {
    _ensureRunning();
    return _client!.sendRequest({'@type': 'tickModule', 'id': moduleId});
  }

  /// Invoke a function on a library module.
  Future<Map<String, dynamic>> invokeLibraryFunction(
    String libraryId,
    String functionName,
    dynamic args,
  ) async {
    _ensureRunning();
    return _client!.sendRequest({
      '@type': 'invokeFunction',
      'libraryId': libraryId,
      'function': functionName,
      'args': args,
    });
  }

  /// Publish an event to all subscribed modules.
  Future<Map<String, dynamic>> publishEvent(String topic, String data) async {
    _ensureRunning();
    return _client!.sendRequest({
      '@type': 'publishEvent',
      'topic': topic,
      'data': data,
    });
  }

  /// Get the API schema for a library module.
  Future<Map<String, dynamic>> getLibrarySchema(String libraryId) async {
    _ensureRunning();
    return _client!.sendRequest({
      '@type': 'getSchema',
      'libraryId': libraryId,
    });
  }

  /// Shut down the bridge and clean up.
  void dispose() {
    _tickTimer?.cancel();
    _tickTimer = null;
    _updateSub?.cancel();
    _updateSub = null;
    _client?.dispose();
    _client = null;
    _modules.clear();
    _initialized = false;

    _emit(WasmEvent(WasmEventType.bridgeDisconnected));
    LogService().log('WasmModuleService: disposed');
  }

  // --- Private ---

  void _ensureRunning() {
    if (!_initialized || _client == null || !_client!.isRunning) {
      throw StateError('WasmModuleService not initialized');
    }
  }

  void _handleUpdate(Map<String, dynamic> update) {
    final type = update['@type'] as String?;
    final moduleId = update['moduleId'] as String?;

    switch (type) {
      case 'moduleLog':
        final level = update['level'] as int? ?? 1;
        final message = update['message'] as String? ?? '';
        final prefix = moduleId != null ? '[wasm:$moduleId]' : '[wasm]';
        if (level >= 2) {
          LogService().log('$prefix $message');
        }
        _emit(WasmEvent(WasmEventType.moduleLog, moduleId: moduleId, data: update));

      case 'moduleMessage':
        _emit(WasmEvent(WasmEventType.moduleMessage, moduleId: moduleId, data: update));

      case 'moduleEvent':
        _emit(WasmEvent(WasmEventType.moduleEvent, moduleId: moduleId, data: update));

      case 'moduleLoaded':
        _emit(WasmEvent(WasmEventType.moduleLoaded, moduleId: moduleId, data: update));

      case 'moduleStopped':
        _modules.remove(moduleId);
        _emit(WasmEvent(WasmEventType.moduleStopped, moduleId: moduleId, data: update));

      case 'error':
        _emit(WasmEvent(WasmEventType.moduleError, moduleId: moduleId, data: update));

      default:
        LogService().log('WasmModuleService: unhandled update type: $type');
    }
  }

  void _emit(WasmEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  /// Start a periodic timer that ticks all running app modules.
  /// Uses the minimum tick interval across all app modules.
  void _startTickTimerIfNeeded() {
    if (_modules.isEmpty) return;
    if (_tickTimer != null) return;

    // Only consider app modules for tick interval
    final appModules = _modules.values.where((m) => m.isApp).toList();
    if (appModules.isEmpty) return;

    // Tick at the minimum interval (minimum 100ms to avoid busy-spinning)
    final interval = appModules
        .map((m) => m.tickIntervalMs)
        .reduce((a, b) => a < b ? a : b)
        .clamp(100, 60000);

    _tickTimer = MonitoredPeriodicTimer(
      id: 'wasm.module_tick',
      name: 'WASM Tick',
      description: 'Ticks all running WASM app modules',
      serviceName: 'WasmModuleService',
      interval: Duration(milliseconds: interval),
      priority: TaskPriority.low,
      callback: (_) => _tickAllModules(),
    );
  }

  void _stopTickTimerIfEmpty() {
    if (_modules.values.where((m) => m.isApp).isEmpty) {
      _tickTimer?.cancel();
      _tickTimer = null;
    }
  }

  void _tickAllModules() {
    if (_client == null || !_client!.isRunning) return;

    // Only tick app modules, skip libraries
    for (final module in _modules.values) {
      if (module.isApp) {
        _client!.send({'@type': 'tickModule', 'id': module.id});
      }
    }
  }
}
