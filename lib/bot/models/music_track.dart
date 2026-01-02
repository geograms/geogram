/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Represents a generated music track
class MusicTrack {
  /// Unique identifier for the track
  final String id;

  /// Path to the audio file
  final String filePath;

  /// Detected/specified genre
  final String genre;

  /// Original user prompt
  final String prompt;

  /// Track duration
  final Duration duration;

  /// When the track was created
  final DateTime createdAt;

  /// Which model was used to generate this track
  final String modelUsed;

  /// Whether this was generated with FM synthesis fallback
  final bool isFMFallback;

  /// Generation statistics (optional)
  final MusicGenerationStats? stats;

  const MusicTrack({
    required this.id,
    required this.filePath,
    required this.genre,
    required this.prompt,
    required this.duration,
    required this.createdAt,
    required this.modelUsed,
    this.isFMFallback = false,
    this.stats,
  });

  /// Get display-friendly genre name
  String get genreDisplayName {
    switch (genre.toLowerCase()) {
      case 'rock':
        return 'Rock';
      case 'metal':
        return 'Metal';
      case 'jazz':
        return 'Jazz';
      case 'blues':
        return 'Blues';
      case 'electronic':
        return 'Electronic';
      case 'techno':
        return 'Techno';
      case 'house':
        return 'House';
      case 'ambient':
        return 'Ambient';
      case 'classical':
        return 'Classical';
      case 'pop':
        return 'Pop';
      case 'lofi':
        return 'Lo-Fi';
      case 'cinematic':
        return 'Cinematic';
      default:
        return genre[0].toUpperCase() + genre.substring(1);
    }
  }

  /// Get model display name
  String get modelDisplayName {
    if (isFMFallback) return 'FM Synthesis';
    switch (modelUsed) {
      case 'fm-synth':
        return 'FM Synthesis';
      case 'musicgen-tiny-jungle':
        return 'MusicGen Tiny (Jungle FP32)';
      default:
        return modelUsed;
    }
  }

  /// Get duration as formatted string (mm:ss)
  String get durationString {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'genre': genre,
        'prompt': prompt,
        'durationMs': duration.inMilliseconds,
        'createdAt': createdAt.toIso8601String(),
        'modelUsed': modelUsed,
        'isFMFallback': isFMFallback,
        if (stats != null) 'stats': stats!.toJson(),
      };

  factory MusicTrack.fromJson(Map<String, dynamic> json) {
    return MusicTrack(
      id: json['id'] as String,
      filePath: json['filePath'] as String,
      genre: json['genre'] as String,
      prompt: json['prompt'] as String,
      duration: Duration(milliseconds: json['durationMs'] as int),
      createdAt: DateTime.parse(json['createdAt'] as String),
      modelUsed: json['modelUsed'] as String,
      isFMFallback: json['isFMFallback'] as bool? ?? false,
      stats: json['stats'] != null
          ? MusicGenerationStats.fromJson(json['stats'] as Map<String, dynamic>)
          : null,
    );
  }

  MusicTrack copyWith({
    String? id,
    String? filePath,
    String? genre,
    String? prompt,
    Duration? duration,
    DateTime? createdAt,
    String? modelUsed,
    bool? isFMFallback,
    MusicGenerationStats? stats,
  }) {
    return MusicTrack(
      id: id ?? this.id,
      filePath: filePath ?? this.filePath,
      genre: genre ?? this.genre,
      prompt: prompt ?? this.prompt,
      duration: duration ?? this.duration,
      createdAt: createdAt ?? this.createdAt,
      modelUsed: modelUsed ?? this.modelUsed,
      isFMFallback: isFMFallback ?? this.isFMFallback,
      stats: stats ?? this.stats,
    );
  }
}

/// Statistics about the music generation process
class MusicGenerationStats {
  /// Time taken to generate in milliseconds
  final int processingTimeMs;

  /// Model version used
  final String? modelVersion;

  /// Quality level setting used
  final String qualityLevel;

  /// File size in bytes
  final int? fileSizeBytes;

  const MusicGenerationStats({
    required this.processingTimeMs,
    this.modelVersion,
    this.qualityLevel = 'standard',
    this.fileSizeBytes,
  });

  /// Get processing time as formatted string
  String get processingTimeString {
    final seconds = processingTimeMs / 1000;
    if (seconds < 60) {
      return '${seconds.toStringAsFixed(1)}s';
    }
    final minutes = (seconds / 60).floor();
    final remainingSeconds = (seconds % 60).round();
    return '${minutes}m ${remainingSeconds}s';
  }

  Map<String, dynamic> toJson() => {
        'processingTimeMs': processingTimeMs,
        if (modelVersion != null) 'modelVersion': modelVersion,
        'qualityLevel': qualityLevel,
        if (fileSizeBytes != null) 'fileSizeBytes': fileSizeBytes,
      };

  factory MusicGenerationStats.fromJson(Map<String, dynamic> json) {
    return MusicGenerationStats(
      processingTimeMs: json['processingTimeMs'] as int,
      modelVersion: json['modelVersion'] as String?,
      qualityLevel: json['qualityLevel'] as String? ?? 'standard',
      fileSizeBytes: json['fileSizeBytes'] as int?,
    );
  }
}
