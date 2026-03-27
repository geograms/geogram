/// Geogram Wapp CLI — runs a WASM wapp interactively from the terminal.
///
/// Usage: dart run bin/wapp_cli.dart <path/to/wapp-dir>
///
/// Loads the module via libwasm_bridge, starts the tick loop,
/// and bridges stdin/stdout as the CLI renderer.
///
/// GeoUI screens from .ui.json files are presented as navigable
/// subcommands per the renderer behaviour matrix in wapps.md:
///   screen → subcommand (cd/ls), group → section,
///   field → get/set, action → verb.

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
  final libName = Platform.isWindows
      ? 'wasm_bridge.dll'
      : Platform.isMacOS
          ? 'libwasm_bridge.dylib'
          : 'libwasm_bridge.so';

  final candidates = [
    '$scriptDir/../../wasm_bridge/target/release/$libName',
    '$scriptDir/../../wasm_bridge/target/debug/$libName',
    '$scriptDir/$libName',
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
const _blue = '\x1B[34m';

String _colorForLevel(String level) => switch (level) {
      'cmd' => _green,
      'err' || 'error' => _red,
      'info' => _cyan,
      'warning' || 'warn' => _yellow,
      _ => _reset,
    };

// ── GeoUI screen model (parsed from .ui.json) ───────────────────────

class _UiScreen {
  final String name;
  final String? tip;
  final List<_UiGroup> groups;
  final List<_UiAction> actions;

  _UiScreen(this.name, this.tip, this.groups, this.actions);
}

class _UiGroup {
  final String name;
  final String? tip;
  final List<_UiField> fields;

  _UiGroup(this.name, this.tip, this.fields);
}

class _UiField {
  final String name;
  final String label;
  final String type;
  final String? tip;
  final dynamic defaultValue;
  final double? min, max, step;
  final List<String> options; // for enum
  final Map<String, String> optionLabels;

  _UiField({
    required this.name,
    required this.label,
    required this.type,
    this.tip,
    this.defaultValue,
    this.min,
    this.max,
    this.step,
    this.options = const [],
    this.optionLabels = const {},
  });
}

class _UiAction {
  final String name;
  final String label;
  final String style;
  final String? tip;

  _UiAction(this.name, this.label, this.style, this.tip);
}

/// Parse all .ui.json screens from a wapp directory.
List<_UiScreen> _loadScreens(String wappDir) {
  final screens = <_UiScreen>[];
  final screensDir = Directory('$wappDir/screens');
  if (!screensDir.existsSync()) return screens;

  for (final file in screensDir.listSync()) {
    if (file is! File || !file.path.endsWith('.ui.json')) continue;
    try {
      final json = jsonDecode(file.readAsStringSync()) as List;
      for (final block in json) {
        final b = block as Map<String, dynamic>;
        final keyword = b[r'$'] as String? ?? '';
        if (keyword == 'screen') {
          screens.add(_parseScreen(b));
        } else if (keyword == 'app') {
          // Extract screens from app children
          final children = b['children'] as List? ?? [];
          for (final child in children) {
            final c = child as Map<String, dynamic>;
            if (c[r'$'] == 'screen') {
              screens.add(_parseScreen(c));
            }
          }
          // Also look for included screens
          for (final child in children) {
            final c = child as Map<String, dynamic>;
            if (c[r'$'] == 'include') {
              final includePath = c['name'] as String? ?? '';
              if (includePath.isNotEmpty) {
                final incFile = File('$wappDir/$includePath');
                if (incFile.existsSync()) {
                  try {
                    final incJson =
                        jsonDecode(incFile.readAsStringSync()) as List;
                    for (final ib in incJson) {
                      final ic = ib as Map<String, dynamic>;
                      if (ic[r'$'] == 'screen') {
                        screens.add(_parseScreen(ic));
                      }
                    }
                  } catch (_) {}
                }
              }
            }
          }
        }
      }
    } catch (_) {}
  }
  // Deduplicate by name (includes may repeat screens)
  final seen = <String>{};
  screens.retainWhere((s) => seen.add(s.name.toLowerCase()));

  return screens;
}

_UiScreen _parseScreen(Map<String, dynamic> b) {
  final name = b['name'] as String? ?? 'Unnamed';
  final tip = b['tip'] as String?;
  final children = b['children'] as List? ?? [];
  final groups = <_UiGroup>[];
  final actions = <_UiAction>[];

  for (final child in children) {
    final c = child as Map<String, dynamic>;
    final kw = c[r'$'] as String? ?? '';
    if (kw == 'group') {
      groups.add(_parseGroup(c));
    } else if (kw == 'action') {
      actions.add(_parseAction(c));
    }
  }

  return _UiScreen(name, tip, groups, actions);
}

_UiGroup _parseGroup(Map<String, dynamic> b) {
  final name = b['name'] as String? ?? '';
  final tip = b['tip'] as String?;
  final children = b['children'] as List? ?? [];
  final fields = <_UiField>[];

  for (final child in children) {
    final c = child as Map<String, dynamic>;
    if (c[r'$'] == 'field') {
      fields.add(_parseField(c));
    }
  }

  return _UiGroup(name, tip, fields);
}

_UiField _parseField(Map<String, dynamic> b) {
  final name = b['name'] as String? ?? '';
  final label = b['label'] as String? ?? name;
  final type = b[r'$type'] as String? ?? 'string';
  final tip = b['tip'] as String?;
  final options = <String>[];
  final optionLabels = <String, String>{};

  for (final child in (b['children'] as List? ?? [])) {
    final c = child as Map<String, dynamic>;
    if (c[r'$'] == 'option') {
      final optName = c['name'] as String? ?? '';
      options.add(optName);
      optionLabels[optName] = c['label'] as String? ?? optName;
    }
  }

  return _UiField(
    name: name,
    label: label,
    type: type,
    tip: tip,
    defaultValue: b['default'],
    min: (b['min'] as num?)?.toDouble(),
    max: (b['max'] as num?)?.toDouble(),
    step: (b['step'] as num?)?.toDouble(),
    options: options,
    optionLabels: optionLabels,
  );
}

_UiAction _parseAction(Map<String, dynamic> b) {
  return _UiAction(
    b['name'] as String? ?? '',
    b['label'] as String? ?? '',
    b['style'] as String? ?? 'secondary',
    b['tip'] as String?,
  );
}

// ── CLI screen renderer ──────────────────────────────────────────────

/// State for the CLI UI navigation.
class _CliUiState {
  final List<_UiScreen> screens;
  final Map<String, dynamic> fieldValues = {};
  _UiScreen? currentScreen;

  _CliUiState(this.screens) {
    // Load defaults
    for (final screen in screens) {
      for (final group in screen.groups) {
        for (final field in group.fields) {
          if (field.defaultValue != null) {
            fieldValues[field.name] = field.defaultValue;
          }
        }
      }
    }
  }

  /// Find screen by name (case-insensitive).
  _UiScreen? findScreen(String name) {
    final lower = name.toLowerCase();
    for (final s in screens) {
      if (s.name.toLowerCase() == lower) return s;
    }
    return null;
  }

  /// Find field by name in current screen.
  _UiField? findField(String name) {
    if (currentScreen == null) return null;
    for (final group in currentScreen!.groups) {
      for (final field in group.fields) {
        if (field.name == name) return field;
      }
    }
    return null;
  }

  /// Print `ls` for the root (list screens).
  void listRoot() {
    stdout.writeln('${_bold}Screens:$_reset');
    for (final s in screens) {
      final tip = s.tip != null ? '  $_dim${s.tip}$_reset' : '';
      stdout.writeln('  $_blue${s.name.toLowerCase()}/$_reset$tip');
    }
  }

  /// Print `ls` for the current screen (list groups, fields, actions).
  void listScreen() {
    final screen = currentScreen!;
    if (screen.tip != null) {
      stdout.writeln('$_dim${screen.tip}$_reset');
      stdout.writeln();
    }
    for (var i = 0; i < screen.groups.length; i++) {
      final group = screen.groups[i];
      stdout.writeln('$_bold${group.name}$_reset  $_dim${group.tip ?? ''}$_reset');
      for (final field in group.fields) {
        final val = fieldValues[field.name] ?? field.defaultValue ?? '';
        final typeHint = _fieldTypeHint(field);
        stdout.writeln(
            '  $_cyan${field.name}$_reset = $val  $typeHint');
      }
      if (i < screen.groups.length - 1) stdout.writeln();
    }
    if (screen.actions.isNotEmpty) {
      if (screen.groups.isNotEmpty) stdout.writeln();
      stdout.writeln('${_bold}Actions:$_reset');
      for (final action in screen.actions) {
        final tip = action.tip != null ? '  $_dim${action.tip}$_reset' : '';
        stdout.writeln('  $_green${action.name}$_reset$tip');
      }
    }
  }

  String _fieldTypeHint(_UiField field) {
    switch (field.type) {
      case 'bool':
        return '$_dim(true|false)$_reset';
      case 'int':
      case 'float':
        final parts = <String>[];
        if (field.min != null) parts.add('min=${_fmtNum(field.min!)}');
        if (field.max != null) parts.add('max=${_fmtNum(field.max!)}');
        if (field.step != null) parts.add('step=${_fmtNum(field.step!)}');
        return parts.isEmpty ? '' : '$_dim(${parts.join(', ')})$_reset';
      case 'enum':
        final opts = field.options
            .map((o) => field.optionLabels[o] ?? o)
            .join('|');
        return '$_dim[$opts]$_reset';
      default:
        return '';
    }
  }

  String _fmtNum(double n) => n == n.roundToDouble() ? n.toInt().toString() : n.toString();

  /// Handle `get <field>` — print current value.
  void getField(String name) {
    final field = findField(name);
    if (field == null) {
      stderr.writeln('${_red}Unknown field: $name$_reset');
      return;
    }
    final val = fieldValues[field.name] ?? field.defaultValue ?? '';
    stdout.writeln('${field.label}: $val');
    if (field.tip != null) stdout.writeln('$_dim${field.tip}$_reset');
  }

  /// Handle `set <field> <value>` — update field value.
  void setField(String name, String rawValue) {
    final field = findField(name);
    if (field == null) {
      stderr.writeln('${_red}Unknown field: $name$_reset');
      return;
    }

    dynamic parsed;
    switch (field.type) {
      case 'bool':
        parsed = rawValue == 'true' || rawValue == '1';
      case 'int':
        parsed = int.tryParse(rawValue);
        if (parsed == null) {
          stderr.writeln('${_red}Invalid integer: $rawValue$_reset');
          return;
        }
        if (field.min != null && parsed < field.min!) {
          stderr.writeln('${_yellow}Clamped to min ${_fmtNum(field.min!)}$_reset');
          parsed = field.min!.toInt();
        }
        if (field.max != null && parsed > field.max!) {
          stderr.writeln('${_yellow}Clamped to max ${_fmtNum(field.max!)}$_reset');
          parsed = field.max!.toInt();
        }
      case 'float':
        parsed = double.tryParse(rawValue);
        if (parsed == null) {
          stderr.writeln('${_red}Invalid number: $rawValue$_reset');
          return;
        }
        if (field.min != null && parsed < field.min!) parsed = field.min!;
        if (field.max != null && parsed > field.max!) parsed = field.max!;
      case 'enum':
        if (!field.options.contains(rawValue)) {
          stderr.writeln(
              '${_red}Invalid option. Choose: ${field.options.join(', ')}$_reset');
          return;
        }
        parsed = rawValue;
      default:
        parsed = rawValue;
    }

    fieldValues[field.name] = parsed;
    stdout.writeln('${field.name} = $parsed');
  }
}

// ── Main ─────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run bin/wapp_cli.dart <wapp-dir-or-wasm>');
    stderr.writeln('       launch-cli.sh <wapp-name>');
    exit(1);
  }

  // Resolve wapp directory and wasm path
  var wappDir = args[0];
  var wasmPath = wappDir;
  if (FileSystemEntity.isDirectorySync(wappDir)) {
    wasmPath = '$wappDir/app.wasm';
  } else {
    wappDir = File(wasmPath).parent.path;
  }
  if (!File(wasmPath).existsSync()) {
    stderr.writeln('Error: $wasmPath not found');
    exit(1);
  }
  wasmPath = File(wasmPath).absolute.path;
  wappDir = Directory(wappDir).absolute.path;

  // Read manifest
  final manifestFile = File('$wappDir/manifest.json');
  String appName = 'Wapp';
  String moduleId = 'app';
  int tickMs = 500;
  if (manifestFile.existsSync()) {
    try {
      final mf =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      appName = (mf['description'] as String?) ?? appName;
      moduleId = (mf['id'] as String?) ?? moduleId;
      tickMs = (mf['tick_interval_ms'] as int?) ?? tickMs;
    } catch (_) {}
  }

  // Load GeoUI screens
  final screens = _loadScreens(wappDir);
  final uiState = _CliUiState(screens);

  // Load bridge
  final scriptDir = File(Platform.script.toFilePath()).parent.path;
  final lib = loadBridgeLibrary(scriptDir);
  final bridge = WasmBridge(lib);

  // Set globals for renderer-side message handling
  _bridge = bridge;
  _moduleId = moduleId;

  // Storage dir
  final storageDir = '${Directory.systemTemp.path}/geogram_cli/$moduleId';
  Directory(storageDir).createSync(recursive: true);

  // Banner
  stdout.writeln('$_bold$_cyan$appName$_reset');
  stdout.writeln('${_dim}Module: $moduleId$_reset');
  if (screens.isNotEmpty) {
    final screenNames =
        screens.map((s) => s.name.toLowerCase()).join(', ');
    stdout.writeln(
        '${_dim}Screens: $screenNames  (use cd/ls to navigate)$_reset');
  }
  stdout.writeln(
      '${_dim}Type "help" for commands, "search <address>" to find locations.$_reset');
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
      stderr.writeln('${_red}Load error: ${event['message']}$_reset');
      bridge.destroy();
      exit(1);
    }
    _handleEvent(event);
  }

  if (!loaded) {
    stderr.writeln('${_red}Timeout waiting for module to load.$_reset');
    bridge.destroy();
    exit(1);
  }

  // Drain init messages
  for (final e in bridge.drain()) {
    _handleEvent(e);
  }

  // Tick timer
  Timer.periodic(Duration(milliseconds: tickMs), (_) {
    bridge.send({'@type': 'tickModule', 'id': moduleId});
    for (final e in bridge.drain()) {
      _handleEvent(e);
    }
  });

  // Interactive loop — use raw mode for Tab completion when on a terminal,
  // fall back to line mode when stdin is piped.
  if (!stdin.hasTerminal) {
    // Piped input — simple line mode, no completion
    _printPrompt(uiState);
    final stdinLines =
        stdin.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in stdinLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        _printPrompt(uiState);
        continue;
      }
      if (_handleSearchSelection(trimmed, bridge, moduleId)) {
        _printPrompt(uiState);
        continue;
      }
      if (_handleUiCommand(trimmed, uiState, bridge, moduleId)) {
        _printPrompt(uiState);
        continue;
      }
      bridge.send({
        '@type': 'sendMessage',
        'moduleId': moduleId,
        'data': {'command': trimmed},
      });
      await Future.delayed(const Duration(milliseconds: 50));
      for (final e in bridge.drain()) {
        _handleEvent(e);
      }
      if (trimmed == 'help' && uiState.currentScreen == null) {
        _printRendererHelp();
      }
      _printPrompt(uiState);
    }
    bridge.send({'@type': 'unloadModule', 'id': moduleId});
    bridge.drain();
    bridge.destroy();
    return;
  }

  // Terminal — raw mode with Tab completion
  final lineEditor = _LineEditor(uiState);
  stdin.echoMode = false;
  stdin.lineMode = false;

  _printPrompt(uiState);

  final sub = stdin.listen((bytes) async {
    for (var i = 0; i < bytes.length; i++) {
      final byte = bytes[i];

      // ── Tab completion ──
      if (byte == 9) {
        lineEditor.complete();
        continue;
      }

      // ── Enter ──
      if (byte == 10 || byte == 13) {
        stdout.writeln();
        final line = lineEditor.submit();
        if (line.isNotEmpty) {
          if (_handleSearchSelection(line, bridge, moduleId)) {
            _printPrompt(uiState);
            continue;
          }
          if (_handleUiCommand(line, uiState, bridge, moduleId)) {
            _printPrompt(uiState);
            continue;
          }
          bridge.send({
            '@type': 'sendMessage',
            'moduleId': moduleId,
            'data': {'command': line},
          });
          await Future.delayed(const Duration(milliseconds: 50));
          for (final e in bridge.drain()) {
            _handleEvent(e);
          }
          if (line == 'help' && uiState.currentScreen == null) {
            _printRendererHelp();
          }
        }
        _printPrompt(uiState);
        continue;
      }

      // ── Backspace ──
      if (byte == 127 || byte == 8) {
        lineEditor.backspace();
        continue;
      }

      // ── Ctrl+C ──
      if (byte == 3) {
        stdout.writeln('\n${_dim}Shutting down...$_reset');
        bridge.send({'@type': 'unloadModule', 'id': moduleId});
        bridge.drain();
        bridge.destroy();
        stdin.echoMode = true;
        stdin.lineMode = true;
        exit(0);
      }

      // ── Ctrl+D (EOF) ──
      if (byte == 4) {
        stdout.writeln();
        bridge.send({'@type': 'unloadModule', 'id': moduleId});
        bridge.drain();
        bridge.destroy();
        stdin.echoMode = true;
        stdin.lineMode = true;
        exit(0);
      }

      // ── Ctrl+U (clear line) ──
      if (byte == 21) {
        lineEditor.clearLine();
        continue;
      }

      // ── Escape sequences (arrows) ──
      if (byte == 27 && i + 2 < bytes.length && bytes[i + 1] == 91) {
        final arrow = bytes[i + 2];
        i += 2;
        if (arrow == 65) {
          lineEditor.historyUp();
        } else if (arrow == 66) {
          lineEditor.historyDown();
        }
        // Left/Right ignored for simplicity
        continue;
      }

      // ── Normal character ──
      if (byte >= 32 && byte < 127) {
        lineEditor.insert(String.fromCharCode(byte));
      }
    }
  });

  // Keep alive until stdin closes
  await sub.asFuture<void>().catchError((_) {});
  bridge.send({'@type': 'unloadModule', 'id': moduleId});
  bridge.drain();
  bridge.destroy();
}

// ── Line editor with Tab completion and history ──────────────────────

class _LineEditor {
  final _CliUiState _ui;
  final _buf = StringBuffer();
  final _history = <String>[];
  int _historyIndex = -1;
  String _savedLine = '';

  _LineEditor(this._ui);

  String get current => _buf.toString();

  void insert(String ch) {
    _buf.write(ch);
    stdout.write(ch);
  }

  void backspace() {
    if (_buf.isEmpty) return;
    final s = _buf.toString();
    _buf.clear();
    _buf.write(s.substring(0, s.length - 1));
    stdout.write('\b \b');
  }

  void clearLine() {
    final len = _buf.length;
    _buf.clear();
    stdout.write('\b' * len + ' ' * len + '\b' * len);
  }

  void _replaceLine(String newLine) {
    final oldLen = _buf.length;
    _buf.clear();
    _buf.write(newLine);
    stdout.write('\b' * oldLen + ' ' * oldLen + '\b' * oldLen + newLine);
  }

  String submit() {
    final line = _buf.toString().trim();
    _buf.clear();
    if (line.isNotEmpty) {
      _history.add(line);
    }
    _historyIndex = -1;
    return line;
  }

  void historyUp() {
    if (_history.isEmpty) return;
    if (_historyIndex < 0) {
      _savedLine = _buf.toString();
      _historyIndex = _history.length - 1;
    } else if (_historyIndex > 0) {
      _historyIndex--;
    } else {
      return;
    }
    _replaceLine(_history[_historyIndex]);
  }

  void historyDown() {
    if (_historyIndex < 0) return;
    if (_historyIndex < _history.length - 1) {
      _historyIndex++;
      _replaceLine(_history[_historyIndex]);
    } else {
      _historyIndex = -1;
      _replaceLine(_savedLine);
    }
  }

  /// Tab completion.
  void complete() {
    final line = _buf.toString();
    final candidates = _completions(line);
    if (candidates.isEmpty) return;

    if (candidates.length == 1) {
      // Single match — complete it
      final completion = candidates.first;
      final toAdd = completion.substring(_completionPrefix(line).length);
      _buf.write(toAdd);
      // Add trailing space unless it ends with /
      if (!completion.endsWith('/')) {
        _buf.write(' ');
        stdout.write('$toAdd ');
      } else {
        stdout.write(toAdd);
      }
      return;
    }

    // Multiple matches — find common prefix
    var common = candidates.first;
    for (final c in candidates.skip(1)) {
      while (!c.startsWith(common)) {
        common = common.substring(0, common.length - 1);
      }
    }
    final prefix = _completionPrefix(line);
    if (common.length > prefix.length) {
      final toAdd = common.substring(prefix.length);
      _buf.write(toAdd);
      stdout.write(toAdd);
    } else {
      // Show all candidates
      stdout.writeln();
      for (final c in candidates) {
        stdout.write('  $_cyan$c$_reset');
      }
      stdout.writeln();
      _printPromptRaw();
      stdout.write(_buf.toString());
    }
  }

  void _printPromptRaw() {
    if (_ui.currentScreen != null) {
      stdout.write(
          '$_blue${_ui.currentScreen!.name.toLowerCase()}$_reset $_green\$ $_reset');
    } else {
      stdout.write('${_green}\$ $_reset');
    }
  }

  /// Get the word being completed (the last token).
  String _completionPrefix(String line) {
    final parts = line.split(RegExp(r'\s+'));
    return parts.isEmpty ? '' : parts.last;
  }

  /// Generate completion candidates for the current line.
  List<String> _completions(String line) {
    final trimmed = line.trimLeft();
    final parts = trimmed.split(RegExp(r'\s+'));
    final cmd = parts.isNotEmpty ? parts[0].toLowerCase() : '';
    final prefix = _completionPrefix(line).toLowerCase();

    // ── Completing the command itself ──
    if (parts.length <= 1) {
      final all = _allCommands();
      return all.where((c) => c.toLowerCase().startsWith(prefix)).toList()
        ..sort();
    }

    // ── Completing arguments ──
    switch (cmd) {
      case 'cd':
        // Complete screen names
        if (_ui.currentScreen != null) {
          return ['..']
              .where((c) => c.startsWith(prefix))
              .toList();
        }
        final names = _ui.screens
            .map((s) => '${s.name.toLowerCase()}/')
            .where((n) => n.startsWith(prefix))
            .toList();
        return names..sort();

      case 'get':
        if (_ui.currentScreen == null) return [];
        return _fieldNames()
            .where((f) => f.startsWith(prefix))
            .toList()
          ..sort();

      case 'set':
        if (_ui.currentScreen == null) return [];
        if (parts.length == 2) {
          // Completing field name
          return _fieldNames()
              .where((f) => f.startsWith(prefix))
              .toList()
            ..sort();
        }
        if (parts.length == 3) {
          // Completing field value — only for enums and bools
          final fieldName = parts[1];
          final field = _ui.findField(fieldName);
          if (field == null) return [];
          if (field.type == 'enum') {
            return field.options
                .where((o) => o.toLowerCase().startsWith(prefix))
                .toList();
          }
          if (field.type == 'bool') {
            return ['true', 'false']
                .where((v) => v.startsWith(prefix))
                .toList();
          }
        }
        return [];

      default:
        return [];
    }
  }

  List<String> _allCommands() {
    if (_ui.currentScreen != null) {
      // Inside a screen
      return [
        'ls',
        'get',
        'set',
        'help',
        'cd',
        'search',
        ..._ui.currentScreen!.actions.map((a) => a.name),
      ];
    }
    // At root — wapp commands + navigation
    return [
      'help', 'clear', 'echo', 'pwd', 'cd', 'ls', 'search',
      'cat', 'touch', 'write', 'rm', 'mkdir', 'stat',
      'kv.get', 'kv.set', 'kv.del', 'kv.list',
      'date', 'uptime', 'platform', 'heap',
      'fetch', 'ping',
    ];
  }

  List<String> _fieldNames() {
    if (_ui.currentScreen == null) return [];
    return _ui.currentScreen!.groups
        .expand((g) => g.fields.map((f) => f.name))
        .toList();
  }
}

/// Print renderer-provided commands (appended after module help at root).
void _printRendererHelp() {
  stdout.writeln();
  stdout.writeln('${_bold}Navigation:$_reset');
  stdout.writeln(
      '  ${_cyan}search$_reset <query>  Search for a location');
}

void _printPrompt(_CliUiState uiState) {
  if (uiState.currentScreen != null) {
    stdout.write(
        '$_blue${uiState.currentScreen!.name.toLowerCase()}$_reset $_green\$ $_reset');
  } else {
    stdout.write('${_green}\$ $_reset');
  }
}

/// Handle CLI UI navigation commands. Returns true if handled locally.
bool _handleUiCommand(
    String input, _CliUiState ui, WasmBridge bridge, String moduleId) {
  final parts = input.split(RegExp(r'\s+'));
  final cmd = parts[0].toLowerCase();
  final arg = parts.length > 1 ? parts[1] : '';
  final rest = parts.length > 2 ? parts.sublist(2).join(' ') : '';

  switch (cmd) {
    // ── Navigation ──
    case 'cd':
      if (arg == '..' || arg.isEmpty) {
        if (ui.currentScreen != null) {
          ui.currentScreen = null;
          return true;
        }
        // Not in a screen — let the wapp handle cd
        return false;
      }
      // Try to enter a screen
      final screen = ui.findScreen(arg);
      if (screen != null) {
        ui.currentScreen = screen;
        return true;
      }
      // Not a screen name — let the wapp handle it
      if (ui.currentScreen != null) {
        stderr.writeln("${_red}No such screen: $arg$_reset");
        stderr.writeln("${_dim}Use 'cd ..' to go back$_reset");
        return true;
      }
      return false;

    case 'ls':
      if (ui.currentScreen != null) {
        ui.listScreen();
        return true;
      }
      // At root: show screens then forward to wapp for its own listing
      if (ui.screens.isNotEmpty) {
        ui.listRoot();
        stdout.writeln();
      }
      return false;

    // ── Field access (only inside a screen) ──
    case 'get':
      if (ui.currentScreen != null && arg.isNotEmpty) {
        ui.getField(arg);
        return true;
      }
      return false;

    case 'set':
      if (ui.currentScreen != null && arg.isNotEmpty && rest.isNotEmpty) {
        ui.setField(arg, rest);
        return true;
      }
      if (ui.currentScreen != null && arg.isNotEmpty) {
        stderr.writeln('${_red}Usage: set <field> <value>$_reset');
        return true;
      }
      return false;

    // ── Actions (only inside a screen) ──
    case 'save' || 'cancel':
      if (ui.currentScreen != null) {
        final action = ui.currentScreen!.actions
            .where((a) => a.name == cmd)
            .firstOrNull;
        if (action != null) {
          if (cmd == 'save') {
            // Send field values to the wapp via the action's body fields
            bridge.send({
              '@type': 'sendMessage',
              'moduleId': moduleId,
              'data': {
                'type': 'action',
                'action': cmd,
                'fields': ui.fieldValues,
              },
            });
            stdout.writeln('${_green}Settings saved.$_reset');
          }
          ui.currentScreen = null; // go back
          return true;
        }
      }
      return false;

    // ── Help override when inside a screen ──
    case 'help':
      if (ui.currentScreen != null) {
        stdout.writeln('${_bold}Screen: ${ui.currentScreen!.name}$_reset');
        stdout.writeln();
        stdout.writeln('  ${_cyan}ls$_reset           List fields and actions');
        stdout.writeln(
            '  ${_cyan}get$_reset <field>   Show field value and info');
        stdout.writeln(
            '  ${_cyan}set$_reset <field> <value>  Change a field');
        for (final action in ui.currentScreen!.actions) {
          stdout.writeln(
              '  ${_cyan}${action.name}$_reset         ${action.tip ?? action.label}');
        }
        stdout.writeln('  ${_cyan}cd ..$_reset        Go back');
        stdout.writeln();
        stdout.writeln('${_bold}Navigation:$_reset');
        stdout.writeln(
            '  ${_cyan}search$_reset <query>  Search for a location');
        return true;
      }
      // At root: forward help to module, then append renderer commands
      return false;

    case 'search':
      // Geocoding search — works at any level, sends goto to module
      if (arg.isEmpty) {
        stderr.writeln('${_red}Usage: search <address or coordinates>$_reset');
        return true;
      }
      final query = parts.sublist(1).join(' ');
      _performSearch(query, bridge, moduleId);
      return true;

    default:
      // Check if the command matches an action name in the current screen
      if (ui.currentScreen != null) {
        final action = ui.currentScreen!.actions
            .where((a) => a.name.toLowerCase() == cmd)
            .firstOrNull;
        if (action != null) {
          bridge.send({
            '@type': 'sendMessage',
            'moduleId': moduleId,
            'data': {
              'type': 'action',
              'action': action.name,
              'fields': ui.fieldValues,
            },
          });
          stdout.writeln('$_green${action.label}$_reset');
          return true;
        }
      }
      return false;
  }
}

/// Geocoding search via Nominatim — results sorted by distance, user picks one.
void _performSearch(
    String query, WasmBridge bridge, String moduleId) {
  // Check for raw coordinates
  final coordMatch =
      RegExp(r'^(-?\d+\.?\d*)\s*[,\s]\s*(-?\d+\.?\d*)$').firstMatch(query);
  if (coordMatch != null) {
    final lat = double.tryParse(coordMatch.group(1)!);
    final lon = double.tryParse(coordMatch.group(2)!);
    if (lat != null && lon != null) {
      stdout.writeln('$_cyan$lat, $lon$_reset');
      bridge.send({
        '@type': 'sendMessage',
        'moduleId': moduleId,
        'data': {'command': 'goto $lat $lon'},
      });
      bridge.drain();
      return;
    }
  }

  stdout.writeln('${_dim}Searching...$_reset');
  try {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': query,
      'format': 'json',
      'limit': '8',
    });
    final request = HttpClient()
      ..userAgent = 'Geogram/1.0';
    final req = request.getUrl(uri);
    req.then((r) => r.close()).then((resp) {
      resp.transform(utf8.decoder).join().then((body) {
        request.close();
        final results = (jsonDecode(body) as List).map((r) {
          final lat = double.tryParse(r['lat']?.toString() ?? '') ?? 0.0;
          final lon = double.tryParse(r['lon']?.toString() ?? '') ?? 0.0;
          final name = r['display_name'] as String? ?? '';
          return (name: name, lat: lat, lon: lon);
        }).toList();

        if (results.isEmpty) {
          stdout.writeln('${_yellow}No results found.$_reset');
          return;
        }

        stdout.writeln('${_bold}Results:$_reset');
        for (var i = 0; i < results.length; i++) {
          final r = results[i];
          final display = r.name.length > 70
              ? '${r.name.substring(0, 70)}...'
              : r.name;
          stdout.writeln(
              '  $_cyan${i + 1}$_reset  $display  $_dim${r.lat.toStringAsFixed(5)}, ${r.lon.toStringAsFixed(5)}$_reset');
        }
        stdout.writeln(
            '${_dim}Type a number to go there, or press Enter to cancel.$_reset');

        // Read selection from stdin (next line)
        // Since we're in raw mode, we can't easily do this synchronously.
        // Store results for the next input line.
        _pendingSearchResults = results
            .map((r) => _PendingResult(r.name, r.lat, r.lon))
            .toList();
      });
    });
  } catch (e) {
    stderr.writeln('${_red}Search failed: $e$_reset');
  }
}

class _PendingResult {
  final String name;
  final double lat, lon;
  _PendingResult(this.name, this.lat, this.lon);
}

List<_PendingResult>? _pendingSearchResults;

/// Check if input is a search result selection (number).
bool _handleSearchSelection(
    String input, WasmBridge bridge, String moduleId) {
  if (_pendingSearchResults == null) return false;
  final results = _pendingSearchResults!;
  _pendingSearchResults = null;

  final idx = int.tryParse(input.trim());
  if (idx == null || idx < 1 || idx > results.length) {
    stdout.writeln('${_dim}Search cancelled.$_reset');
    return true;
  }

  final r = results[idx - 1];
  stdout.writeln('$_green${r.name}$_reset');
  bridge.send({
    '@type': 'sendMessage',
    'moduleId': moduleId,
    'data': {'command': 'goto ${r.lat} ${r.lon}'},
  });
  // Give module time to respond
  Future.delayed(const Duration(milliseconds: 50), () {
    for (final e in bridge.drain()) {
      _handleEvent(e);
    }
  });
  return true;
}

// ── Globals for renderer-side message handling ───────────────────────

WasmBridge? _bridge;
String _moduleId = '';

// ── Event handlers ───────────────────────────────────────────────────

void _handleEvent(Map<String, dynamic> event) {
  final type = event['@type'] as String? ?? '';

  switch (type) {
    case 'moduleMessage':
      _handleModuleMessage(event);
    case 'moduleLog':
      final level = event['level'] as int? ?? 0;
      final msg = event['message'] as String? ?? '';
      if (level >= 2) {
        final prefix = const ['DBG', 'INF', 'WRN', 'ERR'][level.clamp(0, 3)];
        final color = [_grey, _cyan, _yellow, _red][level.clamp(0, 3)];
        stderr.writeln('$color[$prefix]$_reset $msg');
      }
    case 'ok':
      break;
    case 'error':
      stderr.writeln('${_red}Error: ${event['message']}$_reset');
  }
}

void _handleModuleMessage(Map<String, dynamic> event) {
  final dataStr = event['data'] as String? ?? '';
  Map<String, dynamic>? data;
  try {
    data = jsonDecode(dataStr) as Map<String, dynamic>;
  } catch (_) {
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
  } else if (msgType == 'wapp.fetch_index') {
    _handleFetchIndex(data);
  } else if (msgType == 'wapp.install') {
    _handleWappInstall(data);
  } else if (msgType == 'wapp.remove') {
    final name = data['name'] as String? ?? '';
    stdout.writeln('${_yellow}Wapp "$name" removed.$_reset');
  } else {
    stdout.writeln('${_grey}$dataStr$_reset');
  }
}

/// Handle wapp.fetch_index — read index.json from local path and send
/// the contents back to the module.
void _handleFetchIndex(Map<String, dynamic> data) {
  final source = data['source'] as String? ?? '';
  if (source.isEmpty) return;

  var path = source;
  if (!path.endsWith('.json')) {
    if (!path.endsWith('/')) path += '/';
    path += 'index.json';
  }

  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('${_red}Index not found: $path$_reset');
    return;
  }

  final contents = file.readAsStringSync();
  // Send the index data back to the module
  _bridge?.send({
    '@type': 'sendMessage',
    'moduleId': _moduleId,
    'data': {'type': 'wapp.index', 'data': jsonDecode(contents)},
  });
}

/// Handle wapp.install — copy .wapp file from source to a local
/// install directory.
void _handleWappInstall(Map<String, dynamic> data) {
  final source = data['source'] as String? ?? '';
  final file = data['file'] as String? ?? '';
  final name = data['name'] as String? ?? '';
  final version = data['version'] as String? ?? '';

  if (source.isEmpty || file.isEmpty) return;

  String srcPath;
  if (source.startsWith('http://') || source.startsWith('https://')) {
    // For URL sources, download the .wapp file
    var baseUrl = source;
    if (baseUrl.endsWith('.json')) {
      baseUrl = baseUrl.substring(0, baseUrl.lastIndexOf('/'));
    }
    if (!baseUrl.endsWith('/')) baseUrl += '/';
    final url = '$baseUrl$file';
    stdout.writeln('${_dim}Downloading $url...$_reset');
    try {
      final client = HttpClient()..userAgent = 'Geogram/1.0';
      final req = client.getUrl(Uri.parse(url));
      req.then((r) => r.close()).then((resp) {
        final installDir =
            '${Directory.systemTemp.path}/geogram_cli/wapps/$name';
        Directory(installDir).createSync(recursive: true);
        final destPath = '$installDir/$name-$version.wapp';
        final sink = File(destPath).openWrite();
        resp.pipe(sink).then((_) {
          client.close();
          stdout.writeln(
              '$_green$name v$version installed → $destPath$_reset');
        });
      });
    } catch (e) {
      stderr.writeln('${_red}Download failed: $e$_reset');
    }
    return;
  }

  // Local source — extract .wapp to apps dir
  var basePath = source;
  if (basePath.endsWith('.json')) {
    basePath = basePath.substring(0, basePath.lastIndexOf('/'));
  }
  if (!basePath.endsWith('/')) basePath += '/';
  srcPath = '$basePath$file';

  final srcFile = File(srcPath);
  if (!srcFile.existsSync()) {
    stderr.writeln('${_red}File not found: $srcPath$_reset');
    return;
  }

  final home = Platform.environment['HOME'] ?? '/tmp';
  final appsDir = '$home/.local/share/iwi/apps';
  final appDir = '$appsDir/$name';
  final dir = Directory(appDir);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);

  final result = Process.runSync('unzip', ['-o', '-q', srcPath, '-d', appDir]);
  if (result.exitCode != 0) {
    stderr.writeln('${_red}Extract failed: ${result.stderr}$_reset');
    return;
  }
  stdout.writeln('$_green$name v$version installed → $appDir$_reset');
}
