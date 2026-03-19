/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart';

import '../models/whisper_model_info.dart';
import 'whisper_model_manager.dart';
import '../../services/log_service.dart';

/// A timestamped segment of transcribed speech
class TranscriptionSegment {
  final Duration from;
  final Duration to;
  final String text;

  const TranscriptionSegment({
    required this.from,
    required this.to,
    required this.text,
  });

  Map<String, dynamic> toJson() => {
    'from_ms': from.inMilliseconds,
    'to_ms': to.inMilliseconds,
    'text': text,
  };

  factory TranscriptionSegment.fromJson(Map<String, dynamic> json) {
    return TranscriptionSegment(
      from: Duration(milliseconds: json['from_ms'] as int),
      to: Duration(milliseconds: json['to_ms'] as int),
      text: json['text'] as String,
    );
  }
}

/// Result of a transcription operation
class TranscriptionResult {
  /// The transcribed text
  final String text;

  /// Time taken to transcribe in milliseconds
  final int transcriptionTimeMs;

  /// Model used for transcription
  final String modelUsed;

  /// Whether transcription was successful
  final bool success;

  /// Error message if transcription failed
  final String? error;

  /// Timestamped segments (present when transcribeWithTimestamps is used)
  final List<TranscriptionSegment>? segments;

  const TranscriptionResult({
    required this.text,
    required this.transcriptionTimeMs,
    required this.modelUsed,
    required this.success,
    this.error,
    this.segments,
  });

  /// Create a successful result
  factory TranscriptionResult.success({
    required String text,
    required int transcriptionTimeMs,
    required String modelUsed,
    List<TranscriptionSegment>? segments,
  }) {
    return TranscriptionResult(
      text: text,
      transcriptionTimeMs: transcriptionTimeMs,
      modelUsed: modelUsed,
      success: true,
      segments: segments,
    );
  }

  /// Create a failed result
  factory TranscriptionResult.failure({
    required String error,
    String modelUsed = '',
  }) {
    return TranscriptionResult(
      text: '',
      transcriptionTimeMs: 0,
      modelUsed: modelUsed,
      success: false,
      error: error,
    );
  }
}

/// State of the speech-to-text service
enum SpeechToTextState {
  /// Service is idle, ready to transcribe
  idle,

  /// Model is being loaded
  loadingModel,

  /// Audio is being transcribed
  transcribing,

  /// An error occurred
  error,
}

/// Service for converting speech to text using Whisper
class SpeechToTextService {
  static final SpeechToTextService _instance = SpeechToTextService._internal();
  factory SpeechToTextService() => _instance;
  SpeechToTextService._internal();

  final WhisperModelManager _modelManager = WhisperModelManager();

  Whisper? _whisper;
  String? _loadedModelId;
  SpeechToTextState _state = SpeechToTextState.idle;
  Completer<bool>? _preloadCompleter;
  final Set<String> _warmedModels = {};
  Completer<bool>? _warmupCompleter; // guards concurrent warmup calls
  Completer<bool>? _loadCompleter; // guards concurrent loadModel calls

  final StreamController<SpeechToTextState> _stateController =
      StreamController<SpeechToTextState>.broadcast();

  /// Stream of state changes
  Stream<SpeechToTextState> get stateStream => _stateController.stream;

  /// Current state
  SpeechToTextState get state => _state;

  /// Whether a model is currently loaded
  bool get isModelLoaded => _whisper != null && _loadedModelId != null;

  /// ID of the currently loaded model
  String? get loadedModelId => _loadedModelId;

  /// Check if speech-to-text is supported on this platform
  static bool get isSupported {
    if (kIsWeb) return false;
    // whisper_flutter_new supports: Android 5.0+, iOS 13+, macOS 11+, Linux
    // NOT supported on Windows
    if (Platform.isWindows) return false;
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isLinux;
  }

  /// Check if the whisper native library is available
  /// On F-Droid builds, the library may need to be downloaded first
  Future<bool> isLibraryAvailable() async {
    return _modelManager.isLibraryAvailable();
  }

  /// Check if the library needs to be downloaded (F-Droid builds)
  Future<bool> needsLibraryDownload() async {
    return _modelManager.needsLibraryDownload();
  }

  /// Download the whisper library from a station server
  /// Required for F-Droid builds before speech-to-text can be used
  Future<void> downloadLibrary({
    required String stationUrl,
    void Function(double progress)? onProgress,
  }) async {
    await _modelManager.downloadLibrary(
      stationUrl: stationUrl,
      onProgress: onProgress,
    );
  }

  /// Check if preload is in progress
  bool get isPreloading =>
      _preloadCompleter != null && !_preloadCompleter!.isCompleted;

  /// Wait for any in-progress preload to complete
  Future<bool> waitForPreload() async {
    if (_preloadCompleter != null) {
      return _preloadCompleter!.future;
    }
    return isModelLoaded;
  }

  /// Preload model in background.
  /// Sets up a completer so callers can wait for completion.
  Future<void> preloadModel(String modelId) async {
    if (_preloadCompleter != null) return; // Already preloading

    _preloadCompleter = Completer<bool>();
    final stopwatch = Stopwatch()..start();

    try {
      final success = await loadModel(modelId);
      final warmed = success ? await _warmupModel(modelId) : false;
      stopwatch.stop();
      final ready = success && warmed;
      LogService().log(
          'SpeechToTextService: Preload completed in ${stopwatch.elapsedMilliseconds}ms (ready: $ready)');
      _preloadCompleter!.complete(ready);
    } catch (e) {
      LogService().log('SpeechToTextService: Preload failed: $e');
      _preloadCompleter!.completeError(e);
    }
  }

  /// Ensure the current model is fully warmed; returns true when ready.
  Future<bool> ensureModelWarm(String modelId) async {
    return _warmupModel(modelId);
  }

  void _setState(SpeechToTextState state) {
    _state = state;
    _stateController.add(state);
  }

  /// Initialize the service
  Future<void> initialize() async {
    await _modelManager.initialize();
    LogService().log('SpeechToTextService: Initialized');
  }

  /// Convert our model ID to whisper_flutter_new's WhisperModel enum
  WhisperModel _getWhisperModel(String modelId) {
    switch (modelId) {
      case 'whisper-tiny':
        return WhisperModel.tiny;
      case 'whisper-base':
        return WhisperModel.base;
      case 'whisper-small':
        return WhisperModel.small;
      case 'whisper-medium':
        return WhisperModel.medium;
      case 'whisper-large-v2':
        return WhisperModel.largeV2;
      default:
        return WhisperModel.small; // Default to small
    }
  }

  /// Load a Whisper model
  ///
  /// Returns true if model was loaded successfully
  Future<bool> loadModel(String modelId) async {
    print('[STT_SERVICE] loadModel($modelId) called');

    // If another loadModel call is already in progress, wait for it
    if (_loadCompleter != null) {
      print('[STT_SERVICE] loadModel already in progress, waiting...');
      return _loadCompleter!.future;
    }

    // Check if whisper library is available (may need download on F-Droid)
    if (!await isLibraryAvailable()) {
      LogService().log('SpeechToTextService: Whisper library not available');
      print('[STT_SERVICE] Library not available');
      return false;
    }

    if (_loadedModelId == modelId && _whisper != null) {
      LogService().log('SpeechToTextService: Model $modelId already loaded, skipping reload');
      print('[STT_SERVICE] Model already loaded, returning true');
      return true; // Already loaded - instant
    }

    _loadCompleter = Completer<bool>();

    // Unload current model first
    await unloadModel();

    final model = WhisperModels.getById(modelId);
    if (model == null) {
      LogService().log('SpeechToTextService: Unknown model $modelId');
      print('[STT_SERVICE] Unknown model $modelId');
      return false;
    }

    _setState(SpeechToTextState.loadingModel);
    print('[STT_SERVICE] State set to loadingModel');

    try {
      final modelDir = await _modelManager.modelsPath;
      final whisperModel = _getWhisperModel(modelId);

      LogService().log('SpeechToTextService: Loading model $modelId from $modelDir');
      print('[STT_SERVICE] Model dir: $modelDir, creating Whisper object...');

      // Yield before heavy FFI initialization
      await Future.delayed(Duration.zero);

      // Create Whisper instance with our custom model directory
      _whisper = Whisper(
        model: whisperModel,
        modelDir: modelDir,
      );
      print('[STT_SERVICE] Whisper object created successfully');

      // Yield after FFI initialization
      await Future.delayed(Duration.zero);

      _loadedModelId = modelId;
      _setState(SpeechToTextState.idle);

      LogService().log('SpeechToTextService: Model $modelId loaded');
      print('[STT_SERVICE] Model $modelId loaded, returning true');
      _loadCompleter?.complete(true);
      _loadCompleter = null;
      return true;
    } catch (e) {
      LogService().log('SpeechToTextService: Error loading model: $e');
      print('[STT_SERVICE] Error loading model: $e');
      _setState(SpeechToTextState.error);
      _loadCompleter?.complete(false);
      _loadCompleter = null;
      return false;
    }
  }

  /// Unload the current model to free memory
  Future<void> unloadModel() async {
    _whisper = null;
    _loadedModelId = null;
    _setState(SpeechToTextState.idle);
  }

  /// Generate and transcribe a short silent WAV to fully load the model into memory.
  Future<bool> _warmupModel(String modelId) async {
    print('[STT_SERVICE] _warmupModel($modelId) called');

    // If another warmup is already in progress, wait for it
    if (_warmupCompleter != null) {
      print('[STT_SERVICE] Warmup already in progress, waiting...');
      return _warmupCompleter!.future;
    }

    if (_whisper == null || _loadedModelId != modelId) {
      print('[STT_SERVICE] Warmup skipped: whisper=${_whisper != null}, loadedId=$_loadedModelId');
      return false;
    }
    if (_warmedModels.contains(modelId)) {
      print('[STT_SERVICE] Model already warmed, returning true');
      return true;
    }

    _warmupCompleter = Completer<bool>();

    final tempDir = await getTemporaryDirectory();
    final warmupPath = p.join(tempDir.path, 'whisper_warmup.wav');

    try {
      print('[STT_SERVICE] Creating silent WAV at $warmupPath');
      await _createSilentWav(warmupPath);
      final warmupStopwatch = Stopwatch()..start();
      const warmupThreads = 1;

      // Yield before warmup transcription
      await Future.delayed(Duration.zero);

      print('[STT_SERVICE] Starting warmup transcription (threads=$warmupThreads)...');
      await _whisper!.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: warmupPath,
          isTranslate: false,
          isNoTimestamps: true,
          splitOnWord: false,
          threads: warmupThreads,
          nProcessors: 1,
          speedUp: false,
        ),
      );
      print('[STT_SERVICE] Warmup transcription completed');

      // Yield after warmup transcription
      await Future.delayed(Duration.zero);

      warmupStopwatch.stop();
      _warmedModels.add(modelId);
      LogService().log(
          'SpeechToTextService: Warmed up model $modelId in ${warmupStopwatch.elapsedMilliseconds}ms');
      print('[STT_SERVICE] Warmed up in ${warmupStopwatch.elapsedMilliseconds}ms');
      _warmupCompleter?.complete(true);
      _warmupCompleter = null;
      return true;
    } catch (e) {
      _warmedModels.remove(modelId);
      LogService().log('SpeechToTextService: Warmup failed for $modelId: $e');
      print('[STT_SERVICE] Warmup failed: $e');
      _warmupCompleter?.complete(false);
      _warmupCompleter = null;
      return false;
    } finally {
      try {
        final file = File(warmupPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Ignore cleanup errors
      }
    }
  }

  Future<void> _createSilentWav(String path) async {
    const sampleRate = 16000;
    const channels = 1;
    const bitsPerSample = 16;
    const durationMs = 400;
    final totalSamples = (sampleRate * durationMs) ~/ 1000;
    final bytesPerSample = bitsPerSample ~/ 8;
    final dataSize = totalSamples * channels * bytesPerSample;
    final byteRate = sampleRate * channels * bytesPerSample;
    final blockAlign = channels * bytesPerSample;

    final builder = BytesBuilder();
    void writeString(String value) => builder.add(value.codeUnits);
    void writeUint32(int value) {
      final buffer = ByteData(4)..setUint32(0, value, Endian.little);
      builder.add(buffer.buffer.asUint8List());
    }

    void writeUint16(int value) {
      final buffer = ByteData(2)..setUint16(0, value, Endian.little);
      builder.add(buffer.buffer.asUint8List());
    }

    writeString('RIFF');
    writeUint32(36 + dataSize);
    writeString('WAVE');
    writeString('fmt ');
    writeUint32(16);
    writeUint16(1); // PCM
    writeUint16(channels);
    writeUint32(sampleRate);
    writeUint32(byteRate);
    writeUint16(blockAlign);
    writeUint16(bitsPerSample);
    writeString('data');
    writeUint32(dataSize);
    builder.add(Uint8List(dataSize)); // Silence

    final file = File(path);
    await file.writeAsBytes(builder.toBytes(), flush: true);
  }

  /// Transcribe an audio file to text
  ///
  /// The audio file should be in a supported format (wav, mp3, etc.)
  /// Returns a [TranscriptionResult] with the transcribed text or error
  Future<TranscriptionResult> transcribe(String audioFilePath) async {
    if (!isSupported) {
      return TranscriptionResult.failure(
        error: 'Speech-to-text not supported on this platform',
      );
    }

    // Check if whisper library is available (may need download on F-Droid)
    if (!await isLibraryAvailable()) {
      return TranscriptionResult.failure(
        error: 'Whisper library not available. Please download from station.',
      );
    }

    if (!isModelLoaded) {
      return TranscriptionResult.failure(
        error: 'No model loaded',
      );
    }

    // Verify audio file exists
    final audioFile = File(audioFilePath);
    if (!await audioFile.exists()) {
      return TranscriptionResult.failure(
        error: 'Audio file not found',
        modelUsed: _loadedModelId ?? '',
      );
    }

    _setState(SpeechToTextState.transcribing);

    try {
      final stopwatch = Stopwatch()..start();

      // Transcribe the audio
      // whisper_flutter_new handles isolate/background processing internally
      // Use a single thread so transcription doesn't compete with itself or the UI.
      // Whisper work is sequential — one thread completes faster than two splitting CPU.
      const threads = 1;
      final result = await _whisper!.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: audioFilePath,
          isTranslate: false,
          isNoTimestamps: true,
          splitOnWord: false,
          threads: threads,
          nProcessors: 1,
          speedUp: false,
        ),
      );

      stopwatch.stop();

      _setState(SpeechToTextState.idle);

      final transcribedText = result.text.trim();

      LogService().log(
          'SpeechToTextService: Transcribed ${audioFilePath.split('/').last} in ${stopwatch.elapsedMilliseconds}ms');

      if (transcribedText.isEmpty) {
        return TranscriptionResult.failure(
          error: 'No speech detected',
          modelUsed: _loadedModelId ?? '',
        );
      }

      return TranscriptionResult.success(
        text: transcribedText,
        transcriptionTimeMs: stopwatch.elapsedMilliseconds,
        modelUsed: _loadedModelId ?? '',
      );
    } catch (e) {
      LogService().log('SpeechToTextService: Transcription error: $e');
      _setState(SpeechToTextState.error);

      return TranscriptionResult.failure(
        error: e.toString(),
        modelUsed: _loadedModelId ?? '',
      );
    }
  }

  /// Transcribe an audio file with timestamped segments
  ///
  /// Same as [transcribe] but preserves Whisper's per-segment timestamps.
  Future<TranscriptionResult> transcribeWithTimestamps(String audioFilePath) async {
    if (!isSupported) {
      return TranscriptionResult.failure(
        error: 'Speech-to-text not supported on this platform',
      );
    }

    if (!await isLibraryAvailable()) {
      return TranscriptionResult.failure(
        error: 'Whisper library not available. Please download from station.',
      );
    }

    if (!isModelLoaded) {
      return TranscriptionResult.failure(
        error: 'No model loaded',
      );
    }

    final audioFile = File(audioFilePath);
    if (!await audioFile.exists()) {
      return TranscriptionResult.failure(
        error: 'Audio file not found',
        modelUsed: _loadedModelId ?? '',
      );
    }

    _setState(SpeechToTextState.transcribing);

    try {
      final stopwatch = Stopwatch()..start();

      const threads = 1;
      final result = await _whisper!.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: audioFilePath,
          isTranslate: false,
          isNoTimestamps: false,
          splitOnWord: true,
          threads: threads,
          nProcessors: 1,
          speedUp: false,
        ),
      );

      stopwatch.stop();

      _setState(SpeechToTextState.idle);

      final transcribedText = result.text.trim();

      LogService().log(
          'SpeechToTextService: Transcribed with timestamps ${audioFilePath.split('/').last} '
          'in ${stopwatch.elapsedMilliseconds}ms '
          '(${result.segments?.length ?? 0} segments)');

      if (transcribedText.isEmpty) {
        return TranscriptionResult.failure(
          error: 'No speech detected',
          modelUsed: _loadedModelId ?? '',
        );
      }

      final segments = result.segments?.map((seg) {
        return TranscriptionSegment(
          from: seg.fromTs,
          to: seg.toTs,
          text: seg.text.trim(),
        );
      }).where((seg) => seg.text.isNotEmpty).toList();

      return TranscriptionResult.success(
        text: transcribedText,
        transcriptionTimeMs: stopwatch.elapsedMilliseconds,
        modelUsed: _loadedModelId ?? '',
        segments: segments,
      );
    } catch (e) {
      LogService().log('SpeechToTextService: Transcription with timestamps error: $e');
      _setState(SpeechToTextState.error);

      return TranscriptionResult.failure(
        error: e.toString(),
        modelUsed: _loadedModelId ?? '',
      );
    }
  }

  /// Ensure a model is loaded, downloading if necessary
  ///
  /// Returns a stream of download progress (0.0 - 1.0) or yields 1.0 immediately if already available
  Stream<double> ensureModelReady({String? modelId}) async* {
    final id = modelId ?? await _modelManager.getPreferredModel();

    // Check if already loaded
    if (_loadedModelId == id && _whisper != null) {
      yield 1.0;
      return;
    }

    // Check if downloaded
    if (!await _modelManager.isDownloaded(id)) {
      // Download the model
      yield* _modelManager.downloadModel(id);
    } else {
      yield 1.0;
    }

    // Load the model
    final loaded = await loadModel(id);
    if (loaded) {
      await ensureModelWarm(id);
    }
  }

  void dispose() {
    _stateController.close();
    _whisper = null;
    _loadedModelId = null;
  }
}
