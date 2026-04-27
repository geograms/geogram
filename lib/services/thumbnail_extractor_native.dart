/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Native (dart:io) implementation of ThumbnailExtractor. Picked at compile
 * time by the conditional import in thumbnail_extractor.dart.
 *
 * Strategy on native:
 *   Android: MethodChannel "geogram/thumbnail" → MediaMetadataRetriever in
 *     Kotlin. Runs on a Java background thread; UI stays responsive.
 *   Desktop (Linux/macOS/Windows): ffmpeg subprocess when on PATH (truly
 *     separate OS process), else media_kit as the last-resort fallback.
 *
 * media_kit is the only code path that actually runs on the Flutter UI
 * isolate — it's a platform plugin that requires the Flutter binding.
 * Calls into it are serialized one-at-a-time elsewhere; we still want to
 * avoid landing here when ffmpeg or the platform channel can do the job.
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'log_service.dart';
import 'thumbnail_extractor.dart';

ThumbnailExtractor create() => NativeThumbnailExtractor();

class NativeThumbnailExtractor implements ThumbnailExtractor {
  static const MethodChannel _channel = MethodChannel('geogram/thumbnail');

  bool? _ffmpegChecked;
  String? _ffmpegPath;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<Uint8List?> extractVideoFrame(
    String sourcePath, {
    int atSeconds = 1,
  }) async {
    if (Platform.isAndroid) {
      final viaChannel =
          await _extractViaPlatformChannel(sourcePath, atSeconds);
      if (viaChannel != null) return viaChannel;
      // Channel unavailable / failed → fall through to media_kit which
      // also works on Android.
    } else {
      final ffmpeg = await _ensureFfmpegPath();
      if (ffmpeg != null) {
        final viaFfmpeg =
            await _extractViaFfmpeg(ffmpeg, sourcePath, atSeconds);
        if (viaFfmpeg != null) return viaFfmpeg;
      }
    }

    return _extractViaMediaKit(sourcePath, atSeconds);
  }

  Future<Uint8List?> _extractViaPlatformChannel(
      String sourcePath, int atSeconds) async {
    try {
      final result = await _channel.invokeMethod<Uint8List>(
        'extractVideoFrame',
        {
          'path': sourcePath,
          'atSeconds': atSeconds,
        },
      );
      return result;
    } on MissingPluginException {
      // Channel handler not registered (e.g. pre-build, debug shell). The
      // caller falls back to media_kit.
      return null;
    } on PlatformException catch (e) {
      LogService().log(
          'NativeThumbnailExtractor: platform channel failed for $sourcePath: ${e.message}');
      return null;
    } catch (e) {
      LogService().log(
          'NativeThumbnailExtractor: platform channel error for $sourcePath: $e');
      return null;
    }
  }

  Future<String?> _ensureFfmpegPath() async {
    if (_ffmpegChecked == true) return _ffmpegPath;
    _ffmpegChecked = true;

    final probe = Platform.isWindows ? 'where' : 'which';
    try {
      final result = await Process.run(probe, ['ffmpeg']);
      if (result.exitCode == 0) {
        final stdout = (result.stdout as String).trim();
        if (stdout.isNotEmpty) {
          _ffmpegPath = stdout.split('\n').first.trim();
          return _ffmpegPath;
        }
      }
    } catch (_) {}
    _ffmpegPath = null;
    return null;
  }

  Future<Uint8List?> _extractViaFfmpeg(
      String ffmpegPath, String sourcePath, int atSeconds) async {
    final tempDir = Directory.systemTemp;
    final outPath =
        '${tempDir.path}/geogram_ffmpeg_${sourcePath.hashCode}_${DateTime.now().microsecondsSinceEpoch}.png';
    try {
      // -ss before -i = fast input seek (keyframe-aligned, near-instant).
      // -frames:v 1 = grab a single frame.
      // -vf scale=480:-1 = downscale to 480 px wide so the cached file is
      // small (the picker tile is 44 px; 480 leaves headroom for grid view).
      // -y = overwrite the output file silently.
      final result = await Process.run(
        ffmpegPath,
        [
          '-ss', atSeconds.toString(),
          '-i', sourcePath,
          '-frames:v', '1',
          '-vf', 'scale=480:-1',
          '-y',
          outPath,
        ],
      );
      if (result.exitCode != 0) {
        LogService().log(
            'NativeThumbnailExtractor: ffmpeg exit ${result.exitCode} for $sourcePath: ${result.stderr}');
        return null;
      }
      final outFile = File(outPath);
      if (!await outFile.exists()) return null;
      final bytes = await outFile.readAsBytes();
      try {
        await outFile.delete();
      } catch (_) {}
      return bytes;
    } catch (e) {
      LogService()
          .log('NativeThumbnailExtractor: ffmpeg error for $sourcePath: $e');
      return null;
    }
  }

  Future<Uint8List?> _extractViaMediaKit(
      String sourcePath, int atSeconds) async {
    Player? player;
    try {
      player = Player();
      final videoController = VideoController(player);

      final completer = Completer<Duration>();
      late StreamSubscription sub;
      sub = player.stream.duration.listen((duration) {
        if (duration > Duration.zero && !completer.isCompleted) {
          completer.complete(duration);
          sub.cancel();
        }
      });

      await player.open(Media(sourcePath), play: false);

      final duration = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => Duration.zero,
      );

      if (duration == Duration.zero) {
        await player.dispose();
        videoController.hashCode;
        return null;
      }

      await player.seek(Duration(seconds: atSeconds));
      await Future.delayed(const Duration(milliseconds: 300));

      player.play();
      await Future.delayed(const Duration(milliseconds: 200));
      player.pause();
      await Future.delayed(const Duration(milliseconds: 200));

      final bytes = await player.screenshot();
      await player.dispose();
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } catch (e) {
      LogService()
          .log('NativeThumbnailExtractor: media_kit error for $sourcePath: $e');
      try {
        await player?.dispose();
      } catch (_) {}
      return null;
    }
  }
}
