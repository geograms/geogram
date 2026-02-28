/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../bot/models/whisper_model_info.dart';
import '../../bot/services/speech_to_text_service.dart';
import '../../bot/services/whisper_model_manager.dart';
import '../../services/log_service.dart';
import '../models/voicememo_content.dart';
import '../services/ndf_service.dart';

/// Result of a voice memo transcription
class VoiceMemoTranscriptionResult {
  final bool success;
  final String? text;
  final String? model;
  final String? error;
  final bool cancelled;

  const VoiceMemoTranscriptionResult({
    required this.success,
    this.text,
    this.model,
    this.error,
    this.cancelled = false,
  });

  factory VoiceMemoTranscriptionResult.success({
    required String text,
    required String model,
  }) {
    return VoiceMemoTranscriptionResult(
      success: true,
      text: text,
      model: model,
    );
  }

  factory VoiceMemoTranscriptionResult.failure(String error) {
    return VoiceMemoTranscriptionResult(
      success: false,
      error: error,
    );
  }

  factory VoiceMemoTranscriptionResult.cancelled() {
    return const VoiceMemoTranscriptionResult(
      success: false,
      cancelled: true,
    );
  }

  ClipTranscription? toClipTranscription() {
    if (!success || text == null) return null;
    return ClipTranscription(
      text: text!,
      model: model ?? 'whisper',
      transcribedAt: DateTime.now(),
    );
  }
}

/// State of the transcription service
enum TranscriptionState {
  idle,
  preparing,
  downloadingModel,
  loadingModel,
  convertingAudio,
  transcribing,
  cancelling,
}

/// Event emitted when a background transcription completes
class TranscriptionCompletedEvent {
  final String filePath;
  final String clipId;
  final VoiceMemoClip? updatedClip;
  final String? error;

  const TranscriptionCompletedEvent({
    required this.filePath,
    required this.clipId,
    this.updatedClip,
    this.error,
  });

  bool get success => updatedClip != null;
}

/// Detailed progress information for transcription
class TranscriptionProgress {
  /// Current state
  final TranscriptionState state;

  /// Progress percentage (0.0 - 1.0)
  final double progress;

  /// Bytes downloaded (for download state)
  final int bytesDownloaded;

  /// Total bytes to download
  final int totalBytes;

  /// Model name being used
  final String? modelName;

  /// Human-readable status message
  final String message;

  /// File path of the document being transcribed (for background transcription)
  final String? filePath;

  const TranscriptionProgress({
    required this.state,
    this.progress = 0.0,
    this.bytesDownloaded = 0,
    this.totalBytes = 0,
    this.modelName,
    this.message = '',
    this.filePath,
  });

  /// Format bytes to human-readable string (e.g., "45.2 MB")
  static String formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  /// Get download progress string (e.g., "45.2 MB / 141.0 MB")
  String get downloadProgressString {
    if (totalBytes == 0) return '';
    return '${formatBytes(bytesDownloaded)} / ${formatBytes(totalBytes)}';
  }

  /// Get progress percentage as integer (0-100)
  int get progressPercent => (progress * 100).round();
}

/// Service for transcribing voice memo clips using Whisper
///
/// This service provides:
/// - Background transcription that doesn't block UI
/// - Cancellation support at any time
/// - Single session enforcement (only 1 transcription at a time)
/// - In-memory whisper via whisper_flutter_new (Android, iOS, macOS, Linux)
///
/// Models are auto-downloaded from HuggingFace on first use.
class VoiceMemoTranscriptionService {
  static final VoiceMemoTranscriptionService _instance =
      VoiceMemoTranscriptionService._internal();
  factory VoiceMemoTranscriptionService() => _instance;
  VoiceMemoTranscriptionService._internal();

  final SpeechToTextService _sttService = SpeechToTextService();
  final WhisperModelManager _modelManager = WhisperModelManager();
  final NdfService _ndfService = NdfService();

  TranscriptionState _state = TranscriptionState.idle;
  String? _currentClipId;
  String? _currentFilePath;
  VoiceMemoClip? _currentClip;
  bool _isCancelled = false;
  TranscriptionProgress _currentProgress = const TranscriptionProgress(
    state: TranscriptionState.idle,
  );

  final _stateController = StreamController<TranscriptionState>.broadcast();
  final _progressController = StreamController<TranscriptionProgress>.broadcast();
  final _completionController = StreamController<TranscriptionCompletedEvent>.broadcast();

  /// Stream of state changes
  Stream<TranscriptionState> get stateStream => _stateController.stream;

  /// Stream of detailed progress updates
  Stream<TranscriptionProgress> get progressStream => _progressController.stream;

  /// Stream of completion events (for background transcriptions)
  Stream<TranscriptionCompletedEvent> get completionStream => _completionController.stream;

  /// Current state
  TranscriptionState get state => _state;

  /// Current detailed progress
  TranscriptionProgress get currentProgress => _currentProgress;

  /// Current download progress (0.0 - 1.0) - for backward compatibility
  double get downloadProgress => _currentProgress.progress;

  /// ID of the clip currently being transcribed
  String? get currentClipId => _currentClipId;

  /// File path of the document currently being transcribed
  String? get currentFilePath => _currentFilePath;

  /// Whether a transcription is in progress
  bool get isBusy => _state != TranscriptionState.idle;

  void _setState(TranscriptionState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  void _setProgress(TranscriptionProgress progress) {
    _currentProgress = progress;
    _state = progress.state;
    _stateController.add(progress.state);
    _progressController.add(progress);
  }

  /// Initialize the service
  Future<void> initialize() async {
    await _modelManager.initialize();
    await _sttService.initialize();
    LogService().log('VoiceMemoTranscriptionService: Initialized');
  }

  /// Check if transcription is supported on this platform
  Future<bool> isSupported() async {
    await initialize();

    // In-memory whisper (Android, iOS, macOS, Linux)
    if (SpeechToTextService.isSupported) {
      return await _sttService.isLibraryAvailable();
    }

    return false;
  }

  /// Get help message for unsupported platforms
  String getInstallHelp() {
    if (SpeechToTextService.isSupported) {
      return 'Speech model will be downloaded automatically on first use.';
    }

    return 'Speech-to-text is not available on this platform.';
  }

  /// Transcribe a voice memo clip
  ///
  /// [audioBytes] - The audio data (OGG/Opus format)
  /// [clipId] - ID of the clip being transcribed (for tracking)
  ///
  /// Returns a [VoiceMemoTranscriptionResult] with the transcription or error.
  /// Can be cancelled at any time using [cancel].
  Future<VoiceMemoTranscriptionResult> transcribe({
    required List<int> audioBytes,
    required String clipId,
  }) async {
    // Check if already busy
    if (isBusy) {
      return VoiceMemoTranscriptionResult.failure(
        'Another transcription is in progress',
      );
    }

    await initialize();

    // Use in-memory whisper (Android, iOS, macOS, Linux)
    if (SpeechToTextService.isSupported) {
      return _transcribeWithInMemoryWhisper(audioBytes, clipId);
    } else {
      return VoiceMemoTranscriptionResult.failure(
        'Transcription not supported. ${getInstallHelp()}',
      );
    }
  }

  /// Start a background transcription that auto-saves to the NDF when complete.
  ///
  /// This method returns immediately after starting the transcription.
  /// The transcription runs in the background and saves the result directly
  /// to the NDF file when complete, even if the UI navigates away.
  ///
  /// Listen to [completionStream] to be notified when transcription completes.
  ///
  /// [filePath] - Path to the NDF document
  /// [clip] - The clip to transcribe
  /// [audioBytes] - The audio data (OGG/Opus format)
  ///
  /// Returns true if transcription started, false if busy.
  bool transcribeInBackground({
    required String filePath,
    required VoiceMemoClip clip,
    required List<int> audioBytes,
  }) {
    if (isBusy) {
      LogService().log(
        'VoiceMemoTranscriptionService: Cannot start background transcription - busy',
      );
      return false;
    }

    _currentFilePath = filePath;
    _currentClip = clip;

    LogService().log(
      'VoiceMemoTranscriptionService: Starting background transcription for clip ${clip.id}',
    );

    // Fire and forget - transcription runs in background
    _runBackgroundTranscription(filePath, clip, audioBytes);

    return true;
  }

  /// Internal method that runs the transcription and saves the result
  Future<void> _runBackgroundTranscription(
    String filePath,
    VoiceMemoClip clip,
    List<int> audioBytes,
  ) async {
    try {
      final result = await transcribe(
        audioBytes: audioBytes,
        clipId: clip.id,
      );

      if (result.cancelled) {
        LogService().log(
          'VoiceMemoTranscriptionService: Background transcription cancelled for ${clip.id}',
        );
        _completionController.add(TranscriptionCompletedEvent(
          filePath: filePath,
          clipId: clip.id,
          error: 'Transcription cancelled',
        ));
        return;
      }

      if (!result.success) {
        LogService().log(
          'VoiceMemoTranscriptionService: Background transcription failed for ${clip.id}: ${result.error}',
        );
        _completionController.add(TranscriptionCompletedEvent(
          filePath: filePath,
          clipId: clip.id,
          error: result.error ?? 'Transcription failed',
        ));
        return;
      }

      // Create updated clip with transcription
      final updatedClip = clip.copyWith(
        transcription: result.toClipTranscription(),
      );

      // Save to NDF
      LogService().log(
        'VoiceMemoTranscriptionService: Saving transcription for clip ${clip.id} to $filePath',
      );
      await _ndfService.saveVoiceMemoClip(filePath, updatedClip);
      LogService().log(
        'VoiceMemoTranscriptionService: Transcription saved for clip ${clip.id}',
      );

      // Emit completion event
      _completionController.add(TranscriptionCompletedEvent(
        filePath: filePath,
        clipId: clip.id,
        updatedClip: updatedClip,
      ));
    } catch (e) {
      LogService().log(
        'VoiceMemoTranscriptionService: Background transcription error for ${clip.id}: $e',
      );
      _completionController.add(TranscriptionCompletedEvent(
        filePath: filePath,
        clipId: clip.id,
        error: e.toString(),
      ));
    } finally {
      _currentFilePath = null;
      _currentClip = null;
    }
  }

  /// Transcribe using in-memory whisper (Android, iOS, macOS, Linux)
  Future<VoiceMemoTranscriptionResult> _transcribeWithInMemoryWhisper(
    List<int> audioBytes,
    String clipId,
  ) async {
    _currentClipId = clipId;
    _isCancelled = false;

    // Warn about debug mode performance
    if (kDebugMode) {
      LogService().log(
        'VoiceMemoTranscriptionService: WARNING - Running in debug mode. '
        'Whisper transcription will be extremely slow (100x+ slower). '
        'Use "flutter run --profile" or "--release" for usable performance.',
      );
    }

    // Create temp files
    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final wavPath = '${tempDir.path}/voicememo_$timestamp.wav';

    try {
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
      await Future.delayed(Duration.zero); // Yield to allow UI update

      // Check if model needs to be downloaded
      if (!await _modelManager.isDownloaded(modelId)) {
        LogService().log(
          'VoiceMemoTranscriptionService: Downloading model $modelId ($modelSize bytes)',
        );

        // Download model (yields progress)
        await for (final progress in _modelManager.downloadModel(modelId)) {
          if (_isCancelled) {
            return VoiceMemoTranscriptionResult.cancelled();
          }
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

      if (_isCancelled) return VoiceMemoTranscriptionResult.cancelled();
      await Future.delayed(Duration.zero); // Yield after download check

      // Load model if needed
      if (!_sttService.isModelLoaded || _sttService.loadedModelId != modelId) {
        print('[TRANSCRIBE] >>> Starting model load phase');
        final debugWarning = kDebugMode ? ' (debug mode: very slow!)' : '';
        _setProgress(TranscriptionProgress(
          state: TranscriptionState.loadingModel,
          progress: 0.0,
          modelName: modelName,
          message: 'Loading $modelName into memory...$debugWarning',
        ));
        await Future.delayed(Duration.zero); // Yield to allow UI update

        LogService().log(
          'VoiceMemoTranscriptionService: Loading model $modelId',
        );
        print('[TRANSCRIBE] >>> Calling _sttService.loadModel($modelId)...');

        final loaded = await _sttService.loadModel(modelId);
        print('[TRANSCRIBE] >>> loadModel returned: $loaded');
        if (!loaded) {
          return VoiceMemoTranscriptionResult.failure('Failed to load model');
        }
        await Future.delayed(Duration.zero); // Yield after model load

        print('[TRANSCRIBE] >>> Starting warmup phase');
        final warmupWarning = kDebugMode ? ' (debug mode: may take minutes)' : '';
        _setProgress(TranscriptionProgress(
          state: TranscriptionState.loadingModel,
          progress: 0.5,
          modelName: modelName,
          message: 'Warming up model...$warmupWarning',
        ));
        await Future.delayed(Duration.zero); // Yield to allow UI update

        print('[TRANSCRIBE] >>> Calling _sttService.ensureModelWarm($modelId)...');
        await _sttService.ensureModelWarm(modelId);
        print('[TRANSCRIBE] >>> ensureModelWarm completed');
        await Future.delayed(Duration.zero); // Yield after warmup

        _setProgress(TranscriptionProgress(
          state: TranscriptionState.loadingModel,
          progress: 1.0,
          modelName: modelName,
          message: 'Model ready',
        ));
        await Future.delayed(Duration.zero); // Yield to allow UI update
        print('[TRANSCRIBE] >>> Model ready, proceeding to transcription');
      }

      if (_isCancelled) return VoiceMemoTranscriptionResult.cancelled();
      await Future.delayed(Duration.zero); // Yield after cancelled check

      // Write audio to temp file and convert if needed
      _setProgress(TranscriptionProgress(
        state: TranscriptionState.convertingAudio,
        progress: 0.0,
        modelName: modelName,
        message: 'Preparing audio...',
      ));
      await Future.delayed(Duration.zero); // Yield to allow UI update

      // Check if the audio is already WAV (16kHz mono) by inspecting header
      final isWav = audioBytes.length > 4 &&
          audioBytes[0] == 0x52 && // 'R'
          audioBytes[1] == 0x49 && // 'I'
          audioBytes[2] == 0x46 && // 'F'
          audioBytes[3] == 0x46;   // 'F'

      String? tempOggPath;

      if (isWav) {
        // Already WAV — write directly, no conversion needed
        await File(wavPath).writeAsBytes(audioBytes);
      } else {
        // Legacy OGG/Opus clip — try ffmpeg conversion (desktop only)
        tempOggPath = '${tempDir.path}/voicememo_$timestamp.ogg';
        await File(tempOggPath).writeAsBytes(audioBytes);
        await Future.delayed(Duration.zero);

        _setProgress(TranscriptionProgress(
          state: TranscriptionState.convertingAudio,
          progress: 0.5,
          modelName: modelName,
          message: 'Converting audio format...',
        ));
        await Future.delayed(Duration.zero);

        final convertOk = await _convertToWav(tempOggPath, wavPath);
        if (!convertOk) {
          await _safeDelete(tempOggPath);
          return VoiceMemoTranscriptionResult.failure(
            'Audio conversion failed. Legacy OGG clips require ffmpeg for transcription.',
          );
        }
      }

      await Future.delayed(Duration.zero); // Yield after file write

      if (_isCancelled) {
        if (tempOggPath != null) await _safeDelete(tempOggPath);
        await _safeDelete(wavPath);
        return VoiceMemoTranscriptionResult.cancelled();
      }

      // Transcribe using in-memory whisper
      _setProgress(TranscriptionProgress(
        state: TranscriptionState.transcribing,
        progress: 0.0,
        modelName: modelName,
        message: 'Transcribing audio...',
      ));
      await Future.delayed(Duration.zero); // Yield to allow UI update

      final result = await _sttService.transcribe(wavPath);

      // Cleanup
      if (tempOggPath != null) await _safeDelete(tempOggPath);
      await _safeDelete(wavPath);

      if (!result.success) {
        return VoiceMemoTranscriptionResult.failure(
          result.error ?? 'Transcription failed',
        );
      }

      LogService().log(
        'VoiceMemoTranscriptionService: Transcription complete '
        '(${result.text.length} chars, ${result.transcriptionTimeMs}ms)',
      );

      return VoiceMemoTranscriptionResult.success(
        text: result.text,
        model: 'whisper-${result.modelUsed}',
      );
    } catch (e) {
      LogService().log('VoiceMemoTranscriptionService: Error: $e');
      return VoiceMemoTranscriptionResult.failure(e.toString());
    } finally {
      _currentClipId = null;
      _setProgress(const TranscriptionProgress(
        state: TranscriptionState.idle,
      ));
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
      'VoiceMemoTranscriptionService: Cancelled transcription for $_currentClipId',
    );
  }

  /// Convert OGG/Opus to WAV (16kHz mono) using ffmpeg
  Future<bool> _convertToWav(String oggPath, String wavPath) async {
    try {
      final result = await Process.run('ffmpeg', [
        '-i', oggPath,
        '-ar', '16000', // 16kHz sample rate (required by Whisper)
        '-ac', '1', // Mono
        '-y', // Overwrite output
        wavPath,
      ]);

      if (result.exitCode != 0) {
        LogService().log(
          'VoiceMemoTranscriptionService: ffmpeg conversion failed: ${result.stderr}',
        );
        return false;
      }

      return true;
    } catch (e) {
      LogService().log(
        'VoiceMemoTranscriptionService: ffmpeg not available: $e',
      );
      return false;
    }
  }

  Future<void> _safeDelete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Ignore cleanup errors
    }
  }

  void dispose() {
    cancel();
    _stateController.close();
    _progressController.close();
    _completionController.close();
  }
}
