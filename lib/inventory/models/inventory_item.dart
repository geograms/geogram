/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'inventory_batch.dart';

/// Represents an item in the inventory
/// Items are generic definitions; batches contain the actual quantities
class InventoryItem {
  final String id;
  String title;
  String type;
  String unit;
  List<InventoryBatch> batches;
  List<String> media;
  Map<String, dynamic> specs;
  Map<String, dynamic> customFields;
  Map<String, String> translations;

  // Location fields (like Event model)
  String location; // Empty or "lat,lon"
  String? locationName;
  Map<String, dynamic> metadata;

  final DateTime createdAt;
  DateTime updatedAt;

  InventoryItem({
    required this.id,
    required this.title,
    required this.type,
    this.unit = 'units',
    List<InventoryBatch>? batches,
    List<String>? media,
    Map<String, dynamic>? specs,
    Map<String, dynamic>? customFields,
    Map<String, String>? translations,
    this.location = '',
    this.locationName,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : batches = batches ?? [],
        media = media ?? [],
        specs = specs ?? {},
        customFields = customFields ?? {},
        translations = translations ?? {},
        metadata = metadata ?? {},
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Get place path from metadata (reference to Place from Places app)
  String? get placePath => metadata['place_path'] as String?;

  /// Set place path in metadata
  set placePath(String? value) {
    if (value != null) {
      metadata['place_path'] = value;
    } else {
      metadata.remove('place_path');
    }
  }

  /// Check if item has coordinates
  bool get hasCoordinates => location.isNotEmpty && location.contains(',');

  /// Check if item has a place reference
  bool get hasPlace => placePath != null && placePath!.isNotEmpty;

  /// Get latitude from location string
  double? get latitude {
    if (!hasCoordinates) return null;
    final parts = location.split(',');
    return double.tryParse(parts[0]);
  }

  /// Get longitude from location string
  double? get longitude {
    if (!hasCoordinates) return null;
    final parts = location.split(',');
    if (parts.length < 2) return null;
    return double.tryParse(parts[1]);
  }

  /// Set coordinates
  void setCoordinates(double lat, double lon) {
    location = '$lat,$lon';
  }

  /// Clear location
  void clearLocation() {
    location = '';
    locationName = null;
    placePath = null;
  }

  /// Get the localized title for a language code
  String getTitle(String langCode) {
    return translations['${langCode}_title'] ?? title;
  }

  /// Total quantity from all batches
  double get quantity {
    if (batches.isEmpty) return 0;
    return batches.fold(0.0, (sum, batch) => sum + batch.quantity);
  }

  /// Total initial quantity from all batches
  double get initialQuantity {
    if (batches.isEmpty) return 0;
    return batches.fold(0.0, (sum, batch) => sum + batch.initialQuantity);
  }

  /// Check if any batch is expired
  bool get hasExpiredBatch {
    return batches.any((batch) => batch.isExpired);
  }

  /// Check if any batch expires soon
  bool get hasExpiringSoon {
    return batches.any((batch) => batch.expiresSoon);
  }

  /// Get quantity used (consumed)
  double get quantityUsed => initialQuantity - quantity;

  /// Get usage percentage (0.0 - 1.0)
  double get usagePercent {
    if (initialQuantity <= 0) return 0;
    return quantityUsed / initialQuantity;
  }

  /// Check if stock is low (below 20%)
  bool get isLowStock {
    if (initialQuantity <= 0) return false;
    return (quantity / initialQuantity) < 0.2;
  }

  /// Check if item is out of stock
  bool get isOutOfStock => quantity <= 0;

  /// Get the first media item as thumbnail
  String? get thumbnail => media.isNotEmpty ? media.first : null;

  InventoryItem copyWith({
    String? id,
    String? title,
    String? type,
    String? unit,
    List<InventoryBatch>? batches,
    List<String>? media,
    Map<String, dynamic>? specs,
    Map<String, dynamic>? customFields,
    Map<String, String>? translations,
    String? location,
    String? locationName,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return InventoryItem(
      id: id ?? this.id,
      title: title ?? this.title,
      type: type ?? this.type,
      unit: unit ?? this.unit,
      batches: batches ?? this.batches.map((b) => b.copyWith()).toList(),
      media: media ?? List.from(this.media),
      specs: specs ?? Map.from(this.specs),
      customFields: customFields ?? Map.from(this.customFields),
      translations: translations ?? Map.from(this.translations),
      location: location ?? this.location,
      locationName: locationName ?? this.locationName,
      metadata: metadata ?? Map.from(this.metadata),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'type': type,
      'unit': unit,
      'batches': batches.map((b) => b.toJson()).toList(),
      'media': media,
      'specs': specs,
      'custom_fields': customFields,
      'translations': translations,
      'location': location,
      'location_name': locationName,
      'metadata': metadata,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory InventoryItem.fromJson(Map<String, dynamic> json) {
    // Parse batches from JSON
    List<InventoryBatch> batches = (json['batches'] as List<dynamic>?)
            ?.map((b) => InventoryBatch.fromJson(b as Map<String, dynamic>))
            .toList() ??
        [];

    // Handle legacy data: if item has quantity but no batches, create a batch
    if (batches.isEmpty) {
      final legacyQty = (json['quantity'] as num?)?.toDouble() ?? 0;
      if (legacyQty > 0) {
        batches.add(InventoryBatch(
          id: 'legacy_${json['id']}',
          quantity: legacyQty,
          initialQuantity: (json['initial_quantity'] as num?)?.toDouble() ?? legacyQty,
          datePurchased: json['created_at'] != null
              ? DateTime.parse(json['created_at'] as String)
              : DateTime.now(),
        ));
      }
    }

    return InventoryItem(
      id: json['id'] as String,
      title: json['title'] as String,
      type: json['type'] as String? ?? 'other',
      unit: json['unit'] as String? ?? 'units',
      batches: batches,
      media: (json['media'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      specs: json['specs'] as Map<String, dynamic>? ?? {},
      customFields: json['custom_fields'] as Map<String, dynamic>? ?? {},
      translations: (json['translations'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          {},
      location: json['location'] as String? ?? '',
      locationName: json['location_name'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>? ?? {},
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
    return 'InventoryItem(id: $id, title: $title, quantity: $quantity $unit)';
  }
}
