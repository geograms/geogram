/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:math';

/// Default expense categories
const defaultExpenseCategories = [
  'Food',
  'Transport',
  'Housing',
  'Utilities',
  'Health',
  'Education',
  'Entertainment',
  'Shopping',
  'Material',
  'People',
  'Other',
];

/// Default income categories
const defaultIncomeCategories = [
  'Salary',
  'Freelance',
  'Investment',
  'Gift',
  'Other Income',
];

/// Entry type: income or expense
enum AccountingEntryType {
  income,
  expense,
}

/// Sort order for accounting entries
enum AccountingSortOrder {
  dateDesc,
  dateAsc,
  amountDesc,
  amountAsc,
}

/// View period for the chart
enum AccountingViewPeriod {
  weekly,
  monthly,
}

/// A single accounting entry (income or expense)
class AccountingEntry {
  final String id;
  String description;
  DateTime date;
  double amount;
  AccountingEntryType type;
  String category;
  String? currency; // per-entry currency override; null = use document default
  final DateTime createdAt;

  AccountingEntry({
    required this.id,
    required this.description,
    required this.date,
    required this.amount,
    required this.type,
    required this.category,
    this.currency,
    required this.createdAt,
  });

  factory AccountingEntry.create({
    required String description,
    required DateTime date,
    required double amount,
    required AccountingEntryType type,
    required String category,
    String? currency,
  }) {
    final now = DateTime.now();
    final rnd = Random().nextInt(0xFFFF).toRadixString(36);
    final id = 'entry-${now.millisecondsSinceEpoch.toRadixString(36)}-$rnd';
    return AccountingEntry(
      id: id,
      description: description,
      date: date,
      amount: amount,
      type: type,
      category: category,
      currency: currency,
      createdAt: now,
    );
  }

  factory AccountingEntry.fromJson(Map<String, dynamic> json) {
    return AccountingEntry(
      id: json['id'] as String,
      description: json['description'] as String? ?? '',
      date: DateTime.parse(json['date'] as String),
      amount: (json['amount'] as num).toDouble(),
      type: AccountingEntryType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => AccountingEntryType.expense,
      ),
      category: json['category'] as String? ?? 'Other',
      currency: json['currency'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    'date': date.toIso8601String(),
    'amount': amount,
    'type': type.name,
    'category': category,
    if (currency != null) 'currency': currency,
    'created_at': createdAt.toIso8601String(),
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  AccountingEntry copyWith({
    String? description,
    DateTime? date,
    double? amount,
    AccountingEntryType? type,
    String? category,
    String? currency,
  }) {
    return AccountingEntry(
      id: id,
      description: description ?? this.description,
      date: date ?? this.date,
      amount: amount ?? this.amount,
      type: type ?? this.type,
      category: category ?? this.category,
      currency: currency ?? this.currency,
      createdAt: createdAt,
    );
  }
}

/// Settings for accounting display
class AccountingSettings {
  final AccountingSortOrder sortOrder;
  final AccountingViewPeriod viewPeriod;
  final bool showChart;

  AccountingSettings({
    this.sortOrder = AccountingSortOrder.dateDesc,
    this.viewPeriod = AccountingViewPeriod.monthly,
    this.showChart = true,
  });

  factory AccountingSettings.fromJson(Map<String, dynamic> json) {
    return AccountingSettings(
      sortOrder: AccountingSortOrder.values.firstWhere(
        (s) => s.name == json['sort_order'],
        orElse: () => AccountingSortOrder.dateDesc,
      ),
      viewPeriod: AccountingViewPeriod.values.firstWhere(
        (v) => v.name == json['view_period'],
        orElse: () => AccountingViewPeriod.monthly,
      ),
      showChart: json['show_chart'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'sort_order': sortOrder.name,
    'view_period': viewPeriod.name,
    'show_chart': showChart,
  };

  AccountingSettings copyWith({
    AccountingSortOrder? sortOrder,
    AccountingViewPeriod? viewPeriod,
    bool? showChart,
  }) {
    return AccountingSettings(
      sortOrder: sortOrder ?? this.sortOrder,
      viewPeriod: viewPeriod ?? this.viewPeriod,
      showChart: showChart ?? this.showChart,
    );
  }
}

/// Main accounting document content (stored in content/main.json)
class AccountingContent {
  final String id;
  final String schema;
  String title;
  int version;
  final DateTime created;
  DateTime modified;
  String currency;
  AccountingSettings settings;
  List<String> entries; // List of entry IDs
  List<String> customCategories;

  AccountingContent({
    required this.id,
    this.schema = 'ndf-accounting-1.0',
    required this.title,
    this.version = 1,
    required this.created,
    required this.modified,
    this.currency = 'EUR',
    AccountingSettings? settings,
    List<String>? entries,
    List<String>? customCategories,
  }) : settings = settings ?? AccountingSettings(),
       entries = entries ?? [],
       customCategories = customCategories ?? [];

  factory AccountingContent.create({required String title, String currency = 'EUR'}) {
    final now = DateTime.now();
    final id = 'acct-${now.millisecondsSinceEpoch.toRadixString(36)}';
    return AccountingContent(
      id: id,
      title: title,
      currency: currency,
      created: now,
      modified: now,
    );
  }

  factory AccountingContent.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    final id = json['id'] as String? ?? 'acct-${now.millisecondsSinceEpoch.toRadixString(36)}';
    final createdStr = json['created'] as String?;
    final modifiedStr = json['modified'] as String?;
    final created = createdStr != null ? DateTime.parse(createdStr) : now;
    final modified = modifiedStr != null ? DateTime.parse(modifiedStr) : now;

    AccountingSettings? settings;
    final settingsJson = json['settings'] as Map<String, dynamic>?;
    if (settingsJson != null) {
      settings = AccountingSettings.fromJson(settingsJson);
    }

    return AccountingContent(
      id: id,
      schema: json['schema'] as String? ?? 'ndf-accounting-1.0',
      title: json['title'] as String? ?? 'Untitled Accounting',
      version: json['version'] as int? ?? 1,
      created: created,
      modified: modified,
      currency: json['currency'] as String? ?? 'EUR',
      settings: settings,
      entries: (json['entries'] as List<dynamic>?)
          ?.map((i) => i as String)
          .toList() ?? [],
      customCategories: (json['custom_categories'] as List<dynamic>?)
          ?.map((c) => c as String)
          .toList() ?? [],
    );
  }

  Map<String, dynamic> toJson() => {
    'type': 'accounting',
    'id': id,
    'schema': schema,
    'title': title,
    'version': version,
    'created': created.toIso8601String(),
    'modified': modified.toIso8601String(),
    'currency': currency,
    'settings': settings.toJson(),
    'entries': entries,
    if (customCategories.isNotEmpty) 'custom_categories': customCategories,
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Touch the modified timestamp and increment version
  void touch() {
    modified = DateTime.now();
    version++;
  }

  /// Add an entry ID
  void addEntry(String entryId) {
    entries.add(entryId);
    touch();
  }

  /// Remove an entry ID
  void removeEntry(String entryId) {
    entries.remove(entryId);
    touch();
  }
}
