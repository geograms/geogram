/*
 * Deterministic DAG-CBOR encoder/decoder for AT Protocol.
 *
 * Implements the IPLD DAG-CBOR codec subset:
 * - Map keys sorted by byte length, then lexicographic byte order
 * - No floating-point values (AT Proto forbids them in repo data)
 * - CID links encoded as CBOR tag 42 wrapping raw CID bytes
 * - Byte strings for binary data
 *
 * Reference: https://ipld.io/specs/codecs/dag-cbor/spec/
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import 'cid.dart';

/// A CID link within a DAG-CBOR structure.
///
/// When encoding, [CidLink] values are written as CBOR tag 42.
/// When decoding, tag-42 values are returned as [CidLink] instances.
class CidLink {
  final Cid cid;
  const CidLink(this.cid);

  @override
  bool operator ==(Object other) =>
      other is CidLink && cid == other.cid;

  @override
  int get hashCode => cid.hashCode;

  @override
  String toString() => 'CidLink(${cid.toBase32()})';
}

/// Deterministic DAG-CBOR encoder/decoder.
class DagCbor {
  /// CBOR tag number for CID links in DAG-CBOR.
  static const int cidTag = 42;

  /// Encode a Dart value to deterministic DAG-CBOR bytes.
  ///
  /// Supported types:
  /// - `null` → CBOR null
  /// - `bool` → CBOR bool
  /// - `int` → CBOR integer
  /// - `String` → CBOR text string
  /// - `Uint8List` → CBOR byte string
  /// - `List` → CBOR array (elements encoded recursively)
  /// - `Map<String, dynamic>` → CBOR map (keys sorted by DAG-CBOR rules)
  /// - [CidLink] → CBOR tag 42 with CID bytes (0x00 prefix + raw CID)
  static Uint8List encode(dynamic value) {
    final builder = CborEncoder();
    _encodeValue(builder, value);
    return Uint8List.fromList(builder.toBytes());
  }

  /// Decode DAG-CBOR bytes back to Dart objects.
  ///
  /// CID links (tag 42) are returned as [CidLink] instances.
  static dynamic decode(Uint8List bytes) {
    final decoded = cbor.decode(bytes);
    return _convertCborValue(decoded);
  }

  // -- Encoding --

  static void _encodeValue(CborEncoder builder, dynamic value) {
    if (value == null) {
      builder.addNull();
    } else if (value is bool) {
      builder.addBool(value);
    } else if (value is int) {
      builder.addInt(value);
    } else if (value is String) {
      builder.addText(value);
    } else if (value is Uint8List) {
      builder.addBytes(value);
    } else if (value is CidLink) {
      _encodeCidLink(builder, value);
    } else if (value is List) {
      _encodeList(builder, value);
    } else if (value is Map) {
      _encodeMap(builder, value);
    } else {
      throw ArgumentError('Unsupported DAG-CBOR type: ${value.runtimeType}');
    }
  }

  static void _encodeCidLink(CborEncoder builder, CidLink link) {
    // DAG-CBOR CID links: tag 42, byte string = 0x00 + raw CID bytes
    final cidBytes = link.cid.toBytes();
    final tagged = Uint8List(1 + cidBytes.length);
    tagged[0] = 0x00; // multibase identity prefix
    tagged.setRange(1, tagged.length, cidBytes);
    builder.addTag(cidTag);
    builder.addBytes(tagged);
  }

  static void _encodeList(CborEncoder builder, List value) {
    builder.addArrayHeader(value.length);
    for (final item in value) {
      _encodeValue(builder, item);
    }
  }

  static void _encodeMap(CborEncoder builder, Map value) {
    // DAG-CBOR map key sorting: sort by byte length first, then
    // lexicographic byte comparison.
    final entries = value.entries.toList();
    entries.sort((a, b) {
      final aBytes = utf8.encode(a.key.toString());
      final bBytes = utf8.encode(b.key.toString());
      if (aBytes.length != bBytes.length) {
        return aBytes.length.compareTo(bBytes.length);
      }
      for (var i = 0; i < aBytes.length; i++) {
        if (aBytes[i] != bBytes[i]) {
          return aBytes[i].compareTo(bBytes[i]);
        }
      }
      return 0;
    });

    builder.addMapHeader(entries.length);
    for (final entry in entries) {
      builder.addText(entry.key.toString());
      _encodeValue(builder, entry.value);
    }
  }

  // -- Decoding --

  static dynamic _convertCborValue(CborValue value) {
    // Check for CID tag 42 on any value type (cbor 6.x stores tags as a list)
    if (value.tags.contains(cidTag)) {
      return _decodeCidLink(value);
    }

    if (value is CborNull) {
      return null;
    } else if (value is CborBool) {
      return value.value;
    } else if (value is CborSmallInt) {
      return value.value;
    } else if (value is CborInt) {
      return value.toInt();
    } else if (value is CborString) {
      return value.toString();
    } else if (value is CborBytes) {
      return Uint8List.fromList(value.bytes);
    } else if (value is CborList) {
      return value.map(_convertCborValue).toList();
    } else if (value is CborMap) {
      final map = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = _convertCborValue(entry.key);
        map[key.toString()] = _convertCborValue(entry.value);
      }
      return map;
    } else if (value is CborFloat) {
      // AT Proto forbids floats, but decode them for compatibility
      return value.value;
    }
    return value.toString();
  }

  static CidLink _decodeCidLink(CborValue value) {
    if (value is! CborBytes) {
      throw FormatException('CID tag 42 must contain byte string');
    }
    final bytes = Uint8List.fromList(value.bytes);
    if (bytes.isEmpty || bytes[0] != 0x00) {
      throw FormatException('CID tag 42 bytes must start with 0x00 identity multibase');
    }
    // Strip the 0x00 multibase prefix
    final cidBytes = bytes.sublist(1);
    final cid = Cid.fromBytes(cidBytes);
    return CidLink(cid);
  }
}

/// Manual CBOR encoder that produces deterministic output.
///
/// The `package:cbor` encoder doesn't guarantee map key ordering,
/// so we build the bytes ourselves for deterministic encoding.
class CborEncoder {
  final _buffer = BytesBuilder(copy: false);

  Uint8List toBytes() => _buffer.toBytes();

  void addNull() => _buffer.addByte(0xf6);

  void addBool(bool value) => _buffer.addByte(value ? 0xf5 : 0xf4);

  void addInt(int value) {
    if (value >= 0) {
      _writeUint(0, value);
    } else {
      _writeUint(1, -1 - value);
    }
  }

  void addText(String value) {
    final bytes = utf8.encode(value);
    _writeUint(3, bytes.length);
    _buffer.add(bytes);
  }

  void addBytes(Uint8List value) {
    _writeUint(2, value.length);
    _buffer.add(value);
  }

  void addTag(int tag) {
    _writeUint(6, tag);
  }

  void addArrayHeader(int length) {
    _writeUint(4, length);
  }

  void addMapHeader(int length) {
    _writeUint(5, length);
  }

  void _writeUint(int major, int value) {
    final majorBits = major << 5;
    if (value < 24) {
      _buffer.addByte(majorBits | value);
    } else if (value < 0x100) {
      _buffer.addByte(majorBits | 24);
      _buffer.addByte(value);
    } else if (value < 0x10000) {
      _buffer.addByte(majorBits | 25);
      _buffer.addByte((value >> 8) & 0xff);
      _buffer.addByte(value & 0xff);
    } else if (value < 0x100000000) {
      _buffer.addByte(majorBits | 26);
      _buffer.addByte((value >> 24) & 0xff);
      _buffer.addByte((value >> 16) & 0xff);
      _buffer.addByte((value >> 8) & 0xff);
      _buffer.addByte(value & 0xff);
    } else {
      _buffer.addByte(majorBits | 27);
      _buffer.addByte((value >> 56) & 0xff);
      _buffer.addByte((value >> 48) & 0xff);
      _buffer.addByte((value >> 40) & 0xff);
      _buffer.addByte((value >> 32) & 0xff);
      _buffer.addByte((value >> 24) & 0xff);
      _buffer.addByte((value >> 16) & 0xff);
      _buffer.addByte((value >> 8) & 0xff);
      _buffer.addByte(value & 0xff);
    }
  }
}
