/// Wire codec for the BT-DHT-v2 §10.4 relay protocol.
///
/// Frame layout (network byte order):
///   1 byte   message type
///   16 bytes session id (relay-internal, ephemeral)
///   4 bytes  payload length (uint32 BE)
///   N bytes  payload
///
/// Types:
///   HELLO          — latency probe; payload may carry capability flags
///   OPEN_SESSION   — request to bridge with a target npub; payload is the
///                    NOSTR pubkey hex of the desired peer (64 chars)
///   DATA           — opaque application bytes (relay never inspects)
///   CLOSE_SESSION  — graceful teardown
///   PONG           — HELLO reply
///
/// All multi-byte fields are big-endian. Length is bounded at 1 MiB; longer
/// frames are rejected. The relay never inspects DATA payload bytes — the
/// application is responsible for end-to-end encryption above this layer.
library;

import 'dart:typed_data';

class RelayMessageType {
  static const int hello = 0x01;
  static const int openSession = 0x02;
  static const int data = 0x03;
  static const int closeSession = 0x04;
  static const int pong = 0x05;

  static String nameOf(int t) {
    switch (t) {
      case hello:
        return 'HELLO';
      case openSession:
        return 'OPEN_SESSION';
      case data:
        return 'DATA';
      case closeSession:
        return 'CLOSE_SESSION';
      case pong:
        return 'PONG';
      default:
        return '0x${t.toRadixString(16).padLeft(2, '0')}';
    }
  }
}

class RelayMessage {
  final int type;
  final Uint8List sessionId;
  final Uint8List payload;

  RelayMessage({
    required this.type,
    required this.sessionId,
    required this.payload,
  }) {
    if (sessionId.length != 16) {
      throw ArgumentError(
          'session id must be 16 bytes, got ${sessionId.length}');
    }
  }

  /// Encode to the wire format. Returns a contiguous byte buffer.
  Uint8List encode() {
    if (payload.length > _maxPayloadLen) {
      throw ArgumentError(
          'payload too large (${payload.length} > $_maxPayloadLen)');
    }
    final out = Uint8List(1 + 16 + 4 + payload.length);
    out[0] = type & 0xff;
    out.setRange(1, 17, sessionId);
    final len = payload.length;
    out[17] = (len >> 24) & 0xff;
    out[18] = (len >> 16) & 0xff;
    out[19] = (len >> 8) & 0xff;
    out[20] = len & 0xff;
    out.setRange(21, 21 + len, payload);
    return out;
  }

  /// Decode a single frame from [buffer] starting at [offset]. Returns null
  /// if the buffer doesn't yet contain a complete frame; throws on
  /// malformed input. On success, advances the cursor — the caller can
  /// repeatedly call [decodeAll] to drain a stream.
  static (RelayMessage?, int consumed) decodeOne(
      Uint8List buffer, int offset) {
    if (buffer.length - offset < _headerLen) return (null, 0);
    final type = buffer[offset];
    final sid = buffer.sublist(offset + 1, offset + 17);
    final len = ((buffer[offset + 17] & 0xff) << 24) |
        ((buffer[offset + 18] & 0xff) << 16) |
        ((buffer[offset + 19] & 0xff) << 8) |
        (buffer[offset + 20] & 0xff);
    if (len < 0 || len > _maxPayloadLen) {
      throw FormatException('relay frame payload length $len out of range');
    }
    if (buffer.length - offset - _headerLen < len) {
      return (null, 0);
    }
    final payload = buffer.sublist(
        offset + _headerLen, offset + _headerLen + len);
    return (
      RelayMessage(
        type: type,
        sessionId: Uint8List.fromList(sid),
        payload: Uint8List.fromList(payload),
      ),
      _headerLen + len,
    );
  }

  /// Drain every complete frame from [buffer]. Returns the list of decoded
  /// frames plus the leftover bytes (incomplete trailing frame).
  static (List<RelayMessage>, Uint8List remainder) decodeAll(
      Uint8List buffer) {
    final frames = <RelayMessage>[];
    var offset = 0;
    while (offset < buffer.length) {
      final (frame, consumed) = decodeOne(buffer, offset);
      if (frame == null) break;
      frames.add(frame);
      offset += consumed;
    }
    final leftover = offset == buffer.length
        ? Uint8List(0)
        : Uint8List.fromList(buffer.sublist(offset));
    return (frames, leftover);
  }

  @override
  String toString() =>
      'RelayMessage(${RelayMessageType.nameOf(type)}, '
      'sid=${_hex(sessionId).substring(0, 8)}…, '
      'payload=${payload.length}B)';

  static const int _headerLen = 1 + 16 + 4;
  static const int _maxPayloadLen = 1 << 20; // 1 MiB
}

String _hex(Uint8List bytes) {
  const chars = '0123456789abcdef';
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(chars[(b >> 4) & 0xf]);
    out.write(chars[b & 0xf]);
  }
  return out.toString();
}
