library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;

import 'android_screen_recorder_service.dart';
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
  AndroidScreenRecorderService? _androidRecorder;

  // Wayland: GNOME Screencast produces video, separate ffmpeg captures audio
  bool _isWaylandRecording = false;
  String? _screencastVideoPath;
  DBusClient? _dbusClient; // Native D-Bus connection for GNOME Screencast
  Process? _audioProcess;
  String? _audioOutputPath;

  Stream<ConferenceRecordingStatus> get statusStream => _statusController.stream;

  ConferenceRecordingStatus get status => ConferenceRecordingStatus(
    state: _state,
    startedAt: _startedAt,
    lastError: _lastError,
    tempOutputPath: _tempOutputPath,
  );

  bool get isRecording => _state == ConferenceRecordingState.recording;

  bool get isWayland => Platform.isLinux && _isWayland();

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

  /// Start recording. When [includeScreen] is false (default), only audio
  /// is captured — no desktop/screen capture occurs, protecting user privacy.
  /// Screen capture is only included when the user is actively screen-sharing.
  Future<void> start({bool includeScreen = false}) async {
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

      _tempDir = tempDir;
      _tempOutputPath = outputPath;
      _startedAt = DateTime.now();

      if (Platform.isAndroid) {
        if (!includeScreen) {
          // Android audio-only not yet supported; record silently
          LogService().log(
            'ConferenceRecordingService: Android audio-only not supported, skipping',
          );
          _setState(ConferenceRecordingState.idle);
          return;
        }
        _androidRecorder = AndroidScreenRecorderService();
        await _androidRecorder!.start(outputPath);
      } else if (includeScreen && Platform.isLinux && _isWayland()) {
        // Wayland screen+audio requires GNOME Screencast
        await _startWaylandRecording(tempDir.path, outputPath);
      } else {
        // Generic ffmpeg path: audio-only or X11/Windows screen+audio
        final command = includeScreen
            ? (Platform.isWindows
                ? await _buildWindowsFfmpegCommand(outputPath)
                : await _buildLinuxFfmpegCommand(outputPath))
            : (Platform.isWindows
                ? await _buildAudioOnlyWindowsCommand(outputPath)
                : await _buildAudioOnlyLinuxCommand(outputPath));
        LogService().log(
          'ConferenceRecordingService: ffmpeg ${command.join(' ')}',
        );
        final process = await Process.start(
          'ffmpeg',
          command,
          runInShell: false,
        );

        _process = process;

        unawaited(_logProcessOutput(process.stderr));
        unawaited(_logProcessOutput(process.stdout));
      }

      _setState(ConferenceRecordingState.recording);
      LogService().log(
        'ConferenceRecordingService: Recording started '
        '(screen=${includeScreen ? "on" : "off"}) at $outputPath',
      );
    } catch (error) {
      _lastError = '$error';
      _setState(ConferenceRecordingState.failed);
      await _cleanupTempArtifacts();
      rethrow;
    }
  }

  Future<String?> stop() async {
    _setState(ConferenceRecordingState.stopping);
    final outputPath = _tempOutputPath;

    if (Platform.isAndroid && _androidRecorder != null) {
      try {
        final result = await _androidRecorder!.stop();
        _androidRecorder = null;
        final path = result ?? outputPath;
        _setState(ConferenceRecordingState.idle);
        return path;
      } catch (error) {
        _lastError = '$error';
        _androidRecorder = null;
        _setState(ConferenceRecordingState.failed);
        return outputPath;
      }
    }

    if (_isWaylandRecording) {
      return _stopWaylandRecording(outputPath);
    }

    final process = _process;
    if (process == null) {
      _setState(ConferenceRecordingState.idle);
      return outputPath;
    }

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

    _checkOutputFile(outputPath);
    return outputPath;
  }

  Future<void> dispose() async {
    if (_process != null || _isWaylandRecording) {
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

  // ---------------------------------------------------------------------------
  // Availability
  // ---------------------------------------------------------------------------

  Future<bool> _checkAvailability() async {
    if (kIsWeb) {
      _lastError = 'Meeting recording is not implemented for browser hosts yet';
      return false;
    }

    if (Platform.isAndroid) {
      return true;
    }

    if (!Platform.isLinux && !Platform.isWindows) {
      _lastError =
          'Meeting recording supports Linux, Windows, and Android only';
      return false;
    }

    if (Platform.isLinux && _isWayland()) {
      return _checkWaylandAvailability();
    }

    final whichCmd = Platform.isWindows ? 'where' : 'which';
    final ffmpeg = await Process.run(whichCmd, ['ffmpeg']);
    if (ffmpeg.exitCode != 0) {
      _lastError = 'ffmpeg is not installed on this system';
      return false;
    }

    if (Platform.isLinux) {
      final display = Platform.environment['DISPLAY'];
      if (display == null || display.isEmpty) {
        _lastError = 'DISPLAY is not available for desktop capture';
        return false;
      }
    }

    return true;
  }

  bool _isWayland() {
    final sessionType = Platform.environment['XDG_SESSION_TYPE'];
    if (sessionType == 'wayland') return true;
    final waylandDisplay = Platform.environment['WAYLAND_DISPLAY'];
    return waylandDisplay != null && waylandDisplay.isNotEmpty;
  }

  Future<bool> _checkWaylandAvailability() async {
    // Check for GNOME Shell Screencast D-Bus interface
    final result = await Process.run('gdbus', [
      'introspect',
      '--session',
      '--dest',
      'org.gnome.Shell.Screencast',
      '--object-path',
      '/org/gnome/Shell/Screencast',
    ]);
    if (result.exitCode == 0) {
      // Also need ffmpeg for audio capture + merge
      final ffmpeg = await Process.run('which', ['ffmpeg']);
      if (ffmpeg.exitCode != 0) {
        _lastError = 'ffmpeg is required for audio capture';
        return false;
      }
      return true;
    }

    _lastError = 'Wayland screen recording requires GNOME Shell '
        '(org.gnome.Shell.Screencast not found)';
    return false;
  }

  // ---------------------------------------------------------------------------
  // Wayland (GNOME Screencast) backend
  // ---------------------------------------------------------------------------

  Future<void> _startWaylandRecording(
    String tempDirPath,
    String finalOutputPath,
  ) async {
    _isWaylandRecording = true;

    // Connect to session bus — stays alive to keep GNOME Screencast running.
    // GNOME kills the recording if the D-Bus sender disconnects.
    _dbusClient = DBusClient.session();
    final screencast = DBusRemoteObject(
      _dbusClient!,
      name: 'org.gnome.Shell.Screencast',
      path: DBusObjectPath('/org/gnome/Shell/Screencast'),
    );

    // Start GNOME Shell Screencast via D-Bus
    // Pass filename without extension — GNOME 46+ adds its own
    final videoTemplate = p.join(tempDirPath, 'screencast');
    _screencastVideoPath = videoTemplate;

    final result = await screencast.callMethod(
      'org.gnome.Shell.Screencast',
      'Screencast',
      [
        DBusString(videoTemplate),
        DBusDict.stringVariant({'framerate': DBusUint32(12)}),
      ],
    );

    final success = result.values[0].asBoolean();
    final filename = result.values[1].asString();

    if (!success) {
      _isWaylandRecording = false;
      await _dbusClient?.close();
      _dbusClient = null;
      throw StateError('GNOME Screencast failed: $filename');
    }

    _screencastVideoPath = filename;
    LogService().log(
      'ConferenceRecordingService: GNOME Screencast → $filename',
    );

    // Audio: ffmpeg capturing PulseAudio (works on Wayland via PipeWire-pulse)
    final pulseSources = await _detectPulseSources();
    final audioSource = pulseSources.monitorSource ?? 'default';
    final audioPath = p.join(tempDirPath, 'audio.m4a');
    _audioOutputPath = audioPath;

    final audioArgs = <String>[
      '-y',
      '-f',
      'pulse',
      '-i',
      audioSource,
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      audioPath,
    ];

    // Also capture mic and mix if available
    if (pulseSources.micSource != null &&
        pulseSources.micSource!.isNotEmpty &&
        pulseSources.micSource != pulseSources.monitorSource) {
      audioArgs.clear();
      audioArgs.addAll([
        '-y',
        '-f', 'pulse', '-i', audioSource,
        '-f', 'pulse', '-i', pulseSources.micSource!,
        '-filter_complex',
        '[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=2[aout]',
        '-map', '[aout]',
        '-c:a', 'aac', '-b:a', '128k',
        audioPath,
      ]);
    }

    LogService().log(
      'ConferenceRecordingService: audio ffmpeg ${audioArgs.join(' ')}',
    );
    _audioProcess = await Process.start('ffmpeg', audioArgs);
    unawaited(_logProcessOutput(_audioProcess!.stderr));
    unawaited(_logProcessOutput(_audioProcess!.stdout));
  }

  Future<String?> _stopWaylandRecording(String? finalOutputPath) async {
    // Stop GNOME Screencast via D-Bus
    final client = _dbusClient;
    if (client != null) {
      try {
        final screencast = DBusRemoteObject(
          client,
          name: 'org.gnome.Shell.Screencast',
          path: DBusObjectPath('/org/gnome/Shell/Screencast'),
        );
        await screencast
            .callMethod(
              'org.gnome.Shell.Screencast',
              'StopScreencast',
              [],
            )
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        LogService().log(
          'ConferenceRecordingService: Error stopping screencast: $e',
        );
      }
      await client.close();
      _dbusClient = null;
    }

    // Stop audio ffmpeg
    final audioProc = _audioProcess;
    if (audioProc != null) {
      try {
        audioProc.stdin.writeln('q');
        await audioProc.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            audioProc.kill(ProcessSignal.sigint);
            return audioProc.exitCode;
          },
        );
      } catch (_) {
        audioProc.kill(ProcessSignal.sigint);
      }
      _audioProcess = null;
    }

    // Brief pause to let files finalize
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // Merge video + audio into final MP4
    final videoPath = _screencastVideoPath;
    final audioPath = _audioOutputPath;
    _isWaylandRecording = false;
    _screencastVideoPath = null;
    _audioOutputPath = null;

    if (finalOutputPath != null &&
        videoPath != null &&
        await File(videoPath).exists()) {
      final hasAudio =
          audioPath != null && await File(audioPath).exists() &&
          await File(audioPath).length() > 100;

      if (hasAudio) {
        // Merge video + audio
        LogService().log(
          'ConferenceRecordingService: Merging video + audio',
        );
        final merge = await Process.run('ffmpeg', [
          '-y',
          '-i', videoPath,
          '-i', audioPath,
          '-c:v', 'copy',
          '-c:a', 'copy',
          '-map', '0:v',
          '-map', '1:a',
          '-movflags', '+faststart',
          finalOutputPath,
        ]);
        if (merge.exitCode != 0) {
          LogService().log(
            'ConferenceRecordingService: Merge failed '
            '(${merge.stderr}), using video-only',
          );
          await File(videoPath).copy(finalOutputPath);
        }
      } else {
        // Video only
        await File(videoPath).copy(finalOutputPath);
      }
    }

    _checkOutputFile(finalOutputPath);

    _setState(
      _lastError == null
          ? ConferenceRecordingState.idle
          : ConferenceRecordingState.failed,
    );
    return finalOutputPath;
  }

  // ---------------------------------------------------------------------------
  // X11 (ffmpeg x11grab) backend
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Windows (ffmpeg gdigrab) backend
  // ---------------------------------------------------------------------------

  Future<List<String>> _buildWindowsFfmpegCommand(String outputPath) async {
    final audioDevice = await _detectWindowsAudioDevice();

    final args = <String>[
      '-y',
      '-f',
      'gdigrab',
      '-framerate',
      '12',
      '-i',
      'desktop',
    ];

    final audioInputs = <String>[];
    if (audioDevice != null && audioDevice.isNotEmpty) {
      args.addAll([
        '-f',
        'dshow',
        '-i',
        'audio=$audioDevice',
      ]);
      audioInputs.add(audioDevice);
    }

    if (audioInputs.isNotEmpty) {
      args.addAll(['-map', '0:v', '-map', '1:a']);
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

  Future<String?> _detectWindowsAudioDevice() async {
    try {
      final result = await Process.run('ffmpeg', [
        '-hide_banner',
        '-list_devices',
        'true',
        '-f',
        'dshow',
        '-i',
        'dummy',
      ]);
      final output = [
        result.stdout as String? ?? '',
        result.stderr as String? ?? '',
      ].join('\n');

      // Look for audio devices: lines containing "(audio)" with a quoted name
      for (final line in const LineSplitter().convert(output)) {
        if (!line.contains('(audio)')) continue;
        final match = RegExp(r'"([^"]+)"').firstMatch(line);
        if (match != null) {
          final name = match.group(1);
          if (name != null && name.isNotEmpty) {
            // Prefer Stereo Mix / virtual audio cable for system audio
            if (name.toLowerCase().contains('stereo mix') ||
                name.toLowerCase().contains('virtual') ||
                name.toLowerCase().contains('loopback')) {
              return name;
            }
          }
        }
      }

      // Fallback: return first audio device found
      for (final line in const LineSplitter().convert(output)) {
        if (!line.contains('(audio)')) continue;
        final match = RegExp(r'"([^"]+)"').firstMatch(line);
        if (match != null) {
          return match.group(1);
        }
      }
    } catch (_) {}
    return null;
  }

  // ---------------------------------------------------------------------------
  // Audio-only backends (no screen capture — privacy-safe default)
  // ---------------------------------------------------------------------------

  Future<List<String>> _buildAudioOnlyLinuxCommand(String outputPath) async {
    final pulseSources = await _detectPulseSources();
    final args = <String>['-y'];

    final audioInputs = <String>[];
    if (pulseSources.monitorSource != null &&
        pulseSources.monitorSource!.isNotEmpty) {
      args.addAll([
        '-thread_queue_size', '512',
        '-f', 'pulse', '-i', pulseSources.monitorSource!,
      ]);
      audioInputs.add(pulseSources.monitorSource!);
    }
    if (pulseSources.micSource != null &&
        pulseSources.micSource!.isNotEmpty &&
        pulseSources.micSource != pulseSources.monitorSource) {
      args.addAll([
        '-thread_queue_size', '512',
        '-f', 'pulse', '-i', pulseSources.micSource!,
      ]);
      audioInputs.add(pulseSources.micSource!);
    }

    if (audioInputs.length >= 2) {
      args.addAll([
        '-filter_complex',
        '[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=2[aout]',
        '-map', '[aout]',
      ]);
    } else if (audioInputs.isEmpty) {
      // Fallback to default PulseAudio source
      args.addAll(['-f', 'pulse', '-i', 'default']);
    }

    args.addAll(['-c:a', 'aac', '-b:a', '128k', outputPath]);
    return args;
  }

  Future<List<String>> _buildAudioOnlyWindowsCommand(String outputPath) async {
    final audioDevice = await _detectWindowsAudioDevice();
    final args = <String>['-y'];

    if (audioDevice != null && audioDevice.isNotEmpty) {
      args.addAll(['-f', 'dshow', '-i', 'audio=$audioDevice']);
    } else {
      throw StateError('No audio device found for recording');
    }

    args.addAll(['-c:a', 'aac', '-b:a', '128k', outputPath]);
    return args;
  }

  // ---------------------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------------------

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
        if (text.isEmpty) continue;
        LogService().log('ConferenceRecordingService: $text');
        // Detect ffmpeg errors
        if (RegExp(r'Error|Permission denied|No such|Cannot|Failed',
                caseSensitive: false)
            .hasMatch(text)) {
          _lastError = text.length > 200 ? text.substring(0, 200) : text;
        }
      }
    } catch (_) {}
  }

  void _checkOutputFile(String? outputPath) {
    if (outputPath == null) return;
    try {
      final file = File(outputPath);
      if (file.existsSync()) {
        final size = file.lengthSync();
        if (size < 1024) {
          LogService().log(
            'ConferenceRecordingService: WARNING output file is only '
            '$size bytes — recording likely failed',
          );
        }
      } else {
        LogService().log(
          'ConferenceRecordingService: WARNING output file does not exist',
        );
      }
    } catch (_) {}
  }

  Future<void> _cleanupTempArtifacts() async {
    _isWaylandRecording = false;
    _screencastVideoPath = null;
    _audioOutputPath = null;
    _audioProcess = null;
    try {
      await _dbusClient?.close();
    } catch (_) {}
    _dbusClient = null;
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
