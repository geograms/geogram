/*
 * CID v1 (Content Identifier) for AT Protocol.
 *
 * AT Proto uses CID v1 with:
 * - Multicodec: dag-cbor (0x71)
 * - Multihash: SHA-256 (0x12), 32-byte digest
 * - Multibase: base32lower for string representation
 *
 * Binary layout: <multicodec varint><multihash-code varint><digest-length varint><digest>
 *
 * Reference: https://github.com/multiformats/cid
 */

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// CID v1 content identifier.
class Cid {
  /// Raw SHA-256 digest (32 bytes).
  final Uint8List hash;

  /// Multicodec for DAG-CBOR.
  static const int codecDagCbor = 0x71;

  /// Multihash code for SHA-256.
  static const int hashSha256 = 0x12;

  /// SHA-256 digest length.
  static const int hashLength = 32;

  /// CID version.
  static const int version = 1;

  Cid._(this.hash) {
    if (hash.length != hashLength) {
      throw ArgumentError('SHA-256 hash must be $hashLength bytes, got ${hash.length}');
    }
  }

  /// Create a CID by hashing DAG-CBOR encoded content.
  factory Cid.fromContent(Uint8List dagCborBytes) {
    final digest = sha256.convert(dagCborBytes);
    return Cid._(Uint8List.fromList(digest.bytes));
  }

  /// Create a CID from a known SHA-256 hash.
  factory Cid.fromHash(Uint8List sha256Hash) {
    return Cid._(Uint8List.fromList(sha256Hash));
  }

  /// Parse a CID from its raw binary representation (no multibase prefix).
  ///
  /// Binary layout: version(varint) + codec(varint) + hashCode(varint) + hashLen(varint) + hash
  factory Cid.fromBytes(Uint8List bytes) {
    var offset = 0;

    // Read version
    final (ver, o1) = _readUvarint(bytes, offset);
    offset = o1;
    if (ver != version) {
      throw FormatException('Unsupported CID version: $ver');
    }

    // Read codec
    final (codec, o2) = _readUvarint(bytes, offset);
    offset = o2;
    if (codec != codecDagCbor) {
      throw FormatException('Unsupported CID codec: 0x${codec.toRadixString(16)}');
    }

    // Read multihash code
    final (mhCode, o3) = _readUvarint(bytes, offset);
    offset = o3;
    if (mhCode != hashSha256) {
      throw FormatException('Unsupported hash function: 0x${mhCode.toRadixString(16)}');
    }

    // Read digest length
    final (mhLen, o4) = _readUvarint(bytes, offset);
    offset = o4;
    if (mhLen != hashLength) {
      throw FormatException('Unexpected digest length: $mhLen');
    }

    // Read digest
    if (offset + hashLength > bytes.length) {
      throw FormatException('CID too short for digest');
    }
    final hash = bytes.sublist(offset, offset + hashLength);
    return Cid._(Uint8List.fromList(hash));
  }

  /// Parse a CID from a multibase-encoded string.
  ///
  /// Supports base32lower ('b' prefix) which AT Proto uses.
  factory Cid.fromString(String multibase) {
    if (multibase.isEmpty) {
      throw FormatException('Empty CID string');
    }
    final prefix = multibase[0];
    final encoded = multibase.substring(1);

    if (prefix == 'b') {
      // base32lower (RFC 4648, no padding)
      final bytes = _base32Decode(encoded);
      return Cid.fromBytes(bytes);
    }
    throw FormatException('Unsupported multibase prefix: $prefix');
  }

  /// Encode as raw CID bytes (no multibase prefix).
  Uint8List toBytes() {
    final builder = BytesBuilder(copy: false);
    _writeUvarint(builder, version);
    _writeUvarint(builder, codecDagCbor);
    _writeUvarint(builder, hashSha256);
    _writeUvarint(builder, hashLength);
    builder.add(hash);
    return builder.toBytes();
  }

  /// Encode as base32lower multibase string (with 'b' prefix).
  String toBase32() {
    return 'b${_base32Encode(toBytes())}';
  }

  @override
  bool operator ==(Object other) {
    if (other is! Cid) return false;
    if (hash.length != other.hash.length) return false;
    for (var i = 0; i < hash.length; i++) {
      if (hash[i] != other.hash[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    // Use first 4 bytes of SHA-256 as hash code
    return (hash[0] << 24) | (hash[1] << 16) | (hash[2] << 8) | hash[3];
  }

  @override
  String toString() => toBase32();

  // -- Unsigned varint encoding/decoding --

  static (int, int) _readUvarint(Uint8List bytes, int offset) {
    var result = 0;
    var shift = 0;
    while (offset < bytes.length) {
      final b = bytes[offset++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return (result, offset);
      shift += 7;
      if (shift > 35) throw FormatException('Varint too long');
    }
    throw FormatException('Varint truncated');
  }

  static void _writeUvarint(BytesBuilder builder, int value) {
    while (value >= 0x80) {
      builder.addByte((value & 0x7f) | 0x80);
      value >>= 7;
    }
    builder.addByte(value);
  }

  // -- Base32lower (RFC 4648 lowercase, no padding) --

  static const _base32Alphabet = 'abcdefghijklmnopqrstuvwxyz234567';

  static String _base32Encode(Uint8List data) {
    final sb = StringBuffer();
    var bits = 0;
    var buffer = 0;
    for (final byte in data) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        sb.write(_base32Alphabet[(buffer >> bits) & 0x1f]);
      }
    }
    if (bits > 0) {
      sb.write(_base32Alphabet[(buffer << (5 - bits)) & 0x1f]);
    }
    return sb.toString();
  }

  static Uint8List _base32Decode(String encoded) {
    final result = BytesBuilder(copy: false);
    var bits = 0;
    var buffer = 0;
    for (final char in encoded.codeUnits) {
      int value;
      if (char >= 0x61 && char <= 0x7a) {
        // a-z
        value = char - 0x61;
      } else if (char >= 0x32 && char <= 0x37) {
        // 2-7
        value = char - 0x32 + 26;
      } else {
        throw FormatException('Invalid base32 character: ${String.fromCharCode(char)}');
      }
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        result.addByte((buffer >> bits) & 0xff);
      }
    }
    return result.toBytes();
  }
}
