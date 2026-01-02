/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Type of usage event
enum UsageType {
  /// Consumed/used quantity (reduces stock)
  consume,

  /// Refilled/added quantity (increases stock)
  refill,

  /// Manual adjustment (can increase or decrease)
  adjustment,
}

/// Represents a usage event for an inventory item
class InventoryUsage {
  final String id;
  final String itemId;
  final UsageType type;
  final double quantity;
  final String? unit;
  final DateTime date;
  final String? batchId;
  final String? reason;
  final String? notes;
  final DateTime createdAt;

  InventoryUsage({
    required this.id,
    required this.itemId,
    required this.type,
    required this.quantity,
    this.unit,
    DateTime? date,
    this.batchId,
    this.reason,
    this.notes,
    DateTime? createdAt,
  })  : date = date ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();

  /// Check if this usage reduces stock
  bool get reducesStock => type == UsageType.consume;

  /// Check if this usage increases stock
  bool get increasesStock => type == UsageType.refill;

  /// Get the effective quantity change (positive for additions, negative for reductions)
  double get effectiveChange {
    switch (type) {
      case UsageType.consume:
        return -quantity;
      case UsageType.refill:
        return quantity;
      case UsageType.adjustment:
        return quantity; // Can be positive or negative
    }
  }

  /// Get human-readable type string
  String get typeDisplay {
    switch (type) {
      case UsageType.consume:
        return 'Consumed';
      case UsageType.refill:
        return 'Refilled';
      case UsageType.adjustment:
        return 'Adjusted';
    }
  }

  InventoryUsage copyWith({
    String? id,
    String? itemId,
    UsageType? type,
    double? quantity,
    String? unit,
    DateTime? date,
    String? batchId,
    String? reason,
    String? notes,
    DateTime? createdAt,
  }) {
    return InventoryUsage(
      id: id ?? this.id,
      itemId: itemId ?? this.itemId,
      type: type ?? this.type,
      quantity: quantity ?? this.quantity,
      unit: unit ?? this.unit,
      date: date ?? this.date,
      batchId: batchId ?? this.batchId,
      reason: reason ?? this.reason,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'item_id': itemId,
      'type': type.name,
      'quantity': quantity,
      'unit': unit,
      'date': date.toIso8601String(),
      'batch_id': batchId,
      'reason': reason,
      'notes': notes,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory InventoryUsage.fromJson(Map<String, dynamic> json) {
    return InventoryUsage(
      id: json['id'] as String,
      itemId: json['item_id'] as String,
      type: UsageType.values.byName(json['type'] as String),
      quantity: (json['quantity'] as num).toDouble(),
      unit: json['unit'] as String?,
      date: json['date'] != null
          ? DateTime.parse(json['date'] as String)
          : DateTime.now(),
      batchId: json['batch_id'] as String?,
      reason: json['reason'] as String?,
      notes: json['notes'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
    );
  }

  @override
  String toString() {
    return 'InventoryUsage(id: $id, type: $type, quantity: $quantity)';
  }
}
