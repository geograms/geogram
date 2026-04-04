/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';

/// Cell value types
enum CellType {
  string,
  number,
  boolean,
  date,
  datetime,
  error,
  rich,
  asset,
  currency,
}

/// Currency format definition
class CurrencyFormat {
  final String code;
  final String symbol;
  final String name;
  final int decimals;
  final bool symbolBefore;
  final bool isCrypto;

  const CurrencyFormat({
    required this.code,
    required this.symbol,
    required this.name,
    this.decimals = 2,
    this.symbolBefore = true,
    this.isCrypto = false,
  });

  /// Format a number as this currency
  String format(num value) {
    // Format with max decimals, then trim trailing zeros
    String formatted = value.toStringAsFixed(decimals);

    // Remove unnecessary trailing zeros after decimal point
    if (formatted.contains('.')) {
      formatted = formatted.replaceAll(RegExp(r'0+$'), '');
      formatted = formatted.replaceAll(RegExp(r'\.$'), '');
    }

    // Add thousands separator to integer part
    final parts = formatted.split('.');
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
    final result = parts.length > 1 ? '$intPart.${parts[1]}' : intPart;

    if (symbolBefore) {
      return '$symbol$result';
    } else {
      return '$result $symbol';
    }
  }

  /// Common fiat currencies (10 most traded globally)
  static const fiatCurrencies = [
    CurrencyFormat(code: 'USD', symbol: '\$', name: 'US Dollar'),
    CurrencyFormat(code: 'EUR', symbol: '€', name: 'Euro'),
    CurrencyFormat(code: 'JPY', symbol: '¥', name: 'Japanese Yen', decimals: 0),
    CurrencyFormat(code: 'GBP', symbol: '£', name: 'British Pound'),
    CurrencyFormat(code: 'CNY', symbol: '¥', name: 'Chinese Yuan'),
    CurrencyFormat(code: 'AUD', symbol: 'A\$', name: 'Australian Dollar'),
    CurrencyFormat(code: 'CAD', symbol: 'C\$', name: 'Canadian Dollar'),
    CurrencyFormat(code: 'CHF', symbol: 'Fr', name: 'Swiss Franc', symbolBefore: false),
    CurrencyFormat(code: 'INR', symbol: '₹', name: 'Indian Rupee'),
    CurrencyFormat(code: 'BRL', symbol: 'R\$', name: 'Brazilian Real'),
  ];

  /// Cryptocurrencies (Monero first)
  static const cryptoCurrencies = [
    CurrencyFormat(code: 'XMR', symbol: 'ɱ', name: 'Monero', decimals: 12, isCrypto: true),
    CurrencyFormat(code: 'BEAM', symbol: 'BEAM', name: 'BEAM', decimals: 8, symbolBefore: false, isCrypto: true),
    CurrencyFormat(code: 'BTC', symbol: '₿', name: 'Bitcoin', decimals: 8, isCrypto: true),
    CurrencyFormat(code: 'SATS', symbol: 'sats', name: 'Satoshis', decimals: 0, symbolBefore: false, isCrypto: true),
    CurrencyFormat(code: 'LTC', symbol: 'Ł', name: 'Litecoin', decimals: 8, isCrypto: true),
    CurrencyFormat(code: 'ETH', symbol: 'Ξ', name: 'Ethereum', decimals: 6, isCrypto: true),
    CurrencyFormat(code: 'SOL', symbol: 'SOL', name: 'Solana', decimals: 9, symbolBefore: false, isCrypto: true),
    CurrencyFormat(code: 'ADA', symbol: 'ADA', name: 'Cardano', decimals: 6, symbolBefore: false, isCrypto: true),
    CurrencyFormat(code: 'DOGE', symbol: 'D', name: 'Dogecoin', decimals: 8, isCrypto: true),
    CurrencyFormat(code: 'XRP', symbol: 'XRP', name: 'XRP', decimals: 6, symbolBefore: false, isCrypto: true),
  ];

  /// All currencies
  static const allCurrencies = [...fiatCurrencies, ...cryptoCurrencies];

  /// Get currency by code
  static CurrencyFormat? byCode(String code) {
    for (final c in allCurrencies) {
      if (c.code == code) return c;
    }
    return null;
  }
}

/// A cell in a spreadsheet
class SpreadsheetCell {
  dynamic value;
  CellType? type;
  String? formula;
  String? format;
  String? style;

  SpreadsheetCell({
    this.value,
    this.type,
    this.formula,
    this.format,
    this.style,
  });

  factory SpreadsheetCell.fromJson(Map<String, dynamic> json) {
    CellType? type;
    if (json['t'] != null) {
      type = CellType.values.firstWhere(
        (t) => t.name == json['t'],
        orElse: () => CellType.string,
      );
    }

    return SpreadsheetCell(
      value: json['v'],
      type: type,
      formula: json['formula'] as String?,
      format: json['f'] as String?,
      style: json['s'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (value != null) json['v'] = value;
    if (type != null) json['t'] = type!.name;
    if (formula != null) json['formula'] = formula;
    if (format != null) json['f'] = format;
    if (style != null) json['s'] = style;
    return json;
  }

  bool get hasFormula => formula != null && formula!.isNotEmpty;

  /// Get display value (computed value for formulas, raw value otherwise)
  String get displayValue {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num) {
      if (format != null) {
        // Check for currency format first
        final currency = CurrencyFormat.byCode(format!);
        if (currency != null) {
          return currency.format(value as num);
        }
        // Basic number formatting
        if (format!.contains('0.00')) {
          return (value as num).toStringAsFixed(2);
        }
        if (format!.contains('#,##0')) {
          return _formatWithCommas(value as num);
        }
      }
      return value.toString();
    }
    if (value is bool) return value ? 'TRUE' : 'FALSE';
    return value.toString();
  }

  String _formatWithCommas(num n) {
    final parts = n.toString().split('.');
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
    if (parts.length > 1) {
      return '$intPart.${parts[1]}';
    }
    return intPart;
  }
}

/// Column definition
class SpreadsheetColumn {
  double width;
  bool hidden;

  SpreadsheetColumn({
    this.width = 100,
    this.hidden = false,
  });

  factory SpreadsheetColumn.fromJson(Map<String, dynamic> json) {
    return SpreadsheetColumn(
      width: (json['width'] as num?)?.toDouble() ?? 100,
      hidden: json['hidden'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'width': width,
    if (hidden) 'hidden': hidden,
  };
}

/// Row definition
class SpreadsheetRow {
  double height;
  bool hidden;
  String? style;

  SpreadsheetRow({
    this.height = 24,
    this.hidden = false,
    this.style,
  });

  factory SpreadsheetRow.fromJson(Map<String, dynamic> json) {
    return SpreadsheetRow(
      height: (json['height'] as num?)?.toDouble() ?? 24,
      hidden: json['hidden'] as bool? ?? false,
      style: json['style'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'height': height,
    if (hidden) 'hidden': hidden,
    if (style != null) 'style': style,
  };
}

/// Cell merge definition
class CellMerge {
  final String start;
  final String end;

  CellMerge({required this.start, required this.end});

  factory CellMerge.fromJson(Map<String, dynamic> json) {
    return CellMerge(
      start: json['start'] as String,
      end: json['end'] as String,
    );
  }

  Map<String, dynamic> toJson() => {'start': start, 'end': end};
}

/// Cell style definition
class CellStyle {
  // Explicit typed properties for common formatting
  double? fontSize;
  bool? bold;
  bool? italic;
  String? textColor;       // Hex color e.g., "#FF0000"
  String? backgroundColor; // Hex color e.g., "#FFFF00"

  // Keep existing generic maps for backward compatibility
  Map<String, dynamic>? font;
  Map<String, dynamic>? fill;
  String? color;
  Map<String, dynamic>? border;
  Map<String, dynamic>? alignment;

  CellStyle({
    this.fontSize,
    this.bold,
    this.italic,
    this.textColor,
    this.backgroundColor,
    this.font,
    this.fill,
    this.color,
    this.border,
    this.alignment,
  });

  factory CellStyle.fromJson(Map<String, dynamic> json) {
    return CellStyle(
      fontSize: (json['fontSize'] as num?)?.toDouble(),
      bold: json['bold'] as bool?,
      italic: json['italic'] as bool?,
      textColor: json['textColor'] as String?,
      backgroundColor: json['backgroundColor'] as String?,
      font: json['font'] as Map<String, dynamic>?,
      fill: json['fill'] as Map<String, dynamic>?,
      color: json['color'] as String?,
      border: json['border'] as Map<String, dynamic>?,
      alignment: json['alignment'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() => {
    if (fontSize != null) 'fontSize': fontSize,
    if (bold != null) 'bold': bold,
    if (italic != null) 'italic': italic,
    if (textColor != null) 'textColor': textColor,
    if (backgroundColor != null) 'backgroundColor': backgroundColor,
    if (font != null) 'font': font,
    if (fill != null) 'fill': fill,
    if (color != null) 'color': color,
    if (border != null) 'border': border,
    if (alignment != null) 'alignment': alignment,
  };

  /// Returns true if this style has any formatting applied
  bool get hasFormatting =>
      fontSize != null ||
      bold == true ||
      italic == true ||
      textColor != null ||
      backgroundColor != null;
}

/// A single sheet in a spreadsheet
class SpreadsheetSheet {
  final String id;
  String name;
  int index;
  int rows;
  int cols;
  int frozenRows;
  int frozenCols;
  int selectedRow;
  int selectedCol;
  Map<int, SpreadsheetColumn> columns;
  Map<int, SpreadsheetRow> rowDefs;
  Map<String, SpreadsheetCell> cells;
  List<CellMerge> merges;
  Map<String, CellStyle> styles;

  SpreadsheetSheet({
    required this.id,
    required this.name,
    this.index = 0,
    this.rows = 100,
    this.cols = 26,
    this.frozenRows = 0,
    this.frozenCols = 0,
    this.selectedRow = 0,
    this.selectedCol = 0,
    Map<int, SpreadsheetColumn>? columns,
    Map<int, SpreadsheetRow>? rowDefs,
    Map<String, SpreadsheetCell>? cells,
    List<CellMerge>? merges,
    Map<String, CellStyle>? styles,
  }) : columns = columns ?? {},
       rowDefs = rowDefs ?? {},
       cells = cells ?? {},
       merges = merges ?? [],
       styles = styles ?? {};

  factory SpreadsheetSheet.create({
    required String id,
    required String name,
    int index = 0,
  }) {
    return SpreadsheetSheet(
      id: id,
      name: name,
      index: index,
    );
  }

  factory SpreadsheetSheet.fromJson(Map<String, dynamic> json) {
    // Parse columns
    final columnsJson = json['columns'] as Map<String, dynamic>? ?? {};
    final columns = <int, SpreadsheetColumn>{};
    for (final entry in columnsJson.entries) {
      columns[int.parse(entry.key)] = SpreadsheetColumn.fromJson(
        entry.value as Map<String, dynamic>,
      );
    }

    // Parse rows
    final rowsJson = json['rows'] as Map<String, dynamic>? ?? {};
    final rowDefs = <int, SpreadsheetRow>{};
    for (final entry in rowsJson.entries) {
      rowDefs[int.parse(entry.key)] = SpreadsheetRow.fromJson(
        entry.value as Map<String, dynamic>,
      );
    }

    // Parse cells
    final cellsJson = json['cells'] as Map<String, dynamic>? ?? {};
    final cells = <String, SpreadsheetCell>{};
    for (final entry in cellsJson.entries) {
      cells[entry.key] = SpreadsheetCell.fromJson(
        entry.value as Map<String, dynamic>,
      );
    }

    // Parse merges
    final mergesJson = json['merges'] as List<dynamic>? ?? [];
    final merges = mergesJson
        .map((m) => CellMerge.fromJson(m as Map<String, dynamic>))
        .toList();

    // Parse styles
    final stylesJson = json['styles'] as Map<String, dynamic>? ?? {};
    final styles = <String, CellStyle>{};
    for (final entry in stylesJson.entries) {
      styles[entry.key] = CellStyle.fromJson(
        entry.value as Map<String, dynamic>,
      );
    }

    final dimensions = json['dimensions'] as Map<String, dynamic>? ?? {};

    final selection = json['selection'] as Map<String, dynamic>? ?? {};

    return SpreadsheetSheet(
      id: json['id'] as String,
      name: json['name'] as String,
      index: json['index'] as int? ?? 0,
      rows: dimensions['rows'] as int? ?? 100,
      cols: dimensions['cols'] as int? ?? 26,
      frozenRows: dimensions['frozen_rows'] as int? ?? 0,
      frozenCols: dimensions['frozen_cols'] as int? ?? 0,
      selectedRow: selection['row'] as int? ?? 0,
      selectedCol: selection['col'] as int? ?? 0,
      columns: columns,
      rowDefs: rowDefs,
      cells: cells,
      merges: merges,
      styles: styles,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'index': index,
    'dimensions': {
      'rows': rows,
      'cols': cols,
      if (frozenRows > 0) 'frozen_rows': frozenRows,
      if (frozenCols > 0) 'frozen_cols': frozenCols,
    },
    'selection': {
      'row': selectedRow,
      'col': selectedCol,
    },
    if (columns.isNotEmpty)
      'columns': {
        for (final e in columns.entries) '${e.key}': e.value.toJson(),
      },
    if (rowDefs.isNotEmpty)
      'rows': {
        for (final e in rowDefs.entries) '${e.key}': e.value.toJson(),
      },
    'cells': {
      for (final e in cells.entries) e.key: e.value.toJson(),
    },
    if (merges.isNotEmpty)
      'merges': merges.map((m) => m.toJson()).toList(),
    if (styles.isNotEmpty)
      'styles': {
        for (final e in styles.entries) e.key: e.value.toJson(),
      },
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Get cell at row:col (0-indexed)
  SpreadsheetCell? getCell(int row, int col) {
    return cells['$row:$col'];
  }

  /// Set cell at row:col (0-indexed)
  void setCell(int row, int col, SpreadsheetCell cell) {
    cells['$row:$col'] = cell;
  }

  /// Get or create cell at row:col
  SpreadsheetCell getOrCreateCell(int row, int col) {
    final key = '$row:$col';
    return cells.putIfAbsent(key, () => SpreadsheetCell());
  }

  /// Delete cell at row:col
  void deleteCell(int row, int col) {
    cells.remove('$row:$col');
  }

  /// Get column letter from index (0=A, 1=B, etc.)
  static String columnLetter(int index) {
    var result = '';
    var n = index;
    while (n >= 0) {
      result = String.fromCharCode(65 + (n % 26)) + result;
      n = (n ~/ 26) - 1;
    }
    return result;
  }

  /// Get column index from letter (A=0, B=1, etc.)
  static int columnIndex(String letter) {
    var result = 0;
    for (var i = 0; i < letter.length; i++) {
      result = result * 26 + (letter.codeUnitAt(i) - 64);
    }
    return result - 1;
  }
}

/// Main spreadsheet content (main.json)
class SpreadsheetContent {
  String activeSheet;
  List<String> sheets;
  Map<String, Map<String, dynamic>> namedRanges;
  Map<String, dynamic> globalStyles;

  SpreadsheetContent({
    required this.activeSheet,
    required this.sheets,
    Map<String, Map<String, dynamic>>? namedRanges,
    Map<String, dynamic>? globalStyles,
  }) : namedRanges = namedRanges ?? {},
       globalStyles = globalStyles ?? {};

  factory SpreadsheetContent.create() {
    return SpreadsheetContent(
      activeSheet: 'sheet-001',
      sheets: ['sheet-001'],
    );
  }

  factory SpreadsheetContent.fromJson(Map<String, dynamic> json) {
    final namedRangesJson = json['named_ranges'] as Map<String, dynamic>? ?? {};
    final namedRanges = <String, Map<String, dynamic>>{};
    for (final entry in namedRangesJson.entries) {
      namedRanges[entry.key] = entry.value as Map<String, dynamic>;
    }

    return SpreadsheetContent(
      activeSheet: json['active_sheet'] as String? ?? 'sheet-001',
      sheets: (json['sheets'] as List<dynamic>?)
          ?.map((s) => s as String)
          .toList() ?? ['sheet-001'],
      namedRanges: namedRanges,
      globalStyles: json['global_styles'] as Map<String, dynamic>? ?? {},
    );
  }

  Map<String, dynamic> toJson() => {
    'type': 'spreadsheet',
    'active_sheet': activeSheet,
    'sheets': sheets,
    if (namedRanges.isNotEmpty) 'named_ranges': namedRanges,
    if (globalStyles.isNotEmpty) 'global_styles': globalStyles,
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());
}
