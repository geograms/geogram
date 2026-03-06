/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * BitChat binary protocol — encode/decode for BLE mesh packets.
 * Pure Dart, no Flutter dependency. Reusable from CLI.
 *
 * Packet format (wire-compatible with official BitChat apps):
 *   Header (13 bytes):
 *     [0]      version (uint8)
 *     [1]      type (uint8) — broadcast, direct, ack, announce
 *     [2]      TTL (uint8) — remaining hops (max 7)
 *     [3..6]   timestamp (uint32 LE, Unix epoch seconds)
 *     [7]      flags (uint8) — encrypted, signed, compressed
 *     [8..11]  payload length (uint32 LE)
 *     [12]     hop count (uint8)
 *   Sender ID (8 bytes):
 *     [13..20] first 8 bytes of sender's static public key
 *   Recipient ID (8 bytes, optional — only for direct messages):
 *     [21..28] first 8 bytes of recipient's static public key
 *   Payload (variable):
 *     UTF-8 text or encrypted blob
 *   Signature (64 bytes, optional — Ed25519):
 *     present when flags & 0x02 is set
 */

import 'dart:convert';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Protocol constants
// ---------------------------------------------------------------------------

const int bitchatProtocolVersion = 1;
const int bitchatMaxTtl = 7;
const int bitchatHeaderSize = 13;
const int bitchatSenderIdSize = 8;
const int bitchatRecipientIdSize = 8;
const int bitchatSignatureSize = 64;

// ---------------------------------------------------------------------------
// Packet types
// ---------------------------------------------------------------------------

class BitchatPacketType {
  static const int broadcast = 0x01;
  static const int direct = 0x02;
  static const int ack = 0x03;
  static const int announce = 0x04;
}

// ---------------------------------------------------------------------------
// Flags
// ---------------------------------------------------------------------------

class BitchatFlags {
  static const int encrypted = 0x01;
  static const int signed_ = 0x02;
  static const int compressed = 0x04;
}

// ---------------------------------------------------------------------------
// Decoded packet
// ---------------------------------------------------------------------------

sealed class BitchatPacket {
  final int version;
  final int type;
  final int ttl;
  final int timestamp;
  final int flags;
  final int hopCount;
  final Uint8List senderId;
  final Uint8List payload;

  const BitchatPacket({
    required this.version,
    required this.type,
    required this.ttl,
    required this.timestamp,
    required this.flags,
    required this.hopCount,
    required this.senderId,
    required this.payload,
  });

  bool get isEncrypted => flags & BitchatFlags.encrypted != 0;
  bool get isSigned => flags & BitchatFlags.signed_ != 0;
  String get senderIdHex => bytesToHex(senderId);
  String get payloadText => utf8.decode(payload, allowMalformed: true);
}

class BitchatBroadcastPacket extends BitchatPacket {
  const BitchatBroadcastPacket({
    required super.version,
    required super.ttl,
    required super.timestamp,
    required super.flags,
    required super.hopCount,
    required super.senderId,
    required super.payload,
  }) : super(type: BitchatPacketType.broadcast);
}

class BitchatDirectPacket extends BitchatPacket {
  final Uint8List recipientId;

  const BitchatDirectPacket({
    required super.version,
    required super.ttl,
    required super.timestamp,
    required super.flags,
    required super.hopCount,
    required super.senderId,
    required this.recipientId,
    required super.payload,
  }) : super(type: BitchatPacketType.direct);

  String get recipientIdHex => bytesToHex(recipientId);
}

class BitchatAckPacket extends BitchatPacket {
  const BitchatAckPacket({
    required super.version,
    required super.ttl,
    required super.timestamp,
    required super.flags,
    required super.hopCount,
    required super.senderId,
    required super.payload,
  }) : super(type: BitchatPacketType.ack);
}

class BitchatAnnouncePacket extends BitchatPacket {
  const BitchatAnnouncePacket({
    required super.version,
    required super.ttl,
    required super.timestamp,
    required super.flags,
    required super.hopCount,
    required super.senderId,
    required super.payload,
  }) : super(type: BitchatPacketType.announce);
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Encode a broadcast message packet.
Uint8List encodeBroadcast({
  required Uint8List senderId,
  required String text,
  int ttl = bitchatMaxTtl,
}) {
  final payload = Uint8List.fromList(utf8.encode(text));
  return _encodePacket(
    type: BitchatPacketType.broadcast,
    senderId: senderId,
    payload: payload,
    ttl: ttl,
  );
}

/// Encode a direct message packet.
Uint8List encodeDirect({
  required Uint8List senderId,
  required Uint8List recipientId,
  required String text,
  int ttl = bitchatMaxTtl,
  bool encrypted = false,
}) {
  final payload = Uint8List.fromList(utf8.encode(text));
  return _encodePacket(
    type: BitchatPacketType.direct,
    senderId: senderId,
    recipientId: recipientId,
    payload: payload,
    ttl: ttl,
    flags: encrypted ? BitchatFlags.encrypted : 0,
  );
}

/// Encode an acknowledgment packet.
Uint8List encodeAck({
  required Uint8List senderId,
  required String messageUuid,
}) {
  final payload = Uint8List.fromList(utf8.encode(messageUuid));
  return _encodePacket(
    type: BitchatPacketType.ack,
    senderId: senderId,
    payload: payload,
    ttl: 1,
  );
}

/// Encode a peer announcement packet.
Uint8List encodeAnnounce({
  required Uint8List senderId,
  required String nickname,
  required String geohash,
}) {
  final payload = Uint8List.fromList(utf8.encode('$nickname\x00$geohash'));
  return _encodePacket(
    type: BitchatPacketType.announce,
    senderId: senderId,
    payload: payload,
    ttl: 3,
  );
}

Uint8List _encodePacket({
  required int type,
  required Uint8List senderId,
  required Uint8List payload,
  Uint8List? recipientId,
  int ttl = bitchatMaxTtl,
  int flags = 0,
}) {
  final epoch = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  final hasRecipient = type == BitchatPacketType.direct && recipientId != null;

  final totalSize = bitchatHeaderSize +
      bitchatSenderIdSize +
      (hasRecipient ? bitchatRecipientIdSize : 0) +
      payload.length;

  final data = ByteData(totalSize);
  int offset = 0;

  // Header (13 bytes)
  data.setUint8(offset++, bitchatProtocolVersion);
  data.setUint8(offset++, type);
  data.setUint8(offset++, ttl);
  data.setUint32(offset, epoch, Endian.little);
  offset += 4;
  data.setUint8(offset++, flags);
  data.setUint32(offset, payload.length, Endian.little);
  offset += 4;
  data.setUint8(offset++, 0); // hop count starts at 0

  // Sender ID (8 bytes)
  final sid = senderId.length >= bitchatSenderIdSize
      ? senderId.sublist(0, bitchatSenderIdSize)
      : Uint8List(bitchatSenderIdSize)
    ..setRange(0, senderId.length, senderId);
  data.buffer.asUint8List().setRange(offset, offset + bitchatSenderIdSize, sid);
  offset += bitchatSenderIdSize;

  // Recipient ID (8 bytes, direct only)
  if (hasRecipient) {
    final rid = recipientId.length >= bitchatRecipientIdSize
        ? recipientId.sublist(0, bitchatRecipientIdSize)
        : Uint8List(bitchatRecipientIdSize)
      ..setRange(0, recipientId.length, recipientId);
    data.buffer
        .asUint8List()
        .setRange(offset, offset + bitchatRecipientIdSize, rid);
    offset += bitchatRecipientIdSize;
  }

  // Payload
  data.buffer.asUint8List().setRange(offset, offset + payload.length, payload);

  return data.buffer.asUint8List();
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// Decode a raw BLE packet into a typed BitchatPacket.
/// Returns null if the packet is malformed.
BitchatPacket? decodePacket(Uint8List data) {
  if (data.length < bitchatHeaderSize + bitchatSenderIdSize) return null;

  final view = ByteData.sublistView(data);
  int offset = 0;

  // Header
  final version = view.getUint8(offset++);
  final type = view.getUint8(offset++);
  final ttl = view.getUint8(offset++);
  final timestamp = view.getUint32(offset, Endian.little);
  offset += 4;
  final flags = view.getUint8(offset++);
  final payloadLength = view.getUint32(offset, Endian.little);
  offset += 4;
  final hopCount = view.getUint8(offset++);

  // Sender ID
  if (data.length < offset + bitchatSenderIdSize) return null;
  final senderId = data.sublist(offset, offset + bitchatSenderIdSize);
  offset += bitchatSenderIdSize;

  // Recipient ID (direct messages only)
  Uint8List? recipientId;
  if (type == BitchatPacketType.direct) {
    if (data.length < offset + bitchatRecipientIdSize) return null;
    recipientId = data.sublist(offset, offset + bitchatRecipientIdSize);
    offset += bitchatRecipientIdSize;
  }

  // Payload
  final payloadEnd = offset + payloadLength;
  if (payloadEnd > data.length) return null;
  final payload = data.sublist(offset, payloadEnd);

  switch (type) {
    case BitchatPacketType.broadcast:
      return BitchatBroadcastPacket(
        version: version,
        ttl: ttl,
        timestamp: timestamp,
        flags: flags,
        hopCount: hopCount,
        senderId: senderId,
        payload: payload,
      );
    case BitchatPacketType.direct:
      return BitchatDirectPacket(
        version: version,
        ttl: ttl,
        timestamp: timestamp,
        flags: flags,
        hopCount: hopCount,
        senderId: senderId,
        recipientId: recipientId!,
        payload: payload,
      );
    case BitchatPacketType.ack:
      return BitchatAckPacket(
        version: version,
        ttl: ttl,
        timestamp: timestamp,
        flags: flags,
        hopCount: hopCount,
        senderId: senderId,
        payload: payload,
      );
    case BitchatPacketType.announce:
      return BitchatAnnouncePacket(
        version: version,
        ttl: ttl,
        timestamp: timestamp,
        flags: flags,
        hopCount: hopCount,
        senderId: senderId,
        payload: payload,
      );
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Hex utilities
// ---------------------------------------------------------------------------

String bytesToHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List hexToBytes(String hex) {
  final result = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}
