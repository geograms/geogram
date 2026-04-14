/*
 * WappCompilerService — compiles a C source string into a wapp
 * `app.wasm` byte array.
 *
 * Design: a thin singleton in front of a `CompilerBackend`
 * abstraction. Today only the native backend is wired
 * (`NativeWasiSdkBackend`), which shells out to
 * `$HOME/wasi-sdk/bin/clang` via `Process.run`. This is explicitly a
 * Phase 2a interim — it requires a developer wasi-sdk install and
 * fails on any other machine.
 *
 * Phase 2b will add an `InWasmClangBackend` that loads a bundled
 * wasm-clang binary from the App Creator wapp's own package
 * (`media/compilers/cpp.wasm`) and runs it under a custom WASI host.
 * When that lands, the [WappCompilerService] constructor picks
 * between the two backends at runtime: prefer the in-wasm one if
 * the wapp ships a compiler, otherwise fall back to native for
 * developers.
 *
 * Wapps should always call through `WappCompilerService.instance` —
 * the backend swap is invisible to callers.
 */

import 'dart:async';
import 'dart:io'
    show Directory, File, Platform, Process, ProcessResult;
import 'dart:typed_data';

import '../models/monitored_task.dart';
import 'profile_storage.dart';
import 'task_monitor_service.dart';

/// Outcome of a single compile run.
class CompileResult {
  /// True iff the compiler produced non-empty wasm bytes and exited 0.
  final bool ok;

  /// Compiled wapp bytes on success, null on failure.
  final Uint8List? wasmBytes;

  /// Captured stdout / stderr. Shown in the App Creator log view.
  final String stdout;
  final String stderr;
  final int exitCode;
  final int durationMs;

  /// Short human-readable error message on failure. Safe to put in a
  /// notification title.
  final String? error;

  const CompileResult({
    required this.ok,
    this.wasmBytes,
    this.stdout = '',
    this.stderr = '',
    this.exitCode = 0,
    this.durationMs = 0,
    this.error,
  });

  factory CompileResult.failure(
    String message, {
    String stdout = '',
    String stderr = '',
    int exitCode = 1,
    int durationMs = 0,
  }) =>
      CompileResult(
        ok: false,
        stdout: stdout,
        stderr: stderr,
        exitCode: exitCode,
        durationMs: durationMs,
        error: message,
      );
}

/// Abstract compiler backend. Every new compiler path (native,
/// in-wasm, remote) plugs in here.
abstract class CompilerBackend {
  String get name;

  /// True iff this backend can run on the current host right now.
  /// Checked before every compile so the service can pick the best
  /// available backend without the caller knowing.
  bool get isAvailable;

  /// Run the compiler. [pkg] is the calling wapp's package storage
  /// (so the backend can read a bundled `media/compilers/cpp.wasm`
  /// or similar). [workStorage] is the wapp's per-user work folder,
  /// used for temp files (`compile-tmp/`) and the cached output.
  Future<CompileResult> compile({
    required String source,
    required ProfileStorage pkg,
    required ProfileStorage workStorage,
  });
}

// ── Phase 2a: native wasi-sdk backend ───────────────────────────────
//
// TODO(phase-2b): replace this with `InWasmClangBackend` that reads
// `media/compilers/cpp.wasm` from [pkg] and runs it under a Dart-side
// WASI host (`WappWasiHost`). When both backends are present the
// service should prefer the in-wasm one, keeping native as a dev
// fallback.

class NativeWasiSdkBackend implements CompilerBackend {
  const NativeWasiSdkBackend();

  @override
  String get name => 'native-wasi-sdk';

  /// Path to the clang binary — looks at `$HOME/wasi-sdk/bin/clang`
  /// and returns null if not present.
  String? get _clangPath {
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    final clang = '$home/wasi-sdk/bin/clang';
    if (!File(clang).existsSync()) return null;
    return clang;
  }

  @override
  bool get isAvailable => _clangPath != null;

  @override
  Future<CompileResult> compile({
    required String source,
    required ProfileStorage pkg,
    required ProfileStorage workStorage,
  }) async {
    final clang = _clangPath;
    if (clang == null) {
      return CompileResult.failure(
        'wasi-sdk not installed at \$HOME/wasi-sdk. This is the '
        'Phase 2a interim compiler; Phase 2b will bundle wasm-clang '
        'inside the app-creator wapp so this dev-machine dependency '
        'goes away.',
      );
    }

    final halDir = _findHalDir();
    if (halDir == null) {
      return CompileResult.failure(
        'geogram_wasm_hal.h not found — walked up from '
        '${Directory.current.path} looking for wapps/hal/ and '
        'nothing matched. Launch geogram from the repo root (or a '
        'subdirectory of it) so the header is reachable.',
      );
    }

    // Write the source into the wapp's work dir under compile-tmp/.
    // FilesystemProfileStorage backs both writeString and
    // getAbsolutePath with real on-disk paths, so we can then hand
    // those paths to Process.run.
    await workStorage.createDirectory('compile-tmp');
    await workStorage.writeString('compile-tmp/source.c', source);
    final srcAbs = workStorage.getAbsolutePath('compile-tmp/source.c');
    final outAbs = workStorage.getAbsolutePath('compile-tmp/output.wasm');

    final args = <String>[
      '--target=wasm32-wasi',
      '-O2',
      '-flto',
      '-I$halDir',
      '-Wall',
      '-Wextra',
      '-Werror',
      '-fno-exceptions',
      '-DNDEBUG',
      '-Wl,--no-entry',
      '-Wl,--export=module_init',
      '-Wl,--export=module_tick',
      '-Wl,--export=module_handle_event',
      '-Wl,--export=module_destroy',
      '-Wl,--export=module_tick_interval_ms',
      '-Wl,--strip-all',
      '-nostartfiles',
      '-o',
      outAbs,
      srcAbs,
    ];

    final sw = Stopwatch()..start();
    ProcessResult result;
    try {
      result = await Process.run(clang, args);
    } catch (e) {
      sw.stop();
      return CompileResult.failure(
        'clang invocation threw: $e',
        durationMs: sw.elapsedMilliseconds,
      );
    }
    sw.stop();

    final stdout = (result.stdout is String) ? result.stdout as String : '';
    final stderr = (result.stderr is String) ? result.stderr as String : '';

    if (result.exitCode != 0) {
      return CompileResult(
        ok: false,
        stdout: stdout,
        stderr: stderr,
        exitCode: result.exitCode,
        durationMs: sw.elapsedMilliseconds,
        error: 'clang exited with ${result.exitCode}',
      );
    }

    final bytes = await workStorage.readBytes('compile-tmp/output.wasm');
    if (bytes == null || bytes.isEmpty) {
      return CompileResult.failure(
        'clang exited 0 but output.wasm is empty',
        stdout: stdout,
        stderr: stderr,
        durationMs: sw.elapsedMilliseconds,
      );
    }
    return CompileResult(
      ok: true,
      wasmBytes: bytes,
      stdout: stdout,
      stderr: stderr,
      exitCode: 0,
      durationMs: sw.elapsedMilliseconds,
    );
  }

  /// Walk upward from the current directory looking for
  /// `wapps/hal/geogram_wasm_hal.h`. The launcher uses the same
  /// pattern (main.dart _scanArchiveBody) — this is a known
  /// geogram convention, not a new one.
  String? _findHalDir() {
    final cwd = Directory.current.path;
    final candidates = [
      '$cwd/wapps/hal',
      '$cwd/../wapps/hal',
      '$cwd/../../wapps/hal',
      '$cwd/../../../wapps/hal',
    ];
    for (final c in candidates) {
      if (File('$c/geogram_wasm_hal.h').existsSync()) return c;
    }
    return null;
  }
}

// ── Service singleton ───────────────────────────────────────────────

class WappCompilerService {
  WappCompilerService._();
  static final WappCompilerService instance = WappCompilerService._();

  /// The active compiler backend. For now always native; Phase 2b
  /// will pick between native and in-wasm based on what's available.
  final CompilerBackend backend = const NativeWasiSdkBackend();

  /// Run the compiler. Wraps the whole call in a `MonitoredTask` so
  /// it appears in the tasks wapp alongside wapp tick loops. Never
  /// throws — failures come back as `CompileResult.failure`.
  Future<CompileResult> compile({
    required String source,
    required ProfileStorage pkg,
    required ProfileStorage workStorage,
  }) async {
    final monitor = TaskMonitorService.instance;
    const taskId = 'compiler.compile';
    // Re-register so duration numbers reset between runs.
    monitor.unregister(taskId);
    monitor.register(MonitoredTask(
      id: taskId,
      name: 'Compile wapp source',
      description: 'Backend: ${backend.name}',
      serviceName: 'compiler',
      priority: TaskPriority.normal,
      type: TaskType.oneshot,
    ));
    monitor.reportStart(taskId);
    try {
      final result = await backend.compile(
        source: source,
        pkg: pkg,
        workStorage: workStorage,
      );
      if (result.ok) {
        monitor.reportSuccess(taskId);
      } else {
        monitor.reportFailure(taskId, result.error ?? 'compile failed');
      }
      return result;
    } catch (e) {
      monitor.reportFailure(taskId, e);
      return CompileResult.failure(e.toString());
    }
  }
}
