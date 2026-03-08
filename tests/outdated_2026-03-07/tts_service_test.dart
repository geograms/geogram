import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geogram/tts/services/tts_service.dart';
import 'package:geogram/services/log_service.dart';

import 'test_helper.dart';

void main() {
  setUp(() {
    TestHelper.setUp();
  });

  test('TTS Service should synthesize text to audio', () async {
    final logService = LogService();
    await logService.init();

    try {
      final ttsService = TtsService();

      // Load models
      logService.log('Loading TTS models...');
      await for (final progress in ttsService.load()) {
        logService.log(
            'TTS model loading progress: ${(progress * 100).toStringAsFixed(1)}%');
      }
      logService.log('TTS models loaded. isLoaded: ${ttsService.isLoaded}');

      expect(ttsService.isLoaded, isTrue);

      // Synthesize text
      final text = 'Hello world, this is a test of the text to speech system.';
      logService.log('Synthesizing text: "$text"');
      final samples = await ttsService.synthesize(text);
      logService.log('Synthesis complete. Sample count: ${samples?.length}');

      expect(samples, isNotNull);
      expect(samples, isA<Float32List>());
      expect(samples!.isNotEmpty, isTrue);

      // Save audio to file for manual verification
      final outputFile = await ttsService.saveToFile(text, 'tts_output.wav');
      expect(outputFile, isNotNull);
      expect(await outputFile!.exists(), isTrue);
      logService.log('TTS audio saved to: ${outputFile.path}');
    } finally {
      final logContent = await logService.readTodayLog();
      print('--- LOG START ---');
      print(logContent);
      print('--- LOG END ---');
    }
  });
}
