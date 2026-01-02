/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Represents an item template for quick creation
class InventoryTemplate {
  final String id;
  String name;
  String? description;
  final Map<String, dynamic> itemDefaults;
  Map<String, String> translations;
  int useCount;
  final DateTime createdAt;
  DateTime updatedAt;

  InventoryTemplate({
    required this.id,
    required this.name,
    this.description,
    Map<String, dynamic>? itemDefaults,
    Map<String, String>? translations,
    this.useCount = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : itemDefaults = itemDefaults ?? {},
        translations = translations ?? {},
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Get the localized name for a language code
  String getName(String langCode) {
    return translations['${langCode}_name'] ?? name;
  }

  /// Get the localized description for a language code
  String? getDescription(String langCode) {
    return translations['${langCode}_description'] ?? description;
  }

  /// Increment use count
  void incrementUseCount() {
    useCount++;
    updatedAt = DateTime.now();
  }

  InventoryTemplate copyWith({
    String? id,
    String? name,
    String? description,
    Map<String, dynamic>? itemDefaults,
    Map<String, String>? translations,
    int? useCount,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return InventoryTemplate(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      itemDefaults: itemDefaults ?? Map.from(this.itemDefaults),
      translations: translations ?? Map.from(this.translations),
      useCount: useCount ?? this.useCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'item_defaults': itemDefaults,
      'translations': translations,
      'use_count': useCount,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory InventoryTemplate.fromJson(Map<String, dynamic> json) {
    return InventoryTemplate(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      itemDefaults: json['item_defaults'] as Map<String, dynamic>? ?? {},
      translations: (json['translations'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          {},
      useCount: json['use_count'] as int? ?? 0,
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
    return 'InventoryTemplate(id: $id, name: $name, useCount: $useCount)';
  }
}
