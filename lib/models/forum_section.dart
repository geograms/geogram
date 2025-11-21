/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Represents a forum section (category)
class ForumSection implements Comparable<ForumSection> {
  /// Unique section identifier
  final String id;

  /// Display name of the section
  final String name;

  /// Section folder name
  final String folder;

  /// Section description
  final String? description;

  /// Display order (lower numbers first)
  final int order;

  /// Whether section is read-only
  final bool readonly;

  /// Section configuration
  final ForumSectionConfig? config;

  ForumSection({
    required this.id,
    required this.name,
    required this.folder,
    this.description,
    this.order = 999,
    this.readonly = false,
    this.config,
  });

  /// Create from JSON
  factory ForumSection.fromJson(Map<String, dynamic> json) {
    return ForumSection(
      id: json['id'] as String,
      name: json['name'] as String,
      folder: json['folder'] as String,
      description: json['description'] as String?,
      order: json['order'] as int? ?? 999,
      readonly: json['readonly'] as bool? ?? false,
      config: json['config'] != null
          ? ForumSectionConfig.fromJson(json['config'] as Map<String, dynamic>)
          : null,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'folder': folder,
      if (description != null) 'description': description,
      'order': order,
      'readonly': readonly,
      if (config != null) 'config': config!.toJson(),
    };
  }

  /// Compare by order for sorting
  @override
  int compareTo(ForumSection other) {
    return order.compareTo(other.order);
  }

  /// Copy with modifications
  ForumSection copyWith({
    String? id,
    String? name,
    String? folder,
    String? description,
    int? order,
    bool? readonly,
    ForumSectionConfig? config,
  }) {
    return ForumSection(
      id: id ?? this.id,
      name: name ?? this.name,
      folder: folder ?? this.folder,
      description: description ?? this.description,
      order: order ?? this.order,
      readonly: readonly ?? this.readonly,
      config: config ?? this.config,
    );
  }
}

/// Configuration for a forum section
class ForumSectionConfig {
  /// Visibility level
  final String visibility;

  /// Whether file uploads are allowed
  final bool fileUpload;

  /// Maximum files per post
  final int filesPerPost;

  /// Maximum file size in MB
  final int maxFileSize;

  /// Maximum text length for posts
  final int maxSizeText;

  /// List of moderator npubs
  final List<String> moderators;

  /// Whether new threads can be created
  final bool allowNewThreads;

  /// Whether new threads require approval
  final bool threadsRequireApproval;

  ForumSectionConfig({
    this.visibility = 'PUBLIC',
    this.fileUpload = true,
    this.filesPerPost = 3,
    this.maxFileSize = 10,
    this.maxSizeText = 5000,
    List<String>? moderators,
    this.allowNewThreads = true,
    this.threadsRequireApproval = false,
  }) : moderators = moderators ?? [];

  /// Create default configuration
  factory ForumSectionConfig.defaults({
    required String id,
    required String name,
    String? description,
  }) {
    return ForumSectionConfig(
      visibility: 'PUBLIC',
      fileUpload: true,
      filesPerPost: 3,
      maxFileSize: 10,
      maxSizeText: 5000,
      moderators: [],
      allowNewThreads: true,
      threadsRequireApproval: false,
    );
  }

  /// Create from JSON
  factory ForumSectionConfig.fromJson(Map<String, dynamic> json) {
    return ForumSectionConfig(
      visibility: json['visibility'] as String? ?? 'PUBLIC',
      fileUpload: json['file_upload'] as bool? ?? true,
      filesPerPost: json['files_per_post'] as int? ?? 3,
      maxFileSize: json['max_file_size'] as int? ?? 10,
      maxSizeText: json['max_size_text'] as int? ?? 5000,
      moderators: (json['moderators'] as List?)?.cast<String>() ?? [],
      allowNewThreads: json['allow_new_threads'] as bool? ?? true,
      threadsRequireApproval:
          json['threads_require_approval'] as bool? ?? false,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'visibility': visibility,
      'file_upload': fileUpload,
      'files_per_post': filesPerPost,
      'max_file_size': maxFileSize,
      'max_size_text': maxSizeText,
      'moderators': moderators,
      'allow_new_threads': allowNewThreads,
      'threads_require_approval': threadsRequireApproval,
    };
  }
}
