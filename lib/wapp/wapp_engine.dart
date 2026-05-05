import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'dart:io'
    if (dart.library.html) '../platform/io_stub.dart'
    show File, FileMode, Process;

import 'package:wasm_run/wasm_run.dart';

import '../services/i18n_context.dart';
import '../services/profile_storage.dart';
import '../services/wapp_event_broker.dart';

/// State for a single hal_process_exec subprocess. Lives in
/// [WappEngine._procs] keyed by handle. The wapp polls
/// hal_process_poll until [exitCode] is set, drains stdout/stderr
/// at any time, then calls hal_process_free to release the entry.
class _WappProcState {
  Process? proc;
  int? exitCode;
  final List<int> stdoutBuf = <int>[];
  final List<int> stderrBuf = <int>[];
  StreamSubscription<List<int>>? stdoutSub;
  StreamSubscription<List<int>>? stderrSub;
}

/// State for a single hal_file_* handle. Lives in [WappEngine._files]
/// keyed by handle. Reads slurp the whole file at open and serve from
/// the buffer; writes accumulate and flush at close. Fine for the
/// source-code-sized files wapps actually use.
class _WappFileState {
  _WappFileState({required this.path, required this.mode});
  final String path;
  final int mode; // 0 = read, 1 = write (truncate), 2 = append
  Uint8List? readBuf;
  int readOffset = 0;
  final List<int> writeBuf = <int>[];
}

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
  static int _nextEngineId = 0;

  /// Lookup table of every live engine, keyed by [engineId]. Used by
  /// [WidgetBroker] to find a caller engine and inject a
  /// widget.response message without needing a widget tree reference.
  static final Map<String, WappEngine> _byId = {};

  /// Find a live engine by id, or null if none is registered. Called
  /// by the widget broker on the response delivery path.
  static WappEngine? lookup(String engineId) => _byId[engineId];

  /// Stable identifier for this engine instance, used by
  /// [WappEventBroker] for routing cross-wapp pub/sub and by
  /// [WidgetBroker] for delivering widget.response messages.
  final String engineId = 'engine-${_nextEngineId++}';

  WasmInstance? _instance;
  WasmMemory? _memory;
  final List<WappLogEntry> logs = [];
  final List<String> _inbox = [];
  final List<String> _outbox = [];
  final _stopwatch = Stopwatch();
  final _random = Random.secure();
  final Map<String, Uint8List> _kv = {};
  ProfileStorage? _storage;
  bool _loaded = false;

  // hal_process_* state. Handles are positive ints; 0 is reserved
  // (the C side treats 0 as a valid handle but we skip it to leave
  // room for "absent" sentinels in callers).
  final Map<int, _WappProcState> _procs = {};
  int _nextProcHandle = 1;

  // hal_file_* state. Handles are positive ints, same convention as
  // _procs.
  final Map<int, _WappFileState> _files = {};
  int _nextFileHandle = 1;

  // Cached last-known location, fed by the host (LocationProviderService
  // → WappPage). Read by hal_sensor_gps_lat / hal_sensor_gps_lon. When
  // unset, both HAL imports return INT32_MIN so wapps can detect "no fix".
  double? _lastLat;
  double? _lastLon;

  /// Translation tables handed over by [WappPage._reloadI18n]. Used
  /// by the `hal_i18n_get` import to resolve `@key` / bare-key lookups
  /// from the wapp's C code. An empty context (the default) means
  /// `hal_i18n_get` always returns 0 — the wapp's fallback literal
  /// takes over. See i18n_context.dart for the resolution rules.
  I18nContext _i18n = I18nContext.empty();

  /// Attach or replace the translation tables. Called once on wapp
  /// load and again on every [LocaleChangedEvent].
  void setI18n(I18nContext context) {
    _i18n = context;
  }

  /// The active translation context (for the host's GeoUI renderer
  /// to resolve `@key` strings consistently with the WASM side).
  I18nContext get i18n => _i18n;

  WappEngine() {
    _byId[engineId] = this;
    WappEventBroker.instance.registerEngine(engineId);
  }

  bool get isLoaded => _loaded;
  List<String> get outbox => List.unmodifiable(_outbox);

  /// Attach a [ProfileStorage] for persistent KV. Call before [load].
  /// Loads kv.json into the in-memory map. The WASM KV callbacks
  /// operate on the in-memory map (sync) and writes are flushed
  /// fire-and-forget back to storage (async, works with both
  /// filesystem and encrypted backends).
  Future<void> setStorage(ProfileStorage storage) async {
    _storage = storage;
    await _loadKv();
  }

  Future<void> _loadKv() async {
    final storage = _storage;
    if (storage == null) return;
    final bytes = await storage.readBytes('kv.json');
    if (bytes == null) return;
    try {
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      for (final e in data.entries) {
        _kv[e.key] = Uint8List.fromList((e.value as String).codeUnits);
      }
    } catch (_) {}
  }

  void _saveKv() {
    final storage = _storage;
    if (storage == null) return;
    final data = <String, String>{};
    for (final e in _kv.entries) {
      data[e.key] = String.fromCharCodes(e.value);
    }
    // Fire-and-forget; the in-memory _kv map is the source of truth
    // for HAL callbacks, so we don't need to await this.
    storage.writeString('kv.json', jsonEncode(data));
  }

  /// Check if a KV key exists (before module is loaded).
  bool hasKvKey(String key) => _kv.containsKey(key);

  /// List all KV keys (for debugging).
  List<String> get kvKeys => _kv.keys.toList();

  /// Set a KV key directly (before module is loaded).
  void kvSet(String key, String value) {
    // utf8 (not codeUnits) — same reason _writeStr uses utf8: any
    // char > 0x7F otherwise gets truncated to its low byte.
    _kv[key] = Uint8List.fromList(utf8.encode(value));
    _saveKv();
  }

  /// Update the cached location read by `hal_sensor_gps_lat` /
  /// `hal_sensor_gps_lon`. Called by the host whenever a fresh fix
  /// becomes available so the cheap synchronous HAL pair returns
  /// real data instead of INT32_MIN. Pass NaN to clear.
  void setLastLocation({required double lat, required double lon}) {
    _lastLat = lat.isFinite ? lat : null;
    _lastLon = lon.isFinite ? lon : null;
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
    // Wapp memory holds UTF-8 — codeUnits truncates non-ASCII bytes
    // back to mojibake. Always decode as UTF-8.
    return utf8.decode(mem.buffer.asUint8List(ptr, len), allowMalformed: true);
  }

  int _writeStr(int ptr, int maxLen, String s) {
    // Same reasoning as _readStr — wapps see UTF-8 bytes. codeUnits
    // would silently drop the high byte of any char outside 0x00-0xFF
    // (e.g. em-dash U+2014 → 0x14, breaking JSON parsing on the wapp
    // side). utf8.encode keeps multi-byte sequences intact.
    final bytes = utf8.encode(s);
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

    // ── i18n HAL ──
    //
    // Look up a translation key in the wapp's loaded [_i18n]
    // context. Returns the number of bytes written. Zero means
    // "not found" (empty buffer is OK for the caller) — the
    // wapp's C code is expected to fall back to its hard-coded
    // literal in that case. See docs/plan/wapp-i18n.md for the
    // resolution rules.
    final halI18nGet = WasmFunction(
      (int kPtr, int kLen, int oPtr, int oCap) {
        final key = _readStr(kPtr, kLen);
        // Use resolve() so the key's `@` sentinel is stripped if
        // the wapp happens to pass `@foo.bar` instead of `foo.bar`.
        final raw = key.startsWith('@') ? key : '@$key';
        final value = _i18n.resolve(raw);
        // If the lookup missed, resolve() returns the bare key —
        // detect that and report zero so the wapp falls back to
        // its literal instead of writing "foo.bar" into the UI.
        if (value == key || value == raw.substring(1)) return 0;
        final bytes = utf8.encode(value);
        final n = bytes.length < oCap ? bytes.length : oCap;
        final mem = _memory!.view;
        for (var i = 0; i < n; i++) mem[oPtr + i] = bytes[i];
        return n;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
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

    // ── Event HAL (cross-wapp pub/sub via WappEventBroker) ──

    final halEventSubscribe = WasmFunction(
      (int tPtr, int tLen) => WappEventBroker.instance
          .subscribe(engineId, _readStr(tPtr, tLen)),
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halEventUnsubscribe = WasmFunction(
      (int tPtr, int tLen) => WappEventBroker.instance
          .unsubscribe(engineId, _readStr(tPtr, tLen)),
      params: [ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halEventPublish = WasmFunction(
      (int tPtr, int tLen, int dPtr, int dLen) =>
          WappEventBroker.instance.publish(
        engineId,
        _readStr(tPtr, tLen),
        _readStr(dPtr, dLen),
      ),
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halEventAvailable = WasmFunction(
      () => WappEventBroker.instance.availableSize(engineId),
      params: [],
      results: [ValueTy.i32],
    );
    final halEventRecv = WasmFunction(
      (int tPtr, int tLen, int dPtr, int dLen) {
        final ev = WappEventBroker.instance.recv(engineId);
        if (ev == null) return 0;
        // Null-terminate both buffers so C wapps can read them with
        // strlen(). Reserve one byte of each buffer for the null.
        final tWritten = _writeStr(tPtr, tLen - 1, ev.topic);
        _memory!.view[tPtr + tWritten] = 0;
        final dWritten = _writeStr(dPtr, dLen - 1, ev.data);
        _memory!.view[dPtr + dWritten] = 0;
        // Return value is bytes written to the DATA buffer, not
        // counting the null terminator — matches hal_msg_recv.
        return dWritten;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );

    // ── Process HAL (host subprocess, no sandbox) ──
    //
    // See wapps/hal/geogram_wasm_hal.h for the full spec. Runs an
    // arbitrary host binary on behalf of the wapp. Async polling
    // mirroring hal_http_*: exec returns a handle, the wapp polls
    // until done, drains stdout/stderr at any time, frees when
    // finished.

    final halProcessExec = WasmFunction(
      (int argvPtr, int argvLen, int cwdPtr, int cwdLen) {
        final argvJson = _readStr(argvPtr, argvLen);
        final cwd = cwdLen > 0 ? _readStr(cwdPtr, cwdLen) : null;
        List<String> argv;
        try {
          final parsed = jsonDecode(argvJson);
          if (parsed is! List || parsed.isEmpty) return -1;
          argv = parsed.map((e) => e.toString()).toList();
        } catch (_) {
          return -1;
        }
        final h = _nextProcHandle++;
        final s = _WappProcState();
        _procs[h] = s;
        // Spawn asynchronously — return the handle immediately so
        // the wapp can poll on the next tick.
        Process.start(
          argv.first,
          argv.skip(1).toList(),
          workingDirectory: (cwd != null && cwd.isNotEmpty) ? cwd : null,
          runInShell: false,
        ).then((p) {
          s.proc = p;
          s.stdoutSub = p.stdout.listen(s.stdoutBuf.addAll);
          s.stderrSub = p.stderr.listen(s.stderrBuf.addAll);
          p.exitCode.then((c) => s.exitCode = c);
        }).catchError((e) {
          // Spawn failed (binary missing, permission, etc). Mark
          // the entry as exited with a non-zero code so the wapp's
          // poll loop terminates cleanly. Stash the error message
          // into stderr so the wapp can surface it.
          s.exitCode = 127;
          s.stderrBuf.addAll(utf8.encode('$e\n'));
        });
        return h;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halProcessPoll = WasmFunction(
      (int h) {
        final s = _procs[h];
        if (s == null) return -1;
        return s.exitCode == null ? 0 : 1;
      },
      params: [ValueTy.i32], results: [ValueTy.i32],
    );
    final halProcessExitCode = WasmFunction(
      (int h) {
        final s = _procs[h];
        if (s == null) return -1;
        return s.exitCode ?? -1;
      },
      params: [ValueTy.i32], results: [ValueTy.i32],
    );
    int drainBuf(List<int> buf, int bufPtr, int bufLen) {
      final n = buf.length < bufLen ? buf.length : bufLen;
      if (n == 0) return 0;
      final mem = _memory!.view;
      for (var i = 0; i < n; i++) mem[bufPtr + i] = buf[i];
      buf.removeRange(0, n);
      return n;
    }
    final halProcessReadStdout = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _procs[h];
        if (s == null) return 0;
        return drainBuf(s.stdoutBuf, bufPtr, bufLen);
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halProcessReadStderr = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _procs[h];
        if (s == null) return 0;
        return drainBuf(s.stderrBuf, bufPtr, bufLen);
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halProcessFree = WasmFunction.voidReturn(
      (int h) {
        final s = _procs.remove(h);
        if (s == null) return;
        s.stdoutSub?.cancel();
        s.stderrSub?.cancel();
        if (s.exitCode == null) {
          // Still running — best-effort kill.
          try { s.proc?.kill(); } catch (_) {}
        }
      },
      params: [ValueTy.i32],
    );

    // ── File HAL (host filesystem, no sandbox) ──
    //
    // Absolute paths, full filesystem access — same trust model as
    // hal_process_exec. Reads slurp the whole file at open and serve
    // from a buffer; writes accumulate and flush at close. The host
    // creates parent directories on write/append open as a
    // convenience so wapps don't need a separate mkdir round-trip.

    final halFileOpen = WasmFunction(
      (int pathPtr, int pathLen, int mode) {
        final path = _readStr(pathPtr, pathLen);
        if (path.isEmpty || mode < 0 || mode > 2) return -1;
        final s = _WappFileState(path: path, mode: mode);
        if (mode == 0) {
          try {
            s.readBuf = File(path).readAsBytesSync();
          } catch (_) {
            return -1;
          }
        } else {
          // Write or append — make sure the parent dir exists so the
          // close-time flush doesn't fail on a missing directory.
          try {
            final parent = File(path).parent;
            if (!parent.existsSync()) parent.createSync(recursive: true);
          } catch (_) {
            return -1;
          }
        }
        final h = _nextFileHandle++;
        _files[h] = s;
        return h;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halFileRead = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _files[h];
        if (s == null || s.mode != 0) return -1;
        final buf = s.readBuf;
        if (buf == null) return -1;
        final remain = buf.length - s.readOffset;
        if (remain <= 0) return 0;
        final n = remain < bufLen ? remain : bufLen;
        final mem = _memory!.view;
        for (var i = 0; i < n; i++) {
          mem[bufPtr + i] = buf[s.readOffset + i];
        }
        s.readOffset += n;
        return n;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halFileWrite = WasmFunction(
      (int h, int bufPtr, int bufLen) {
        final s = _files[h];
        if (s == null || s.mode == 0) return -1;
        if (bufLen <= 0) return 0;
        final mem = _memory!.view;
        for (var i = 0; i < bufLen; i++) {
          s.writeBuf.add(mem[bufPtr + i]);
        }
        return bufLen;
      },
      params: [ValueTy.i32, ValueTy.i32, ValueTy.i32],
      results: [ValueTy.i32],
    );
    final halFileClose = WasmFunction.voidReturn(
      (int h) {
        final s = _files.remove(h);
        if (s == null) return;
        if (s.mode == 1) {
          try {
            File(s.path).writeAsBytesSync(s.writeBuf);
          } catch (_) {}
        } else if (s.mode == 2) {
          try {
            File(s.path).writeAsBytesSync(s.writeBuf,
                mode: FileMode.append);
          } catch (_) {}
        }
      },
      params: [ValueTy.i32],
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

    final allImports = [
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
      // i18n
      WasmImport('hal', 'i18n_get', halI18nGet),
      // Messages
      WasmImport('hal', 'msg_available', halMsgAvailable),
      WasmImport('hal', 'msg_recv', halMsgRecv),
      WasmImport('hal', 'msg_send', halMsgSend),
      // File (host filesystem, no sandbox — see geogram_wasm_hal.h)
      WasmImport('hal', 'file_open', halFileOpen),
      WasmImport('hal', 'file_read', halFileRead),
      WasmImport('hal', 'file_write', halFileWrite),
      WasmImport('hal', 'file_close', halFileClose),
      // HTTP (stubs)
      WasmImport('hal', 'http_request', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32, ValueTy.i32], -1)),
      WasmImport('hal', 'http_poll', stubI32([ValueTy.i32], -1)),
      WasmImport('hal', 'http_read_response', stubI32([ValueTy.i32, ValueTy.i32, ValueTy.i32], 0)),
      WasmImport('hal', 'http_status', stubI32([ValueTy.i32], -1)),
      WasmImport('hal', 'http_free', stubVoid([ValueTy.i32])),
      // Process (host subprocess, no sandbox — see geogram_wasm_hal.h)
      WasmImport('hal', 'process_exec', halProcessExec),
      WasmImport('hal', 'process_poll', halProcessPoll),
      WasmImport('hal', 'process_exit_code', halProcessExitCode),
      WasmImport('hal', 'process_read_stdout', halProcessReadStdout),
      WasmImport('hal', 'process_read_stderr', halProcessReadStderr),
      WasmImport('hal', 'process_free', halProcessFree),
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
      // GPS lat/lon — backed by the host's cached last-known fix
      // (see setLastLocation). Returned as int32 scaled by 1e7 per
      // Section 12 of wapp-interfaces.md. INT32_MIN means "no fix".
      WasmImport('hal', 'sensor_gps_lat', WasmFunction(
        () => _lastLat == null ? -2147483648 : (_lastLat! * 1e7).round(),
        params: [], results: [ValueTy.i32],
      )),
      WasmImport('hal', 'sensor_gps_lon', WasmFunction(
        () => _lastLon == null ? -2147483648 : (_lastLon! * 1e7).round(),
        params: [], results: [ValueTy.i32],
      )),
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
      // Events (real — backed by WappEventBroker)
      WasmImport('hal', 'event_subscribe', halEventSubscribe),
      WasmImport('hal', 'event_unsubscribe', halEventUnsubscribe),
      WasmImport('hal', 'event_publish', halEventPublish),
      WasmImport('hal', 'event_available', halEventAvailable),
      WasmImport('hal', 'event_recv', halEventRecv),
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
    ];

    // Add imports one by one, skipping any the module doesn't declare.
    // wasm_run throws if we provide an import the module doesn't need.
    for (final imp in allImports) {
      try {
        builder.addImports([imp]);
      } catch (_) {
        // Module doesn't use this import — skip it
      }
    }

    _instance = await builder.build();
    _memory = _instance!.exports['memory'] as WasmMemory?;
    _loaded = true;
  }

  void init() { _instance?.getFunction('module_init')?.call([]); }
  void tick() { _instance?.getFunction('module_tick')?.call([]); }
  void handleEvent() { _instance?.getFunction('module_handle_event')?.call([]); }
  void destroy() { _instance?.getFunction('module_destroy')?.call([]); }

  /// Whether this engine's wasm exports `module_run_tests`. True for a
  /// tests.wasm built via the SDK's `make tests` target.
  bool get hasTests => _instance?.getFunction('module_run_tests') != null;

  /// Invoke the test runner. Wapps emit one `tests.case` outbox
  /// message per case plus a final `tests.complete`; drain via
  /// [drainOutbox] right after this call returns. No-op when the
  /// module does not export `module_run_tests`.
  void runTests() {
    final fn = _instance?.getFunction('module_run_tests');
    if (fn != null) fn.call([]);
  }

  int get tickIntervalMs {
    final fn = _instance?.getFunction('module_tick_interval_ms');
    if (fn == null) return 5000;
    return (fn.call([]).first as int?) ?? 5000;
  }

  void dispose() {
    if (_loaded) { destroy(); _loaded = false; }
    // Tear down any subprocesses the wapp left running. Mirrors
    // hal_process_free per handle but tolerant of failure since
    // dispose runs in best-effort cleanup.
    for (final s in _procs.values) {
      s.stdoutSub?.cancel();
      s.stderrSub?.cancel();
      if (s.exitCode == null) {
        try { s.proc?.kill(); } catch (_) {}
      }
    }
    _procs.clear();
    // Flush any open write/append files. Reads can be dropped — no
    // visible side effects.
    for (final s in _files.values) {
      if (s.mode == 1) {
        try { File(s.path).writeAsBytesSync(s.writeBuf); } catch (_) {}
      } else if (s.mode == 2) {
        try {
          File(s.path).writeAsBytesSync(s.writeBuf, mode: FileMode.append);
        } catch (_) {}
      }
    }
    _files.clear();
    _byId.remove(engineId);
    WappEventBroker.instance.unregisterEngine(engineId);
    _stopwatch.stop();
  }

  /// Direct handle on the outbox for the widget broker's headless
  /// provider path. Ordinary callers should use [drainOutbox] instead,
  /// which also clears the list.
  List<String> peekOutbox() => List<String>.unmodifiable(_outbox);
}
