/*
 * Web compiler backend — returns a backend that's always
 * unavailable, so the App Creator's Compile button surfaces a clean
 * "not supported in the browser" error instead of trying to shell
 * out to wasi-sdk.
 *
 * A future phase could compile via a remote build service OR load
 * wasm-clang as a browser-side WASM module. Out of scope for now.
 */

import 'profile_storage.dart';
import 'wapp_compiler_service.dart';

CompilerBackend makeCompilerBackend() => const _WebStubBackend();

class _WebStubBackend implements CompilerBackend {
  const _WebStubBackend();

  @override
  String get name => 'web-stub';

  @override
  bool get isAvailable => false;

  @override
  Future<CompileResult> compile({
    required String source,
    required ProfileStorage pkg,
    required ProfileStorage workStorage,
  }) async {
    return CompileResult.failure(
      'C compilation is not available in the browser. Use the '
      'desktop build of geogram to compile wapps, or install '
      'a pre-compiled wapp from the store.',
    );
  }
}
