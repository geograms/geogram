/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'package:uuid/uuid.dart';

/// Visibility options for shared folders
enum SharedFolderVisibility {
  public('public', 'Public'),
  private_('private', 'Private'),
  restricted('restricted', 'Restricted');

  final String value;
  final String displayName;

  const SharedFolderVisibility(this.value, this.displayName);

  static SharedFolderVisibility fromValue(String value) {
    for (final v in SharedFolderVisibility.values) {
      if (v.value == value) return v;
    }
    return SharedFolderVisibility.public;
  }
}

/// Model for a shared folder entry within the "Shared" app
class SharedFolder {
  static const String formatVersion = '1.0';

  final String id;
  final String title;
  final String location;
  final SharedFolderVisibility visibility;
  final List<String> allowedReaders;
  final List<String> allowedGroups;
  final String description;
  final DateTime createdAt;
  final DateTime modifiedAt;

  /// File path within storage (set when loaded from disk)
  final String? filePath;

  SharedFolder({
    String? id,
    required this.title,
    required this.location,
    this.visibility = SharedFolderVisibility.public,
    List<String>? allowedReaders,
    List<String>? allowedGroups,
    this.description = '',
    DateTime? createdAt,
    DateTime? modifiedAt,
    this.filePath,
  })  : id = id ?? const Uuid().v4(),
        allowedReaders = allowedReaders ?? [],
        allowedGroups = allowedGroups ?? [],
        createdAt = createdAt ?? DateTime.now(),
        modifiedAt = modifiedAt ?? DateTime.now();

  /// Create a copy with updated fields
  SharedFolder copyWith({
    String? id,
    String? title,
    String? location,
    SharedFolderVisibility? visibility,
    List<String>? allowedReaders,
    List<String>? allowedGroups,
    String? description,
    DateTime? createdAt,
    DateTime? modifiedAt,
    String? filePath,
  }) {
    return SharedFolder(
      id: id ?? this.id,
      title: title ?? this.title,
      location: location ?? this.location,
      visibility: visibility ?? this.visibility,
      allowedReaders: allowedReaders ?? List.from(this.allowedReaders),
      allowedGroups: allowedGroups ?? List.from(this.allowedGroups),
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? DateTime.now(),
      filePath: filePath ?? this.filePath,
    );
  }

  /// Convert to JSON map
  Map<String, dynamic> toJson() {
    return {
      'version': formatVersion,
      'id': id,
      'title': title,
      'location': location,
      'visibility': visibility.value,
      if (allowedReaders.isNotEmpty) 'allowedReaders': allowedReaders,
      if (allowedGroups.isNotEmpty) 'allowedGroups': allowedGroups,
      if (description.isNotEmpty) 'description': description,
      'created': createdAt.toIso8601String(),
      'modified': modifiedAt.toIso8601String(),
    };
  }

  /// Create from JSON map
  factory SharedFolder.fromJson(Map<String, dynamic> json, {String? filePath}) {
    return SharedFolder(
      id: json['id'] as String,
      title: json['title'] as String,
      location: json['location'] as String,
      visibility: SharedFolderVisibility.fromValue(
        json['visibility'] as String? ?? 'public',
      ),
      allowedReaders:
          (json['allowedReaders'] as List<dynamic>?)?.cast<String>() ?? [],
      allowedGroups:
          (json['allowedGroups'] as List<dynamic>?)?.cast<String>() ?? [],
      description: json['description'] as String? ?? '',
      createdAt: DateTime.parse(json['created'] as String),
      modifiedAt: DateTime.parse(json['modified'] as String),
      filePath: filePath,
    );
  }

  /// Serialize to JSON string
  String toJsonString() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  /// Create from JSON string
  factory SharedFolder.fromJsonString(String jsonString, {String? filePath}) {
    return SharedFolder.fromJson(
      jsonDecode(jsonString) as Map<String, dynamic>,
      filePath: filePath,
    );
  }

  /// Generate a sanitized filename from the title
  String get sanitizedFilename {
    return title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  @override
  String toString() =>
      'SharedFolder(id: $id, title: $title, location: $location)';
}
