/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Data model for APRS packets — covers both broadcast stream packets
 * and directed 1:1 messages.
 */

/// Classification of an APRS packet by its info-field content.
enum AprsPacketType { position, message, status, weather, telemetry, other }

/// A single APRS packet as decoded from the TNC2 frame format.
class AprsPacket {
  /// Source callsign with SSID, e.g. "N0CALL-9"
  final String fromCallsign;

  /// Destination callsign or generic tocall, e.g. "APRS" or "N0CALL-5"
  final String toCallsign;

  /// Digipeater path, e.g. "WIDE1-1,WIDE2-1"
  final String? path;

  /// Raw info field content (everything after the ":")
  final String infoField;

  /// Full TNC2 frame string
  final String rawTnc2;

  /// When the packet was received
  final DateTime timestamp;

  /// Packet type classification
  final AprsPacketType type;

  // --- Directed-message fields (only set when type == message) ---

  /// Parsed message body text
  final String? messageText;

  /// APRS message sequence number (used for ack/rej)
  final String? messageId;

  /// Whether an ack has been received for this message
  final bool isAcked;

  const AprsPacket({
    required this.fromCallsign,
    required this.toCallsign,
    this.path,
    required this.infoField,
    required this.rawTnc2,
    required this.timestamp,
    required this.type,
    this.messageText,
    this.messageId,
    this.isAcked = false,
  });

  /// Create a copy with updated fields.
  AprsPacket copyWith({bool? isAcked}) {
    return AprsPacket(
      fromCallsign: fromCallsign,
      toCallsign: toCallsign,
      path: path,
      infoField: infoField,
      rawTnc2: rawTnc2,
      timestamp: timestamp,
      type: type,
      messageText: messageText,
      messageId: messageId,
      isAcked: isAcked ?? this.isAcked,
    );
  }

  @override
  String toString() =>
      'AprsPacket($fromCallsign>$toCallsign [$type] $infoField)';
}
