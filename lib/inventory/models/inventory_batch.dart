/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Represents a batch/lot of inventory items
/// Each batch tracks its own quantity and can have expiry dates, costs, etc.
class InventoryBatch {
  final String id;
  double quantity;
  double initialQuantity;
  final DateTime? datePurchased;
  final DateTime? dateExpired;
  final double? cost;
  final String? currency;
  final String? supplier;
  final String? notes;
  final DateTime createdAt;
  DateTime updatedAt;

  InventoryBatch({
    required this.id,
    required this.quantity,
    double? initialQuantity,
    this.datePurchased,
    this.dateExpired,
    this.cost,
    this.currency,
    this.supplier,
    this.notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : initialQuantity = initialQuantity ?? quantity,
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Check if this batch is expired
  bool get isExpired {
    if (dateExpired == null) return false;
    return DateTime.now().isAfter(dateExpired!);
  }

  /// Check if this batch expires soon (within 7 days)
  bool get expiresSoon {
    if (dateExpired == null) return false;
    final daysUntilExpiry = dateExpired!.difference(DateTime.now()).inDays;
    return daysUntilExpiry >= 0 && daysUntilExpiry <= 7;
  }

  /// Days until expiry (negative if expired)
  int? get daysUntilExpiry {
    if (dateExpired == null) return null;
    return dateExpired!.difference(DateTime.now()).inDays;
  }

  /// Check if batch has remaining quantity
  bool get hasStock => quantity > 0;

  InventoryBatch copyWith({
    String? id,
    double? quantity,
    double? initialQuantity,
    DateTime? datePurchased,
    DateTime? dateExpired,
    double? cost,
    String? currency,
    String? supplier,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return InventoryBatch(
      id: id ?? this.id,
      quantity: quantity ?? this.quantity,
      initialQuantity: initialQuantity ?? this.initialQuantity,
      datePurchased: datePurchased ?? this.datePurchased,
      dateExpired: dateExpired ?? this.dateExpired,
      cost: cost ?? this.cost,
      currency: currency ?? this.currency,
      supplier: supplier ?? this.supplier,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'quantity': quantity,
      'initial_quantity': initialQuantity,
      'date_purchased': datePurchased?.toIso8601String(),
      'date_expired': dateExpired?.toIso8601String(),
      'cost': cost,
      'currency': currency,
      'supplier': supplier,
      'notes': notes,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory InventoryBatch.fromJson(Map<String, dynamic> json) {
    final qty = (json['quantity'] as num).toDouble();
    return InventoryBatch(
      id: json['id'] as String,
      quantity: qty,
      initialQuantity: (json['initial_quantity'] as num?)?.toDouble() ?? qty,
      datePurchased: json['date_purchased'] != null
          ? DateTime.parse(json['date_purchased'] as String)
          : null,
      dateExpired: json['date_expired'] != null
          ? DateTime.parse(json['date_expired'] as String)
          : null,
      cost: json['cost'] != null ? (json['cost'] as num).toDouble() : null,
      currency: json['currency'] as String?,
      supplier: json['supplier'] as String?,
      notes: json['notes'] as String?,
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
    return 'InventoryBatch(id: $id, quantity: $quantity, expired: $isExpired)';
  }
}
