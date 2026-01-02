/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Information about a music generation model available for use
class MusicModelFile {
  /// Relative path within the model folder (can include subdirectories)
  final String path;

  /// File size in bytes (optional, 0 = unknown)
  final int size;

  const MusicModelFile({
    required this.path,
    this.size = 0,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'size': size,
      };

  factory MusicModelFile.fromJson(Map<String, dynamic> json) {
    return MusicModelFile(
      path: json['path'] as String,
      size: json['size'] as int? ?? 0,
    );
  }
}

/// Information about a music generation model available for use
class MusicModelInfo {
  /// Unique identifier for the model
  final String id;

  /// Display name
  final String name;

  /// Model tier: 'instant', 'lite', 'standard', 'quality'
  final String tier;

  /// Model size in bytes (0 for FM synthesis)
  final int size;

  /// Model format: 'native' (FM synth), 'onnx', 'tflite'
  final String format;

  /// Download URL (null for native FM synthesis)
  final String? url;

  /// HuggingFace repo ID for multi-file models (e.g. "owner/repo")
  final String? repoId;

  /// Required files for the model (empty for native or legacy single-file models)
  final List<MusicModelFile> files;

  /// Brief description of the model
  final String description;

  /// Minimum recommended RAM in MB
  final int minRamMb;

  /// Maximum duration in seconds this model can generate
  final int maxDurationSec;

  /// Generation speed ratio (e.g., 0.73 means 11s audio in 8s)
  /// Values > 1 mean faster than real-time, < 1 mean slower
  final double genSpeedRatio;

  /// Supported genres/styles
  final List<String> genres;

  const MusicModelInfo({
    required this.id,
    required this.name,
    required this.tier,
    required this.size,
    required this.format,
    this.url,
    this.repoId,
    this.files = const [],
    required this.description,
    this.minRamMb = 0,
    this.maxDurationSec = 300,
    this.genSpeedRatio = 1.0,
    this.genres = const [],
  });

  /// Get human-readable size string
  String get sizeString {
    if (size == 0) {
      return 'Built-in';
    } else if (size < 1024) {
      return '$size B';
    } else if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    } else if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(0)} MB';
    } else {
      return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
  }

  /// Check if this is the native FM synthesis (no download required)
  bool get isNative => format == 'native';

  /// Check if model supports a specific genre
  bool supportsGenre(String genre) =>
      genres.isEmpty || genres.contains(genre.toLowerCase());

  /// Whether this model uses multiple files
  bool get hasFiles => files.isNotEmpty;

  /// Estimate generation time for a given duration
  Duration estimateGenerationTime(Duration audioDuration) {
    if (genSpeedRatio >= 1.0) {
      return Duration.zero; // Real-time or faster
    }
    final seconds = audioDuration.inSeconds / genSpeedRatio;
    return Duration(seconds: seconds.round());
  }

  /// Get tier display name
  String get tierDisplayName {
    switch (tier) {
      case 'instant':
        return 'Instant';
      case 'lite':
        return 'Lite';
      case 'standard':
        return 'Standard';
      case 'quality':
        return 'Quality';
      default:
        return tier;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tier': tier,
        'size': size,
        'format': format,
        if (url != null) 'url': url,
        if (repoId != null) 'repoId': repoId,
        if (files.isNotEmpty) 'files': files.map((f) => f.toJson()).toList(),
        'description': description,
        'minRamMb': minRamMb,
        'maxDurationSec': maxDurationSec,
        'genSpeedRatio': genSpeedRatio,
        'genres': genres,
      };

  factory MusicModelInfo.fromJson(Map<String, dynamic> json) {
    return MusicModelInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      tier: json['tier'] as String,
      size: json['size'] as int,
      format: json['format'] as String,
      url: json['url'] as String?,
      repoId: json['repoId'] as String?,
      files: (json['files'] as List<dynamic>?)
              ?.map((f) => MusicModelFile.fromJson(f as Map<String, dynamic>))
              .toList() ??
          const [],
      description: json['description'] as String,
      minRamMb: json['minRamMb'] as int? ?? 0,
      maxDurationSec: json['maxDurationSec'] as int? ?? 300,
      genSpeedRatio: (json['genSpeedRatio'] as num?)?.toDouble() ?? 1.0,
      genres: (json['genres'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }
}

/// Available music generation models
class MusicModels {
  /// FM Synthesis - always available, no download required
  static const fmSynth = MusicModelInfo(
    id: 'fm-synth',
    name: 'FM Synthesis',
    tier: 'instant',
    size: 0,
    format: 'native',
    description: 'Instant procedural music - works on all devices',
    minRamMb: 0,
    maxDurationSec: 3600, // 1 hour
    genSpeedRatio: 100.0, // Effectively instant
    genres: ['rock', 'jazz', 'electronic', 'ambient', 'classical', 'lofi'],
  );

  /// MusicGen Tiny (ONNX, FP32)
  static const musicgenTiny = MusicModelInfo(
    id: 'musicgen-tiny-jungle',
    name: 'MusicGen Tiny (Jungle FP32)',
    tier: 'lite',
    size: 1872143394, // Sum of required ONNX files (approx)
    format: 'onnx',
    repoId: 'pharoAIsanders420/musicgen-tiny-jungle-onnx',
    files: [
      MusicModelFile(
        path: 'onnx/text_encoder.onnx',
        size: 438689759,
      ),
      MusicModelFile(
        path: 'onnx/decoder_model.onnx',
        size: 694425570,
      ),
      MusicModelFile(
        path: 'onnx/decoder_with_past_model.onnx',
        size: 620993470,
      ),
      MusicModelFile(
        path: 'onnx/encodec_decode.onnx',
        size: 118034595,
      ),
      MusicModelFile(path: 'config.json'),
      MusicModelFile(path: 'generation_config.json'),
      MusicModelFile(path: 'preprocessor_config.json'),
      MusicModelFile(path: 'tokenizer.json'),
      MusicModelFile(path: 'tokenizer_config.json'),
      MusicModelFile(path: 'special_tokens_map.json'),
    ],
    description: 'Text-to-audio generation (ONNX, FP32)',
    minRamMb: 6000,
    maxDurationSec: 30,
    genSpeedRatio: 0.25,
    genres: [
      'rock',
      'metal',
      'jazz',
      'electronic',
      'ambient',
      'classical',
      'lofi',
      'cinematic',
    ],
  );

  /// All available models
  static const List<MusicModelInfo> available = [
    fmSynth,
    musicgenTiny,
  ];

  /// AI models only (excludes FM synth)
  static List<MusicModelInfo> get aiModels =>
      available.where((m) => !m.isNative).toList();

  /// Get models by tier
  static List<MusicModelInfo> byTier(String tier) =>
      available.where((m) => m.tier == tier).toList();

  /// Get model by ID
  static MusicModelInfo? getById(String id) {
    try {
      return available.firstWhere((m) => m.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Select best model for available RAM
  static MusicModelInfo selectForRam(int availableRamMb) {
    if (availableRamMb >= musicgenTiny.minRamMb) {
      return musicgenTiny;
    }
    return fmSynth;
  }

  /// Get models that support a specific genre
  static List<MusicModelInfo> forGenre(String genre) =>
      available.where((m) => m.supportsGenre(genre)).toList();
}
