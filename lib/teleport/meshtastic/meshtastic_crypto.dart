/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * AES256-CTR encryption/decryption for Meshtastic channel packets.
 * Uses pointycastle (already in deps).
 *
 * Nonce = packetId(4 LE) + fromNode(4 LE) + 8 zero bytes.
 * PSK expansion: 0 bytes = none, 1 byte = predefined table, 16 = AES128, 32 = AES256.
 */

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Predefined PSK expansion table from Meshtastic.
/// When a 1-byte PSK is used, expand to 32 bytes using this table.
const List<List<int>> _predefinedPskTable = [
  // Index 0: "AQ==" = default LongFast key
  [
    0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59,
    0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01,
    0x68, 0x35, 0x81, 0x7c, 0x20, 0x7d, 0x69, 0x20,
    0x01, 0xa3, 0x5f, 0xa8, 0xdb, 0x77, 0xa2, 0x4c,
  ],
];

/// Expand a PSK to its full 32-byte key.
/// - 0 bytes: return empty (no encryption)
/// - 1 byte: lookup in predefined table (only index 0 currently)
/// - 16 bytes: pad to 32 (AES128 in CTR mode)
/// - 32 bytes: use as-is (AES256)
Uint8List expandPsk(Uint8List psk) {
  if (psk.isEmpty) return Uint8List(0);

  if (psk.length == 1) {
    final index = psk[0];
    if (index < _predefinedPskTable.length) {
      return Uint8List.fromList(_predefinedPskTable[index]);
    }
    // Unknown index — use as single-byte key (shouldn't happen)
    return Uint8List(0);
  }

  if (psk.length == 16) {
    // AES128: zero-pad to 32 bytes
    final expanded = Uint8List(32);
    expanded.setRange(0, 16, psk);
    return expanded;
  }

  if (psk.length == 32) return psk;

  // Unknown length — return as-is, caller should handle
  return psk;
}

/// Build the 16-byte nonce for AES-CTR.
/// packetId (4 LE) + fromNode (4 LE) + 8 zero bytes.
Uint8List buildNonce(int packetId, int fromNode) {
  final nonce = Uint8List(16);
  final bd = ByteData.sublistView(nonce);
  bd.setUint32(0, packetId, Endian.little);
  bd.setUint32(4, fromNode, Endian.little);
  // bytes 8-15 are already zero
  return nonce;
}

/// Encrypt plaintext payload using AES256-CTR.
Uint8List encryptMeshtastic(
    Uint8List plaintext, Uint8List key, int packetId, int fromNode) {
  if (key.isEmpty) return plaintext;
  final nonce = buildNonce(packetId, fromNode);
  return _aesCtr(plaintext, key, nonce);
}

/// Decrypt ciphertext payload using AES256-CTR.
Uint8List decryptMeshtastic(
    Uint8List ciphertext, Uint8List key, int packetId, int fromNode) {
  if (key.isEmpty) return ciphertext;
  final nonce = buildNonce(packetId, fromNode);
  return _aesCtr(ciphertext, key, nonce);
}

Uint8List _aesCtr(Uint8List input, Uint8List key, Uint8List nonce) {
  final params = ParametersWithIV<KeyParameter>(
    KeyParameter(key),
    nonce,
  );
  final cipher = StreamCipher('AES/CTR');
  cipher.init(true, params); // encrypt == decrypt for CTR
  return cipher.process(input);
}
