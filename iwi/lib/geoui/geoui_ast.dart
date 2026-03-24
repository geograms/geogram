/// GeoUI AST — node types produced by the parser, consumed by renderers.

sealed class GeoUiValue {
  const GeoUiValue();
}

class GeoUiString extends GeoUiValue {
  final String value;
  const GeoUiString(this.value);
  @override
  String toString() => '"$value"';
}

class GeoUiNumber extends GeoUiValue {
  final double value;
  const GeoUiNumber(this.value);
  @override
  String toString() => value.toString();
}

class GeoUiBool extends GeoUiValue {
  final bool value;
  const GeoUiBool(this.value);
  @override
  String toString() => value.toString();
}

class GeoUiFuncCall extends GeoUiValue {
  final String name;
  final List<GeoUiValue> args;
  const GeoUiFuncCall(this.name, this.args);
  @override
  String toString() => '$name(${args.join(', ')})';
}

class GeoUiList extends GeoUiValue {
  final List<GeoUiValue> items;
  const GeoUiList(this.items);
  @override
  String toString() => items.join(', ');
}

/// A single block: keyword name? type? { decls + children }
class GeoUiBlock {
  final String keyword;
  final String? name;
  final String? type;
  final Map<String, GeoUiValue> decls;
  final List<GeoUiBlock> children;

  const GeoUiBlock({
    required this.keyword,
    this.name,
    this.type,
    this.decls = const {},
    this.children = const [],
  });

  /// Get a string declaration value.
  String? getString(String key) {
    final v = decls[key];
    if (v is GeoUiString) return v.value;
    return null;
  }

  /// Get a number declaration value.
  double? getNumber(String key) {
    final v = decls[key];
    if (v is GeoUiNumber) return v.value;
    return null;
  }

  /// Get a bool declaration value.
  bool? getBool(String key) {
    final v = decls[key];
    if (v is GeoUiBool) return v.value;
    return null;
  }

  /// Find child blocks by keyword.
  List<GeoUiBlock> childrenOf(String kw) =>
      children.where((c) => c.keyword == kw).toList();

  /// Find first child block by keyword.
  GeoUiBlock? childOf(String kw) {
    for (final c in children) {
      if (c.keyword == kw) return c;
    }
    return null;
  }

  @override
  String toString() => 'GeoUiBlock($keyword ${name ?? ''} ${type ?? ''})';
}

/// Root of a parsed .ui file.
class GeoUiFile {
  final List<GeoUiBlock> blocks;
  const GeoUiFile(this.blocks);

  /// Find the first screen block.
  GeoUiBlock? get firstScreen {
    for (final b in blocks) {
      if (b.keyword == 'screen') return b;
      if (b.keyword == 'app') {
        for (final c in b.children) {
          if (c.keyword == 'screen') return c;
        }
      }
    }
    return null;
  }
}
