/// GeoUI recursive descent parser.
///
/// Grammar:
///   file     :=  block*
///   block    :=  keyword  name?  type?  "{"  ( declaration | block )*  "}"
///   decl     :=  key  ":"  value  ";"
///   value    :=  bare_word | quoted_string | number | bool | func_call | list

import 'geoui_ast.dart';

class GeoUiParser {
  final String _source;
  int _pos = 0;
  int _line = 1;
  int _col = 1;

  GeoUiParser(this._source);

  /// Parse the full .ui source into a GeoUiFile.
  GeoUiFile parse() {
    final blocks = <GeoUiBlock>[];
    _skipWs();
    while (_pos < _source.length) {
      blocks.add(_parseBlock(0));
      _skipWs();
    }
    return GeoUiFile(blocks);
  }

  // ── Block parsing ───────────────────────────────────────────────────

  GeoUiBlock _parseBlock(int depth) {
    if (depth > 6) _error('Maximum nesting depth (6) exceeded');

    final keyword = _readBareWord();
    _skipWs();

    // Optional name (quoted or bare word, but not '{' or ':')
    String? name;
    if (_peek() == '"') {
      name = _readQuotedString();
      _skipWs();
    } else if (_peek() != '{' && _peek() != ':') {
      final saved = _pos;
      final word = _tryBareWord();
      if (word != null) {
        _skipWs();
        if (_peek() == ':' || _peek() == '{') {
          // It's a name or name : type
          name = word;
        } else {
          // Not a name, rewind
          _pos = saved;
        }
      }
    }

    // Optional : type
    String? type;
    if (_peek() == ':') {
      _advance(); // skip ':'
      _skipWs();
      type = _readBareWord();
      _skipWs();
    }

    _expect('{');
    _skipWs();

    final decls = <String, GeoUiValue>{};
    final children = <GeoUiBlock>[];

    while (_pos < _source.length && _peek() != '}') {
      // Determine: is next item a declaration or a nested block?
      // Look ahead: if we see `word : value ;` it's a decl.
      // If we see `word ... {` it's a block.
      final savedPos = _pos;
      final firstWord = _tryBareWord();
      if (firstWord == null) _error('Expected identifier or }');

      _skipWs();
      final next = _peek();

      if (next == '{') {
        // Block with no name/type — rewind and parse as block
        _pos = savedPos;
        children.add(_parseBlock(depth + 1));
      } else if (next == ':') {
        // Could be decl (key : value ;) or block (keyword name : type { ... })
        // Peek further to decide
        final savedPos2 = _pos;
        _advance(); // skip ':'
        _skipWs();

        // Try reading a value
        final valStart = _pos;
        final valLine = _line;
        final valCol = _col;
        try {
          final value = _readValue();
          _skipWs();
          if (_peek() == ';') {
            _advance(); // consume ';'
            decls[firstWord!] = value;
          } else if (_peek() == ',') {
            // List value: first, second, third;
            final items = <GeoUiValue>[value];
            while (_peek() == ',') {
              _advance();
              _skipWs();
              items.add(_readValue());
              _skipWs();
            }
            _expect(';');
            decls[firstWord!] = GeoUiList(items);
          } else {
            // Not a decl — it's a block with `keyword name : type {`
            // Rewind to after firstWord
            _pos = savedPos;
            children.add(_parseBlock(depth + 1));
          }
        } catch (_) {
          // Value parsing failed — treat as block
          _pos = savedPos;
          children.add(_parseBlock(depth + 1));
        }
      } else if (next == '"') {
        // Block with quoted name: `keyword "Name" {`
        _pos = savedPos;
        children.add(_parseBlock(depth + 1));
      } else {
        // Could be `keyword name {` or `keyword name : type {`
        _pos = savedPos;
        children.add(_parseBlock(depth + 1));
      }

      _skipWs();
    }

    _expect('}');
    return GeoUiBlock(
      keyword: keyword,
      name: name,
      type: type,
      decls: decls,
      children: children,
    );
  }

  // ── Value parsing ───────────────────────────────────────────────────

  GeoUiValue _readValue() {
    _skipWs();
    final c = _peek();

    if (c == '"') return GeoUiString(_readQuotedString());
    if (c == '-' || _isDigit(c)) return _readNumber();

    // Try bare word
    final word = _readBareWord();
    if (word == 'true') return const GeoUiBool(true);
    if (word == 'false') return const GeoUiBool(false);

    _skipWs();
    if (_pos < _source.length && _peek() == '(') {
      // Function call
      _advance(); // skip '('
      _skipWs();
      final args = <GeoUiValue>[];
      if (_peek() != ')') {
        args.add(_readValue());
        _skipWs();
        while (_peek() == ',') {
          _advance();
          _skipWs();
          args.add(_readValue());
          _skipWs();
        }
      }
      _expect(')');
      return GeoUiFuncCall(word, args);
    }

    return GeoUiBareWord(word);
  }

  GeoUiNumber _readNumber() {
    final start = _pos;
    if (_peek() == '-') _advance();
    while (_pos < _source.length && _isDigit(_peek())) _advance();
    if (_pos < _source.length && _peek() == '.') {
      _advance();
      while (_pos < _source.length && _isDigit(_peek())) _advance();
    }
    final text = _source.substring(start, _pos);
    return GeoUiNumber(double.parse(text));
  }

  // ── Tokenizer helpers ───────────────────────────────────────────────

  String _readBareWord() {
    final word = _tryBareWord();
    if (word == null) _error('Expected identifier');
    return word!;
  }

  String? _tryBareWord() {
    _skipWs();
    final start = _pos;
    while (_pos < _source.length && _isBareWordChar(_peek())) {
      _advance();
    }
    if (_pos == start) return null;
    return _source.substring(start, _pos);
  }

  String _readQuotedString() {
    _expect('"');
    final buf = StringBuffer();
    while (_pos < _source.length && _peek() != '"') {
      if (_peek() == '\\') {
        _advance();
        if (_pos < _source.length) {
          final c = _peek();
          _advance();
          switch (c) {
            case 'n':
              buf.write('\n');
            case 't':
              buf.write('\t');
            case '"':
              buf.write('"');
            case '\\':
              buf.write('\\');
            default:
              buf.write('\\');
              buf.write(c);
          }
        }
      } else {
        buf.write(_peek());
        _advance();
      }
    }
    _expect('"');
    return buf.toString();
  }

  void _skipWs() {
    while (_pos < _source.length) {
      final c = _source[_pos];
      if (c == ' ' || c == '\t' || c == '\r') {
        _advance();
      } else if (c == '\n') {
        _advance();
      } else if (_pos + 1 < _source.length && c == '/' && _source[_pos + 1] == '*') {
        // Block comment
        _pos += 2;
        _col += 2;
        while (_pos + 1 < _source.length &&
            !(_source[_pos] == '*' && _source[_pos + 1] == '/')) {
          if (_source[_pos] == '\n') {
            _line++;
            _col = 1;
          } else {
            _col++;
          }
          _pos++;
        }
        if (_pos + 1 < _source.length) {
          _pos += 2;
          _col += 2;
        }
      } else {
        break;
      }
    }
  }

  String _peek() {
    if (_pos >= _source.length) _error('Unexpected end of input');
    return _source[_pos];
  }

  void _advance() {
    if (_pos < _source.length) {
      if (_source[_pos] == '\n') {
        _line++;
        _col = 1;
      } else {
        _col++;
      }
      _pos++;
    }
  }

  void _expect(String char) {
    _skipWs();
    if (_pos >= _source.length || _source[_pos] != char) {
      _error('Expected \'$char\'');
    }
    _advance();
  }

  bool _isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;

  bool _isBareWordChar(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 65 && code <= 90) || // A-Z
        (code >= 97 && code <= 122) || // a-z
        (code >= 48 && code <= 57) || // 0-9
        c == '_' ||
        c == '-' ||
        c == '.' ||
        c == '*' ||
        c == '/' ||
        c == '#' ||
        c == '@' ||
        c == '<' ||
        c == '>' ||
        c == '=' ||
        c == '+';
  }

  Never _error(String msg) {
    throw FormatException('GeoUI parse error at line $_line:$_col: $msg');
  }
}
