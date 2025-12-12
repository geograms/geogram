/// Stub implementations for web platform where FFI is not available.
/// This file is imported on web, audio_native_ffi.dart is imported on native.

import 'dart:typed_data';

/// Stub for AlsaRecorder - not available on web
class AlsaRecorder {
  static bool get isAvailable => false;

  AlsaRecorder({int sampleRate = 16000, int channels = 1});

  void initialize() {}
  Future<bool> startRecording(String outputPath) async => false;
  Int16List? readFrames(int numFrames) => null;
  void stopRecording() {}
  bool get isRecording => false;
}

/// Stub for AlsaPlayer - not available on web
class AlsaPlayer {
  static bool get isAvailable => false;

  AlsaPlayer();

  void initialize() {}
  void load(Int16List samples, int sampleRate, int channels) {}
  Duration? get duration => null;
  Duration get position => Duration.zero;
  bool get isPlaying => false;
  bool get isPaused => false;
  Future<void> play() async {}
  void pause() {}
  void stop() {}
  void seek(Duration position) {}
  void dispose() {}

  Stream<Duration> get positionStream => const Stream.empty();
  Stream<AlsaPlayerState> get stateStream => const Stream.empty();
}

enum AlsaPlayerState {
  stopped,
  playing,
  paused,
  completed,
}

/// Stub for OpusEncoder - not available on web
class OpusEncoder {
  static bool get isAvailable => false;

  OpusEncoder({int sampleRate = 16000, int channels = 1, int application = 2048});

  void initialize() {}
  Uint8List? encodeFrame(Int16List pcmData, int frameSize) => null;
  List<Uint8List> encodeAll(Int16List pcmData) => [];
  void dispose() {}
}

const int OPUS_APPLICATION_VOIP = 2048;

/// Stub for OpusDecoder - not available on web
class OpusDecoder {
  static bool get isAvailable => false;

  OpusDecoder({int sampleRate = 16000, int channels = 1});

  void initialize() {}
  Int16List? decodeFrame(Uint8List opusData, int frameSize) => null;
  Int16List decodeAll(List<Uint8List> packets, int frameSize) => Int16List(0);
  void dispose() {}
}

/// Stub for OggOpusReader - not available on web
class OggOpusReader {
  static Future<(List<Uint8List>, int, int, int, int)> read(String filePath) async {
    throw UnsupportedError('OggOpusReader not available on web');
  }
}
