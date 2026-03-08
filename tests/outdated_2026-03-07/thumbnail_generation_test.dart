/*
 * Thumbnail Generation Test using media_kit
 *
 * This test demonstrates thumbnail generation from video using the media_kit package
 * which supports ALL platforms (Windows, Linux, macOS, Android, iOS).
 *
 * media_kit's player.screenshot() works WITHOUT needing to render the video on screen,
 * making it ideal for background thumbnail generation.
 *
 * Run with:
 *   cd /home/brito/code/geograms/geogram
 *   flutter run -d linux -t tests/thumbnail_generation_test.dart
 *
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const ThumbnailTestApp());
}

class ThumbnailTestApp extends StatelessWidget {
  const ThumbnailTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Thumbnail Generation Test (media_kit)',
      theme: ThemeData.dark(),
      home: const ThumbnailTestPage(),
    );
  }
}

class ThumbnailTestPage extends StatefulWidget {
  const ThumbnailTestPage({super.key});

  @override
  State<ThumbnailTestPage> createState() => _ThumbnailTestPageState();
}

class _ThumbnailTestPageState extends State<ThumbnailTestPage> {
  final List<TestResult> _results = [];
  Uint8List? _thumbnailBytes;
  String? _savedThumbnailPath;
  bool _isRunning = false;
  bool _allPassed = false;
  String _status = 'Ready to run tests...';

  // Test configuration
  static const String videoPath =
      '/home/brito/code/geograms/geogram/tests/videos/test1.mp4';
  static const String outputDir = '/tmp/geogram_thumbnail_test';
  static const String thumbnailPath = '$outputDir/thumbnail_media_kit.png';

  Player? _player;
  VideoController? _videoController;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  void _addResult(String name, bool passed, String message) {
    setState(() {
      _results.add(TestResult(name: name, passed: passed, message: message));
    });
    _writeLog('[$name] ${passed ? "PASS" : "FAIL"}: $message');
  }

  Future<void> _writeLog(String message) async {
    try {
      await Directory(outputDir).create(recursive: true);
      final logFile = File('$outputDir/test_log.txt');
      await logFile.writeAsString(
        '${DateTime.now().toIso8601String()}: $message\n',
        mode: FileMode.append,
        flush: true,
      );
      debugPrint(message);
    } catch (_) {}
  }

  Future<void> _runAllTests() async {
    setState(() {
      _isRunning = true;
      _results.clear();
      _thumbnailBytes = null;
      _savedThumbnailPath = null;
      _status = 'Running tests...';
    });

    try {
      // Clear old log
      final logFile = File('$outputDir/test_log.txt');
      if (await logFile.exists()) {
        await logFile.delete();
      }

      await _writeLog('=== Starting Thumbnail Generation Test (media_kit) ===');
      await _writeLog('Video: $videoPath');
      await _writeLog('Output: $thumbnailPath');

      // Test 1: Video file exists
      await _testVideoFileExists();

      // Test 2: Initialize Player
      await _testPlayerInit();

      // Test 3: Seek to position
      await _testSeekToPosition();

      // Test 4: Take screenshot
      await _testScreenshot();

      // Test 5: Save thumbnail to file
      await _testSaveThumbnail();

      // Cleanup
      _player?.dispose();
      _player = null;

      // Check if all tests passed
      _allPassed = _results.every((r) => r.passed);
      setState(() {
        _status = _allPassed ? 'All tests passed!' : 'Some tests failed';
      });
      await _writeLog('=== Test Complete: ${_allPassed ? "ALL PASSED" : "SOME FAILED"} ===');
    } catch (e, stack) {
      _addResult('Unexpected Error', false, 'Exception: $e\n$stack');
      setState(() => _status = 'Test error: $e');
    }

    setState(() => _isRunning = false);
  }

  Future<void> _testVideoFileExists() async {
    final file = File(videoPath);
    final exists = await file.exists();

    if (exists) {
      final stat = await file.stat();
      final sizeMB = (stat.size / (1024 * 1024)).toStringAsFixed(2);
      _addResult('Video File Exists', true, 'Size: $sizeMB MB');
    } else {
      _addResult('Video File Exists', false, 'File not found: $videoPath');
    }
  }

  Future<void> _testPlayerInit() async {
    setState(() => _status = 'Initializing player...');

    try {
      _player = Player();
      // VideoController is needed for screenshot() to work - it handles frame decoding
      _videoController = VideoController(_player!);

      // Wait for duration to be set (indicates file is loaded)
      final completer = Completer<Duration>();
      late StreamSubscription sub;
      sub = _player!.stream.duration.listen((duration) {
        if (duration > Duration.zero && !completer.isCompleted) {
          completer.complete(duration);
          sub.cancel();
        }
      });

      // Open the media file
      await _player!.open(Media(videoPath), play: false);

      // Wait for duration with timeout
      final duration = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => Duration.zero,
      );

      if (duration > Duration.zero) {
        _addResult(
          'Player Init (media_kit)',
          true,
          'Duration: ${duration.inSeconds}s (VideoController attached)',
        );
      } else {
        _addResult('Player Init (media_kit)', false, 'Failed to get duration');
      }
    } catch (e) {
      _addResult('Player Init (media_kit)', false, 'Exception: $e');
    }
  }

  Future<void> _testSeekToPosition() async {
    if (_player == null) {
      _addResult('Seek to Position', false, 'Player not initialized');
      return;
    }

    setState(() => _status = 'Seeking to 10%...');

    try {
      final duration = _player!.state.duration;
      final seekPosition = Duration(
        milliseconds: (duration.inMilliseconds * 0.1).round(),
      );

      await _player!.seek(seekPosition);
      // Wait for seek to complete
      await Future.delayed(const Duration(milliseconds: 500));

      _addResult(
        'Seek to Position',
        true,
        'Seeked to ${seekPosition.inSeconds}s (10% of ${duration.inSeconds}s)',
      );
    } catch (e) {
      _addResult('Seek to Position', false, 'Exception: $e');
    }
  }

  Future<void> _testScreenshot() async {
    if (_player == null) {
      _addResult('Screenshot', false, 'Player not initialized');
      return;
    }

    setState(() => _status = 'Taking screenshot...');

    try {
      // Play briefly to ensure frames are being decoded, then pause
      _player!.play();
      await Future.delayed(const Duration(milliseconds: 200));
      _player!.pause();
      await Future.delayed(const Duration(milliseconds: 300));

      // Take screenshot - requires VideoController to be attached
      final bytes = await _player!.screenshot();

      if (bytes != null && bytes.isNotEmpty) {
        setState(() => _thumbnailBytes = bytes);
        _addResult(
          'Screenshot (media_kit)',
          true,
          'Captured ${(bytes.length / 1024).toStringAsFixed(2)} KB',
        );
      } else {
        _addResult('Screenshot (media_kit)', false, 'Screenshot returned null or empty');
      }
    } catch (e) {
      _addResult('Screenshot (media_kit)', false, 'Exception: $e');
    }
  }

  Future<void> _testSaveThumbnail() async {
    if (_thumbnailBytes == null || _thumbnailBytes!.isEmpty) {
      _addResult('Save Thumbnail', false, 'No thumbnail bytes to save');
      return;
    }

    setState(() => _status = 'Saving thumbnail...');

    try {
      final outputFile = File(thumbnailPath);
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      await outputFile.writeAsBytes(_thumbnailBytes!, flush: true);

      if (await outputFile.exists()) {
        final stat = await outputFile.stat();
        setState(() => _savedThumbnailPath = thumbnailPath);
        _addResult(
          'Save Thumbnail',
          true,
          'Saved ${(stat.size / 1024).toStringAsFixed(2)} KB to $thumbnailPath',
        );
      } else {
        _addResult('Save Thumbnail', false, 'File not created');
      }
    } catch (e) {
      _addResult('Save Thumbnail', false, 'Exception: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Thumbnail Test (media_kit)'),
        backgroundColor: _allPassed ? Colors.green[700] : Colors.blueGrey[800],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status and Run button
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blueGrey[800],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  if (_isRunning)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      _allPassed ? Icons.check_circle : Icons.info,
                      color: _allPassed ? Colors.green : Colors.white,
                    ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_status)),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _isRunning ? null : _runAllTests,
                    child: const Text('Run Tests'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Generated thumbnail preview
            if (_thumbnailBytes != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green[900],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.white),
                        SizedBox(width: 8),
                        Text(
                          'Thumbnail Generated Successfully!',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        _thumbnailBytes!,
                        fit: BoxFit.contain,
                        errorBuilder: (ctx, err, stack) => Text('Error: $err'),
                      ),
                    ),
                    if (_savedThumbnailPath != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Saved to: $_savedThumbnailPath',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Colors.greenAccent,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],

            // Test results
            if (_results.isNotEmpty) ...[
              const Text(
                'Test Results:',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ..._results.map((result) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    color: result.passed ? Colors.green[900] : Colors.red[900],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(
                            result.passed ? Icons.check : Icons.close,
                            color: Colors.white,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  result.name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  result.message,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.8),
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  )),
            ],
          ],
        ),
      ),
    );
  }
}

class TestResult {
  final String name;
  final bool passed;
  final String message;

  TestResult({
    required this.name,
    required this.passed,
    required this.message,
  });
}
