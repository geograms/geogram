import 'dart:convert';
import 'dart:io';
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

/// Lightweight WASM engine that loads a module and provides the full Geogram HAL.
class WappEngine {
  WasmInstance? _instance;
  WasmMemory? _memory;
  final List<WappLogEntry> logs = [];
  final List<String> _inbox = [];
  final List<String> _outbox = [];
  final _stopwatch = Stopwatch();
  final _random = Random.secure();
  final Map<String, Uint8List> _kv = {};
  String? _kvDir;
  bool _loaded = false;

  bool get isLoaded => _loaded;
  List<String> get outbox => List.unmodifiable(_outbox);

  /// Set a storage directory for persistent KV. Call before load().
  void setStorageDir(String dir) {
    _kvDir = dir;
    Directory(dir).createSync(recursive: true);
    _loadKv();
  }

  void _loadKv() {
    if (_kvDir == null) return;
    final file = File('$_kvDir/kv.json');
    if (!file.existsSync()) return;
    try {
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final e in data.entries) {
        _kv[e.key] = Uint8List.fromList((e.value as String).codeUnits);
      }
    } catch (_) {}
  }

  void _saveKv() {
    if (_kvDir == null) return;
    final data = <String, String>{};
    for (final e in _kv.entries) {
      data[e.key] = String.fromCharCodes(e.value);
    }
    File('$_kvDir/kv.json').writeAsStringSync(jsonEncode(data));
  }

  /// Check if a KV key exists (before module is loaded).
  bool hasKvKey(String key) => _kv.containsKey(key);

  /// Set a KV key directly (before module is loaded).
  void kvSet(String key, String value) {
    _kv[key] = Uint8List.fromList(value.codeUnits);
    _saveKv();
  }

  void sendMessage(String msg) => _inbox.add(msg);

  List<String> drainOutbox() {
    final out = List<String>.from(_outbox);
    _outbox.clear();
    return out;
  }

  // ── Helpers ──────────────────────────────────────────────────────────

  String _readStr(int ptr, int len) {
    final mem = _memory!.view;
    return String.fromCharCodes(mem.buffer.asUint8List(ptr, len));
  }

  int _writeStr(int ptr, int maxLen, String s) {
    final bytes = s.codeUnits;
    final n = bytes.length < maxLen ? bytes.length : maxLen;
    final mem = _memory!.view;
    for (var i = 0; i < n; i++) mem[ptr + i] = bytes[i];
    return n;
  }

  // ── Load ─────────────────────────────────────────────────────────────

  Future<void> load(Uint8List wasmBytes) async {
    _stopwatch.start();
    final module = await compileWasmModule(wasmBytes);
    final builder = module.builder();

    // ── System HAL ──

    final halPlatform = WasmFunction(
      (int ptr, int len) => _writeStr(ptr, len, 'flutter-desktop'),
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halHeapFree = WasmFunction(() => 1024 * 1024,
        params: [], results: [ValueTy.i32]);
    final halTimeMs = WasmFunction(
      () => _stopwatch.elapsedMilliseconds,
      params: [], results: [ValueTy.i64],
    );
    final halTimeEpoch = WasmFunction(
      () => DateTime.now().millisecondsSinceEpoch ~/ 1000,
      params: [], results: [ValueTy.i64],
    );
    final halLog = WasmFunction.voidReturn(
      (int level, int ptr, int len) {
        logs.add(WappLogEntry(level, _readStr(ptr, len)));
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
    );
    final halYield = WasmFunction.voidReturn(
      () {}, params: [],
    );

    // ── KV HAL ──

    final halKvGet = WasmFunction(
      (int kPtr, int kLen, int vPtr, int vLen) {
        final key = _readStr(kPtr, kLen);
        final val = _kv[key];
        if (val == null) return 0;
        final n = val.length < vLen ? val.length : vLen;
        final mem = _memory!.view;
        for (var i = 0; i < n; i++) mem[vPtr + i] = val[i];
        return n;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halKvSet = WasmFunction(
      (int kPtr, int kLen, int vPtr, int vLen) {
        final key = _readStr(kPtr, kLen);
        final mem = _memory!.view;
        _kv[key] = Uint8List.fromList(mem.buffer.asUint8List(vPtr, vLen));
        _saveKv();
        return 0;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halKvDelete = WasmFunction(
      (int kPtr, int kLen) {
        final removed = _kv.remove(_readStr(kPtr, kLen)) != null;
        if (removed) _saveKv();
        return removed ? 0 : -1;
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halKvList = WasmFunction(
      (int pPtr, int pLen, int bPtr, int bLen) {
        final prefix = _readStr(pPtr, pLen);
        final keys = _kv.keys.where((k) => k.startsWith(prefix)).toList();
        var offset = 0, count = 0;
        final mem = _memory!.view;
        for (final key in keys) {
          final kb = key.codeUnits;
          if (offset + kb.length + 1 > bLen) break;
          for (var i = 0; i < kb.length; i++) mem[bPtr + offset + i] = kb[i];
          offset += kb.length;
          mem[bPtr + offset] = 0;
          offset++;
          count++;
        }
        return count;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halKvExists = WasmFunction(
      (int kPtr, int kLen) => _kv.containsKey(_readStr(kPtr, kLen)) ? 1 : 0,
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halKvSize = WasmFunction(
      (int kPtr, int kLen) {
        final val = _kv[_readStr(kPtr, kLen)];
        return val?.length ?? 0;
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );

    // ── Message HAL ──

    final halMsgAvailable = WasmFunction(
      () => _inbox.isEmpty ? 0 : _inbox.first.codeUnits.length,
      params: [], results: [ValueTy.i32],
    );
    final halMsgRecv = WasmFunction(
      (int ptr, int len) {
        if (_inbox.isEmpty) return 0;
        return _writeStr(ptr, len, _inbox.removeAt(0));
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );
    final halMsgSend = WasmFunction.voidReturn(
      (int ptr, int len) => _outbox.add(_readStr(ptr, len)),
      params: [ValueTy.i32, ValueTy.i32],
    );

    // ── Stubs (return sentinel values) ──

    WasmFunction stubVoid(List<ValueTy> p) =>
        WasmFunction.voidReturn(() {}, params: p);
    WasmFunction stubI32(List<ValueTy> p, int v) =>
        WasmFunction(() => v, params: p, results: [ValueTy.i32]);

    final wasiRandomGet = WasmFunction(
      (int ptr, int len) {
        final mem = _memory!.view;
        for (var i = 0; i < len; i++) mem[ptr + i] = _random.nextInt(256);
        return 0;
      },
      params: [ValueTy.i32, ValueTy.i32], results: [ValueTy.i32],
    );

    builder.addImports([
      // System
      WasmImport('hal', 'platform', halPlatform),
      WasmImport('hal', 'heap_free', halHeapFree),
      WasmImport('hal', 'time_ms', halTimeMs),
      WasmImport('hal', 'time_epoch', halTimeEpoch),
      WasmImport('hal', 'log', halLog),
      WasmImport('hal', 'yield', halYield),
      // KV
      WasmImport('hal', 'kv_get', halKvGet),
      WasmImport('hal', 'kv_set', halKvSet),
      WasmImport('hal', 'kv_delete', halKvDelete),
      WasmImport('hal', 'kv_list', halKvList),
      WasmImport('hal', 'kv_exists', halKvExists),
      WasmImport('hal', 'kv_size', halKvSize),
      // Messages
      WasmImport('hal', 'msg_available', halMsgAvailable),
      WasmImport('hal', 'msg_recv', halMsgRecv),
      WasmImport('hal', 'msg_send', halMsgSend),
      // File (stubs)
      WasmImport('hal', 'file_open', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32], -1)),
      WasmImport('hal', 'file_read', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32], -1)),
      WasmImport('hal', 'file_write', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32], -1)),
      WasmImport('hal', 'file_close', stubVoid([ValueTy.i32])),
      // HTTP (stubs)
      WasmImport('hal', 'http_request', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32], -1)),
      WasmImport('hal', 'http_poll', stubI32([ValueTy.i32], -1)),
      WasmImport('hal', 'http_read_response', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('hal', 'http_status', stubI32([ValueTy.i32], -1)),
      WasmImport('hal', 'http_free', stubVoid([ValueTy.i32])),
      // LoRa (stubs)
      WasmImport('hal', 'lora_available_hw', stubI32([], 0)),
      WasmImport('hal', 'lora_send', stubI32([ValueTy.i32, ValueTy.i32], -1)),
      WasmImport('hal', 'lora_available', stubI32([], 0)),
      WasmImport('hal', 'lora_recv', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      // BLE (stubs)
      WasmImport('hal', 'ble_scan_start', stubI32([], -1)),
      WasmImport('hal', 'ble_scan_stop', stubVoid([])),
      WasmImport('hal', 'ble_scan_read', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('hal', 'ble_advertise', stubI32([ValueTy.i32, ValueTy.i32], -1)),
      WasmImport('hal', 'ble_advertise_stop', stubVoid([])),
      // Sensors (stubs — INT32_MIN)
      WasmImport('hal', 'sensor_temperature', stubI32([], -2147483648)),
      WasmImport('hal', 'sensor_humidity', stubI32([], -2147483648)),
      WasmImport('hal', 'sensor_battery', stubI32([], -2147483648)),
      WasmImport('hal', 'sensor_gps_lat', stubI32([], -2147483648)),
      WasmImport('hal', 'sensor_gps_lon', stubI32([], -2147483648)),
      // Display (stubs)
      WasmImport('hal', 'display_width', stubI32([], 0)),
      WasmImport('hal', 'display_height', stubI32([], 0)),
      WasmImport('hal', 'display_clear', stubVoid([])),
      WasmImport('hal', 'display_text', stubVoid([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32])),
      WasmImport('hal', 'display_pixel', stubVoid([ValueTy.i32, ValueTy.i32, ValueTy.i32])),
      WasmImport('hal', 'display_rect', stubVoid([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32])),
      WasmImport('hal', 'display_flush', stubVoid([])),
      // GPIO (stubs)
      WasmImport('hal', 'gpio_mode', stubVoid([ValueTy.i32, ValueTy.i32])),
      WasmImport('hal', 'gpio_read', stubI32([ValueTy.i32], 0)),
      WasmImport('hal', 'gpio_write', stubVoid([ValueTy.i32, ValueTy.i32])),
      // Library calls (stub)
      WasmImport('hal', 'lib_call', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32], -1)),
      // Events (stubs)
      WasmImport('hal', 'event_subscribe', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('hal', 'event_unsubscribe', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('hal', 'event_publish', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('hal', 'event_available', stubI32([], 0)),
      WasmImport('hal', 'event_recv', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32], 0)),
      // WASI
      WasmImport('wasi_snapshot_preview1', 'random_get', wasiRandomGet),
      WasmImport('wasi_snapshot_preview1', 'args_get', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'args_sizes_get', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'environ_get', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'environ_sizes_get', stubI32([ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'clock_time_get', stubI32([ValueTy.i32, ValueTy.i64, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'proc_exit', stubVoid([ValueTy.i32])),
      WasmImport('wasi_snapshot_preview1', 'fd_close', stubI32([ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'fd_write', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'fd_read', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'fd_seek', stubI32([ValueTy.i32, ValueTy.i64, ValueTy.i32], 0)),
      WasmImport('wasi_snapshot_preview1', 'fd_fdstat_get', stubI32([ValueTy.i32, ValueTy.i32], 0)),
    ]);

    _instance = await builder.build();
    _memory = _instance!.exports['memory'] as WasmMemory?;
    _loaded = true;
  }

  void init() { _instance?.getFunction('module_init')?.call([]); }
  void tick() { _instance?.getFunction('module_tick')?.call([]); }
  void handleEvent() { _instance?.getFunction('module_handle_event')?.call([]); }
  void destroy() { _instance?.getFunction('module_destroy')?.call([]); }

  int get tickIntervalMs {
    final fn = _instance?.getFunction('module_tick_interval_ms');
    if (fn == null) return 5000;
    return (fn.call([]).first as int?) ?? 5000;
  }

  void dispose() {
    if (_loaded) { destroy(); _loaded = false; }
    _stopwatch.stop();
  }
}
