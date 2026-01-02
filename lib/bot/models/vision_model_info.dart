/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Information about a vision model available for download
class VisionModelInfo {
  /// Unique identifier for the model
  final String id;

  /// Display name
  final String name;

  /// Model tier: 'lite', 'standard', 'quality', 'premium'
  final String tier;

  /// Category: 'general', 'plant', 'ocr', 'detection'
  final String category;

  /// Model size in bytes
  final int size;

  /// List of capabilities: 'classification', 'object_detection', 'visual_qa', 'ocr', 'translation', 'plant_id'
  final List<String> capabilities;

  /// Download URL (HuggingFace or other source)
  final String url;

  /// Model format: 'tflite', 'gguf'
  final String format;

  /// Brief description of the model
  final String description;

  /// Minimum recommended RAM in MB
  final int minRamMb;

  const VisionModelInfo({
    required this.id,
    required this.name,
    required this.tier,
    required this.category,
    required this.size,
    required this.capabilities,
    required this.url,
    required this.format,
    required this.description,
    this.minRamMb = 500,
  });

  /// Get human-readable size string
  String get sizeString {
    if (size < 1024) {
      return '$size B';
    } else if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    } else if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(0)} MB';
    } else {
      return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
  }

  /// Check if model supports a specific capability
  bool hasCapability(String capability) => capabilities.contains(capability);

  /// Get tier display name
  String get tierDisplayName {
    switch (tier) {
      case 'lite':
        return 'Lite';
      case 'standard':
        return 'Standard';
      case 'quality':
        return 'Quality';
      case 'premium':
        return 'Premium';
      default:
        return tier;
    }
  }

  /// Get category display name
  String get categoryDisplayName {
    switch (category) {
      case 'general':
        return 'General Vision';
      case 'plant':
        return 'Plant & Nature';
      case 'ocr':
        return 'Text Recognition';
      case 'detection':
        return 'Object Detection';
      default:
        return category;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tier': tier,
        'category': category,
        'size': size,
        'capabilities': capabilities,
        'url': url,
        'format': format,
        'description': description,
        'minRamMb': minRamMb,
      };

  factory VisionModelInfo.fromJson(Map<String, dynamic> json) {
    return VisionModelInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      tier: json['tier'] as String,
      category: json['category'] as String,
      size: json['size'] as int,
      capabilities: (json['capabilities'] as List<dynamic>).cast<String>(),
      url: json['url'] as String,
      format: json['format'] as String,
      description: json['description'] as String,
      minRamMb: json['minRamMb'] as int? ?? 500,
    );
  }
}

/// Available vision models for download
class VisionModels {
  static const List<VisionModelInfo> available = [
    // Lite tier - TensorFlow Lite models (fast, small)
    VisionModelInfo(
      id: 'mobilenet-v3',
      name: 'MobileNet v3',
      tier: 'lite',
      category: 'general',
      size: 5 * 1024 * 1024, // 5 MB
      capabilities: ['classification'],
      url: 'https://tfhub.dev/google/lite-model/imagenet/mobilenet_v3_small_100_224/classification/5/default/1',
      format: 'tflite',
      description: 'Fast image classification - identifies objects in photos',
      minRamMb: 100,
    ),
    VisionModelInfo(
      id: 'efficientdet-lite0',
      name: 'EfficientDet Lite',
      tier: 'lite',
      category: 'detection',
      size: 20 * 1024 * 1024, // 20 MB
      capabilities: ['object_detection'],
      url: 'https://tfhub.dev/tensorflow/lite-model/efficientdet/lite0/detection/metadata/1',
      format: 'tflite',
      description: 'Object detection with bounding boxes',
      minRamMb: 200,
    ),
    VisionModelInfo(
      id: 'mobilenet-v3-small',
      name: 'MobileNet V3 Small',
      tier: 'lite',
      category: 'general',
      size: 10 * 1024 * 1024, // 10.2 MB
      capabilities: ['classification'],
      url: 'https://huggingface.co/qualcomm/MobileNet-v3-Small/resolve/main/MobileNet-v3-Small_float.tflite',
      format: 'tflite',
      description: 'Fast image classification (1000 categories)',
      minRamMb: 200,
    ),
    VisionModelInfo(
      id: 'mobilenet-v4-medium',
      name: 'MobileNet V4 Medium',
      tier: 'lite',
      category: 'general',
      size: 19 * 1024 * 1024, // 19.4 MB
      capabilities: ['classification'],
      url: 'https://huggingface.co/byoussef/MobileNetV4_Conv_Medium_TFLite_224/resolve/main/mobilenetv4_conv_medium.e500_r224_in1k_float16.tflite',
      format: 'tflite',
      description: 'Better accuracy image classification (1000 categories)',
      minRamMb: 300,
    ),

    // Standard tier - Quantized multimodal models
    VisionModelInfo(
      id: 'llava-7b-q4',
      name: 'LLaVA 7B (Q4)',
      tier: 'standard',
      category: 'general',
      size: 4080 * 1024 * 1024, // 4.08 GB
      capabilities: ['visual_qa', 'classification', 'ocr', 'translation'],
      url: 'https://huggingface.co/mys/ggml_llava-v1.5-7b/resolve/main/ggml-model-q4_k.gguf',
      format: 'gguf',
      description: 'Full visual Q&A - ask any question about images',
      minRamMb: 6000,
    ),

    // Quality tier - Better quantization
    VisionModelInfo(
      id: 'llava-7b-q5',
      name: 'LLaVA 7B (Q5)',
      tier: 'quality',
      category: 'general',
      size: 4780 * 1024 * 1024, // 4.78 GB
      capabilities: ['visual_qa', 'classification', 'ocr', 'translation'],
      url: 'https://huggingface.co/mys/ggml_llava-v1.5-7b/resolve/main/ggml-model-q5_k.gguf',
      format: 'gguf',
      description: 'Better quality visual Q&A with improved accuracy',
      minRamMb: 8000,
    ),
  ];

  /// Get models by tier
  static List<VisionModelInfo> byTier(String tier) =>
      available.where((m) => m.tier == tier).toList();

  /// Get models by category
  static List<VisionModelInfo> byCategory(String category) =>
      available.where((m) => m.category == category).toList();

  /// Get models by capability
  static List<VisionModelInfo> withCapability(String capability) =>
      available.where((m) => m.hasCapability(capability)).toList();

  /// Get model by ID
  static VisionModelInfo? getById(String id) {
    try {
      return available.firstWhere((m) => m.id == id);
    } catch (_) {
      return null;
    }
  }
}
