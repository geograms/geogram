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
import 'dart:typed_data';

import '../models/monitored_task.dart';
import 'profile_storage.dart';
import 'task_monitor_service.dart';
import 'wapp_compiler_backend_web.dart'
    if (dart.library.io) 'wapp_compiler_backend_io.dart';

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

// ── Service singleton ───────────────────────────────────────────────

class WappCompilerService {
  WappCompilerService._();
  static final WappCompilerService instance = WappCompilerService._();

  /// The active compiler backend. Resolved via a conditional import
  /// factory: desktop gets the native wasi-sdk backend, web gets a
  /// stub that always returns "not supported". A future Phase 2b
  /// can swap in an in-wasm clang backend here transparently.
  final CompilerBackend backend = makeCompilerBackend();

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
