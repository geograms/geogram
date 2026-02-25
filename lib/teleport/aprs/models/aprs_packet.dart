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

  /// Whether the comment is an automated beacon rather than human text.
  /// Beacons are already visible in the Stream tab — geo-chat only shows
  /// messages that look like they were typed by a person.
  bool get isBeaconComment {
    if (comment == null || comment!.isEmpty) return false;
    final c = comment!;
    final lower = c.toLowerCase();

    // Altitude report: /A=000377 (standard APRS extension)
    if (_altitudeRe.hasMatch(c)) return true;

    // Course/speed at start: 124/000 (3-digit bearing / 3-digit speed)
    if (_courseSpeedRe.hasMatch(c)) return true;

    // Infrastructure keywords
    if (lower.contains('igate') || lower.contains('digi')) return true;
    if (lower.contains('repeater') || lower.contains('relais')) return true;
    if (lower.contains('tracker')) return true;

    // Station metadata: QTH:, DOK, PHG (power/height/gain)
    if (lower.contains('qth:') || lower.contains('dok ') ||
        lower.contains('phg')) return true;

    // Frequency: 438.500 MHz or 145,500 mhz
    if (_freqRe.hasMatch(c)) return true;

    // Battery/current telemetry: Bat.: 4.1V, Cur.: 0mA
    if (_batteryRe.hasMatch(c)) return true;

    // Software version in braces: {UIV32N}, {APRX}, {APRSISCE}
    if (_softwareRe.hasMatch(c)) return true;

    // RX/TX radio configuration
    if (lower.contains('rx/tx') || lower.contains('rx -->')) return true;

    // Very short single-word (≤5 chars) — device type labels like "LoRa"
    if (c.trim().length <= 5 && !c.trim().contains(' ')) return true;

    return false;
  }

  static final _altitudeRe = RegExp(r'/A=\d{6}');
  static final _courseSpeedRe = RegExp(r'^\d{3}/\d{3}');
  static final _freqRe = RegExp(r'\d{3}[.,]\d{3}\s*mhz', caseSensitive: false);
  static final _batteryRe = RegExp(r'bat[.:]', caseSensitive: false);
  static final _softwareRe = RegExp(r'\{[A-Za-z0-9]+\}');

  /// Whether this is a human geo-chat message (has comment, not a beacon).
  bool get isHumanGeoChat => isGeoChat && !isBeaconComment;

  /// Create a copy with updated fields.
  AprsPacket copyWith({
    String? messageText,
    String? messageId,
    DateTime? timestamp,
    bool? isAcked,
    bool? isOutgoing,
  }) {
    return AprsPacket(
      fromCallsign: fromCallsign,
      toCallsign: toCallsign,
      path: path,
      infoField: infoField,
      rawTnc2: rawTnc2,
      timestamp: timestamp ?? this.timestamp,
      type: type,
      latitude: latitude,
      longitude: longitude,
      messageAddressee: messageAddressee,
      messageText: messageText ?? this.messageText,
      messageId: messageId ?? this.messageId,
      isAcked: isAcked ?? this.isAcked,
      isOutgoing: isOutgoing ?? this.isOutgoing,
      comment: comment,
    );
  }

  @override
  String toString() =>
      'AprsPacket($fromCallsign>$toCallsign [$type] $infoField)';
}
