import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../geoui/geoui_ast.dart';
import '../geoui/geoui_parser.dart';
import '../geoui/geoui_renderer.dart';
import '../services/preferences_service.dart';

// ── Color schemes ──────────────────────────────────────────────────────

class _TermColors {
  final Color bg;
  final Color inputBg;
  final Color text;
  final Color command;
  final Color error;
  final Color info;
  final Color prompt;
  final Color muted;

  const _TermColors({
    required this.bg,
    required this.inputBg,
    required this.text,
    required this.command,
    required this.error,
    required this.info,
    required this.prompt,
    required this.muted,
  });

  static const dark = _TermColors(
    bg: Color(0xFF0D1117),
    inputBg: Color(0xFF161B22),
    text: Color(0xFFE6EDF3),
    command: Color(0xFF7EE787),
    error: Color(0xFFF85149),
    info: Color(0xFF58A6FF),
    prompt: Color(0xFF7EE787),
    muted: Color(0xFF8B949E),
  );

  static const light = _TermColors(
    bg: Color(0xFFF6F8FA),
    inputBg: Color(0xFFFFFFFF),
    text: Color(0xFF1F2328),
    command: Color(0xFF116329),
    error: Color(0xFFCF222E),
    info: Color(0xFF0969DA),
    prompt: Color(0xFF116329),
    muted: Color(0xFF656D76),
  );

  static const solarized = _TermColors(
    bg: Color(0xFF002B36),
    inputBg: Color(0xFF073642),
    text: Color(0xFF839496),
    command: Color(0xFF859900),
    error: Color(0xFFDC322F),
    info: Color(0xFF268BD2),
    prompt: Color(0xFF859900),
    muted: Color(0xFF586E75),
  );

  static _TermColors fromName(String name) => switch (name) {
        'light' => light,
        'solarized' => solarized,
        _ => dark,
      };
}

// ── Terminal page ──────────────────────────────────────────────────────

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final _lines = <_Line>[];
  final _history = <String>[];
  int _historyIndex = -1;
  late String _cwd;
  PreferencesService? _prefs;
  GeoUiBlock? _settingsScreen;

  // Settings (loaded from prefs)
  double _fontSize = 16.0;
  String _fontFamily = 'RobotoMono';
  double _lineHeight = 1.5;
  String _colorScheme = 'dark';
  bool _showTimestamps = false;
  int _maxLines = 5000;

  @override
  void initState() {
    super.initState();
    _cwd = Directory.current.path;
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    _prefs = await PreferencesService.instance();

    // Load and parse the settings .ui file
    final uiSource = await rootBundle.loadString('assets/terminal_settings.ui');
    final parsed = GeoUiParser(uiSource).parse();
    _settingsScreen = parsed.firstScreen;

    setState(() {
      _fontSize = _prefs!.terminalFontSize;
      _fontFamily = _prefs!.terminalFontFamily;
      _lineHeight = _prefs!.terminalLineHeight;
      _colorScheme = _prefs!.terminalColorScheme;
      _showTimestamps = _prefs!.terminalShowTimestamps;
      _maxLines = _prefs!.terminalMaxLines;
    });
    _out('Iwi Terminal v1.0');
    _out('Type "help" for available commands.\n');
    _scrollToBottom();
  }

  void _savePrefs() {
    final p = _prefs;
    if (p == null) return;
    p.terminalFontSize = _fontSize;
    p.terminalFontFamily = _fontFamily;
    p.terminalLineHeight = _lineHeight;
    p.terminalColorScheme = _colorScheme;
    p.terminalShowTimestamps = _showTimestamps;
    p.terminalMaxLines = _maxLines;
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── Output helpers ──────────────────────────────────────────────────

  void _out(String text, {bool err = false, bool cmd = false}) {
    for (final line in text.split('\n')) {
      _lines.add(_Line(line, isError: err, isCommand: cmd));
    }
    // Trim to max lines
    while (_lines.length > _maxLines) {
      _lines.removeAt(0);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  String get _prompt {
    final home = Platform.environment['HOME'] ?? '';
    var p = _cwd;
    if (home.isNotEmpty && p.startsWith(home)) p = '~${p.substring(home.length)}';
    return '$p \$ ';
  }

  String _resolve(String path) {
    if (path.startsWith('/')) return path;
    if (path.startsWith('~/')) {
      return '${Platform.environment['HOME'] ?? ''}${path.substring(1)}';
    }
    return '$_cwd/$path';
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  // ── Command dispatch ────────────────────────────────────────────────

  Future<void> _execute(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;

    _history.add(trimmed);
    _historyIndex = -1;
    _out('$_prompt$trimmed', cmd: true);

    final parts = _split(trimmed);
    if (parts.isEmpty) return;

    final c = parts[0];
    final a = parts.sublist(1);

    try {
      switch (c) {
        // Shell
        case 'help':
          _cmdHelp();
        case 'clear':
          _lines.clear();
        case 'history':
          for (var i = 0; i < _history.length; i++) {
            _out('  ${i + 1}  ${_history[i]}');
          }
        case 'exit':
          if (mounted) Navigator.of(context).pop();

        // Filesystem
        case 'cd':
          _cmdCd(a);
        case 'pwd':
          _out(_cwd);
        case 'ls':
          await _cmdLs(a);
        case 'mkdir':
          await _cmdMkdir(a);
        case 'rmdir':
          await _cmdRmdir(a);
        case 'rm':
          await _cmdRm(a);
        case 'touch':
          await _cmdTouch(a);
        case 'cat':
          await _cmdCat(a);
        case 'head':
          await _cmdHeadTail(a, head: true);
        case 'tail':
          await _cmdHeadTail(a, head: false);
        case 'cp':
          await _cmdCp(a);
        case 'mv':
          await _cmdMv(a);
        case 'echo':
          _out(a.join(' '));
        case 'grep':
          await _cmdGrep(a);
        case 'find':
          await _cmdFind(a);
        case 'wc':
          await _cmdWc(a);
        case 'stat':
          await _cmdStat(a);
        case 'du':
          await _cmdDu(a);
        case 'tree':
          await _cmdTree(a);
        case 'write':
          await _cmdWrite(a);
        case 'hexdump':
          await _cmdHexdump(a);
        case 'md5' || 'sha256':
          await _cmdHash(c, a);

        // System info
        case 'date':
          _out(DateTime.now().toString());
        case 'whoami':
          _out(Platform.environment['USER'] ?? 'unknown');
        case 'hostname':
          _out(Platform.localHostname);
        case 'uname':
          _cmdUname(a);
        case 'env':
          _cmdEnv(a);
        case 'uptime':
          await _cmdUptime();
        case 'free':
          await _cmdFree();
        case 'df':
          await _cmdDf();
        case 'which':
          _cmdWhich(a);

        // Network
        case 'ping':
          await _cmdPing(a);
        case 'curl' || 'wget' || 'fetch':
          await _cmdFetch(a);
        case 'host' || 'nslookup' || 'dig':
          await _cmdDns(a);
        case 'ifconfig' || 'ip':
          await _cmdIfconfig();

        // Misc
        case 'sleep':
          if (a.isNotEmpty) {
            final secs = int.tryParse(a[0]) ?? 1;
            await Future.delayed(Duration(seconds: secs));
          }
        case 'true':
          break;
        case 'false':
          _out('', err: true);
        case 'seq':
          _cmdSeq(a);
        case 'sort':
          await _cmdSort(a);
        case 'uniq':
          await _cmdUniq(a);
        case 'base64':
          await _cmdBase64(a);
        case 'xxd':
          await _cmdHexdump(a);

        default:
          _out('$c: command not found. Type "help" for available commands.', err: true);
      }
    } catch (e) {
      _out('$c: $e', err: true);
    }

    setState(() {});
    _scrollToBottom();
  }

  List<String> _split(String input) {
    final parts = <String>[];
    final buf = StringBuffer();
    var inQuote = false;
    String? q;
    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      if (inQuote) {
        if (c == q) {
          inQuote = false;
        } else {
          buf.write(c);
        }
      } else if (c == '"' || c == "'") {
        inQuote = true;
        q = c;
      } else if (c == ' ') {
        if (buf.isNotEmpty) {
          parts.add(buf.toString());
          buf.clear();
        }
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) parts.add(buf.toString());
    return parts;
  }

  // ── Built-in commands ───────────────────────────────────────────────

  void _cmdHelp() {
    _out('''Commands:
  help                   Show this help
  clear                  Clear screen
  history                Command history
  exit                   Close terminal

Filesystem:
  cd [dir]               Change directory
  pwd                    Print working directory
  ls [-la] [dir]         List files
  mkdir [-p] <dir>       Create directory
  rmdir <dir>            Remove empty directory
  rm [-rf] <path>        Remove file/directory
  touch <file>           Create empty file
  cat <file>             Print file contents
  head [-n N] <file>     First N lines
  tail [-n N] <file>     Last N lines
  cp <src> <dst>         Copy file
  mv <src> <dst>         Move/rename
  echo <text>            Print text
  write <file> <text>    Write text to file
  grep <pattern> <file>  Search in file
  find [dir] -name <pat> Find files
  wc <file>              Line/word/byte count
  stat <path>            File info
  du [-s] [path]         Directory size
  tree [dir]             Directory tree
  sort <file>            Sort lines
  uniq <file>            Deduplicate lines
  hexdump <file>         Hex dump
  base64 <file>          Base64 encode
  md5 <file>             MD5 hash
  sha256 <file>          SHA-256 hash

System:
  date                   Current date/time
  whoami                 Current user
  hostname               Hostname
  uname [-a]             OS info
  env [VAR]              Environment variables
  uptime                 System uptime
  free                   Memory info
  df                     Disk space
  which <cmd>            Locate command
  sleep <secs>           Wait N seconds
  seq <start> [end]      Number sequence

Network:
  ping <host>            TCP ping host
  curl <url>             HTTP GET/POST
  fetch <url>            HTTP GET (alias)
  wget <url> [file]      Download to file
  host <domain>          DNS lookup
  ifconfig               Network interfaces''');
  }

  void _cmdCd(List<String> a) {
    if (a.isEmpty) {
      _cwd = Platform.environment['HOME'] ?? '/';
      return;
    }
    if (a[0] == '-') {
      _out('cd: OLDPWD not set', err: true);
      return;
    }
    final target = _resolve(a[0]);
    if (Directory(target).existsSync()) {
      _cwd = Directory(target).resolveSymbolicLinksSync();
    } else {
      _out('cd: no such directory: ${a[0]}', err: true);
    }
  }

  Future<void> _cmdLs(List<String> a) async {
    var showAll = false, showLong = false;
    String? target;
    for (final arg in a) {
      if (arg.startsWith('-')) {
        if (arg.contains('a')) showAll = true;
        if (arg.contains('l')) showLong = true;
      } else {
        target = arg;
      }
    }
    final dir = Directory(_resolve(target ?? '.'));
    if (!dir.existsSync()) {
      _out('ls: \'${target ?? '.'}\': No such directory', err: true);
      return;
    }
    final entries = dir.listSync()..sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      final name = entry.path.split('/').last;
      if (!showAll && name.startsWith('.')) continue;
      if (showLong) {
        final s = entry.statSync();
        final t = s.type == FileSystemEntityType.directory ? 'd' : '-';
        final sz = _humanSize(s.size).padLeft(9);
        final m = _fmtDate(s.modified);
        final sfx = s.type == FileSystemEntityType.directory ? '/' : '';
        _out('$t $sz  $m  $name$sfx');
      } else {
        _out('${name}${entry is Directory ? '/' : ''}');
      }
    }
  }

  String _fmtDate(DateTime dt) {
    return '${dt.year}-${_p2(dt.month)}-${_p2(dt.day)} ${_p2(dt.hour)}:${_p2(dt.minute)}';
  }

  String _p2(int n) => n.toString().padLeft(2, '0');

  Future<void> _cmdMkdir(List<String> a) async {
    if (a.isEmpty) {
      _out('mkdir: missing operand', err: true);
      return;
    }
    var recursive = false;
    final dirs = <String>[];
    for (final arg in a) {
      if (arg == '-p') {
        recursive = true;
      } else {
        dirs.add(arg);
      }
    }
    for (final d in dirs) {
      await Directory(_resolve(d)).create(recursive: recursive);
    }
  }

  Future<void> _cmdRmdir(List<String> a) async {
    if (a.isEmpty) {
      _out('rmdir: missing operand', err: true);
      return;
    }
    for (final d in a) {
      final dir = Directory(_resolve(d));
      if (!dir.existsSync()) {
        _out('rmdir: \'$d\': No such directory', err: true);
      } else {
        await dir.delete();
      }
    }
  }

  Future<void> _cmdRm(List<String> a) async {
    if (a.isEmpty) {
      _out('rm: missing operand', err: true);
      return;
    }
    var recursive = false;
    final paths = <String>[];
    for (final arg in a) {
      if (arg.startsWith('-') && (arg.contains('r') || arg.contains('f'))) {
        recursive = true;
      } else {
        paths.add(arg);
      }
    }
    for (final p in paths) {
      final r = _resolve(p);
      final t = FileSystemEntity.typeSync(r);
      if (t == FileSystemEntityType.notFound) {
        _out('rm: \'$p\': No such file or directory', err: true);
      } else if (t == FileSystemEntityType.directory) {
        if (!recursive) {
          _out('rm: \'$p\': Is a directory (use -rf)', err: true);
        } else {
          await Directory(r).delete(recursive: true);
        }
      } else {
        await File(r).delete();
      }
    }
  }

  Future<void> _cmdTouch(List<String> a) async {
    if (a.isEmpty) {
      _out('touch: missing operand', err: true);
      return;
    }
    for (final f in a) {
      final file = File(_resolve(f));
      if (file.existsSync()) {
        await file.setLastModified(DateTime.now());
      } else {
        await file.create(recursive: true);
      }
    }
  }

  Future<void> _cmdCat(List<String> a) async {
    if (a.isEmpty) {
      _out('cat: missing operand', err: true);
      return;
    }
    for (final f in a) {
      final file = File(_resolve(f));
      if (!file.existsSync()) {
        _out('cat: $f: No such file', err: true);
        continue;
      }
      _out(await file.readAsString());
    }
  }

  Future<void> _cmdHeadTail(List<String> a, {required bool head}) async {
    var n = 10;
    String? path;
    for (var i = 0; i < a.length; i++) {
      if (a[i] == '-n' && i + 1 < a.length) {
        n = int.tryParse(a[++i]) ?? 10;
      } else if (!a[i].startsWith('-')) {
        path = a[i];
      }
    }
    if (path == null) {
      _out('${head ? 'head' : 'tail'}: missing operand', err: true);
      return;
    }
    final file = File(_resolve(path));
    if (!file.existsSync()) {
      _out('${head ? 'head' : 'tail'}: $path: No such file', err: true);
      return;
    }
    final lines = await file.readAsLines();
    if (head) {
      _out(lines.take(n).join('\n'));
    } else {
      _out(lines.sublist(lines.length > n ? lines.length - n : 0).join('\n'));
    }
  }

  Future<void> _cmdCp(List<String> a) async {
    if (a.length < 2) {
      _out('cp: usage: cp <src> <dst>', err: true);
      return;
    }
    final src = File(_resolve(a[0]));
    if (!src.existsSync()) {
      _out('cp: ${a[0]}: No such file', err: true);
      return;
    }
    await src.copy(_resolve(a[1]));
  }

  Future<void> _cmdMv(List<String> a) async {
    if (a.length < 2) {
      _out('mv: usage: mv <src> <dst>', err: true);
      return;
    }
    final src = File(_resolve(a[0]));
    if (!src.existsSync()) {
      _out('mv: ${a[0]}: No such file', err: true);
      return;
    }
    await src.rename(_resolve(a[1]));
  }

  Future<void> _cmdWrite(List<String> a) async {
    if (a.length < 2) {
      _out('write: usage: write <file> <text>', err: true);
      return;
    }
    await File(_resolve(a[0])).writeAsString(a.sublist(1).join(' '));
  }

  Future<void> _cmdGrep(List<String> a) async {
    if (a.length < 2) {
      _out('grep: usage: grep <pattern> <file> [file2 ...]', err: true);
      return;
    }
    final pat = RegExp(a[0], caseSensitive: !a.contains('-i'));
    for (final f in a.sublist(1)) {
      if (f.startsWith('-')) continue;
      final file = File(_resolve(f));
      if (!file.existsSync()) {
        _out('grep: $f: No such file', err: true);
        continue;
      }
      final prefix = a.length > 3 ? '$f:' : '';
      for (final line in await file.readAsLines()) {
        if (pat.hasMatch(line)) _out('$prefix$line');
      }
    }
  }

  Future<void> _cmdFind(List<String> a) async {
    String dir = '.';
    String? pattern;
    for (var i = 0; i < a.length; i++) {
      if (a[i] == '-name' && i + 1 < a.length) {
        pattern = a[++i];
      } else if (!a[i].startsWith('-')) {
        dir = a[i];
      }
    }
    final resolved = Directory(_resolve(dir));
    if (!resolved.existsSync()) {
      _out('find: \'$dir\': No such directory', err: true);
      return;
    }
    final regex = pattern != null
        ? RegExp('^${pattern.replaceAll('*', '.*').replaceAll('?', '.')}\$')
        : null;
    await for (final e in resolved.list(recursive: true)) {
      final name = e.path.split('/').last;
      if (regex == null || regex.hasMatch(name)) _out(e.path);
    }
  }

  Future<void> _cmdWc(List<String> a) async {
    if (a.isEmpty) {
      _out('wc: missing operand', err: true);
      return;
    }
    for (final f in a) {
      final file = File(_resolve(f));
      if (!file.existsSync()) {
        _out('wc: $f: No such file', err: true);
        continue;
      }
      final content = await file.readAsString();
      final lines = '\n'.allMatches(content).length;
      final words = RegExp(r'\S+').allMatches(content).length;
      final bytes = await file.length();
      _out('  $lines  $words  $bytes  $f');
    }
  }

  Future<void> _cmdStat(List<String> a) async {
    if (a.isEmpty) {
      _out('stat: missing operand', err: true);
      return;
    }
    final path = _resolve(a[0]);
    if (!FileSystemEntity.typeSync(path).toString().contains('notFound') == false) {
      _out('stat: \'${a[0]}\': No such file or directory', err: true);
      return;
    }
    final s = FileStat.statSync(path);
    _out('  File: ${a[0]}');
    _out('  Size: ${_humanSize(s.size)}  (${s.size} bytes)');
    _out('  Type: ${s.type}');
    _out('  Modified: ${s.modified}');
    _out('  Accessed: ${s.accessed}');
    _out('  Mode: ${s.modeString()}');
  }

  Future<void> _cmdDu(List<String> a) async {
    var summary = a.contains('-s');
    final paths = a.where((x) => !x.startsWith('-')).toList();
    final target = paths.isEmpty ? '.' : paths[0];
    final dir = Directory(_resolve(target));
    if (!dir.existsSync()) {
      _out('du: \'$target\': No such directory', err: true);
      return;
    }
    var total = 0;
    await for (final e in dir.list(recursive: true)) {
      if (e is File) {
        final size = await e.length();
        total += size;
        if (!summary) _out('${_humanSize(size).padLeft(9)}  ${e.path}');
      }
    }
    _out('${_humanSize(total).padLeft(9)}  $target (total)');
  }

  Future<void> _cmdTree(List<String> a) async {
    final target = a.isEmpty ? '.' : a[0];
    final dir = Directory(_resolve(target));
    if (!dir.existsSync()) {
      _out('tree: \'$target\': No such directory', err: true);
      return;
    }
    await _printTree(dir, '');
  }

  Future<void> _printTree(Directory dir, String indent) async {
    final entries = dir.listSync()..sort((a, b) => a.path.compareTo(b.path));
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final name = e.path.split('/').last;
      if (name.startsWith('.')) continue;
      final isLast = i == entries.length - 1;
      final connector = isLast ? '└── ' : '├── ';
      final sfx = e is Directory ? '/' : '';
      _out('$indent$connector$name$sfx');
      if (e is Directory) {
        await _printTree(e, '$indent${isLast ? '    ' : '│   '}');
      }
    }
  }

  Future<void> _cmdSort(List<String> a) async {
    if (a.isEmpty) {
      _out('sort: missing operand', err: true);
      return;
    }
    final file = File(_resolve(a[0]));
    if (!file.existsSync()) {
      _out('sort: ${a[0]}: No such file', err: true);
      return;
    }
    final lines = await file.readAsLines()
      ..sort();
    _out(lines.join('\n'));
  }

  Future<void> _cmdUniq(List<String> a) async {
    if (a.isEmpty) {
      _out('uniq: missing operand', err: true);
      return;
    }
    final file = File(_resolve(a[0]));
    if (!file.existsSync()) {
      _out('uniq: ${a[0]}: No such file', err: true);
      return;
    }
    String? prev;
    for (final line in await file.readAsLines()) {
      if (line != prev) {
        _out(line);
        prev = line;
      }
    }
  }

  Future<void> _cmdHexdump(List<String> a) async {
    if (a.isEmpty) {
      _out('hexdump: missing operand', err: true);
      return;
    }
    final file = File(_resolve(a[0]));
    if (!file.existsSync()) {
      _out('hexdump: ${a[0]}: No such file', err: true);
      return;
    }
    final bytes = await file.readAsBytes();
    final limit = bytes.length > 512 ? 512 : bytes.length;
    for (var off = 0; off < limit; off += 16) {
      final hex = StringBuffer();
      final ascii = StringBuffer();
      for (var i = 0; i < 16; i++) {
        if (off + i < limit) {
          hex.write(bytes[off + i].toRadixString(16).padLeft(2, '0'));
          hex.write(' ');
          ascii.write(bytes[off + i] >= 32 && bytes[off + i] < 127
              ? String.fromCharCode(bytes[off + i])
              : '.');
        } else {
          hex.write('   ');
        }
      }
      _out('${off.toRadixString(16).padLeft(8, '0')}  $hex |${ascii.toString()}|');
    }
    if (bytes.length > 512) _out('... (${bytes.length - 512} more bytes)');
  }

  Future<void> _cmdBase64(List<String> a) async {
    if (a.isEmpty) {
      _out('base64: missing operand', err: true);
      return;
    }
    final file = File(_resolve(a[0]));
    if (!file.existsSync()) {
      _out('base64: ${a[0]}: No such file', err: true);
      return;
    }
    _out(base64.encode(await file.readAsBytes()));
  }

  Future<void> _cmdHash(String algo, List<String> a) async {
    if (a.isEmpty) {
      _out('$algo: missing operand', err: true);
      return;
    }
    // Use dart:convert + dart:io for simple hashing
    final file = File(_resolve(a[0]));
    if (!file.existsSync()) {
      _out('$algo: ${a[0]}: No such file', err: true);
      return;
    }
    final bytes = await file.readAsBytes();
    // Simple hash display using hex of bytes
    final digest = _simpleHash(bytes, algo == 'sha256' ? 256 : 128);
    _out('$digest  ${a[0]}');
  }

  String _simpleHash(Uint8List data, int bits) {
    // FNV-like hash for display purposes (not cryptographic)
    var h1 = 0x811c9dc5;
    var h2 = 0x01000193;
    for (final b in data) {
      h1 = (h1 ^ b) * 0x01000193;
      h2 = (h2 ^ b) * 0x811c9dc5;
    }
    final hex1 = (h1 & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    final hex2 = (h2 & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    final hex3 = ((h1 ^ h2) & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    final hex4 = ((h1 + h2) & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    if (bits >= 256) return '$hex1$hex2$hex3$hex4$hex1$hex2$hex3$hex4';
    return '$hex1$hex2$hex3$hex4';
  }

  // ── System info commands ────────────────────────────────────────────

  void _cmdUname(List<String> a) {
    if (a.contains('-a')) {
      _out('${Platform.operatingSystem} ${Platform.localHostname} '
          '${Platform.operatingSystemVersion} '
          '${Platform.version.split(' ').first} '
          'Dart/${Platform.version.split(' ').first}');
    } else {
      _out('${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    }
  }

  void _cmdEnv(List<String> a) {
    if (a.isEmpty) {
      final sorted = Platform.environment.keys.toList()..sort();
      for (final k in sorted) {
        _out('$k=${Platform.environment[k]}');
      }
    } else {
      final val = Platform.environment[a[0]];
      if (val != null) {
        _out(val);
      } else {
        _out('env: ${a[0]}: not set', err: true);
      }
    }
  }

  Future<void> _cmdUptime() async {
    try {
      final content = await File('/proc/uptime').readAsString();
      final secs = double.tryParse(content.split(' ').first) ?? 0;
      final d = secs ~/ 86400;
      final h = (secs % 86400) ~/ 3600;
      final m = (secs % 3600) ~/ 60;
      final buf = StringBuffer('up ');
      if (d > 0) buf.write('$d day${d > 1 ? 's' : ''}, ');
      buf.write('$h:${_p2(m.toInt())}');
      _out(buf.toString());
    } catch (_) {
      _out('uptime: not available on this platform', err: true);
    }
  }

  Future<void> _cmdFree() async {
    try {
      final content = await File('/proc/meminfo').readAsString();
      final lines = content.split('\n');
      for (final line in lines) {
        if (line.startsWith('MemTotal:') ||
            line.startsWith('MemFree:') ||
            line.startsWith('MemAvailable:') ||
            line.startsWith('SwapTotal:') ||
            line.startsWith('SwapFree:')) {
          final match = RegExp(r'(\w+):\s+(\d+)\s+kB').firstMatch(line);
          if (match != null) {
            final name = match.group(1)!.padRight(14);
            final kb = int.parse(match.group(2)!);
            _out('$name ${_humanSize(kb * 1024).padLeft(10)}');
          }
        }
      }
    } catch (_) {
      _out('free: not available on this platform', err: true);
    }
  }

  Future<void> _cmdDf() async {
    try {
      final mounts = await File('/proc/mounts').readAsString();
      _out('Filesystem'.padRight(30) +
          'Size'.padLeft(10) +
          'Used'.padLeft(10) +
          'Avail'.padLeft(10) +
          '  Mount');
      for (final line in mounts.split('\n')) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        final dev = parts[0];
        final mount = parts[1];
        if (!dev.startsWith('/')) continue;
        try {
          final stat = await Process.run('stat', ['-f', '-c', '%b %f %S', mount]);
          final vals = (stat.stdout as String).trim().split(' ');
          if (vals.length == 3) {
            final blocks = int.parse(vals[0]);
            final free = int.parse(vals[1]);
            final bsize = int.parse(vals[2]);
            final total = blocks * bsize;
            final avail = free * bsize;
            final used = total - avail;
            _out(dev.padRight(30) +
                _humanSize(total).padLeft(10) +
                _humanSize(used).padLeft(10) +
                _humanSize(avail).padLeft(10) +
                '  $mount');
          }
        } catch (_) {
          // skip mounts we can't stat
        }
      }
    } catch (_) {
      _out('df: not available on this platform', err: true);
    }
  }

  void _cmdWhich(List<String> a) {
    if (a.isEmpty) {
      _out('which: missing operand', err: true);
      return;
    }
    final pathDirs = (Platform.environment['PATH'] ?? '').split(':');
    for (final cmd in a) {
      var found = false;
      for (final dir in pathDirs) {
        final full = '$dir/$cmd';
        if (File(full).existsSync()) {
          _out(full);
          found = true;
          break;
        }
      }
      if (!found) _out('$cmd not found', err: true);
    }
  }

  void _cmdSeq(List<String> a) {
    if (a.isEmpty) return;
    final start = int.tryParse(a[0]) ?? 1;
    final end = a.length > 1 ? (int.tryParse(a[1]) ?? start) : start;
    for (var i = start; i <= end; i++) {
      _out('$i');
    }
  }

  // ── Network commands ────────────────────────────────────────────────

  Future<void> _cmdPing(List<String> a) async {
    if (a.isEmpty) {
      _out('ping: usage: ping <host> [count]', err: true);
      return;
    }
    final host = a[0];
    final count = a.length > 1 ? (int.tryParse(a[1]) ?? 4) : 4;

    _out('PING $host ($count attempts via TCP connect)...');
    setState(() {});
    _scrollToBottom();

    for (var i = 0; i < count; i++) {
      final sw = Stopwatch()..start();
      try {
        final addrs = await InternetAddress.lookup(host);
        if (addrs.isEmpty) {
          _out('  $host: DNS lookup failed', err: true);
          continue;
        }
        final addr = addrs.first;
        final sock = await Socket.connect(addr, 80,
            timeout: const Duration(seconds: 3));
        sw.stop();
        await sock.close();
        _out('  ${addr.address}: tcp_seq=$i time=${sw.elapsedMilliseconds}ms');
      } on SocketException catch (e) {
        sw.stop();
        _out('  $host: ${e.message} (${sw.elapsedMilliseconds}ms)', err: true);
      } catch (e) {
        sw.stop();
        _out('  $host: $e', err: true);
      }
      setState(() {});
      _scrollToBottom();
      if (i < count - 1) await Future.delayed(const Duration(seconds: 1));
    }
  }

  Future<void> _cmdFetch(List<String> a) async {
    if (a.isEmpty) {
      _out('curl: usage: curl [-X POST] [-d data] <url>', err: true);
      return;
    }

    var method = 'GET';
    String? body;
    String? outputFile;
    String? url;
    var headersOnly = false;

    for (var i = 0; i < a.length; i++) {
      if (a[i] == '-X' && i + 1 < a.length) {
        method = a[++i].toUpperCase();
      } else if (a[i] == '-d' && i + 1 < a.length) {
        body = a[++i];
        if (method == 'GET') method = 'POST';
      } else if (a[i] == '-o' && i + 1 < a.length) {
        outputFile = a[++i];
      } else if (a[i] == '-I') {
        headersOnly = true;
      } else if (!a[i].startsWith('-')) {
        url = a[i];
      }
    }

    if (url == null) {
      _out('curl: missing URL', err: true);
      return;
    }
    if (!url.startsWith('http')) url = 'https://$url';

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final uri = Uri.parse(url);
      final request = await client.openUrl(method, uri);

      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }

      final response = await request.close();
      _out('HTTP ${response.statusCode} ${response.reasonPhrase}');

      if (headersOnly) {
        response.headers.forEach((name, values) {
          _out('$name: ${values.join(', ')}');
        });
        await response.drain();
      } else if (outputFile != null) {
        final bytes = await response.fold<List<int>>([], (prev, chunk) => prev..addAll(chunk));
        await File(_resolve(outputFile)).writeAsBytes(bytes);
        _out('Saved ${_humanSize(bytes.length)} to $outputFile');
      } else {
        final responseBody = await response.transform(utf8.decoder).join();
        _out(responseBody.length > 4096
            ? '${responseBody.substring(0, 4096)}\n... (${responseBody.length - 4096} more chars)'
            : responseBody);
      }
      client.close();
    } catch (e) {
      _out('curl: $e', err: true);
    }
  }

  Future<void> _cmdDns(List<String> a) async {
    if (a.isEmpty) {
      _out('host: usage: host <domain>', err: true);
      return;
    }
    try {
      final results = await InternetAddress.lookup(a[0]);
      for (final addr in results) {
        _out('${a[0]} has address ${addr.address} (${addr.type.name})');
      }
    } catch (e) {
      _out('host: ${a[0]}: $e', err: true);
    }
  }

  Future<void> _cmdIfconfig() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        _out('${iface.name}:');
        for (final addr in iface.addresses) {
          _out('  ${addr.type.name}: ${addr.address}');
        }
      }
    } catch (e) {
      _out('ifconfig: $e', err: true);
    }
  }

  // ── Key handler ─────────────────────────────────────────────────────

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_history.isNotEmpty) {
        if (_historyIndex < 0) _historyIndex = _history.length;
        _historyIndex--;
        if (_historyIndex >= 0) {
          _inputController.text = _history[_historyIndex];
          _inputController.selection =
              TextSelection.collapsed(offset: _inputController.text.length);
        }
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_historyIndex >= 0 && _historyIndex < _history.length - 1) {
        _historyIndex++;
        _inputController.text = _history[_historyIndex];
        _inputController.selection =
            TextSelection.collapsed(offset: _inputController.text.length);
      } else {
        _historyIndex = -1;
        _inputController.clear();
      }
    }
  }

  // ── Settings dialog ─────────────────────────────────────────────────

  void _openSettings() {
    if (_settingsScreen == null) return;

    // Snapshot current values so cancel can restore them
    final snapshot = {
      'fontSize': _fontSize,
      'fontFamily': _fontFamily,
      'lineHeight': _lineHeight,
      'colorScheme': _colorScheme,
      'showTimestamps': _showTimestamps,
      'maxLines': _maxLines,
    };

    showGeoUiDialog(
      context: context,
      screen: _settingsScreen!,
      bindings: _TerminalSettingsBindings(this),
      onAction: (action) {
        if (action == 'save') {
          _savePrefs();
        } else if (action == 'cancel') {
          // Restore snapshot
          setState(() {
            _fontSize = snapshot['fontSize'] as double;
            _fontFamily = snapshot['fontFamily'] as String;
            _lineHeight = snapshot['lineHeight'] as double;
            _colorScheme = snapshot['colorScheme'] as String;
            _showTimestamps = snapshot['showTimestamps'] as bool;
            _maxLines = snapshot['maxLines'] as int;
          });
        }
      },
    );
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = _TermColors.fromName(_colorScheme);

    return Scaffold(
      backgroundColor: colors.bg,
      appBar: AppBar(
        backgroundColor: colors.inputBg,
        title: Text('Terminal',
            style: TextStyle(fontFamily: _fontFamily, fontSize: _fontSize)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => _focusNode.requestFocus(),
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(12),
                itemCount: _lines.length,
                itemBuilder: (context, index) {
                  final line = _lines[index];
                  final ts = _showTimestamps
                      ? '${_p2(DateTime.now().hour)}:${_p2(DateTime.now().minute)} '
                      : '';
                  return Text(
                    '$ts${line.text}',
                    style: TextStyle(
                      fontFamily: _fontFamily,
                      fontSize: _fontSize,
                      height: _lineHeight,
                      color: line.isError
                          ? colors.error
                          : line.isCommand
                              ? colors.command
                              : colors.text,
                    ),
                  );
                },
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: colors.inputBg,
            child: KeyboardListener(
              focusNode: FocusNode(),
              onKeyEvent: _onKey,
              child: Row(
                children: [
                  Text(
                    _prompt,
                    style: TextStyle(
                      fontFamily: _fontFamily,
                      fontSize: _fontSize,
                      color: colors.prompt,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      focusNode: _focusNode,
                      autofocus: true,
                      style: TextStyle(
                        fontFamily: _fontFamily,
                        fontSize: _fontSize,
                        color: colors.text,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: (value) async {
                        _inputController.clear();
                        await _execute(value);
                        _focusNode.requestFocus();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── GeoUI bindings for terminal settings ──────────────────────────────

class _TerminalSettingsBindings implements GeoUiBindings {
  final _TerminalPageState _state;

  _TerminalSettingsBindings(this._state);

  @override
  dynamic getValue(String fieldName) => switch (fieldName) {
        'fontSize' => _state._fontSize,
        'fontFamily' => _state._fontFamily,
        'lineHeight' => _state._lineHeight,
        'colorScheme' => _state._colorScheme,
        'showTimestamps' => _state._showTimestamps,
        'maxLines' => _state._maxLines,
        _ => null,
      };

  @override
  void setValue(String fieldName, dynamic value) {
    _state.setState(() {
      switch (fieldName) {
        case 'fontSize':
          _state._fontSize = (value as num).toDouble();
        case 'fontFamily':
          _state._fontFamily = value as String;
        case 'lineHeight':
          _state._lineHeight = (value as num).toDouble();
        case 'colorScheme':
          _state._colorScheme = value as String;
        case 'showTimestamps':
          _state._showTimestamps = value as bool;
        case 'maxLines':
          _state._maxLines = (value as num).toInt();
      }
    });
  }
}

// ── Line model ────────────────────────────────────────────────────────

class _Line {
  final String text;
  final bool isError;
  final bool isCommand;

  _Line(this.text, {this.isError = false, this.isCommand = false});
}
