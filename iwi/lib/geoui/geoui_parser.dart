/// GeoUI JSON parser.
///
/// Reads `.ui.json` files (JSON arrays of block objects) and produces the
/// same AST that the old brace-delimited parser did.  The public API is
/// unchanged: `GeoUiParser(source).parse()` → `GeoUiFile`.

import 'dart:convert';

import 'geoui_ast.dart';

class GeoUiParser {
  final String _source;

  GeoUiParser(this._source);

  /// Parse the full .ui.json source into a GeoUiFile.
  GeoUiFile parse() {
    final dynamic decoded;
    try {
      decoded = jsonDecode(_source);
    } catch (e) {
      throw FormatException('GeoUI: invalid JSON – $e');
    }
    if (decoded is! List) {
      throw const FormatException('GeoUI: root must be a JSON array');
    }
    return GeoUiFile(decoded.map((e) => _parseBlock(e as Map<String, dynamic>)).toList());
  }

  GeoUiBlock _parseBlock(Map<String, dynamic> map) {
    final keyword = map[r'$'] as String? ?? '';
    final name = map['name'] as String?;
    final type = map[r'$type'] as String?;

    final decls = <String, GeoUiValue>{};
    final children = <GeoUiBlock>[];

    for (final entry in map.entries) {
      final key = entry.key;
      if (key == r'$' || key == 'name' || key == r'$type' || key == 'children') {
        continue;
      }
      decls[key] = _parseValue(entry.value);
    }

    final rawChildren = map['children'];
    if (rawChildren is List) {
      for (final child in rawChildren) {
        children.add(_parseBlock(child as Map<String, dynamic>));
      }
    }

    return GeoUiBlock(
      keyword: keyword,
      name: name,
      type: type,
      decls: decls,
      children: children,
    );
  }

  GeoUiValue _parseValue(dynamic v) {
    if (v is String) return GeoUiString(v);
    if (v is bool) return GeoUiBool(v);
    if (v is num) return GeoUiNumber(v.toDouble());
    if (v is List) {
      return GeoUiList(v.map(_parseValue).toList());
    }
    if (v is Map<String, dynamic>) {
      // Function call: {"$fn": "name", "args": [...]}
      if (v.containsKey(r'$fn')) {
        final name = v[r'$fn'] as String;
        final args = (v['args'] as List?)?.map(_parseValue).toList() ?? const [];
        return GeoUiFuncCall(name, args);
      }
      // Arbitrary map – encode as string fallback
      return GeoUiString(jsonEncode(v));
    }
    if (v == null) return const GeoUiString('');
    return GeoUiString(v.toString());
  }
}
