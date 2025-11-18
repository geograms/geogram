import 'dart:collection';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Global singleton for logging
class LogService {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  final int maxLogMessages = 1000;
  final Queue<String> _logMessages = Queue<String>();
  final List<Function(String)> _listeners = [];
  File? _logFile;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${appDir.path}/geogram');

      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }

      _logFile = File('${logDir.path}/log.txt');
      _initialized = true;

      // Write startup marker
      await _writeToFile('\n=== Application Started: ${DateTime.now()} ===\n');
    } catch (e) {
      // Can't use log() here as we're in init(), use stderr
      stderr.writeln('Error initializing log file: $e');
    }
  }

  Future<void> _writeToFile(String message) async {
    if (_logFile == null) return;

    try {
      // Check file size and rotate if needed (keep last 1MB)
      if (await _logFile!.exists()) {
        final fileSize = await _logFile!.length();
        if (fileSize > 5 * 1024 * 1024) { // 5MB
          // Keep last 1MB
          final contents = await _logFile!.readAsString();
          final lines = contents.split('\n');
          final keepLines = lines.length > 1000 ? lines.sublist(lines.length - 1000) : lines;
          await _logFile!.writeAsString(keepLines.join('\n'));
        }
      }

      // Append log entry
      await _logFile!.writeAsString('$message\n', mode: FileMode.append, flush: true);
    } catch (e) {
      stderr.writeln('Error writing to log file: $e');
    }
  }

  void addListener(Function(String) listener) {
    _listeners.add(listener);
  }

  void removeListener(Function(String) listener) {
    _listeners.remove(listener);
  }

  List<String> get messages => _logMessages.toList();

  void log(String message) {
    final now = DateTime.now();
    final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
    final logEntry = '$date $time | $message';

    _logMessages.add(logEntry);

    // Keep only the last maxLogMessages
    if (_logMessages.length > maxLogMessages) {
      _logMessages.removeFirst();
    }

    // Write to file asynchronously
    _writeToFile(logEntry);

    // Notify all listeners
    for (var listener in _listeners) {
      listener(logEntry);
    }
  }

  void clear() {
    _logMessages.clear();
    for (var listener in _listeners) {
      listener('');
    }
  }
}
