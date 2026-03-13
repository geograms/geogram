/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Stub implementation for web platform where Whisper is not available
import 'dart:async';

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
  final String text;
  final int transcriptionTimeMs;
  final String modelUsed;
  final bool success;
  final String? error;
  final List<TranscriptionSegment>? segments;

  const TranscriptionResult({
    required this.text,
    required this.transcriptionTimeMs,
    required this.modelUsed,
    required this.success,
    this.error,
    this.segments,
  });

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
  idle,
  loadingModel,
  transcribing,
  error,
}

/// Stub service for web - always returns not supported
class SpeechToTextService {
  static final SpeechToTextService _instance = SpeechToTextService._internal();
  factory SpeechToTextService() => _instance;
  SpeechToTextService._internal();

  final StreamController<SpeechToTextState> _stateController =
      StreamController<SpeechToTextState>.broadcast();

  Stream<SpeechToTextState> get stateStream => _stateController.stream;
  SpeechToTextState get state => SpeechToTextState.idle;
  bool get isModelLoaded => false;
  String? get loadedModelId => null;

  static bool get isSupported => false;

  Future<bool> isLibraryAvailable() async => false;

  Future<bool> needsLibraryDownload() async => false;

  Future<void> downloadLibrary({
    required String stationUrl,
    void Function(double progress)? onProgress,
  }) async {}

  Future<void> initialize() async {}

  Future<bool> loadModel(String modelId) async => false;

  Future<void> unloadModel() async {}

  bool get isPreloading => false;

  Future<bool> waitForPreload() async => false;

  Future<void> preloadModel(String modelId) async {}

  Future<bool> ensureModelWarm(String modelId) async => false;

  Future<TranscriptionResult> transcribe(String audioFilePath) async {
    return TranscriptionResult.failure(
      error: 'Speech-to-text not supported on web',
    );
  }

  Future<TranscriptionResult> transcribeWithTimestamps(String audioFilePath) async {
    return TranscriptionResult.failure(
      error: 'Speech-to-text not supported on web',
    );
  }

  Stream<double> ensureModelReady({String? modelId}) async* {
    yield 0.0;
  }

  void dispose() {
    _stateController.close();
  }
}
