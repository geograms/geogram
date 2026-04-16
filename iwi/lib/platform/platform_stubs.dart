/*
 * Platform abstraction — web stubs.
 *
 * This file is selected by `platform.dart` on every target that does
 * NOT have `dart.library.io` (i.e. Flutter web). Every function here
 * has a no-op / default implementation so the rest of the codebase
 * can call through without knowing which platform it's running on.
 *
 * The native equivalent lives in `platform_io.dart` and uses
 * Platform/Process/File/Directory. Keep the signatures in sync.
 */

/// The user's preferred locale. On web we fall back to English;
/// callers override via [PreferencesService.localePreference] anyway.
String currentLocale() => 'en';

/// Home directory path. Null on web — callers must gate filesystem
/// paths with a `kIsWeb` check or use [homeDir] == null to branch.
String? homeDir() => null;

/// Fire a desktop system notification. No-op on web: the browser
/// has its own Notification API but gating it behind permission
/// prompts is out of scope for this abstraction.
Future<void> showSystemNotification({
  required String title,
  String? body,
  bool error = false,
}) async {
  // no-op
}

/// True when the current platform supports spawning subprocesses
/// (Linux / macOS / Windows). Web and mobile return false so
/// callers can show a graceful "not supported here" message.
bool get supportsSubprocesses => false;

/// Run a subprocess and capture its stdout/stderr. Web returns an
/// empty-stdout / non-zero-exit stub so callers that ignore the
/// result still behave, and compile fails early for anyone who
/// relies on real output.
Future<PlatformProcessResult> runSubprocess(
    String executable, List<String> arguments,
    {String? workingDirectory}) async {
  return const PlatformProcessResult(
      exitCode: -1, stdout: '', stderr: 'not supported on web');
}

/// Path separator. `/` on web; `Platform.pathSeparator` on native.
String get pathSeparator => '/';

/// Current working directory. On web there isn't one, so we return
/// an empty string; callers that use this for relative filesystem
/// lookups should gate on [kIsWeb] and skip that path entirely.
String currentDirectory() => '';

/// Read an arbitrary file's contents as bytes. Used for preview
/// fetches (e.g. showing the user-picked SVG). Returns null on web
/// — file access there flows through the browser file picker which
/// already hands back an `XFile`.
Future<List<int>?> readArbitraryFileBytes(String path) async => null;

/// Sync variant of [readArbitraryFileBytes]. Used by code that runs
/// inside `build()` and can't await (e.g. the store card SVG
/// resolver). Returns null on web.
List<int>? readArbitraryFileBytesSync(String path) => null;

/// Whether a file exists at an absolute path. Only used from native
/// code that resolves wapp svg sidecars; always false on web.
bool arbitraryFileExistsSync(String path) => false;

/// Open a directory in the OS file manager. No-op on web.
Future<void> openInFileManager(String path) async {}

/// Wide-open capture of a subprocess result in a platform-neutral
/// way. Mirrors the fields we actually read from `ProcessResult` —
/// keeps the abstraction tiny.
class PlatformProcessResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  const PlatformProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}
