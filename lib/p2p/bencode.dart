/// Bencode encoder/decoder for BitTorrent DHT protocol messages.
///
/// Supports the four bencode types:
/// - Byte strings: `<length>:<contents>` (e.g., `4:spam`)
/// - Integers: `i<number>e` (e.g., `i42e`)
/// - Lists: `l<items>e` (e.g., `l4:spami42ee`)
/// - Dictionaries: `d<key><value>...e` (keys must be strings, sorted)
library;

import 'dart:typed_data';

/// Bencode codec for DHT message serialization.
class Bencode {
  /// Encode a Dart value to bencoded bytes.
  ///
  /// Supported types:
  /// - [int] → bencode integer
  /// - [String] → bencode string (UTF-8)
  /// - [Uint8List] / [List<int>] → bencode string (raw bytes)
  /// - [List] → bencode list
  /// - [Map<String, dynamic>] → bencode dictionary (keys sorted)
  static Uint8List encode(dynamic value) {
    final buffer = <int>[];
    _encode(value, buffer);
    return Uint8List.fromList(buffer);
  }

  static void _encode(dynamic value, List<int> buffer) {
    if (value is int) {
      buffer.addAll('i${value}e'.codeUnits);
    } else if (value is Uint8List) {
      buffer.addAll('${value.length}:'.codeUnits);
      buffer.addAll(value);
    } else if (value is List<int>) {
      buffer.addAll('${value.length}:'.codeUnits);
      buffer.addAll(value);
    } else if (value is String) {
      final bytes = value.codeUnits;
      buffer.addAll('${bytes.length}:'.codeUnits);
      buffer.addAll(bytes);
    } else if (value is List) {
      buffer.add(0x6C); // 'l'
      for (final item in value) {
        _encode(item, buffer);
      }
      buffer.add(0x65); // 'e'
    } else if (value is Map) {
      buffer.add(0x64); // 'd'
      // Keys must be sorted lexicographically
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      for (final key in keys) {
        _encode(key, buffer);
        _encode(value[key], buffer);
      }
      buffer.add(0x65); // 'e'
    } else {
      throw ArgumentError('Cannot bencode type: ${value.runtimeType}');
    }
  }

  /// Decode bencoded bytes to a Dart value.
  ///
  /// Returns one of:
  /// - [Uint8List] for byte strings
  /// - [int] for integers
  /// - [List] for lists
  /// - [Map<String, dynamic>] for dictionaries
  static dynamic decode(Uint8List data) {
    final result = _decode(data, 0);
    return result.value;
  }

  /// Decode and return both value and consumed byte count.
  static ({dynamic value, int end}) _decode(Uint8List data, int offset) {
    if (offset >= data.length) {
      throw FormatException('Unexpected end of bencode data at offset $offset');
    }

    final byte = data[offset];

    // Integer: i<number>e
    if (byte == 0x69) {
      // 'i'
      return _decodeInt(data, offset);
    }

    // List: l<items>e
    if (byte == 0x6C) {
      // 'l'
      return _decodeList(data, offset);
    }

    // Dictionary: d<pairs>e
    if (byte == 0x64) {
      // 'd'
      return _decodeDict(data, offset);
    }

    // Byte string: <length>:<contents>
    if (byte >= 0x30 && byte <= 0x39) {
      // '0'-'9'
      return _decodeString(data, offset);
    }

    throw FormatException(
        'Invalid bencode byte 0x${byte.toRadixString(16)} at offset $offset');
  }

  static ({dynamic value, int end}) _decodeInt(Uint8List data, int offset) {
    // Skip 'i'
    var pos = offset + 1;
    final start = pos;

    while (pos < data.length && data[pos] != 0x65) {
      // 'e'
      pos++;
    }
    if (pos >= data.length) {
      throw FormatException('Unterminated integer at offset $offset');
    }

    final numStr = String.fromCharCodes(data, start, pos);
    final value = int.parse(numStr);
    return (value: value, end: pos + 1); // skip 'e'
  }

  static ({dynamic value, int end}) _decodeString(
      Uint8List data, int offset) {
    // Find ':'
    var colonPos = offset;
    while (colonPos < data.length && data[colonPos] != 0x3A) {
      // ':'
      colonPos++;
    }
    if (colonPos >= data.length) {
      throw FormatException('Missing colon in string at offset $offset');
    }

    final lengthStr = String.fromCharCodes(data, offset, colonPos);
    final length = int.parse(lengthStr);
    final start = colonPos + 1;
    final end = start + length;

    if (end > data.length) {
      throw FormatException(
          'String length $length exceeds data at offset $offset');
    }

    final value = Uint8List.fromList(data.sublist(start, end));
    return (value: value, end: end);
  }

  static ({dynamic value, int end}) _decodeList(Uint8List data, int offset) {
    final list = <dynamic>[];
    var pos = offset + 1; // skip 'l'

    while (pos < data.length && data[pos] != 0x65) {
      // 'e'
      final result = _decode(data, pos);
      list.add(result.value);
      pos = result.end;
    }
    if (pos >= data.length) {
      throw FormatException('Unterminated list at offset $offset');
    }

    return (value: list, end: pos + 1); // skip 'e'
  }

  static ({dynamic value, int end}) _decodeDict(Uint8List data, int offset) {
    final dict = <String, dynamic>{};
    var pos = offset + 1; // skip 'd'

    while (pos < data.length && data[pos] != 0x65) {
      // 'e'
      // Key must be a byte string
      final keyResult = _decodeString(data, pos);
      final key = String.fromCharCodes(keyResult.value as Uint8List);
      pos = keyResult.end;

      // Value can be anything
      final valueResult = _decode(data, pos);
      dict[key] = valueResult.value;
      pos = valueResult.end;
    }
    if (pos >= data.length) {
      throw FormatException('Unterminated dictionary at offset $offset');
    }

    return (value: dict, end: pos + 1); // skip 'e'
  }

  /// Helper: convert a decoded Uint8List to String (for reading string values).
  static String asString(dynamic value) {
    if (value is Uint8List) return String.fromCharCodes(value);
    if (value is String) return value;
    throw ArgumentError('Expected string, got ${value.runtimeType}');
  }

  /// Helper: convert a decoded value to Uint8List (for reading raw bytes).
  static Uint8List asBytes(dynamic value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is String) return Uint8List.fromList(value.codeUnits);
    throw ArgumentError('Expected bytes, got ${value.runtimeType}');
  }

  /// Helper: convert a decoded value to int.
  static int asInt(dynamic value) {
    if (value is int) return value;
    throw ArgumentError('Expected int, got ${value.runtimeType}');
  }

  /// Helper: convert a decoded value to Map.
  static Map<String, dynamic> asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
    throw ArgumentError('Expected map, got ${value.runtimeType}');
  }

  /// Helper: convert a decoded value to List.
  static List<dynamic> asList(dynamic value) {
    if (value is List) return value;
    throw ArgumentError('Expected list, got ${value.runtimeType}');
  }
}
