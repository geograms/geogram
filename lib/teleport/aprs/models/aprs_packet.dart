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

  // --- Position fields (set when type == position or parseable) ---

  /// Latitude in decimal degrees (positive = N, negative = S)
  final double? latitude;

  /// Longitude in decimal degrees (positive = E, negative = W)
  final double? longitude;

  // --- Directed-message fields (only set when type == message) ---

  /// The addressee inside a directed message (trimmed of APRS 9-char padding).
  /// This is the actual recipient, NOT the TNC2 header destination.
  final String? messageAddressee;

  /// Parsed message body text
  final String? messageText;

  /// APRS message sequence number (used for ack/rej)
  final String? messageId;

  /// Whether an ack has been received for this message
  final bool isAcked;

  /// Whether this is a locally-generated outgoing message.
  final bool isOutgoing;

  /// Comment text extracted from position reports (geo-chat).
  final String? comment;

  const AprsPacket({
    required this.fromCallsign,
    required this.toCallsign,
    this.path,
    required this.infoField,
    required this.rawTnc2,
    required this.timestamp,
    required this.type,
    this.latitude,
    this.longitude,
    this.messageAddressee,
    this.messageText,
    this.messageId,
    this.isAcked = false,
    this.isOutgoing = false,
    this.comment,
  });

  /// Whether this packet has a valid parsed position.
  bool get hasPosition => latitude != null && longitude != null;

  /// Whether this is a hashtag group message (text starts with '#').
  bool get isTagMessage => messageText != null && messageText!.startsWith('#');

  /// Extract '#tag' from a tag message, lowercase. Null if not a tag message.
  String? get messageTag {
    if (!isTagMessage) return null;
    final spaceIdx = messageText!.indexOf(' ');
    return (spaceIdx < 0 ? messageText! : messageText!.substring(0, spaceIdx))
        .toLowerCase();
  }

  /// Message body without the leading #tag prefix.
  String? get messageBody {
    if (!isTagMessage) return messageText;
    final spaceIdx = messageText!.indexOf(' ');
    return spaceIdx < 0 ? '' : messageText!.substring(spaceIdx + 1);
  }

  /// Whether this position packet carries a geo-chat comment.
  bool get isGeoChat => comment != null && comment!.isNotEmpty;

  /// Create a copy with updated fields.
  AprsPacket copyWith({bool? isAcked, bool? isOutgoing}) {
    return AprsPacket(
      fromCallsign: fromCallsign,
      toCallsign: toCallsign,
      path: path,
      infoField: infoField,
      rawTnc2: rawTnc2,
      timestamp: timestamp,
      type: type,
      latitude: latitude,
      longitude: longitude,
      messageAddressee: messageAddressee,
      messageText: messageText,
      messageId: messageId,
      isAcked: isAcked ?? this.isAcked,
      isOutgoing: isOutgoing ?? this.isOutgoing,
      comment: comment,
    );
  }

  @override
  String toString() =>
      'AprsPacket($fromCallsign>$toCallsign [$type] $infoField)';
}
