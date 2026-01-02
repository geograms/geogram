/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Visibility settings for a folder
enum FolderVisibility {
  /// Visible to owner only
  private,

  /// Visible to specified groups
  shared,

  /// Visible to all
  public,
}

/// Represents a folder in the inventory hierarchy
class InventoryFolder {
  final String id;
  String name;
  final String? parentId;
  final int depth;
  FolderVisibility visibility;
  List<String> sharedGroups;
  Map<String, String> translations;
  final DateTime createdAt;
  DateTime updatedAt;

  /// Maximum folder depth allowed
  static const int maxDepth = 5;

  InventoryFolder({
    required this.id,
    required this.name,
    this.parentId,
    this.depth = 0,
    this.visibility = FolderVisibility.private,
    List<String>? sharedGroups,
    Map<String, String>? translations,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : sharedGroups = sharedGroups ?? [],
        translations = translations ?? {},
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Check if this is a root folder
  bool get isRoot => parentId == null;

  /// Check if subfolder creation is allowed
  bool get canCreateSubfolder => depth < maxDepth;

  /// Get the localized name for a language code
  String getName(String langCode) {
    return translations[langCode] ?? name;
  }

  InventoryFolder copyWith({
    String? id,
    String? name,
    String? parentId,
    int? depth,
    FolderVisibility? visibility,
    List<String>? sharedGroups,
    Map<String, String>? translations,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return InventoryFolder(
      id: id ?? this.id,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      depth: depth ?? this.depth,
      visibility: visibility ?? this.visibility,
      sharedGroups: sharedGroups ?? List.from(this.sharedGroups),
      translations: translations ?? Map.from(this.translations),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'parent_id': parentId,
      'depth': depth,
      'visibility': visibility.name,
      'shared_groups': sharedGroups,
      'translations': translations,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory InventoryFolder.fromJson(Map<String, dynamic> json) {
    return InventoryFolder(
      id: json['id'] as String,
      name: json['name'] as String,
      parentId: json['parent_id'] as String?,
      depth: json['depth'] as int? ?? 0,
      visibility: json['visibility'] != null
          ? FolderVisibility.values.byName(json['visibility'] as String)
          : FolderVisibility.private,
      sharedGroups: (json['shared_groups'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      translations: (json['translations'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          {},
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : DateTime.now(),
    );
  }

  @override
  String toString() {
    return 'InventoryFolder(id: $id, name: $name, depth: $depth)';
  }
}
