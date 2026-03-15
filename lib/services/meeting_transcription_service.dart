/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../bot/models/whisper_model_info.dart';
import '../bot/services/speech_to_text_service.dart';
import '../bot/services/whisper_model_manager.dart';
import '../models/conference_archive_entry.dart';
import '../models/monitored_task.dart';
import '../services/conference_archive_service.dart';
import '../services/log_service.dart';
import '../services/task_monitor_service.dart';
import '../work/utils/voicememo_transcription_service.dart';

/// Result of a meeting recording transcription
class MeetingTranscriptionResult {
  final bool success;
  final String? text;
  final String? model;
  final String? error;
  final bool cancelled;
  final List<MeetingTranscriptionSegment>? segments;

  const MeetingTranscriptionResult({
    required this.success,
    this.text,
    this.model,
    this.error,
    this.cancelled = false,
    this.segments,
  });

  factory MeetingTranscriptionResult.success({
    required String text,
    required String model,
    List<MeetingTranscriptionSegment>? segments,
  }) {
    return MeetingTranscriptionResult(
      success: true,
      text: text,
      model: model,
      segments: segments,
    );
  }

  factory MeetingTranscriptionResult.failure(String error) {
    return MeetingTranscriptionResult(success: false, error: error);
  }

  factory MeetingTranscriptionResult.cancelled() {
    return const MeetingTranscriptionResult(success: false, cancelled: true);
  }
}

/// A timestamped segment from meeting transcription
class MeetingTranscriptionSegment {
  final Duration from;
  final Duration to;
  final String text;

  const MeetingTranscriptionSegment({
    required this.from,
    required this.to,
    required this.text,
  });
}

/// Event emitted when a background meeting transcription completes
class MeetingTranscriptionCompletedEvent {
  final String archiveRelativePath;
  final String recordingName;
  final MeetingTranscriptionResult? result;
  final String? error;

  const MeetingTranscriptionCompletedEvent({
    required this.archiveRelativePath,
    required this.recordingName,
    this.result,
    this.error,
  });

  bool get success => result != null && result!.success;
}

/// Service for transcribing meeting recordings using Whisper
///
/// Handles:
/// - MP4 to WAV audio extraction via ffmpeg
/// - Audio splitting for long recordings (>10min chunks)
/// - Timestamped transcription via SpeechToTextService
/// - Progress reporting and cancellation
class MeetingTranscriptionService {
  static final MeetingTranscriptionService _instance =
      MeetingTranscriptionService._internal();
  factory MeetingTranscriptionService() => _instance;
  MeetingTranscriptionService._internal();

  final SpeechToTextService _sttService = SpeechToTextService();
  final WhisperModelManager _modelManager = WhisperModelManager();

  bool _isCancelled = false;
  String? _currentRecordingName;
  TranscriptionProgress _currentProgress = const TranscriptionProgress(
    state: TranscriptionState.idle,
  );

  final _progressController = StreamController<TranscriptionProgress>.broadcast();
  final _completionController =
      StreamController<MeetingTranscriptionCompletedEvent>.broadcast();

  static const _taskId = 'meeting_transcription.transcribe';

  String? _currentArchivePath;

  /// Stream of detailed progress updates
  Stream<TranscriptionProgress> get progressStream => _progressController.stream;

  /// Stream of completion events (for background transcriptions)
  Stream<MeetingTranscriptionCompletedEvent> get completionStream =>
      _completionController.stream;

  /// Archive path of the entry currently being transcribed
  String? get currentArchivePath => _currentArchivePath;

  /// Current detailed progress
  TranscriptionProgress get currentProgress => _currentProgress;

  /// Name of the recording currently being transcribed
  String? get currentRecordingName => _currentRecordingName;

  /// Whether a transcription is in progress
  bool get isBusy => _currentProgress.state != TranscriptionState.idle;

  void _setProgress(TranscriptionProgress progress) {
    _currentProgress = progress;
    _progressController.add(progress);
  }

  /// Initialize the service
  Future<void> initialize() async {
    await _modelManager.initialize();
    await _sttService.initialize();
  }

  /// Transcribe a meeting recording from an MP4 file
  Future<MeetingTranscriptionResult> transcribeRecording({
    required String mp4Path,
    required String recordingName,
  }) async {
    if (isBusy) {
      return MeetingTranscriptionResult.failure(
        'Another transcription is in progress',
      );
    }

    _currentRecordingName = recordingName;
    _isCancelled = false;

    if (kDebugMode) {
      LogService().log(
        'MeetingTranscriptionService: WARNING - Running in debug mode. '
        'Whisper transcription will be extremely slow.',
      );
    }

    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final wavPath = '${tempDir.path}/meeting_$timestamp.wav';
    final chunksDir = Directory('${tempDir.path}/meeting_chunks_$timestamp');

    try {
      await initialize();

      // Get preferred model
      final modelId = await _modelManager.getPreferredModel();
      final modelInfo = WhisperModels.getById(modelId);
      final modelName = modelInfo?.name ?? modelId;
      final modelSize = modelInfo?.size ?? 0;

      _setProgress(TranscriptionProgress(
        state: TranscriptionState.preparing,
        modelName: modelName,
        message: 'Checking model...',
      ));
      await Future.delayed(Duration.zero);

      // Download model if needed
      if (!await _modelManager.isDownloaded(modelId)) {
        await for (final progress in _modelManager.downloadModel(modelId)) {
          if (_isCancelled) return MeetingTranscriptionResult.cancelled();
          final bytesDownloaded = (progress * modelSize).round();
          _setProgress(TranscriptionProgress(
            state: TranscriptionState.downloadingModel,
            progress: progress,
            bytesDownloaded: bytesDownloaded,
            totalBytes: modelSize,
            modelName: modelName,
            message: 'Downloading $modelName...',
          ));
        }
      }

      if (_isCancelled) return MeetingTranscriptionResult.cancelled();

      // Load model if needed
      if (!_sttService.isModelLoaded || _sttService.loadedModelId != modelId) {
        _setProgress(TranscriptionProgress(
          state: TranscriptionState.loadingModel,
          progress: 0.0,
          modelName: modelName,
          message: 'Loading $modelName into memory...',
        ));
        await Future.delayed(Duration.zero);

        final loaded = await _sttService.loadModel(modelId);
        if (!loaded) {
          return MeetingTranscriptionResult.failure('Failed to load model');
        }
        await Future.delayed(Duration.zero);

        _setProgress(TranscriptionProgress(
          state: TranscriptionState.loadingModel,
          progress: 0.5,
          modelName: modelName,
          message: 'Warming up model...',
        ));
        await Future.delayed(Duration.zero);

        await _sttService.ensureModelWarm(modelId);
        await Future.delayed(Duration.zero);
      }

      if (_isCancelled) return MeetingTranscriptionResult.cancelled();

      // Extract audio from MP4
      _setProgress(TranscriptionProgress(
        state: TranscriptionState.convertingAudio,
        progress: 0.0,
        modelName: modelName,
        message: 'Extracting audio from recording...',
      ));
      await Future.delayed(Duration.zero);

      final extractOk = await _extractAudioToWav(mp4Path, wavPath);
      if (!extractOk) {
        return MeetingTranscriptionResult.failure(
          'Failed to extract audio from recording. Is ffmpeg installed?',
        );
      }

      if (_isCancelled) return MeetingTranscriptionResult.cancelled();

      // Get audio duration
      final durationSeconds = await _getAudioDuration(wavPath);

      // Split into chunks if needed (>10 minutes)
      final chunkPaths = await _splitIfNeeded(
        wavPath,
        durationSeconds,
        chunksDir,
      );

      if (_isCancelled) return MeetingTranscriptionResult.cancelled();

      // Transcribe each chunk
      final allSegments = <MeetingTranscriptionSegment>[];
      final textParts = <String>[];
      var chunkOffset = Duration.zero;

      for (var i = 0; i < chunkPaths.length; i++) {
        if (_isCancelled) return MeetingTranscriptionResult.cancelled();

        final chunkProgress = chunkPaths.length > 1
            ? ' (${i + 1}/${chunkPaths.length})'
            : '';
        _setProgress(TranscriptionProgress(
          state: TranscriptionState.transcribing,
          progress: i / chunkPaths.length,
          modelName: modelName,
          message: 'Transcribing audio$chunkProgress...',
        ));
        await Future.delayed(Duration.zero);

        final result = await _sttService.transcribeWithTimestamps(chunkPaths[i]);

        if (!result.success) {
          LogService().log(
            'MeetingTranscriptionService: Chunk $i failed: ${result.error}',
          );
          continue;
        }

        textParts.add(result.text);

        if (result.segments != null) {
          for (final seg in result.segments!) {
            allSegments.add(MeetingTranscriptionSegment(
              from: seg.from + chunkOffset,
              to: seg.to + chunkOffset,
              text: seg.text,
            ));
          }
        }

        // Calculate offset for next chunk (10 minutes per chunk)
        chunkOffset += const Duration(minutes: 10);
      }

      if (textParts.isEmpty) {
        return MeetingTranscriptionResult.failure('No speech detected');
      }

      // Format transcript with timestamps
      final formattedText = _formatTranscript(allSegments, textParts.join(' '));

      LogService().log(
        'MeetingTranscriptionService: Transcription complete '
        '(${formattedText.length} chars, ${allSegments.length} segments)',
      );

      return MeetingTranscriptionResult.success(
        text: formattedText,
        model: modelId,
        segments: allSegments,
      );
    } catch (e) {
      LogService().log('MeetingTranscriptionService: Error: $e');
      return MeetingTranscriptionResult.failure(e.toString());
    } finally {
      _currentRecordingName = null;
      _setProgress(const TranscriptionProgress(
        state: TranscriptionState.idle,
      ));

      // Cleanup temp files
      await _safeDelete(wavPath);
      if (await chunksDir.exists()) {
        try {
          await chunksDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Start a background transcription that saves the result when complete.
  ///
  /// Returns immediately after starting. The transcription runs in background
  /// and saves directly to the archive, even if the UI navigates away.
  /// Listen to [completionStream] to be notified when done.
  bool transcribeInBackground({
    required ConferenceArchiveEntry entry,
    required ConferenceArchiveAsset recording,
    int? maxDurationSeconds,
  }) {
    if (isBusy) {
      LogService().log(
        'MeetingTranscriptionService: Cannot start background transcription - busy',
      );
      return false;
    }

    _currentArchivePath = entry.relativePath;

    LogService().log(
      'MeetingTranscriptionService: Starting background transcription '
      'for ${recording.name}',
    );

    TaskMonitorService().register(MonitoredTask(
      id: _taskId,
      name: 'Meeting Transcription',
      description: 'Transcribing recording: ${recording.name}',
      serviceName: 'MeetingTranscription',
      priority: TaskPriority.normal,
      type: TaskType.oneshot,
    ));
    TaskMonitorService().reportStart(_taskId);

    // Fire and forget
    _runBackgroundTranscription(entry, recording, maxDurationSeconds);
    return true;
  }

  /// Internal method that runs the transcription and saves the result
  Future<void> _runBackgroundTranscription(
    ConferenceArchiveEntry entry,
    ConferenceArchiveAsset recording,
    int? maxDurationSeconds,
  ) async {
    try {
      // Export MP4 to temp path
      final mp4Path =
          await ConferenceArchiveService().exportArchiveFileToTemporaryPath(
        entry,
        recording.relativePath,
      );
      if (mp4Path == null) {
        const error = 'Unable to export recording';
        LogService().log('MeetingTranscriptionService: $error');
        TaskMonitorService().reportFailure(_taskId, error);
        _completionController.add(MeetingTranscriptionCompletedEvent(
          archiveRelativePath: entry.relativePath,
          recordingName: recording.name,
          error: error,
        ));
        return;
      }

      // Check duration before expensive WAV conversion
      if (maxDurationSeconds != null) {
        final duration = await _getAudioDuration(mp4Path);
        if (duration > maxDurationSeconds) {
          LogService().log(
            'MeetingTranscriptionService: Skipping ${recording.name} — '
            '${duration.round()}s exceeds max ${maxDurationSeconds}s',
          );
          await _safeDelete(mp4Path);
          TaskMonitorService().reportFailure(_taskId, 'exceeds_max_duration');
          _completionController.add(MeetingTranscriptionCompletedEvent(
            archiveRelativePath: entry.relativePath,
            recordingName: recording.name,
            error: 'exceeds_max_duration',
          ));
          return;
        }
      }

      final result = await transcribeRecording(
        mp4Path: mp4Path,
        recordingName: recording.name,
      );

      if (result.cancelled) {
        LogService().log(
          'MeetingTranscriptionService: Background transcription cancelled '
          'for ${recording.name}',
        );
        TaskMonitorService().reportFailure(_taskId, 'Cancelled');
        _completionController.add(MeetingTranscriptionCompletedEvent(
          archiveRelativePath: entry.relativePath,
          recordingName: recording.name,
          error: 'Transcription cancelled',
        ));
        return;
      }

      if (!result.success) {
        final error = result.error ?? 'Transcription failed';
        LogService().log(
          'MeetingTranscriptionService: Background transcription failed '
          'for ${recording.name}: $error',
        );
        TaskMonitorService().reportFailure(_taskId, error);
        _completionController.add(MeetingTranscriptionCompletedEvent(
          archiveRelativePath: entry.relativePath,
          recordingName: recording.name,
          error: error,
        ));
        return;
      }

      // Save transcript to archive
      await ConferenceArchiveService().writeTranscriptForRecording(
        entry,
        recording.name,
        result.text!,
      );

      LogService().log(
        'MeetingTranscriptionService: Background transcription saved '
        'for ${recording.name}',
      );

      TaskMonitorService().reportSuccess(_taskId);
      _completionController.add(MeetingTranscriptionCompletedEvent(
        archiveRelativePath: entry.relativePath,
        recordingName: recording.name,
        result: result,
      ));
    } catch (e) {
      LogService().log(
        'MeetingTranscriptionService: Background transcription error '
        'for ${recording.name}: $e',
      );
      TaskMonitorService().reportFailure(_taskId, e);
      _completionController.add(MeetingTranscriptionCompletedEvent(
        archiveRelativePath: entry.relativePath,
        recordingName: recording.name,
        error: e.toString(),
      ));
    } finally {
      _currentArchivePath = null;
      TaskMonitorService().unregister(_taskId);
    }
  }

  /// Cancel the current transcription
  Future<void> cancel() async {
    if (!isBusy) return;
    _isCancelled = true;
    _setProgress(const TranscriptionProgress(
      state: TranscriptionState.cancelling,
      message: 'Cancelling...',
    ));
    LogService().log(
      'MeetingTranscriptionService: Cancelled transcription for $_currentRecordingName',
    );
  }

  /// Extract audio from MP4 to 16kHz mono WAV
  Future<bool> _extractAudioToWav(String mp4Path, String wavPath) async {
    try {
      final result = await Process.run('ffmpeg', [
        '-i', mp4Path,
        '-ar', '16000',
        '-ac', '1',
        '-y',
        wavPath,
      ]);
      if (result.exitCode != 0) {
        LogService().log(
          'MeetingTranscriptionService: ffmpeg extraction failed: ${result.stderr}',
        );
        return false;
      }
      return true;
    } catch (e) {
      LogService().log(
        'MeetingTranscriptionService: ffmpeg not available: $e',
      );
      return false;
    }
  }

  /// Get audio duration in seconds using ffprobe
  Future<double> _getAudioDuration(String audioPath) async {
    try {
      final result = await Process.run('ffprobe', [
        '-i', audioPath,
        '-show_entries', 'format=duration',
        '-v', 'quiet',
        '-of', 'csv=p=0',
      ]);
      if (result.exitCode == 0) {
        final output = (result.stdout as String).trim();
        return double.tryParse(output) ?? 0;
      }
    } catch (e) {
      LogService().log(
        'MeetingTranscriptionService: ffprobe not available: $e',
      );
    }
    return 0;
  }

  /// Split audio into 10-minute chunks if longer than 10 minutes
  Future<List<String>> _splitIfNeeded(
    String wavPath,
    double durationSeconds,
    Directory chunksDir,
  ) async {
    if (durationSeconds <= 600) {
      return [wavPath];
    }

    LogService().log(
      'MeetingTranscriptionService: Splitting ${durationSeconds.round()}s audio into chunks',
    );

    await chunksDir.create(recursive: true);
    final outputPattern = '${chunksDir.path}/chunk_%03d.wav';

    try {
      final result = await Process.run('ffmpeg', [
        '-i', wavPath,
        '-f', 'segment',
        '-segment_time', '600',
        '-ar', '16000',
        '-ac', '1',
        '-y',
        outputPattern,
      ]);

      if (result.exitCode != 0) {
        LogService().log(
          'MeetingTranscriptionService: Split failed: ${result.stderr}',
        );
        return [wavPath]; // Fall back to full file
      }

      final chunks = await chunksDir.list().toList();
      final chunkPaths = chunks
          .whereType<File>()
          .map((f) => f.path)
          .toList()
        ..sort();

      if (chunkPaths.isEmpty) {
        return [wavPath];
      }

      LogService().log(
        'MeetingTranscriptionService: Split into ${chunkPaths.length} chunks',
      );
      return chunkPaths;
    } catch (e) {
      LogService().log(
        'MeetingTranscriptionService: Split error: $e',
      );
      return [wavPath];
    }
  }

  /// Format segments into a timestamped transcript grouped by paragraphs.
  ///
  /// Segments are grouped into paragraphs when the gap between the previous
  /// segment's end and the next segment's start exceeds 5 seconds. Each
  /// paragraph is prefixed with the start time of its first segment.
  String _formatTranscript(
    List<MeetingTranscriptionSegment> segments,
    String fallbackText,
  ) {
    if (segments.isEmpty) return fallbackText;

    final paragraphs = <String>[];
    var paragraphStart = segments.first.from;
    var paragraphTexts = <String>[segments.first.text];

    for (var i = 1; i < segments.length; i++) {
      final gap = segments[i].from - segments[i - 1].to;
      if (gap.inMilliseconds > 5000) {
        // Flush current paragraph
        paragraphs.add(
          '[${_formatDuration(paragraphStart)}] '
          '${paragraphTexts.join(' ').trim()}',
        );
        paragraphStart = segments[i].from;
        paragraphTexts = [segments[i].text];
      } else {
        paragraphTexts.add(segments[i].text);
      }
    }
    // Flush last paragraph
    paragraphs.add(
      '[${_formatDuration(paragraphStart)}] '
      '${paragraphTexts.join(' ').trim()}',
    );

    return paragraphs.join('\n\n');
  }

  /// Format a Duration as HH:MM:SS
  static String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  Future<void> _safeDelete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  void dispose() {
    cancel();
    _progressController.close();
    _completionController.close();
  }
}
