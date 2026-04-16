/*
 * Native (dart:io) compiler backend.
 *
 * Compiled into iwi only when `dart.library.io` is available. The
 * matching web stub lives in `wapp_compiler_backend_web.dart` and
 * always returns an `isAvailable == false` backend so the App
 * Creator's Compile button can surface a clean "not supported on
 * web" message instead of silently doing nothing.
 */

import 'dart:async';
import 'dart:io'
    show Directory, File, Platform, Process, ProcessResult;

import 'profile_storage.dart';
import 'wapp_compiler_service.dart';

CompilerBackend makeCompilerBackend() => const NativeWasiSdkBackend();

class NativeWasiSdkBackend implements CompilerBackend {
  const NativeWasiSdkBackend();

  @override
  String get name => 'native-wasi-sdk';

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
