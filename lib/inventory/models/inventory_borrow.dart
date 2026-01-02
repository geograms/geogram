/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Type of borrower
enum BorrowerType {
  /// A geogram user identified by callsign
  callsign,

  /// Free text description (external person/entity)
  text,
}

/// Represents a borrow event for an inventory item
class InventoryBorrow {
  final String id;
  final String itemId;
  final double quantity;
  final String? unit;
  final BorrowerType borrowerType;
  final String? borrowerCallsign;
  final String? borrowerText;
  final DateTime borrowedAt;
  final DateTime? expectedReturnAt;
  DateTime? returnedAt;
  double? returnedQuantity;
  final String? notes;
  final DateTime createdAt;
  DateTime updatedAt;

  InventoryBorrow({
    required this.id,
    required this.itemId,
    required this.quantity,
    this.unit,
    required this.borrowerType,
    this.borrowerCallsign,
    this.borrowerText,
    required this.borrowedAt,
    this.expectedReturnAt,
    this.returnedAt,
    this.returnedQuantity,
    this.notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Check if this borrow is still active (not returned)
  bool get isActive => returnedAt == null;

  /// Check if return is overdue
  bool get isOverdue {
    if (!isActive || expectedReturnAt == null) return false;
    return DateTime.now().isAfter(expectedReturnAt!);
  }

  /// Get the borrower display name
  String get borrowerDisplay {
    if (borrowerType == BorrowerType.callsign) {
      return borrowerCallsign ?? 'Unknown';
    }
    return borrowerText ?? 'Unknown';
  }

  /// Days overdue (0 if not overdue)
  int get daysOverdue {
    if (!isOverdue || expectedReturnAt == null) return 0;
    return DateTime.now().difference(expectedReturnAt!).inDays;
  }

  InventoryBorrow copyWith({
    String? id,
    String? itemId,
    double? quantity,
    String? unit,
    BorrowerType? borrowerType,
    String? borrowerCallsign,
    String? borrowerText,
    DateTime? borrowedAt,
    DateTime? expectedReturnAt,
    DateTime? returnedAt,
    double? returnedQuantity,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return InventoryBorrow(
      id: id ?? this.id,
      itemId: itemId ?? this.itemId,
      quantity: quantity ?? this.quantity,
      unit: unit ?? this.unit,
      borrowerType: borrowerType ?? this.borrowerType,
      borrowerCallsign: borrowerCallsign ?? this.borrowerCallsign,
      borrowerText: borrowerText ?? this.borrowerText,
      borrowedAt: borrowedAt ?? this.borrowedAt,
      expectedReturnAt: expectedReturnAt ?? this.expectedReturnAt,
      returnedAt: returnedAt ?? this.returnedAt,
      returnedQuantity: returnedQuantity ?? this.returnedQuantity,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'item_id': itemId,
      'quantity': quantity,
      'unit': unit,
      'borrower_type': borrowerType.name,
      'borrower_callsign': borrowerCallsign,
      'borrower_text': borrowerText,
      'borrowed_at': borrowedAt.toIso8601String(),
      'expected_return_at': expectedReturnAt?.toIso8601String(),
      'returned_at': returnedAt?.toIso8601String(),
      'returned_quantity': returnedQuantity,
      'notes': notes,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory InventoryBorrow.fromJson(Map<String, dynamic> json) {
    return InventoryBorrow(
      id: json['id'] as String,
      itemId: json['item_id'] as String,
      quantity: (json['quantity'] as num).toDouble(),
      unit: json['unit'] as String?,
      borrowerType: BorrowerType.values.byName(json['borrower_type'] as String),
      borrowerCallsign: json['borrower_callsign'] as String?,
      borrowerText: json['borrower_text'] as String?,
      borrowedAt: DateTime.parse(json['borrowed_at'] as String),
      expectedReturnAt: json['expected_return_at'] != null
          ? DateTime.parse(json['expected_return_at'] as String)
          : null,
      returnedAt: json['returned_at'] != null
          ? DateTime.parse(json['returned_at'] as String)
          : null,
      returnedQuantity: json['returned_quantity'] != null
          ? (json['returned_quantity'] as num).toDouble()
          : null,
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
    return 'InventoryBorrow(id: $id, quantity: $quantity, borrower: $borrowerDisplay, active: $isActive)';
  }
}
