/*
 * Platform abstraction — native (dart:io) implementation.
 *
 * Selected by `platform.dart` on every target that exposes
 * `dart.library.io`: Linux / macOS / Windows desktop, plus mobile.
 * Web picks up `platform_stubs.dart` instead. Keep the public API
 * of this file byte-identical to the stubs file so the conditional
 * import is a drop-in.
 */

import 'dart:io';

import 'platform_stubs.dart' show PlatformProcessResult;

export 'platform_stubs.dart' show PlatformProcessResult;

String currentLocale() {
  try {
    final os = Platform.localeName;
    if (os.isNotEmpty) return os;
  } catch (_) {}
  return 'en';
}

String? homeDir() {
  try {
    return Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
  } catch (_) {
    return null;
  }
}

Future<void> showSystemNotification({
  required String title,
  String? body,
  bool error = false,
}) async {
  try {
    if (Platform.isLinux) {
      await Process.run('notify-send', [
        '--app-name=geogram',
        if (error) '--urgency=critical',
        title,
        if (body != null && body.isNotEmpty) body,
      ]);
    } else if (Platform.isMacOS) {
      final escaped = (body ?? '').replaceAll('"', '\\"');
      final titleEsc = title.replaceAll('"', '\\"');
      await Process.run('osascript', [
        '-e',
        'display notification "$escaped" with title "$titleEsc"',
      ]);
    }
    // Windows native balloon not implemented — use winrt toast later.
  } catch (_) {
    // Ignore — the in-app overlay is the source of truth anyway.
  }
}

bool get supportsSubprocesses => true;

Future<PlatformProcessResult> runSubprocess(
    String executable, List<String> arguments,
    {String? workingDirectory}) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    return PlatformProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout?.toString() ?? '',
      stderr: result.stderr?.toString() ?? '',
    );
  } catch (e) {
    return PlatformProcessResult(exitCode: -1, stdout: '', stderr: '$e');
  }
}

String get pathSeparator => Platform.pathSeparator;

String currentDirectory() {
  try {
    return Directory.current.path;
  } catch (_) {
    return '';
  }
}

Future<List<int>?> readArbitraryFileBytes(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    return await f.readAsBytes();
  } catch (_) {
    return null;
  }
}

List<int>? readArbitraryFileBytesSync(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    return f.readAsBytesSync();
  } catch (_) {
    return null;
  }
}

bool arbitraryFileExistsSync(String path) {
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}

Future<void> openInFileManager(String path) async {
  try {
    if (Platform.isLinux) {
      await Process.run('xdg-open', [path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [path]);
    }
  } catch (_) {
    // Best-effort — caller has no way to recover anyway.
  }
}
