library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;

import 'log_service.dart';

enum ConferenceRecordingState { idle, starting, recording, stopping, failed }

class ConferenceRecordingStatus {
  final ConferenceRecordingState state;
  final DateTime? startedAt;
  final String? lastError;
  final String? tempOutputPath;

  const ConferenceRecordingStatus({
    required this.state,
    this.startedAt,
    this.lastError,
    this.tempOutputPath,
  });

  bool get isRecording => state == ConferenceRecordingState.recording;

  Map<String, dynamic> toJson() => {
    'state': state.name,
    'started_at': startedAt?.toIso8601String(),
    'last_error': lastError,
    'temp_output_path': tempOutputPath,
    'is_recording': isRecording,
  };
}

class ConferenceRecordingService {
  final _statusController = StreamController<ConferenceRecordingStatus>.broadcast();

  Process? _process;
  Directory? _tempDir;
  String? _tempOutputPath;
  DateTime? _startedAt;
  String? _lastError;
  ConferenceRecordingState _state = ConferenceRecordingState.idle;
  Future<bool>? _availabilityCheck;

  Stream<ConferenceRecordingStatus> get statusStream => _statusController.stream;

  ConferenceRecordingStatus get status => ConferenceRecordingStatus(
    state: _state,
    startedAt: _startedAt,
    lastError: _lastError,
    tempOutputPath: _tempOutputPath,
  );

  bool get isRecording => _state == ConferenceRecordingState.recording;

  Future<bool> isSupported() {
    final pending = _availabilityCheck;
    if (pending != null) {
      return pending;
    }

    late final Future<bool> check;
    check = _checkAvailability().whenComplete(() {
      if (identical(_availabilityCheck, check)) {
        _availabilityCheck = null;
      }
    });
    _availabilityCheck = check;
    return check;
  }

  Future<void> start() async {
    if (isRecording) {
      return;
    }
    if (!await isSupported()) {
      throw StateError(_lastError ?? 'Meeting recording is not supported');
    }

    _setState(ConferenceRecordingState.starting);
    _clearError();

    try {
      final tempDir = await Directory.systemTemp.createTemp(
        'geogram-meeting-recording-',
      );
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final outputPath = p.join(tempDir.path, 'meeting_$timestamp.mp4');
      final command = await _buildLinuxFfmpegCommand(outputPath);
      final process = await Process.start(
        'ffmpeg',
        command,
        runInShell: false,
      );

      _tempDir = tempDir;
      _tempOutputPath = outputPath;
      _process = process;
      _startedAt = DateTime.now();

      unawaited(_logProcessOutput(process.stderr));
      unawaited(_logProcessOutput(process.stdout));

      _setState(ConferenceRecordingState.recording);
      LogService().log(
        'ConferenceRecordingService: Recording started at $outputPath',
      );
    } catch (error) {
      _lastError = '$error';
      _setState(ConferenceRecordingState.failed);
      await _cleanupTempArtifacts();
      rethrow;
    }
  }

  Future<String?> stop() async {
    final process = _process;
    if (process == null) {
      return _tempOutputPath;
    }

    _setState(ConferenceRecordingState.stopping);
    final outputPath = _tempOutputPath;
    try {
      process.stdin.writeln('q');
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process.kill(ProcessSignal.sigint);
          return process.exitCode;
        },
      );
      if (exitCode != 0) {
        LogService().log(
          'ConferenceRecordingService: ffmpeg exited with code $exitCode',
        );
      }
    } catch (error) {
      _lastError = '$error';
      process.kill(ProcessSignal.sigint);
    } finally {
      _process = null;
      _setState(
        _lastError == null
            ? ConferenceRecordingState.idle
            : ConferenceRecordingState.failed,
      );
    }
    return outputPath;
  }

  Future<void> dispose() async {
    if (_process != null) {
      await stop();
    }
    await _cleanupTempArtifacts();
    if (!_statusController.isClosed) {
      await _statusController.close();
    }
  }

  Future<void> clearTempRecording() async {
    await _cleanupTempArtifacts();
    _clearError();
    _setState(ConferenceRecordingState.idle);
  }

  Future<bool> _checkAvailability() async {
    if (kIsWeb) {
      _lastError = 'Meeting recording is not implemented for browser hosts yet';
      return false;
    }
    if (!Platform.isLinux) {
      _lastError = 'Meeting recording currently supports Linux desktop hosts only';
      return false;
    }

    final ffmpeg = await Process.run('which', ['ffmpeg']);
    if (ffmpeg.exitCode != 0) {
      _lastError = 'ffmpeg is not installed on this system';
      return false;
    }

    final display = Platform.environment['DISPLAY'];
    if (display == null || display.isEmpty) {
      _lastError = 'DISPLAY is not available for desktop capture';
      return false;
    }

    return true;
  }

  Future<List<String>> _buildLinuxFfmpegCommand(String outputPath) async {
    final display = Platform.environment['DISPLAY'] ?? ':0';
    final screenSize = await _detectScreenSize() ?? '1280x720';
    final pulseSources = await _detectPulseSources();

    final args = <String>[
      '-y',
      '-video_size',
      screenSize,
      '-framerate',
      '12',
      '-f',
      'x11grab',
      '-i',
      display,
    ];

    final audioInputs = <String>[];
    if (pulseSources.monitorSource != null &&
        pulseSources.monitorSource!.isNotEmpty) {
      args.addAll([
        '-thread_queue_size',
        '512',
        '-f',
        'pulse',
        '-i',
        pulseSources.monitorSource!,
      ]);
      audioInputs.add(pulseSources.monitorSource!);
    }
    if (pulseSources.micSource != null &&
        pulseSources.micSource!.isNotEmpty &&
        pulseSources.micSource != pulseSources.monitorSource) {
      args.addAll([
        '-thread_queue_size',
        '512',
        '-f',
        'pulse',
        '-i',
        pulseSources.micSource!,
      ]);
      audioInputs.add(pulseSources.micSource!);
    }

    if (audioInputs.length >= 2) {
      args.addAll([
        '-filter_complex',
        '[1:a][2:a]amix=inputs=2:duration=longest:dropout_transition=2[aout]',
        '-map',
        '0:v',
        '-map',
        '[aout]',
      ]);
    } else if (audioInputs.length == 1) {
      args.addAll([
        '-map',
        '0:v',
        '-map',
        '1:a',
      ]);
    } else {
      args.addAll(['-map', '0:v']);
    }

    args.addAll([
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-pix_fmt',
      'yuv420p',
      '-crf',
      '28',
    ]);

    if (audioInputs.isNotEmpty) {
      args.addAll([
        '-c:a',
        'aac',
        '-b:a',
        '128k',
      ]);
    }

    args.addAll([
      '-movflags',
      '+faststart',
      outputPath,
    ]);
    return args;
  }

  Future<String?> _detectScreenSize() async {
    try {
      final result = await Process.run('sh', [
        '-lc',
        "xrandr 2>/dev/null | awk '/\\*/ {print \$1; exit}'",
      ]);
      if (result.exitCode != 0) {
        return null;
      }
      final size = (result.stdout as String).trim();
      if (RegExp(r'^\d+x\d+$').hasMatch(size)) {
        return size;
      }
    } catch (_) {}
    return null;
  }

  Future<_PulseSources> _detectPulseSources() async {
    try {
      final result = await Process.run('ffmpeg', [
        '-hide_banner',
        '-sources',
        'pulse',
      ]);
      final output = [
        result.stdout as String? ?? '',
        result.stderr as String? ?? '',
      ].join('\n');

      String? monitorSource;
      String? micSource;

      for (final rawLine in const LineSplitter().convert(output)) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith('Auto-detected sources')) {
          continue;
        }

        final match = RegExp(r'^\*?\s*([^\s]+)\s+\[').firstMatch(line);
        if (match == null) {
          continue;
        }
        final sourceName = match.group(1);
        if (sourceName == null || sourceName.isEmpty) {
          continue;
        }

        if (sourceName.contains('.monitor') && monitorSource == null) {
          monitorSource = sourceName;
        }
        if (line.startsWith('*') && micSource == null) {
          micSource = sourceName;
        }
      }

      return _PulseSources(
        monitorSource: monitorSource,
        micSource: micSource,
      );
    } catch (_) {
      return const _PulseSources();
    }
  }

  Future<void> _logProcessOutput(Stream<List<int>> stream) async {
    try {
      await for (final chunk in stream.transform(utf8.decoder)) {
        final text = chunk.trim();
        if (text.isNotEmpty) {
          LogService().log('ConferenceRecordingService: $text');
        }
      }
    } catch (_) {}
  }

  Future<void> _cleanupTempArtifacts() async {
    final tempDir = _tempDir;
    _tempDir = null;
    _tempOutputPath = null;
    _startedAt = null;
    if (tempDir != null && await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  }

  void _setState(ConferenceRecordingState state) {
    _state = state;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  void _clearError() {
    _lastError = null;
  }
}

class _PulseSources {
  final String? monitorSource;
  final String? micSource;

  const _PulseSources({this.monitorSource, this.micSource});
}
