/*
 * CAR v1 (Content-Addressable aRchive) reader/writer for AT Protocol.
 *
 * CAR files bundle a set of content-addressed blocks with one or more root CIDs.
 * Used by AT Proto for repo export (getRepo) and sync operations.
 *
 * Format:
 *   header = DAG-CBOR({ "version": 1, "roots": [CID, ...] })
 *   body   = repeated: <varint block-length><CID bytes><block data>
 *
 * Reference: https://ipld.io/specs/transport/car/carv1/
 */

import 'dart:typed_data';

import 'cid.dart';
import 'dag_cbor.dart';

/// Write CAR v1 files.
class CarWriter {
  /// Create a CAR v1 byte stream with the given root CID and blocks.
  ///
  /// [root] is the CID of the repo commit (the entry point).
  /// [blocks] maps CID → DAG-CBOR encoded content for each block.
  static Uint8List write(Cid root, Map<Cid, Uint8List> blocks) {
    final output = BytesBuilder(copy: false);

    // Encode header as DAG-CBOR
    final header = DagCbor.encode({
      'version': 1,
      'roots': [CidLink(root)],
    });

    // Write header length (varint) + header
    _writeUvarint(output, header.length);
    output.add(header);

    // Write each block: varint(cidBytes.length + data.length) + cidBytes + data
    for (final entry in blocks.entries) {
      final cidBytes = entry.key.toBytes();
      final data = entry.value;
      _writeUvarint(output, cidBytes.length + data.length);
      output.add(cidBytes);
      output.add(data);
    }

    return output.toBytes();
  }
}

/// Read CAR v1 files.
class CarReader {
  /// Parse a CAR v1 file into roots and block map.
  ///
  /// Returns the list of root CIDs and a map of CID → block content.
  static CarFile read(Uint8List carBytes) {
    var offset = 0;

    // Read header length
    final (headerLen, o1) = _readUvarint(carBytes, offset);
    offset = o1;

    // Decode header
    final headerBytes = carBytes.sublist(offset, offset + headerLen);
    offset += headerLen;
    final header = DagCbor.decode(headerBytes);
    if (header is! Map) {
      throw FormatException('CAR header must be a map');
    }
    final version = header['version'];
    if (version != 1) {
      throw FormatException('Unsupported CAR version: $version');
    }

    final rootsList = header['roots'];
    if (rootsList is! List) {
      throw FormatException('CAR header must have roots array');
    }
    final roots = <Cid>[];
    for (final r in rootsList) {
      if (r is CidLink) {
        roots.add(r.cid);
      } else {
        throw FormatException('CAR root must be a CID link');
      }
    }

    // Read blocks
    final blocks = <Cid, Uint8List>{};
    while (offset < carBytes.length) {
      final (blockLen, o2) = _readUvarint(carBytes, offset);
      offset = o2;

      if (blockLen == 0) break;

      // Parse CID from block start
      final blockStart = offset;
      final blockEnd = offset + blockLen;
      if (blockEnd > carBytes.length) {
        throw FormatException('CAR block extends past end of data');
      }

      final cid = Cid.fromBytes(carBytes.sublist(offset, blockEnd));
      final cidLen = cid.toBytes().length;
      final data = carBytes.sublist(offset + cidLen, blockEnd);
      blocks[cid] = Uint8List.fromList(data);

      offset = blockEnd;
    }

    return CarFile(roots: roots, blocks: blocks);
  }
}

/// Parsed CAR v1 file.
class CarFile {
  final List<Cid> roots;
  final Map<Cid, Uint8List> blocks;

  CarFile({required this.roots, required this.blocks});
}

// -- Shared varint helpers --

void _writeUvarint(BytesBuilder builder, int value) {
  while (value >= 0x80) {
    builder.addByte((value & 0x7f) | 0x80);
    value >>= 7;
  }
  builder.addByte(value);
}

(int, int) _readUvarint(Uint8List bytes, int offset) {
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
