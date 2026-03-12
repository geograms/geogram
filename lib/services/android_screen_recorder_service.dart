library;

import 'package:flutter/services.dart';

/// Dart-side platform channel wrapper for Android MediaProjection screen recording.
class AndroidScreenRecorderService {
  static const _channel = MethodChannel('dev.geogram/screen_recorder');

  Future<void> start(String outputPath) async {
    await _channel.invokeMethod('start', {'outputPath': outputPath});
  }

  Future<String?> stop() async {
    return await _channel.invokeMethod<String>('stop');
  }

  Future<bool> get isRecording async {
    return await _channel.invokeMethod<bool>('isRecording') ?? false;
  }
}
