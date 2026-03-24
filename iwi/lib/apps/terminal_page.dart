import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final _lines = <TerminalLine>[];
  late String _cwd;
  final _history = <String>[];
  int _historyIndex = -1;

  @override
  void initState() {
    super.initState();
    _cwd = Directory.current.path;
    _addOutput('Iwi Terminal v1.0');
    _addOutput('Type "help" for available commands.\n');
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _addOutput(String text, {bool isError = false, bool isCommand = false}) {
    for (final line in text.split('\n')) {
      _lines.add(TerminalLine(line, isError: isError, isCommand: isCommand));
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  String get _prompt => '${_shortPath(_cwd)} \$ ';

  String _shortPath(String path) {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isNotEmpty && path.startsWith(home)) {
      return '~${path.substring(home.length)}';
    }
    return path;
  }

  Future<void> _execute(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;

    _history.add(trimmed);
    _historyIndex = -1;
    _addOutput('$_prompt$trimmed', isCommand: true);

    final parts = _splitCommand(trimmed);
    if (parts.isEmpty) return;

    final cmd = parts[0];
    final args = parts.sublist(1);

    try {
      switch (cmd) {
        case 'help':
          _cmdHelp();
        case 'clear':
          _lines.clear();
        case 'cd':
          _cmdCd(args);
        case 'pwd':
          _addOutput(_cwd);
        case 'ls':
          await _cmdLs(args);
        case 'mkdir':
          await _cmdMkdir(args);
        case 'rmdir':
          await _cmdRmdir(args);
        case 'rm':
          await _cmdRm(args);
        case 'touch':
          await _cmdTouch(args);
        case 'cat':
          await _cmdCat(args);
        case 'echo':
          _addOutput(args.join(' '));
        case 'cp':
          await _cmdCp(args);
        case 'mv':
          await _cmdMv(args);
        case 'head':
          await _cmdHead(args);
        case 'tail':
          await _cmdTail(args);
        case 'wc':
          await _cmdWc(args);
        case 'grep':
          await _cmdGrep(args);
        case 'find':
          await _cmdFind(args);
        case 'stat':
          await _cmdStat(args);
        case 'date':
          _addOutput(DateTime.now().toString());
        case 'whoami':
          _addOutput(Platform.environment['USER'] ?? 'unknown');
        case 'hostname':
          _addOutput(Platform.localHostname);
        case 'uname':
          _addOutput('${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
        case 'env':
          _cmdEnv(args);
        case 'export':
          _addOutput('export: read-only environment', isError: true);
        case 'ping':
          await _cmdExec('ping', ['-c', '4', ...args]);
        case 'curl':
          await _cmdExec('curl', args);
        case 'wget':
          await _cmdExec('wget', args);
        case 'df':
          await _cmdExec('df', ['-h', ...args]);
        case 'du':
          await _cmdExec('du', ['-sh', ...args]);
        case 'free':
          await _cmdExec('free', ['-h', ...args]);
        case 'uptime':
          await _cmdExec('uptime', args);
        case 'ps':
          await _cmdExec('ps', args.isEmpty ? ['aux'] : args);
        case 'top':
          _addOutput('top: interactive commands not supported, use "ps" instead', isError: true);
        case 'kill':
          await _cmdExec('kill', args);
        case 'which':
          await _cmdExec('which', args);
        case 'file':
          await _cmdExec('file', args);
        case 'chmod':
          await _cmdExec('chmod', args);
        case 'chown':
          await _cmdExec('chown', args);
        case 'exit':
          if (mounted) Navigator.of(context).pop();
        default:
          // Try running as system command
          await _cmdExec(cmd, args);
      }
    } catch (e) {
      _addOutput('$cmd: $e', isError: true);
    }

    setState(() {});
    _scrollToBottom();
  }

  List<String> _splitCommand(String input) {
    final parts = <String>[];
    final buf = StringBuffer();
    var inQuote = false;
    String? quoteChar;

    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      if (inQuote) {
        if (c == quoteChar) {
          inQuote = false;
        } else {
          buf.write(c);
        }
      } else if (c == '"' || c == "'") {
        inQuote = true;
        quoteChar = c;
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

  String _resolve(String path) {
    if (path.startsWith('/')) return path;
    if (path.startsWith('~/')) {
      final home = Platform.environment['HOME'] ?? '';
      return '$home${path.substring(1)}';
    }
    return '$_cwd/$path';
  }

  void _cmdHelp() {
    _addOutput('''Available commands:
  help              Show this help
  clear             Clear screen
  exit              Close terminal

  cd [dir]          Change directory
  pwd               Print working directory
  ls [-la] [dir]    List files
  mkdir <dir>       Create directory
  rmdir <dir>       Remove empty directory
  rm [-rf] <path>   Remove file or directory
  touch <file>      Create empty file
  cat <file>        Print file contents
  head [-n N] file  First N lines (default 10)
  tail [-n N] file  Last N lines (default 10)
  cp <src> <dst>    Copy file
  mv <src> <dst>    Move/rename file
  echo <text>       Print text
  grep <pat> <file> Search in file
  find [dir] -name  Find files by name
  wc <file>         Line/word/byte count
  stat <path>       File information

  date              Current date/time
  whoami            Current user
  hostname          Machine hostname
  uname             OS information
  env [VAR]         Environment variables

  ping <host>       Ping a host
  curl <url>        HTTP request
  wget <url>        Download file
  df                Disk usage
  du [path]         Directory size
  free              Memory usage
  uptime            System uptime
  ps [args]         Process list
  kill <pid>        Kill process
  which <cmd>       Locate command
  file <path>       File type
  chmod <mode> <f>  Change permissions

Any unrecognized command is executed as a system command.''');
  }

  void _cmdCd(List<String> args) {
    if (args.isEmpty) {
      _cwd = Platform.environment['HOME'] ?? '/';
      return;
    }
    final target = _resolve(args[0]);
    if (Directory(target).existsSync()) {
      _cwd = Directory(target).resolveSymbolicLinksSync();
    } else {
      _addOutput('cd: no such directory: ${args[0]}', isError: true);
    }
  }

  Future<void> _cmdLs(List<String> args) async {
    var showAll = false;
    var showLong = false;
    String? target;

    for (final a in args) {
      if (a.startsWith('-')) {
        if (a.contains('a')) showAll = true;
        if (a.contains('l')) showLong = true;
      } else {
        target = a;
      }
    }

    final dir = Directory(_resolve(target ?? '.'));
    if (!dir.existsSync()) {
      _addOutput('ls: cannot access \'${target ?? '.'}\': No such directory', isError: true);
      return;
    }

    final entries = dir.listSync()..sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      final name = entry.path.split('/').last;
      if (!showAll && name.startsWith('.')) continue;

      if (showLong) {
        final stat = entry.statSync();
        final type = stat.type == FileSystemEntityType.directory ? 'd' : '-';
        final size = stat.size.toString().padLeft(10);
        final mod = _formatDate(stat.modified);
        final suffix = stat.type == FileSystemEntityType.directory ? '/' : '';
        _addOutput('$type $size $mod $name$suffix');
      } else {
        final suffix = entry is Directory ? '/' : '';
        _addOutput('$name$suffix');
      }
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _cmdMkdir(List<String> args) async {
    if (args.isEmpty) {
      _addOutput('mkdir: missing operand', isError: true);
      return;
    }
    for (final a in args) {
      await Directory(_resolve(a)).create(recursive: a.contains('/'));
    }
  }

  Future<void> _cmdRmdir(List<String> args) async {
    if (args.isEmpty) {
      _addOutput('rmdir: missing operand', isError: true);
      return;
    }
    final dir = Directory(_resolve(args[0]));
    if (!dir.existsSync()) {
      _addOutput('rmdir: no such directory: ${args[0]}', isError: true);
      return;
    }
    await dir.delete();
  }

  Future<void> _cmdRm(List<String> args) async {
    if (args.isEmpty) {
      _addOutput('rm: missing operand', isError: true);
      return;
    }
    var recursive = false;
    final paths = <String>[];
    for (final a in args) {
      if (a.startsWith('-') && (a.contains('r') || a.contains('f'))) {
        recursive = true;
      } else {
        paths.add(a);
      }
    }
    for (final p in paths) {
      final resolved = _resolve(p);
      final type = FileSystemEntity.typeSync(resolved);
      if (type == FileSystemEntityType.notFound) {
        _addOutput('rm: cannot remove \'$p\': No such file or directory', isError: true);
      } else if (type == FileSystemEntityType.directory) {
        if (!recursive) {
          _addOutput('rm: cannot remove \'$p\': Is a directory (use -rf)', isError: true);
        } else {
          await Directory(resolved).delete(recursive: true);
        }
      } else {
        await File(resolved).delete();
      }
    }
  }

  Future<void> _cmdTouch(List<String> args) async {
    if (args.isEmpty) {
      _addOutput('touch: missing operand', isError: true);
      return;
    }
    for (final a in args) {
      final f = File(_resolve(a));
      if (f.existsSync()) {
        await f.setLastModified(DateTime.now());
      } else {
        await f.create();
      }
    }
  }

  Future<void> _cmdCat(List<String> args) async {
    if (args.isEmpty) {
      _addOutput('cat: missing operand', isError: true);
      return;
    }
    for (final a in args) {
      final f = File(_resolve(a));
      if (!f.existsSync()) {
        _addOutput('cat: $a: No such file', isError: true);
        continue;
      }
      _addOutput(await f.readAsString());
    }
  }

  Future<void> _cmdHead(List<String> args) async {
    var n = 10;
    String? path;
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '-n' && i + 1 < args.length) {
        n = int.tryParse(args[++i]) ?? 10;
      } else {
        path = args[i];
      }
    }
    if (path == null) {
      _addOutput('head: missing operand', isError: true);
      return;
    }
    final f = File(_resolve(path));
    if (!f.existsSync()) {
      _addOutput('head: $path: No such file', isError: true);
      return;
    }
    final lines = await f.readAsLines();
    _addOutput(lines.take(n).join('\n'));
  }

  Future<void> _cmdTail(List<String> args) async {
    var n = 10;
    String? path;
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '-n' && i + 1 < args.length) {
        n = int.tryParse(args[++i]) ?? 10;
      } else {
        path = args[i];
      }
    }
    if (path == null) {
      _addOutput('tail: missing operand', isError: true);
      return;
    }
    final f = File(_resolve(path));
    if (!f.existsSync()) {
      _addOutput('tail: $path: No such file', isError: true);
      return;
    }
    final lines = await f.readAsLines();
    final start = lines.length > n ? lines.length - n : 0;
    _addOutput(lines.sublist(start).join('\n'));
  }

  Future<void> _cmdCp(List<String> args) async {
    if (args.length < 2) {
      _addOutput('cp: missing operand', isError: true);
      return;
    }
    final src = File(_resolve(args[0]));
    if (!src.existsSync()) {
      _addOutput('cp: ${args[0]}: No such file', isError: true);
      return;
    }
    await src.copy(_resolve(args[1]));
  }

  Future<void> _cmdMv(List<String> args) async {
    if (args.length < 2) {
      _addOutput('mv: missing operand', isError: true);
      return;
    }
    final src = File(_resolve(args[0]));
    if (!src.existsSync()) {
      _addOutput('mv: ${args[0]}: No such file', isError: true);
      return;
    }
    await src.rename(_resolve(args[1]));
  }

  Future<void> _cmdWc(List<String> args) async {
    if (args.isEmpty) {
      _addOutput('wc: missing operand', isError: true);
      return;
    }
    for (final a in args) {
      final f = File(_resolve(a));
      if (!f.existsSync()) {
        _addOutput('wc: $a: No such file', isError: true);
        continue;
      }
      final content = await f.readAsString();
      final lines = content.split('\n').length;
      final words = content.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      final bytes = (await f.readAsBytes()).length;
      _addOutput('  $lines  $words  $bytes $a');
    }
  }

  Future<void> _cmdGrep(List<String> args) async {
    if (args.length < 2) {
      _addOutput('grep: usage: grep <pattern> <file>', isError: true);
      return;
    }
    final pattern = RegExp(args[0]);
    for (final a in args.sublist(1)) {
      final f = File(_resolve(a));
      if (!f.existsSync()) {
        _addOutput('grep: $a: No such file', isError: true);
        continue;
      }
      final lines = await f.readAsLines();
      for (final line in lines) {
        if (pattern.hasMatch(line)) _addOutput(line);
      }
    }
  }

  Future<void> _cmdFind(List<String> args) async {
    String dir = '.';
    String? namePattern;
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '-name' && i + 1 < args.length) {
        namePattern = args[++i];
      } else if (!args[i].startsWith('-')) {
        dir = args[i];
      }
    }
    final resolved = Directory(_resolve(dir));
    if (!resolved.existsSync()) {
      _addOutput('find: \'$dir\': No such directory', isError: true);
      return;
    }
    final regex = namePattern != null
        ? RegExp(namePattern.replaceAll('*', '.*').replaceAll('?', '.'))
        : null;
    await for (final entity in resolved.list(recursive: true)) {
      final name = entity.path.split('/').last;
      if (regex == null || regex.hasMatch(name)) {
        _addOutput(entity.path);
      }
    }
  }

  Future<void> _cmdStat(List<String> args) async {
    if (args.isEmpty) {
      _addOutput('stat: missing operand', isError: true);
      return;
    }
    final path = _resolve(args[0]);
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      _addOutput('stat: \'${args[0]}\': No such file or directory', isError: true);
      return;
    }
    final stat = FileStat.statSync(path);
    _addOutput('  File: ${args[0]}');
    _addOutput('  Size: ${stat.size}');
    _addOutput('  Type: ${stat.type}');
    _addOutput('  Modified: ${stat.modified}');
    _addOutput('  Accessed: ${stat.accessed}');
    _addOutput('  Mode: ${stat.modeString()}');
  }

  void _cmdEnv(List<String> args) {
    if (args.isEmpty) {
      Platform.environment.forEach((k, v) => _addOutput('$k=$v'));
    } else {
      final val = Platform.environment[args[0]];
      if (val != null) {
        _addOutput(val);
      } else {
        _addOutput('env: ${args[0]}: not set', isError: true);
      }
    }
  }

  Future<void> _cmdExec(String cmd, List<String> args) async {
    try {
      final result = await Process.run(
        cmd,
        args,
        workingDirectory: _cwd,
        environment: Platform.environment,
      );
      if ((result.stdout as String).isNotEmpty) {
        _addOutput((result.stdout as String).trimRight());
      }
      if ((result.stderr as String).isNotEmpty) {
        _addOutput((result.stderr as String).trimRight(), isError: true);
      }
      if (result.exitCode != 0 &&
          (result.stdout as String).isEmpty &&
          (result.stderr as String).isEmpty) {
        _addOutput('$cmd: exited with code ${result.exitCode}', isError: true);
      }
    } on ProcessException {
      _addOutput('$cmd: command not found', isError: true);
    }
  }

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_history.isNotEmpty) {
        if (_historyIndex < 0) _historyIndex = _history.length;
        _historyIndex--;
        if (_historyIndex >= 0) {
          _inputController.text = _history[_historyIndex];
          _inputController.selection = TextSelection.collapsed(
            offset: _inputController.text.length,
          );
        }
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_historyIndex >= 0 && _historyIndex < _history.length - 1) {
        _historyIndex++;
        _inputController.text = _history[_historyIndex];
        _inputController.selection = TextSelection.collapsed(
          offset: _inputController.text.length,
        );
      } else {
        _historyIndex = -1;
        _inputController.clear();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('Terminal', style: TextStyle(fontFamily: 'monospace')),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => _focusNode.requestFocus(),
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(8),
                itemCount: _lines.length,
                itemBuilder: (context, index) {
                  final line = _lines[index];
                  return Text(
                    line.text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.4,
                      color: line.isError
                          ? Colors.redAccent
                          : line.isCommand
                              ? Colors.lightGreenAccent
                              : const Color(0xFFE0E0E0),
                    ),
                  );
                },
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            color: const Color(0xFF0F3460),
            child: KeyboardListener(
              focusNode: FocusNode(),
              onKeyEvent: _onKey,
              child: Row(
                children: [
                  Text(
                    _prompt,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: Colors.lightGreenAccent,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      focusNode: _focusNode,
                      autofocus: true,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: Color(0xFFE0E0E0),
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

class TerminalLine {
  final String text;
  final bool isError;
  final bool isCommand;

  TerminalLine(this.text, {this.isError = false, this.isCommand = false});
}
