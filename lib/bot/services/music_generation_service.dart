/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/music_generation_state.dart';
import '../models/music_model_info.dart';
import '../models/music_track.dart';
import 'fm_synth_service.dart';
import 'music_model_manager.dart';
import 'music_storage_service.dart';
import 'music_onnx_service.dart';
import '../../services/audio_service.dart';
import '../../services/log_service.dart';

/// Orchestrates music generation with hybrid approach:
/// 1. Start FM synthesis immediately for instant playback
/// 2. Generate AI music in background (if model available)
/// 3. Report progress to UI
/// 4. Save generated tracks for replay
class MusicGenerationService {
  static final MusicGenerationService _instance =
      MusicGenerationService._internal();
  factory MusicGenerationService() => _instance;
  MusicGenerationService._internal();

  final FMSynthService _fmSynth = FMSynthService();
  final MusicModelManager _modelManager = MusicModelManager();
  final MusicStorageService _storage = MusicStorageService();
  final AudioService _audioService = AudioService();
  final MusicOnnxService _onnxService = MusicOnnxService();

  /// Currently playing track
  MusicTrack? _currentTrack;

  /// Whether music is currently playing
  bool get isPlaying => _audioService.isPlaying;

  /// Current playback position
  Duration get position => _audioService.position;

  /// Stream of playback position updates
  Stream<Duration> get positionStream => _audioService.positionStream;

  /// Stream of playing state changes
  Stream<bool> get playingStream => _audioService.playingStream;

  /// Currently playing track
  MusicTrack? get currentTrack => _currentTrack;

  /// Initialize the service
  Future<void> initialize() async {
    await _modelManager.initialize();
    await _storage.initialize();
    await _audioService.initialize();
    LogService().log('MusicGenerationService: Initialized');
  }

  /// Parse a natural language prompt into a music generation request.
  /// Examples:
  /// - "play 5 minutes of heavy rock"
  /// - "generate ambient music"
  /// - "play jazz"
  MusicGenerationRequest parsePrompt(String prompt) {
    final lower = prompt.toLowerCase();

    // Parse duration
    Duration duration = const Duration(minutes: 2); // Default 2 minutes

    // Match patterns like "5 minutes", "30 seconds", "1 hour"
    final durationRegex = RegExp(r'(\d+)\s*(minute|min|second|sec|hour|hr)s?');
    final match = durationRegex.firstMatch(lower);
    if (match != null) {
      final value = int.parse(match.group(1)!);
      final unit = match.group(2)!;

      if (unit.startsWith('hour') || unit.startsWith('hr')) {
        duration = Duration(hours: value);
      } else if (unit.startsWith('minute') || unit.startsWith('min')) {
        duration = Duration(minutes: value);
      } else if (unit.startsWith('second') || unit.startsWith('sec')) {
        duration = Duration(seconds: value);
      }
    }

    // Clamp duration between 10 seconds and 1 hour
    if (duration.inSeconds < 10) {
      duration = const Duration(seconds: 10);
    } else if (duration.inHours > 1) {
      duration = const Duration(hours: 1);
    }

    // Parse genre
    final genre = _detectGenre(lower);

    return MusicGenerationRequest(
      prompt: prompt,
      duration: duration,
      genre: genre,
      allowFMFallback: true,
      useHybridMode: false,
    );
  }

  /// Detect genre from prompt
  String _detectGenre(String lower) {
    const genreKeywords = {
      'rock': ['rock', 'metal', 'punk', 'grunge', 'hard rock'],
      'jazz': ['jazz', 'swing', 'bebop', 'blues'],
      'electronic': ['electronic', 'techno', 'house', 'edm', 'synth', 'dance'],
      'ambient': ['ambient', 'chill', 'relaxing', 'meditation', 'sleep', 'calm'],
      'classical': ['classical', 'orchestra', 'piano', 'symphony', 'violin'],
      'lofi': ['lofi', 'lo-fi', 'study', 'beats', 'hip hop'],
    };

    for (final entry in genreKeywords.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) {
          return entry.key;
        }
      }
    }

    return 'ambient'; // Default genre
  }

  /// Check if a query is asking for music generation
  bool isMusicQuery(String query) {
    final lower = query.toLowerCase();

    // Check for explicit music commands
    if (lower.contains('play') ||
        lower.contains('generate') ||
        lower.contains('create') ||
        lower.contains('compose')) {
      if (lower.contains('music') ||
          lower.contains('song') ||
          lower.contains('track') ||
          lower.contains('tune')) {
        return true;
      }

      // Check for duration patterns with genre
      if (RegExp(r'\d+\s*(minute|min|second|sec|hour)').hasMatch(lower)) {
        return true;
      }

      // Check for genre keywords
      final genreWords = [
        'rock', 'metal', 'jazz', 'blues', 'electronic', 'techno',
        'house', 'ambient', 'chill', 'classical', 'lofi', 'lo-fi',
      ];
      if (genreWords.any((g) => lower.contains(g))) {
        return true;
      }
    }

    return false;
  }

  /// Generate music from a prompt.
  /// Returns a stream of generation state updates.
  Stream<MusicGenerationState> generateMusic(String prompt) {
    final controller = StreamController<MusicGenerationState>();
    () async {
      try {
        final request = parsePrompt(prompt);
        LogService().log(
            'MusicGenerationService: Generating ${request.genre} music for ${request.duration.inSeconds}s');
        controller.add(MusicGenerationState.queued(
            message: 'Preparing to generate ${request.genre} music...'));

        final ramMb = await _getAvailableRamMb();
        var bestModel = await _modelManager.getBestAvailableModel(ramMb);

        if (kIsWeb) {
          bestModel = MusicModels.fmSynth;
        }

        if (bestModel.isNative && !kIsWeb) {
          final recommended = _modelManager.getRecommendedModel(ramMb);
          if (!recommended.isNative) {
            LogService().log(
                'MusicGenerationService: Auto-downloading recommended model: ${recommended.name}');

            controller.add(MusicGenerationState.downloading(
              progress: 0.0,
              modelName: recommended.name,
            ));

            try {
              await for (final progress
                  in _modelManager.downloadModel(recommended.id)) {
                controller.add(MusicGenerationState.downloading(
                  progress: progress,
                  modelName: recommended.name,
                ));
              }

              bestModel = await _modelManager.getBestAvailableModel(ramMb);
              LogService().log(
                  'MusicGenerationService: Model downloaded, now using: ${bestModel.name}');
            } catch (e) {
              LogService().log(
                  'MusicGenerationService: Model download failed: $e, continuing with FM synth');
              controller.add(MusicGenerationState.queued(
                message: 'Download failed, using FM synthesis instead...',
              ));
            }
          }
        }

        if (bestModel.isNative) {
          final fmTrack = await _fmSynth.generate(
            genre: request.genre,
            duration: request.duration,
            prompt: request.prompt,
          );
          await _playTrack(fmTrack);
          controller.add(MusicGenerationState.completed(fmTrack));
          return;
        }

        MusicTrack? fmTrack;
        if (request.useHybridMode && request.allowFMFallback) {
          try {
            fmTrack = await _fmSynth.generate(
              genre: request.genre,
              duration: request.duration.inSeconds > bestModel.maxDurationSec
                  ? Duration(seconds: bestModel.maxDurationSec)
                  : request.duration,
              prompt: request.prompt,
            );
            await _playTrack(fmTrack);
            controller.add(MusicGenerationState.fmPlaying(
              fmTrack: fmTrack,
              aiProgress: 0.0,
              eta: bestModel.estimateGenerationTime(request.duration),
            ));
          } catch (e) {
            LogService().log(
                'MusicGenerationService: FM generation failed: $e, continuing with AI');
          }
        }

        double lastProgress = -1.0;
        controller.add(MusicGenerationState.generating(
          progress: 0.0,
          eta: bestModel.estimateGenerationTime(request.duration),
        ));
        MusicTrack aiTrack;
        try {
          aiTrack = await _generateAiTrack(
            request,
            bestModel,
            onProgress: (progress) {
              if ((progress - lastProgress) < 0.01 && progress < 1.0) return;
              lastProgress = progress;
              controller.add(MusicGenerationState.generating(
                progress: progress,
                eta: bestModel.estimateGenerationTime(request.duration),
              ));
            },
          );
        } catch (e) {
          LogService().log('MusicGenerationService: AI generation failed: $e');
          if (request.allowFMFallback) {
            if (fmTrack != null) {
              final fallbackTrack = fmTrack.copyWith(
                isFMFallback: true,
                modelUsed: bestModel.id,
              );
              controller.add(MusicGenerationState.completed(fallbackTrack));
              return;
            }
            final fallback = await _fmSynth.generate(
              genre: request.genre,
              duration: request.duration,
              prompt: request.prompt,
            );
            await _playTrack(fallback);
            controller.add(MusicGenerationState.completed(
              fallback.copyWith(
                isFMFallback: true,
                modelUsed: bestModel.id,
              ),
            ));
            return;
          }
          rethrow;
        }

        await _playTrack(aiTrack);
        controller.add(MusicGenerationState.completed(aiTrack));
      } catch (e, stackTrace) {
        LogService().log('MusicGenerationService: Unhandled error: $e');
        LogService().log('MusicGenerationService: Stack trace: $stackTrace');
        controller.add(MusicGenerationState.failed('Error: $e'));
      } finally {
        await controller.close();
      }
    }();

    return controller.stream;
  }

  Future<MusicTrack> _generateAiTrack(
    MusicGenerationRequest request,
    MusicModelInfo model, {
    required void Function(double progress) onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();
    final modelDir = await _modelManager.getModelDir(model.id);
    await _onnxService.initialize(modelDir);

    final totalSeconds =
        max(1, (request.duration.inMilliseconds / 1000).round());
    final chunkSeconds = max(1, model.maxDurationSec);
    final totalChunks = (totalSeconds / chunkSeconds).ceil();

    final chunks = <Float32List>[];
    var sampleRate = 32000;

    final aiPrompt = _buildAiPrompt(request);

    for (var i = 0; i < totalChunks; i++) {
      final remaining = totalSeconds - (i * chunkSeconds);
      final durationSeconds = min(chunkSeconds, remaining);
      final chunkDuration = Duration(seconds: durationSeconds);

      final chunk = await _onnxService.generateAudio(
        prompt: aiPrompt,
        duration: chunkDuration,
        onProgress: (progress) {
          onProgress((i + progress) / totalChunks);
        },
      );
      sampleRate = chunk.sampleRate;
      chunks.add(chunk.samples);
    }

    final combined = _combineChunks(chunks, sampleRate);
    final wavData = _encodeWav(combined, sampleRate);
    final trackDuration = _durationFromSamples(combined.length, sampleRate);

    final trackId =
        'ai_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(10000)}';
    final track = MusicTrack(
      id: trackId,
      filePath: '',
      genre: request.genre,
      prompt: request.prompt,
      duration: trackDuration,
      createdAt: DateTime.now(),
      modelUsed: model.id,
      isFMFallback: false,
      stats: MusicGenerationStats(
        processingTimeMs: stopwatch.elapsedMilliseconds,
        qualityLevel: model.tier,
      ),
    );

    final filePath = await _storage.saveTrack(track, wavData);
    stopwatch.stop();
    return track.copyWith(filePath: filePath);
  }

  String _buildAiPrompt(MusicGenerationRequest request) {
    final lower = request.prompt.toLowerCase();
    if (lower.contains(request.genre)) return request.prompt;
    return '${request.genre} music. ${request.prompt}';
  }

  Float32List _combineChunks(List<Float32List> chunks, int sampleRate) {
    if (chunks.isEmpty) return Float32List(0);
    var combined = chunks.first;
    const crossfadeMs = 500;
    final crossfadeSamples = (sampleRate * crossfadeMs / 1000).round();

    for (var i = 1; i < chunks.length; i++) {
      combined = _crossfade(combined, chunks[i], crossfadeSamples);
    }

    return combined;
  }

  Float32List _crossfade(
    Float32List a,
    Float32List b,
    int fadeSamples,
  ) {
    if (fadeSamples <= 0 || a.isEmpty) {
      final out = Float32List(a.length + b.length);
      out.setAll(0, a);
      out.setAll(a.length, b);
      return out;
    }

    final fade = min(fadeSamples, min(a.length, b.length));
    final outLength = a.length + b.length - fade;
    final out = Float32List(outLength);

    final leadLength = a.length - fade;
    if (leadLength > 0) {
      out.setAll(0, a.sublist(0, leadLength));
    }

    for (var i = 0; i < fade; i++) {
      final t = fade <= 1 ? 1.0 : i / (fade - 1);
      final aSample = a[leadLength + i];
      final bSample = b[i];
      out[leadLength + i] = aSample * (1 - t) + bSample * t;
    }

    if (b.length > fade) {
      out.setAll(leadLength + fade, b.sublist(fade));
    }

    return out;
  }

  Duration _durationFromSamples(int sampleCount, int sampleRate) {
    final seconds = sampleCount / sampleRate;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  Uint8List _encodeWav(Float32List samples, int sampleRate) {
    final pcmSamples = Int16List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      pcmSamples[i] = (samples[i] * 32767).round().clamp(-32768, 32767);
    }

    final dataSize = pcmSamples.length * 2;
    final fileSize = 36 + dataSize;

    final buffer = ByteData(44 + dataSize);
    var offset = 0;

    buffer.setUint8(offset++, 0x52); // 'R'
    buffer.setUint8(offset++, 0x49); // 'I'
    buffer.setUint8(offset++, 0x46); // 'F'
    buffer.setUint8(offset++, 0x46); // 'F'
    buffer.setUint32(offset, fileSize, Endian.little);
    offset += 4;
    buffer.setUint8(offset++, 0x57); // 'W'
    buffer.setUint8(offset++, 0x41); // 'A'
    buffer.setUint8(offset++, 0x56); // 'V'
    buffer.setUint8(offset++, 0x45); // 'E'

    buffer.setUint8(offset++, 0x66); // 'f'
    buffer.setUint8(offset++, 0x6D); // 'm'
    buffer.setUint8(offset++, 0x74); // 't'
    buffer.setUint8(offset++, 0x20); // ' '
    buffer.setUint32(offset, 16, Endian.little);
    offset += 4;
    buffer.setUint16(offset, 1, Endian.little);
    offset += 2;
    buffer.setUint16(offset, 1, Endian.little);
    offset += 2;
    buffer.setUint32(offset, sampleRate, Endian.little);
    offset += 4;
    buffer.setUint32(offset, sampleRate * 2, Endian.little);
    offset += 4;
    buffer.setUint16(offset, 2, Endian.little);
    offset += 2;
    buffer.setUint16(offset, 16, Endian.little);
    offset += 2;

    buffer.setUint8(offset++, 0x64); // 'd'
    buffer.setUint8(offset++, 0x61); // 'a'
    buffer.setUint8(offset++, 0x74); // 't'
    buffer.setUint8(offset++, 0x61); // 'a'
    buffer.setUint32(offset, dataSize, Endian.little);
    offset += 4;

    for (var i = 0; i < pcmSamples.length; i++) {
      buffer.setInt16(offset, pcmSamples[i], Endian.little);
      offset += 2;
    }

    return buffer.buffer.asUint8List();
  }

  /// Play a music track
  Future<void> _playTrack(MusicTrack track) async {
    print('>>> MusicGenerationService: _playTrack called with file: ${track.filePath}');
    _currentTrack = track;
    final duration = await _audioService.load(track.filePath);
    print('>>> MusicGenerationService: Audio loaded, duration: $duration');
    await _audioService.play();
    print('>>> MusicGenerationService: Audio play() called');
  }

  /// Play a specific track
  Future<void> play(MusicTrack track) async {
    await _playTrack(track);
  }

  /// Pause current playback
  Future<void> pause() async {
    await _audioService.pause();
  }

  /// Resume current playback
  Future<void> resume() async {
    await _audioService.play();
  }

  /// Stop current playback
  Future<void> stop() async {
    await _audioService.stop();
    _currentTrack = null;
  }

  /// Seek to position
  Future<void> seek(Duration position) async {
    await _audioService.seek(position);
  }

  /// Get saved tracks
  Future<List<MusicTrack>> getSavedTracks() async {
    return await _storage.getSavedTracks();
  }

  /// Delete a saved track
  Future<void> deleteTrack(String trackId) async {
    await _storage.deleteTrack(trackId);
  }

  /// Get available RAM in MB (approximate)
  Future<int> _getAvailableRamMb() async {
    try {
      if (Platform.isAndroid) {
        // On Android, estimate based on typical device tiers
        // This could be improved with a native plugin
        return 4000; // Assume mid-range device
      } else if (Platform.isIOS) {
        return 4000; // Modern iOS devices typically have 4GB+
      } else if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        return 8000; // Desktop devices
      }
    } catch (e) {
      LogService()
          .log('MusicGenerationService: Failed to get RAM info: $e');
    }
    return 2000; // Conservative fallback
  }

  /// Get recommended model for this device (may not be downloaded)
  MusicModelInfo getRecommendedModel() {
    // Use a reasonable default for now
    return _modelManager.getRecommendedModel(4000);
  }

  /// Check if any AI model is downloaded
  Future<bool> hasAIModel() async {
    if (kIsWeb) return false;
    final downloaded = await _modelManager.getDownloadedModels();
    return downloaded.isNotEmpty;
  }

  /// Download the recommended AI model
  Stream<double> downloadRecommendedModel() async* {
    final recommended = getRecommendedModel();
    if (recommended.isNative) {
      yield 1.0;
      return;
    }

    yield* _modelManager.downloadModel(recommended.id);
  }
}
