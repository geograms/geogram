/*
 * NOSTR vanity key generator (multi-isolate).
 *
 * Usage:
 *   dart run tests/nostr_vanity_generator.dart ABCD
 *   dart run tests/nostr_vanity_generator.dart **xy --threads 4
 *
 * Pattern rules (matched against the npub payload after "npub1"):
 *   - Letters are case-insensitive.
 *   - '*' matches exactly one character.
 *   - "ABCD" matches npub1abcd...
 *   - "**XY" matches npub1??xy...
 */

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:geogram/util/nostr_key_generator.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    _printUsage();
    exit(64);
  }

  final parsed = _parseArgs(args);
  final pattern = _normalizePattern(parsed.pattern);
  if (pattern.isEmpty) {
    stderr.writeln('Error: pattern is empty after normalization.');
    _printUsage();
    exit(64);
  }
  if (!_isValidPattern(pattern)) {
    stderr.writeln('Error: pattern contains invalid characters.');
    _printUsage();
    exit(64);
  }

  // Default to half of CPU cores to avoid contention (min 1, max 8)
  final threads = parsed.threads ?? max(1, min(Platform.numberOfProcessors ~/ 2, 8));
  final receivePort = ReceivePort();
  final errorPort = ReceivePort();
  final exitPort = ReceivePort();
  final isolates = <Isolate>[];
  var totalAttempts = 0;
  var totalMatches = 0;
  var initialMatches = _countExistingMatches();
  var activeWorkers = 0;

  final matchesFile = _matchesFile();
  final sink = matchesFile.openWrite(mode: FileMode.append);

  final startTime = DateTime.now();
  var lastAttempts = 0;

  // Progress timer - updates the same line using \r
  final progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
    final attemptsDelta = totalAttempts - lastAttempts;
    lastAttempts = totalAttempts;
    final elapsed = DateTime.now().difference(startTime).inSeconds;
    final progress =
        'Progress: $totalAttempts tries, '
        '${initialMatches + totalMatches} matches, '
        '$attemptsDelta keys/sec, ${elapsed}s elapsed, '
        '$activeWorkers workers';
    stdout.write('\r${progress.padRight(80)}');
  });

  receivePort.listen((message) {
    if (message is Map) {
      switch (message['type']) {
        case 'progress':
          totalAttempts += message['count'] as int;
          break;
        case 'match':
          totalAttempts += message['count'] as int;
          totalMatches += 1;
          final npub = message['npub'] as String;
          final nsec = message['nsec'] as String;
          final line = '$npub | $nsec';
          sink.writeln(line);
          // Print match on new line, then progress will resume on next line
          stdout.write('\n$line\n');
          break;
      }
    }
  });

  errorPort.listen((message) {
    stderr.writeln('\nWorker error: $message');
  });

  exitPort.listen((_) {
    activeWorkers -= 1;
  });

  for (var i = 0; i < threads; i++) {
    final isolate = await Isolate.spawn(
      _workerMain,
      {
        'sendPort': receivePort.sendPort,
        'pattern': pattern,
        'patternLength': pattern.length,
        'batch': 100, // Smaller batch for more responsive progress
      },
      debugName: 'nostr-vanity-$i',
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
    );
    isolates.add(isolate);
    activeWorkers += 1;
  }

  stdout.writeln(
    'Running with $threads workers. Writing matches to ${matchesFile.path}',
  );
  stdout.writeln('Press Ctrl+C to stop.\n');
  if (initialMatches > 0) {
    stdout.writeln('Existing matches in file: $initialMatches');
  }

  // Wait for SIGINT (Ctrl+C) or SIGTERM
  await Future.any([
    ProcessSignal.sigint.watch().first,
    ProcessSignal.sigterm.watch().first,
  ]);

  stdout.write('\nStopping...\n');

  progressTimer.cancel();
  for (final isolate in isolates) {
    isolate.kill(priority: Isolate.immediate);
  }
  await sink.flush();
  await sink.close();
  receivePort.close();
  errorPort.close();
  exitPort.close();
}

class _ParsedArgs {
  final String pattern;
  final int? threads;

  const _ParsedArgs(this.pattern, this.threads);
}

_ParsedArgs _parseArgs(List<String> args) {
  final pattern = args.first;
  int? threads;

  for (var i = 1; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--threads' || arg == '-t') {
      if (i + 1 < args.length) {
        threads = int.tryParse(args[i + 1]);
        i++;
      }
    } else if (arg.startsWith('--threads=')) {
      threads = int.tryParse(arg.split('=').last);
    } else if (arg.startsWith('-t=')) {
      threads = int.tryParse(arg.split('=').last);
    }
  }

  if (threads != null && threads <= 0) {
    threads = null;
  }

  return _ParsedArgs(pattern, threads);
}

String _normalizePattern(String pattern) {
  var normalized = pattern.trim().toLowerCase();
  if (normalized.startsWith('npub1')) {
    normalized = normalized.substring(5);
  }
  return normalized;
}

bool _isValidPattern(String pattern) {
  final validChars = RegExp(r'^[a-z0-9\*]+$');
  return validChars.hasMatch(pattern);
}

bool _matchesPattern(String npub, String pattern, int patternLength) {
  if (!npub.startsWith('npub1')) return false;
  if (npub.length < 5 + patternLength) return false;

  for (var i = 0; i < patternLength; i++) {
    final expected = pattern.codeUnitAt(i);
    final actual = npub.codeUnitAt(5 + i);
    if (expected == 42) {
      continue; // '*'
    }
    if (actual != expected) {
      return false;
    }
  }
  return true;
}

File _matchesFile() {
  final scriptDir = File.fromUri(Platform.script).parent;
  return File('${scriptDir.path}${Platform.pathSeparator}matches.txt');
}

int _countExistingMatches() {
  try {
    final file = _matchesFile();
    if (!file.existsSync()) return 0;
    return file.readAsLinesSync().where((line) => line.trim().isNotEmpty).length;
  } catch (_) {
    return 0;
  }
}

void _workerMain(Map<String, dynamic> config) {
  final sendPort = config['sendPort'] as SendPort;
  final pattern = config['pattern'] as String;
  final patternLength = config['patternLength'] as int;
  final batch = config['batch'] as int;

  while (true) {
    var attempts = 0;
    while (attempts < batch) {
      final keys = NostrKeyGenerator.generateKeyPair();
      attempts++;
      if (_matchesPattern(keys.npub, pattern, patternLength)) {
        sendPort.send({
          'type': 'match',
          'npub': keys.npub,
          'nsec': keys.nsec,
          'count': attempts,
        });
        attempts = 0;
      }
    }
    sendPort.send({'type': 'progress', 'count': attempts});
  }
}

void _printUsage() {
  stdout.writeln('Usage:');
  stdout.writeln('  dart run tests/nostr_vanity_generator.dart PATTERN');
  stdout.writeln('  dart run tests/nostr_vanity_generator.dart PATTERN --threads 4');
  stdout.writeln('');
  stdout.writeln('Pattern rules:');
  stdout.writeln('  - Pattern is matched after "npub1".');
  stdout.writeln('  - "*" matches a single character.');
  stdout.writeln('  - "ABCD" matches npub1abcd...');
  stdout.writeln('  - "**XY" matches npub1??xy...');
}
