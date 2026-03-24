import 'dart:math';
import 'dart:typed_data';

import 'package:wasm_run/wasm_run.dart';

/// Log entry from a WASM module.
class WappLogEntry {
  final int level; // 0=debug, 1=info, 2=warn, 3=error
  final String message;
  final DateTime timestamp;

  WappLogEntry(this.level, this.message) : timestamp = DateTime.now();

  String get levelName => const ['DEBUG', 'INFO', 'WARN', 'ERROR'][level.clamp(0, 3)];
}

/// Lightweight WASM engine that loads a module and provides the Geogram HAL.
class WappEngine {
  WasmInstance? _instance;
  WasmMemory? _memory;
  final List<WappLogEntry> logs = [];
  final List<String> _inbox = []; // messages queued for the module
  final List<String> _outbox = []; // messages sent by the module
  final _stopwatch = Stopwatch();
  final _random = Random.secure();
  bool _loaded = false;

  bool get isLoaded => _loaded;
  List<String> get outbox => List.unmodifiable(_outbox);

  /// Send a message to the module (available on next tick/event).
  void sendMessage(String msg) => _inbox.add(msg);

  /// Consume outbox messages sent by the module.
  List<String> drainOutbox() {
    final out = List<String>.from(_outbox);
    _outbox.clear();
    return out;
  }

  /// Load and instantiate a WASM binary with HAL host functions.
  Future<void> load(Uint8List wasmBytes) async {
    _stopwatch.start();
    final module = await compileWasmModule(wasmBytes);
    final builder = module.builder();

    // We need memory to read/write string buffers.
    // The module exports its own memory — we'll grab it after build.
    // For now, provide HAL imports.

    // hal.platform(ptr, len) -> i32
    final halPlatform = WasmFunction(
      (int ptr, int len) {
        const platform = 'flutter-desktop';
        final bytes = platform.codeUnits;
        final n = bytes.length < len ? bytes.length : len;
        final mem = _memory!.view;
        for (var i = 0; i < n; i++) {
          mem[ptr + i] = bytes[i];
        }
        return n;
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );

    // hal.heap_free() -> i32
    final halHeapFree = WasmFunction(
      () => 1024 * 1024, // report 1MB
      params: [],
      results: [ValueTy.i32],
    );

    // hal.time_ms() -> i64
    final halTimeMs = WasmFunction(
      () => _stopwatch.elapsedMilliseconds,
      params: [],
      results: [ValueTy.i64],
    );

    // hal.log(level, ptr, len) -> void
    final halLog = WasmFunction.voidReturn(
      (int level, int ptr, int len) {
        final mem = _memory!.view;
        final bytes = mem.buffer.asUint8List(ptr, len);
        final msg = String.fromCharCodes(bytes);
        logs.add(WappLogEntry(level, msg));
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
    );

    // hal.msg_available() -> i32
    final halMsgAvailable = WasmFunction(
      () => _inbox.isEmpty ? 0 : 1,
      params: [],
      results: [ValueTy.i32],
    );

    // hal.msg_recv(ptr, len) -> i32
    final halMsgRecv = WasmFunction(
      (int ptr, int len) {
        if (_inbox.isEmpty) return 0;
        final msg = _inbox.removeAt(0);
        final bytes = msg.codeUnits;
        final n = bytes.length < len ? bytes.length : len;
        final mem = _memory!.view;
        for (var i = 0; i < n; i++) {
          mem[ptr + i] = bytes[i];
        }
        return n;
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );

    // hal.msg_send(ptr, len) -> void
    final halMsgSend = WasmFunction.voidReturn(
      (int ptr, int len) {
        final mem = _memory!.view;
        final bytes = mem.buffer.asUint8List(ptr, len);
        _outbox.add(String.fromCharCodes(bytes));
      },
      params: [ValueTy.i32, ValueTy.i32],
    );

    // wasi_snapshot_preview1.random_get(ptr, len) -> i32
    final wasiRandomGet = WasmFunction(
      (int ptr, int len) {
        final mem = _memory!.view;
        for (var i = 0; i < len; i++) {
          mem[ptr + i] = _random.nextInt(256);
        }
        return 0; // success
      },
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );

    builder.addImports([
      WasmImport('hal', 'platform', halPlatform),
      WasmImport('hal', 'heap_free', halHeapFree),
      WasmImport('hal', 'time_ms', halTimeMs),
      WasmImport('hal', 'log', halLog),
      WasmImport('hal', 'msg_available', halMsgAvailable),
      WasmImport('hal', 'msg_recv', halMsgRecv),
      WasmImport('hal', 'msg_send', halMsgSend),
      WasmImport('wasi_snapshot_preview1', 'random_get', wasiRandomGet),
    ]);

    _instance = await builder.build();

    // Grab the exported memory
    _memory = _instance!.exports['memory'] as WasmMemory?;
    _loaded = true;
  }

  /// Call module_init().
  void init() {
    _instance?.getFunction('module_init')?.call([]);
  }

  /// Call module_tick().
  void tick() {
    _instance?.getFunction('module_tick')?.call([]);
  }

  /// Call module_handle_event().
  void handleEvent() {
    _instance?.getFunction('module_handle_event')?.call([]);
  }

  /// Call module_destroy().
  void destroy() {
    _instance?.getFunction('module_destroy')?.call([]);
  }

  /// Get tick interval from the module (ms).
  int get tickIntervalMs {
    final fn = _instance?.getFunction('module_tick_interval_ms');
    if (fn == null) return 5000;
    final result = fn.call([]);
    return (result.first as int?) ?? 5000;
  }

  void dispose() {
    if (_loaded) {
      destroy();
      _loaded = false;
    }
    _stopwatch.stop();
  }
}
