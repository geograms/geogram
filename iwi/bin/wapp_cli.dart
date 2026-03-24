/// Geogram Wapp CLI — runs a WASM wapp interactively from the terminal.
///
/// Usage: dart run bin/wapp_cli.dart <path/to/app.wasm>
///
/// Loads the module via libwasm_bridge, starts the tick loop,
/// and bridges stdin/stdout as the CLI renderer.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ── FFI typedefs ─────────────────────────────────────────────────────

typedef _CreateNative = Pointer<Void> Function();
typedef _Create = Pointer<Void> Function();

typedef _SendNative = Void Function(Pointer<Void>, Pointer<Utf8>);
typedef _Send = void Function(Pointer<Void>, Pointer<Utf8>);

typedef _ReceiveNative = Pointer<Utf8> Function(Pointer<Void>, Double);
typedef _Receive = Pointer<Utf8> Function(Pointer<Void>, double);

typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _Destroy = void Function(Pointer<Void>);

// ── Bridge wrapper ───────────────────────────────────────────────────

class WasmBridge {
  final _Create _create;
  final _Send _send;
  final _Receive _receive;
  final _Destroy _destroy;
  late final Pointer<Void> _client;

  WasmBridge(DynamicLibrary lib)
      : _create = lib.lookupFunction<_CreateNative, _Create>(
            'wasm_json_client_create'),
        _send = lib.lookupFunction<_SendNative, _Send>(
            'wasm_json_client_send'),
        _receive = lib.lookupFunction<_ReceiveNative, _Receive>(
            'wasm_json_client_receive'),
        _destroy = lib.lookupFunction<_DestroyNative, _Destroy>(
            'wasm_json_client_destroy') {
    _client = _create();
  }

  void send(Map<String, dynamic> json) {
    final str = jsonEncode(json);
    final ptr = str.toNativeUtf8();
    _send(_client, ptr);
    malloc.free(ptr);
  }

  /// Receive next event, blocking up to [timeout] seconds.
  /// Returns null if nothing available.
  Map<String, dynamic>? receive({double timeout = 0.05}) {
    final ptr = _receive(_client, timeout);
    if (ptr == nullptr) return null;
    final str = ptr.toDartString();
    if (str.isEmpty) return null;
    try {
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Drain all pending events (non-blocking).
  List<Map<String, dynamic>> drain() {
    final events = <Map<String, dynamic>>[];
    while (true) {
      final e = receive(timeout: 0.001);
      if (e == null) break;
      events.add(e);
    }
    return events;
  }

  void destroy() => _destroy(_client);
}

// ── Library loader ───────────────────────────────────────────────────

DynamicLibrary loadBridgeLibrary(String scriptDir) {
  // Platform-specific library name
  final libName = Platform.isWindows
      ? 'wasm_bridge.dll'
      : Platform.isMacOS
          ? 'libwasm_bridge.dylib'
          : 'libwasm_bridge.so';

  final candidates = [
    // Relative to repo root (most common for dev)
    '$scriptDir/../../wasm_bridge/target/release/$libName',
    '$scriptDir/../../wasm_bridge/target/debug/$libName',
    // Next to the script
    '$scriptDir/$libName',
    // System paths
    libName,
    '/usr/lib/$libName',
    '/usr/local/lib/$libName',
  ];

  for (final path in candidates) {
    try {
      return DynamicLibrary.open(path);
    } catch (_) {
      continue;
    }
  }

  stderr.writeln('Error: Could not find $libName');
  stderr.writeln('Build it with: cd wasm_bridge && cargo build --release');
  stderr.writeln('Searched: ${candidates.join(', ')}');
  exit(1);
}

// ── ANSI helpers ─────────────────────────────────────────────────────

const _reset = '\x1B[0m';
const _bold = '\x1B[1m';
const _dim = '\x1B[2m';
const _green = '\x1B[32m';
const _red = '\x1B[31m';
const _yellow = '\x1B[33m';
const _cyan = '\x1B[36m';
const _grey = '\x1B[90m';

String _colorForLevel(String level) => switch (level) {
      'cmd' => _green,
      'err' || 'error' => _red,
      'info' => _cyan,
      'warning' || 'warn' => _yellow,
      _ => _reset,
    };

// ── Main ─────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run bin/wapp_cli.dart <wapp-dir-or-wasm>');
    stderr.writeln('       launch-cli.sh <wapp-name>');
    exit(1);
  }

  // Resolve wasm path
  var wasmPath = args[0];
  if (FileSystemEntity.isDirectorySync(wasmPath)) {
    wasmPath = '$wasmPath/app.wasm';
  }
  if (!File(wasmPath).existsSync()) {
    stderr.writeln('Error: $wasmPath not found');
    exit(1);
  }
  wasmPath = File(wasmPath).absolute.path;

  // Read manifest for display info
  final manifestFile =
      File('${File(wasmPath).parent.path}/manifest.json');
  String appName = 'Wapp';
  String moduleId = 'app';
  int tickMs = 500;
  if (manifestFile.existsSync()) {
    try {
      final mf = jsonDecode(manifestFile.readAsStringSync())
          as Map<String, dynamic>;
      appName = (mf['description'] as String?) ?? appName;
      moduleId = (mf['id'] as String?) ?? moduleId;
      tickMs = (mf['tick_interval_ms'] as int?) ?? tickMs;
    } catch (_) {}
  }

  // Find script directory for library resolution
  final scriptDir = File(Platform.script.toFilePath()).parent.path;
  final lib = loadBridgeLibrary(scriptDir);
  final bridge = WasmBridge(lib);

  // Storage dir
  final storageDir = '${Directory.systemTemp.path}/geogram_cli/$moduleId';
  Directory(storageDir).createSync(recursive: true);

  // Banner
  stdout.writeln('$_bold$_cyan$appName$_reset');
  stdout.writeln('${_dim}Module: $moduleId$_reset');
  stdout.writeln('${_dim}WASM:   $wasmPath$_reset');
  stdout.writeln('${_dim}Type "help" for commands, Ctrl+C to quit.$_reset');
  stdout.writeln();

  // Load module
  bridge.send({
    '@type': 'loadModule',
    'path': wasmPath,
    'id': moduleId,
    'storageDir': storageDir,
  });

  // Wait for moduleLoaded or error
  var loaded = false;
  for (var i = 0; i < 50; i++) {
    final event = bridge.receive(timeout: 0.1);
    if (event == null) continue;
    final type = event['@type'] as String? ?? '';
    if (type == 'moduleLoaded') {
      loaded = true;
      break;
    } else if (type == 'error') {
      stderr.writeln(
          '${_red}Load error: ${event['message']}$_reset');
      bridge.destroy();
      exit(1);
    }
    // Print any init messages
    _handleEvent(event);
  }

  if (!loaded) {
    stderr.writeln('${_red}Timeout waiting for module to load.$_reset');
    bridge.destroy();
    exit(1);
  }

  // Drain init messages (module_init output)
  for (final e in bridge.drain()) {
    _handleEvent(e);
  }

  // Set up tick timer
  Timer.periodic(Duration(milliseconds: tickMs), (_) {
    bridge.send({'@type': 'tickModule', 'id': moduleId});
    for (final e in bridge.drain()) {
      _handleEvent(e);
    }
  });

  // Set up signal handler for clean exit
  ProcessSignal.sigint.watch().listen((_) {
    stdout.writeln('\n${_dim}Shutting down...$_reset');
    bridge.send({'@type': 'unloadModule', 'id': moduleId});
    bridge.drain(); // flush
    bridge.destroy();
    exit(0);
  });

  // Interactive stdin loop
  stdout.write('${_green}\$ $_reset');
  final stdinLines = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  await for (final line in stdinLines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      stdout.write('${_green}\$ $_reset');
      continue;
    }

    // Send command to the wapp module.
    // The bridge's sendMessage calls val["data"].to_string() on the JSON
    // value, so we pass data as a nested object — its to_string() yields
    // the JSON the wapp expects.
    bridge.send({
      '@type': 'sendMessage',
      'moduleId': moduleId,
      'data': {'command': trimmed},
    });

    // Give the module time to process and collect output
    await Future.delayed(const Duration(milliseconds: 50));
    for (final e in bridge.drain()) {
      _handleEvent(e);
    }

    stdout.write('${_green}\$ $_reset');
  }

  // EOF on stdin
  bridge.send({'@type': 'unloadModule', 'id': moduleId});
  bridge.drain();
  bridge.destroy();
}

/// Handle an event from the WASM bridge.
void _handleEvent(Map<String, dynamic> event) {
  final type = event['@type'] as String? ?? '';

  switch (type) {
    case 'moduleMessage':
      _handleModuleMessage(event);
    case 'moduleLog':
      final level = event['level'] as int? ?? 0;
      final msg = event['message'] as String? ?? '';
      // Only show warnings and errors by default; debug/info are noise
      if (level >= 2) {
        final prefix = const ['DBG', 'INF', 'WRN', 'ERR'][level.clamp(0, 3)];
        final color = [_grey, _cyan, _yellow, _red][level.clamp(0, 3)];
        stderr.writeln('$color[$prefix]$_reset $msg');
      }
    case 'ok':
      break; // Silent ack
    case 'error':
      stderr.writeln(
          '${_red}Error: ${event['message']}$_reset');
  }
}

/// Handle a moduleMessage — the wapp's hal_msg_send output.
/// The terminal wapp sends JSON like:
///   {"type":"ui.append","target":"output-list","item":{"text":"...","level":"..."}}
void _handleModuleMessage(Map<String, dynamic> event) {
  final dataStr = event['data'] as String? ?? '';
  Map<String, dynamic>? data;
  try {
    data = jsonDecode(dataStr) as Map<String, dynamic>;
  } catch (_) {
    // Plain text fallback
    stdout.writeln(dataStr);
    return;
  }

  final msgType = data['type'] as String? ?? '';

  if (msgType == 'ui.append') {
    final item = data['item'] as Map<String, dynamic>? ?? {};
    final text = item['text'] as String? ?? '';
    final level = item['level'] as String? ?? 'out';
    final color = _colorForLevel(level);
    stdout.writeln('$color$text$_reset');
  } else if (msgType == 'ui.toast') {
    final msg = data['message'] as String? ?? '';
    final level = data['level'] as String? ?? 'info';
    final color = _colorForLevel(level);
    stdout.writeln('$color$_bold$msg$_reset');
  } else if (msgType == 'ui.field') {
    final target = data['target'] as String? ?? '';
    final value = data['value'] ?? '';
    stdout.writeln('$_cyan$target$_reset = $value');
  } else {
    // Unknown message type — dump it
    stdout.writeln('${_grey}$dataStr$_reset');
  }
}
