/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Internal helper returned by [Postcard._readBlock].
class _BlockRead {
  final Map<String, String> fields;
  final int nextIndex;
  const _BlockRead({required this.fields, required this.nextIndex});
}

/// Model representing a postcard stamp added by a carrier
class PostcardStamp {
  final int number; // Stamp number (1, 2, 3...)
  final String stamperCallsign;
  final String stamperNpub;
  final String timestamp; // Format: YYYY-MM-DD HH:MM_ss
  final double latitude;
  final double longitude;
  final String? locationName;
  final String receivedFrom; // "sender" or npub
  final String receivedVia; // BLE, LoRa, Radio, etc.
  final int hopNumber;
  final String signature;

  PostcardStamp({
    required this.number,
    required this.stamperCallsign,
    required this.stamperNpub,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    this.locationName,
    required this.receivedFrom,
    required this.receivedVia,
    required this.hopNumber,
    required this.signature,
  });

  /// Parse timestamp to DateTime
  DateTime get dateTime {
    try {
      final normalized = timestamp.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Get display timestamp (formatted for UI)
  String get displayTimestamp => timestamp.replaceAll('_', ':');

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
        'number': number,
        'stamperCallsign': stamperCallsign,
        'stamperNpub': stamperNpub,
        'timestamp': timestamp,
        'latitude': latitude,
        'longitude': longitude,
        if (locationName != null) 'locationName': locationName,
        'receivedFrom': receivedFrom,
        'receivedVia': receivedVia,
        'hopNumber': hopNumber,
        'signature': signature,
      };

  /// Create from JSON
  factory PostcardStamp.fromJson(Map<String, dynamic> json) {
    return PostcardStamp(
      number: json['number'] as int,
      stamperCallsign: json['stamperCallsign'] as String,
      stamperNpub: json['stamperNpub'] as String,
      timestamp: json['timestamp'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      locationName: json['locationName'] as String?,
      receivedFrom: json['receivedFrom'] as String,
      receivedVia: json['receivedVia'] as String,
      hopNumber: json['hopNumber'] as int,
      signature: json['signature'] as String,
    );
  }
}

/// Model representing a delivery receipt
class PostcardDeliveryReceipt {
  final String recipientNpub;
  final String timestamp; // Format: YYYY-MM-DD HH:MM_ss
  final String carrierCallsign;
  final String carrierNpub;
  final double deliveryLatitude;
  final double deliveryLongitude;
  final String? deliveryLocationName;
  final String? deliveryNote;
  final String signature;

  PostcardDeliveryReceipt({
    required this.recipientNpub,
    required this.timestamp,
    required this.carrierCallsign,
    required this.carrierNpub,
    required this.deliveryLatitude,
    required this.deliveryLongitude,
    this.deliveryLocationName,
    this.deliveryNote,
    required this.signature,
  });

  /// Parse timestamp to DateTime
  DateTime get dateTime {
    try {
      final normalized = timestamp.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Get display timestamp (formatted for UI)
  String get displayTimestamp => timestamp.replaceAll('_', ':');

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
        'recipientNpub': recipientNpub,
        'timestamp': timestamp,
        'carrierCallsign': carrierCallsign,
        'carrierNpub': carrierNpub,
        'deliveryLatitude': deliveryLatitude,
        'deliveryLongitude': deliveryLongitude,
        if (deliveryLocationName != null)
          'deliveryLocationName': deliveryLocationName,
        if (deliveryNote != null) 'deliveryNote': deliveryNote,
        'signature': signature,
      };

  /// Create from JSON
  factory PostcardDeliveryReceipt.fromJson(Map<String, dynamic> json) {
    return PostcardDeliveryReceipt(
      recipientNpub: json['recipientNpub'] as String,
      timestamp: json['timestamp'] as String,
      carrierCallsign: json['carrierCallsign'] as String,
      carrierNpub: json['carrierNpub'] as String,
      deliveryLatitude: (json['deliveryLatitude'] as num).toDouble(),
      deliveryLongitude: (json['deliveryLongitude'] as num).toDouble(),
      deliveryLocationName: json['deliveryLocationName'] as String?,
      deliveryNote: json['deliveryNote'] as String?,
      signature: json['signature'] as String,
    );
  }
}

/// Model representing sender acknowledgment
class PostcardAcknowledgment {
  final String senderNpub;
  final String timestamp; // Format: YYYY-MM-DD HH:MM_ss
  final String? acknowledgmentNote;
  final String signature;

  PostcardAcknowledgment({
    required this.senderNpub,
    required this.timestamp,
    this.acknowledgmentNote,
    required this.signature,
  });

  /// Parse timestamp to DateTime
  DateTime get dateTime {
    try {
      final normalized = timestamp.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Get display timestamp (formatted for UI)
  String get displayTimestamp => timestamp.replaceAll('_', ':');

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
        'senderNpub': senderNpub,
        'timestamp': timestamp,
        if (acknowledgmentNote != null) 'acknowledgmentNote': acknowledgmentNote,
        'signature': signature,
      };

  /// Create from JSON
  factory PostcardAcknowledgment.fromJson(Map<String, dynamic> json) {
    return PostcardAcknowledgment(
      senderNpub: json['senderNpub'] as String,
      timestamp: json['timestamp'] as String,
      acknowledgmentNote: json['acknowledgmentNote'] as String?,
      signature: json['signature'] as String,
    );
  }
}

/// Compact "I am carrying this" record appended by a courier when
/// they pick the postcard up to physically transport it. Smaller than
/// a full STAMP — no coordinates, no transmission method — because it
/// describes intent ("I'm taking this with me") rather than a hop.
/// The signature covers `signablePart()` and is verifiable against
/// [carrierNpub] using a Schnorr verifier.
class CarryRecord {
  final String carrierCallsign;
  final String carrierNpub;
  final String timestamp; // YYYY-MM-DD HH:MM_ss
  final String signature; // hex Schnorr sig over signablePart()

  const CarryRecord({
    required this.carrierCallsign,
    required this.carrierNpub,
    required this.timestamp,
    required this.signature,
  });

  /// Bytes that the [signature] covers.
  String signablePart() =>
      'CARRY|$carrierCallsign|$carrierNpub|$timestamp';

  String get displayTimestamp => timestamp.replaceAll('_', ':');

  DateTime get dateTime {
    try {
      return DateTime.parse(timestamp.replaceAll('_', ':'));
    } catch (_) {
      return DateTime.now();
    }
  }

  Map<String, dynamic> toJson() => {
        'carrierCallsign': carrierCallsign,
        'carrierNpub': carrierNpub,
        'timestamp': timestamp,
        'signature': signature,
      };

  factory CarryRecord.fromJson(Map<String, dynamic> json) {
    return CarryRecord(
      carrierCallsign: json['carrierCallsign'] as String,
      carrierNpub: json['carrierNpub'] as String,
      timestamp: json['timestamp'] as String,
      signature: json['signature'] as String,
    );
  }
}

/// Model representing recipient location hint
class RecipientLocation {
  final double latitude;
  final double longitude;
  final String? locationName;

  RecipientLocation({
    required this.latitude,
    required this.longitude,
    this.locationName,
  });

  /// Format as "lat,lon" string
  String toCoordinateString() => '$latitude,$longitude';

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        if (locationName != null) 'locationName': locationName,
      };

  /// Create from JSON
  factory RecipientLocation.fromJson(Map<String, dynamic> json) {
    return RecipientLocation(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      locationName: json['locationName'] as String?,
    );
  }

  /// Parse from "lat,lon" string
  factory RecipientLocation.fromCoordinateString(String coords) {
    final parts = coords.split(',');
    return RecipientLocation(
      latitude: double.parse(parts[0].trim()),
      longitude: double.parse(parts[1].trim()),
    );
  }
}

/// Model representing a postcard in the sneakernet delivery system
class Postcard {
  final String id; // Folder name: YYYY-MM-DD_msg-{hash}
  final String title;
  final String createdTimestamp; // Format: YYYY-MM-DD HH:MM_ss
  final String senderCallsign;
  final String senderNpub;
  final String? recipientCallsign;
  final String recipientNpub;
  final List<RecipientLocation> recipientLocations;
  final String type; // "open" or "encrypted"
  final String status; // "in-transit", "delivered", "acknowledged", "expired"
  final int? ttl; // Time-to-live in days (optional)
  final String priority; // "emergency", "urgent", "normal", "low"
  final String content; // Plain text or encrypted content
  final Map<String, String> metadata; // npub, signature

  // Journey tracking
  final List<PostcardStamp> stamps; // Outbound stamps
  final PostcardDeliveryReceipt? deliveryReceipt;
  final List<PostcardStamp> returnStamps; // Return journey stamps
  final PostcardAcknowledgment? acknowledgment;
  final List<CarryRecord> carries; // Couriers who picked it up

  // Additional data
  final List<String> attachments; // Photo filenames, etc.
  final Map<String, int> contributorCounts; // callsign -> file count

  Postcard({
    required this.id,
    required this.title,
    required this.createdTimestamp,
    required this.senderCallsign,
    required this.senderNpub,
    this.recipientCallsign,
    required this.recipientNpub,
    this.recipientLocations = const [],
    this.type = 'open',
    this.status = 'in-transit',
    this.ttl,
    this.priority = 'normal',
    required this.content,
    this.metadata = const {},
    this.stamps = const [],
    this.deliveryReceipt,
    this.returnStamps = const [],
    this.acknowledgment,
    this.carries = const [],
    this.attachments = const [],
    this.contributorCounts = const {},
  });

  /// Parse timestamp to DateTime
  DateTime get dateTime {
    try {
      final normalized = createdTimestamp.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Alias for dateTime (for compatibility)
  DateTime get createdDateTime => dateTime;

  /// Get display time (HH:MM)
  String get displayTime {
    final dt = dateTime;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  /// Get display date (YYYY-MM-DD)
  String get displayDate {
    final dt = dateTime;
    final year = dt.year.toString();
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// Get year from timestamp
  int get year => dateTime.year;

  /// Get message ID (last part of folder name)
  String get messageId {
    final parts = id.split('_msg-');
    return parts.length > 1 ? parts[1] : '';
  }

  /// Check if postcard is encrypted
  bool get isEncrypted => type == 'encrypted';

  /// Check if postcard is open (readable by all)
  bool get isOpen => type == 'open';

  /// Check if postcard is in transit
  bool get isInTransit => status == 'in-transit';

  /// Check if postcard is delivered
  bool get isDelivered => status == 'delivered';

  /// Check if postcard is acknowledged
  bool get isAcknowledged => status == 'acknowledged';

  /// Check if postcard is expired
  bool get isExpired => status == 'expired';

  /// Get total hop count (outbound)
  int get totalHops => stamps.length;

  /// Get total return hops
  int get totalReturnHops => returnStamps.length;

  /// Check if postcard has delivery receipt
  bool get hasDeliveryReceipt => deliveryReceipt != null;

  /// Check if postcard has return journey
  bool get hasReturnJourney => returnStamps.isNotEmpty;

  /// Check if postcard has sender acknowledgment
  bool get hasAcknowledgment => acknowledgment != null;

  /// Check if postcard is signed with NOSTR
  bool get isSigned => metadata.containsKey('signature');

  /// Get signature
  String? get signature => metadata['signature'];

  /// Check if user is sender
  bool isSender(String callsign) => senderCallsign == callsign;

  /// Check if user is recipient
  bool isRecipient(String callsign) => recipientCallsign == callsign;

  /// Get last stamp (most recent outbound)
  PostcardStamp? get lastStamp => stamps.isEmpty ? null : stamps.last;

  /// Get last return stamp (most recent return)
  PostcardStamp? get lastReturnStamp =>
      returnStamps.isEmpty ? null : returnStamps.last;

  /// Get current location (from last stamp or return stamp)
  String? get currentLocation {
    if (hasReturnJourney && returnStamps.isNotEmpty) {
      final stamp = returnStamps.last;
      return stamp.locationName ?? '${stamp.latitude},${stamp.longitude}';
    }
    if (stamps.isNotEmpty) {
      final stamp = stamps.last;
      return stamp.locationName ?? '${stamp.latitude},${stamp.longitude}';
    }
    return null;
  }

  /// Get all unique carriers (callsigns) who handled the postcard
  List<String> get allCarriers {
    final carriers = <String>{};
    for (final stamp in stamps) {
      carriers.add(stamp.stamperCallsign);
    }
    for (final stamp in returnStamps) {
      carriers.add(stamp.stamperCallsign);
    }
    return carriers.toList();
  }

  /// Get recipient locations as formatted string
  String get recipientLocationsString {
    return recipientLocations
        .map((loc) => loc.toCoordinateString())
        .join('; ');
  }

  /// Create a copy with updated fields
  Postcard copyWith({
    String? id,
    String? title,
    String? createdTimestamp,
    String? senderCallsign,
    String? senderNpub,
    String? recipientCallsign,
    String? recipientNpub,
    List<RecipientLocation>? recipientLocations,
    String? type,
    String? status,
    int? ttl,
    String? priority,
    String? content,
    Map<String, String>? metadata,
    List<PostcardStamp>? stamps,
    PostcardDeliveryReceipt? deliveryReceipt,
    List<PostcardStamp>? returnStamps,
    PostcardAcknowledgment? acknowledgment,
    List<CarryRecord>? carries,
    List<String>? attachments,
    Map<String, int>? contributorCounts,
  }) {
    return Postcard(
      id: id ?? this.id,
      title: title ?? this.title,
      createdTimestamp: createdTimestamp ?? this.createdTimestamp,
      senderCallsign: senderCallsign ?? this.senderCallsign,
      senderNpub: senderNpub ?? this.senderNpub,
      recipientCallsign: recipientCallsign ?? this.recipientCallsign,
      recipientNpub: recipientNpub ?? this.recipientNpub,
      recipientLocations: recipientLocations ?? this.recipientLocations,
      type: type ?? this.type,
      status: status ?? this.status,
      ttl: ttl ?? this.ttl,
      priority: priority ?? this.priority,
      content: content ?? this.content,
      metadata: metadata ?? this.metadata,
      stamps: stamps ?? this.stamps,
      deliveryReceipt: deliveryReceipt ?? this.deliveryReceipt,
      returnStamps: returnStamps ?? this.returnStamps,
      acknowledgment: acknowledgment ?? this.acknowledgment,
      carries: carries ?? this.carries,
      attachments: attachments ?? this.attachments,
      contributorCounts: contributorCounts ?? this.contributorCounts,
    );
  }

  /// The bytes that the sender's first signature must cover: title,
  /// header fields, blank line, and content. Does not include the
  /// `--> npub:` / `--> signature:` metadata lines that ARE the
  /// signature.
  String signableHeaderAndContent() {
    final buffer = StringBuffer();
    buffer.writeln('# POSTCARD: $title');
    buffer.writeln();
    buffer.writeln('CREATED: $createdTimestamp');
    buffer.writeln('SENDER_CALLSIGN: $senderCallsign');
    buffer.writeln('SENDER_NPUB: $senderNpub');
    if (recipientCallsign != null) {
      buffer.writeln('RECIPIENT_CALLSIGN: $recipientCallsign');
    }
    buffer.writeln('RECIPIENT_NPUB: $recipientNpub');
    buffer.writeln('RECIPIENT_LOCATIONS: $recipientLocationsString');
    buffer.writeln('TYPE: $type');
    buffer.writeln('STATUS: $status');
    if (ttl != null) {
      buffer.writeln('TTL: $ttl');
    }
    buffer.writeln('PRIORITY: $priority');
    buffer.writeln();
    buffer.writeln(content);
    return buffer.toString();
  }

  /// Export postcard as text format for file storage
  String exportAsText() {
    final buffer = StringBuffer();

    // Header
    buffer.writeln('# POSTCARD: $title');
    buffer.writeln();
    buffer.writeln('CREATED: $createdTimestamp');
    buffer.writeln('SENDER_CALLSIGN: $senderCallsign');
    buffer.writeln('SENDER_NPUB: $senderNpub');
    if (recipientCallsign != null) {
      buffer.writeln('RECIPIENT_CALLSIGN: $recipientCallsign');
    }
    buffer.writeln('RECIPIENT_NPUB: $recipientNpub');
    buffer.writeln('RECIPIENT_LOCATIONS: $recipientLocationsString');
    buffer.writeln('TYPE: $type');
    buffer.writeln('STATUS: $status');
    if (ttl != null) {
      buffer.writeln('TTL: $ttl');
    }
    buffer.writeln('PRIORITY: $priority');
    buffer.writeln();

    // Content
    buffer.writeln(content);
    buffer.writeln();

    // Sender metadata
    if (metadata.containsKey('npub')) {
      buffer.writeln('--> npub: ${metadata['npub']}');
    }
    if (metadata.containsKey('signature')) {
      buffer.writeln('--> signature: ${metadata['signature']}');
    }
    buffer.writeln();

    // Outbound stamps
    for (final stamp in stamps) {
      buffer.writeln('## STAMP: ${stamp.number}');
      buffer.writeln('STAMPER_CALLSIGN: ${stamp.stamperCallsign}');
      buffer.writeln('STAMPER_NPUB: ${stamp.stamperNpub}');
      buffer.writeln('TIMESTAMP: ${stamp.timestamp}');
      buffer.writeln('COORDINATES: ${stamp.latitude},${stamp.longitude}');
      if (stamp.locationName != null) {
        buffer.writeln('LOCATION_NAME: ${stamp.locationName}');
      }
      buffer.writeln('RECEIVED_FROM: ${stamp.receivedFrom}');
      buffer.writeln('RECEIVED_VIA: ${stamp.receivedVia}');
      buffer.writeln('HOP_NUMBER: ${stamp.hopNumber}');
      buffer.writeln('--> signature: ${stamp.signature}');
      buffer.writeln();
    }

    // Delivery receipt
    if (deliveryReceipt != null) {
      final receipt = deliveryReceipt!;
      buffer.writeln('## DELIVERY_RECEIPT');
      buffer.writeln('RECIPIENT_NPUB: ${receipt.recipientNpub}');
      buffer.writeln('DELIVERED_AT: ${receipt.timestamp}');
      buffer.writeln('CARRIER_CALLSIGN: ${receipt.carrierCallsign}');
      buffer.writeln('CARRIER_NPUB: ${receipt.carrierNpub}');
      buffer.writeln(
          'COORDINATES: ${receipt.deliveryLatitude},${receipt.deliveryLongitude}');
      if (receipt.deliveryLocationName != null) {
        buffer.writeln('LOCATION_NAME: ${receipt.deliveryLocationName}');
      }
      if (receipt.deliveryNote != null) {
        buffer.writeln('NOTE: ${receipt.deliveryNote}');
      }
      buffer.writeln('--> signature: ${receipt.signature}');
      buffer.writeln();
    }

    // Return stamps
    for (final stamp in returnStamps) {
      buffer.writeln('## RETURN_STAMP: ${stamp.number}');
      buffer.writeln('STAMPER_CALLSIGN: ${stamp.stamperCallsign}');
      buffer.writeln('STAMPER_NPUB: ${stamp.stamperNpub}');
      buffer.writeln('TIMESTAMP: ${stamp.timestamp}');
      buffer.writeln('COORDINATES: ${stamp.latitude},${stamp.longitude}');
      if (stamp.locationName != null) {
        buffer.writeln('LOCATION_NAME: ${stamp.locationName}');
      }
      buffer.writeln('RECEIVED_FROM: ${stamp.receivedFrom}');
      buffer.writeln('RECEIVED_VIA: ${stamp.receivedVia}');
      buffer.writeln('HOP_NUMBER: ${stamp.hopNumber}');
      buffer.writeln('--> signature: ${stamp.signature}');
      buffer.writeln();
    }

    // Sender acknowledgment
    if (acknowledgment != null) {
      final ack = acknowledgment!;
      buffer.writeln('## SENDER_ACKNOWLEDGMENT');
      buffer.writeln('SENDER_NPUB: ${ack.senderNpub}');
      buffer.writeln('ACKNOWLEDGED_AT: ${ack.timestamp}');
      if (ack.acknowledgmentNote != null) {
        buffer.writeln('NOTE: ${ack.acknowledgmentNote}');
      }
      buffer.writeln('--> signature: ${ack.signature}');
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// Parse a postcard.txt file back into a Postcard.
  ///
  /// Inverse of [exportAsText]. The parser is line-based and tolerant of
  /// extra blank lines but strict about the section markers:
  ///   # POSTCARD:                     — title line (line 1)
  ///   KEY: VALUE                      — header fields
  ///   <blank line>                    — header/content separator
  ///   ... content lines ...
  ///   --> npub: …                     — sender metadata
  ///   --> signature: …
  ///   ## STAMP: N                     — outbound stamps
  ///   ## DELIVERY_RECEIPT             — recipient's delivery proof
  ///   ## RETURN_STAMP: N              — return-leg stamps
  ///   ## SENDER_ACKNOWLEDGMENT        — sender's final ack
  ///
  /// [postcardId] is the filename stem (without the .txt extension) —
  /// the Postcard.id field.
  static Postcard fromText(String text, String postcardId) {
    final lines = text.split(RegExp(r'\r?\n'));
    int i = 0;

    // Title line.
    if (i >= lines.length || !lines[i].startsWith('# POSTCARD:')) {
      throw FormatException('Missing "# POSTCARD:" title line');
    }
    final title = lines[i].substring('# POSTCARD:'.length).trim();
    i++;

    // Skip blank lines after the title.
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }

    // Header KEY: VALUE lines, until blank.
    final header = <String, String>{};
    while (i < lines.length && lines[i].trim().isNotEmpty) {
      final line = lines[i];
      final colon = line.indexOf(':');
      if (colon > 0) {
        final key = line.substring(0, colon).trim();
        final value = line.substring(colon + 1).trim();
        header[key] = value;
      }
      i++;
    }

    // Skip blank lines after the header.
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }

    // Content, until either "--> npub:" metadata or a "## " section marker.
    final contentLines = <String>[];
    while (i < lines.length) {
      final line = lines[i];
      if (line.startsWith('--> npub:') ||
          line.startsWith('--> signature:') ||
          line.startsWith('## ')) {
        break;
      }
      contentLines.add(line);
      i++;
    }
    // Trim the trailing blank line that exportAsText always writes.
    while (contentLines.isNotEmpty && contentLines.last.trim().isEmpty) {
      contentLines.removeLast();
    }

    // Sender metadata.
    final metadata = <String, String>{};
    while (i < lines.length && lines[i].startsWith('--> ')) {
      final line = lines[i].substring(4);
      final colon = line.indexOf(':');
      if (colon > 0) {
        metadata[line.substring(0, colon).trim()] =
            line.substring(colon + 1).trim();
      }
      i++;
    }

    // Walk remaining sections.
    final stamps = <PostcardStamp>[];
    final returnStamps = <PostcardStamp>[];
    PostcardDeliveryReceipt? deliveryReceipt;
    PostcardAcknowledgment? acknowledgment;

    while (i < lines.length) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        i++;
        continue;
      }
      if (line.startsWith('## STAMP:')) {
        final n = int.tryParse(line.substring('## STAMP:'.length).trim()) ?? 0;
        i++;
        final block = _readBlock(lines, i);
        i = block.nextIndex;
        stamps.add(_stampFromBlock(block.fields, number: n, hopFallback: n));
      } else if (line.startsWith('## RETURN_STAMP:')) {
        final n = int.tryParse(
              line.substring('## RETURN_STAMP:'.length).trim(),
            ) ??
            0;
        i++;
        final block = _readBlock(lines, i);
        i = block.nextIndex;
        returnStamps.add(
          _stampFromBlock(block.fields, number: n, hopFallback: n),
        );
      } else if (line == '## DELIVERY_RECEIPT') {
        i++;
        final block = _readBlock(lines, i);
        i = block.nextIndex;
        deliveryReceipt = _receiptFromBlock(block.fields);
      } else if (line == '## SENDER_ACKNOWLEDGMENT') {
        i++;
        final block = _readBlock(lines, i);
        i = block.nextIndex;
        acknowledgment = _ackFromBlock(block.fields);
      } else {
        // Unknown section — skip one line to avoid an infinite loop.
        i++;
      }
    }

    final recipientLocations = _parseRecipientLocations(
      header['RECIPIENT_LOCATIONS'] ?? '',
    );

    return Postcard(
      id: postcardId,
      title: title,
      createdTimestamp: header['CREATED'] ?? '',
      senderCallsign: header['SENDER_CALLSIGN'] ?? '',
      senderNpub: header['SENDER_NPUB'] ?? '',
      recipientCallsign: header['RECIPIENT_CALLSIGN'],
      recipientNpub: header['RECIPIENT_NPUB'] ?? '',
      recipientLocations: recipientLocations,
      type: header['TYPE'] ?? 'open',
      status: header['STATUS'] ?? 'in-transit',
      ttl: int.tryParse(header['TTL'] ?? ''),
      priority: header['PRIORITY'] ?? 'normal',
      content: contentLines.join('\n'),
      metadata: metadata,
      stamps: stamps,
      deliveryReceipt: deliveryReceipt,
      returnStamps: returnStamps,
      acknowledgment: acknowledgment,
    );
  }

  /// Read a block of KEY: VALUE (or "--> key: value") lines until we hit a
  /// blank line or the next "## " section marker. Returns the parsed fields
  /// plus the index of the first line that was NOT consumed.
  static _BlockRead _readBlock(List<String> lines, int start) {
    final fields = <String, String>{};
    int i = start;
    while (i < lines.length) {
      final line = lines[i];
      final stripped = line.trim();
      if (stripped.isEmpty) {
        i++;
        break;
      }
      if (stripped.startsWith('## ')) break;
      if (stripped.startsWith('--> ')) {
        final rest = stripped.substring(4);
        final colon = rest.indexOf(':');
        if (colon > 0) {
          fields[rest.substring(0, colon).trim()] =
              rest.substring(colon + 1).trim();
        }
      } else {
        final colon = stripped.indexOf(':');
        if (colon > 0) {
          fields[stripped.substring(0, colon).trim()] =
              stripped.substring(colon + 1).trim();
        }
      }
      i++;
    }
    return _BlockRead(fields: fields, nextIndex: i);
  }

  static PostcardStamp _stampFromBlock(
    Map<String, String> f, {
    required int number,
    required int hopFallback,
  }) {
    final coords = (f['COORDINATES'] ?? '').split(',');
    final lat = coords.length == 2
        ? (double.tryParse(coords[0].trim()) ?? 0.0)
        : 0.0;
    final lon = coords.length == 2
        ? (double.tryParse(coords[1].trim()) ?? 0.0)
        : 0.0;
    return PostcardStamp(
      number: number,
      stamperCallsign: f['STAMPER_CALLSIGN'] ?? '',
      stamperNpub: f['STAMPER_NPUB'] ?? '',
      timestamp: f['TIMESTAMP'] ?? '',
      latitude: lat,
      longitude: lon,
      locationName: f['LOCATION_NAME'],
      receivedFrom: f['RECEIVED_FROM'] ?? '',
      receivedVia: f['RECEIVED_VIA'] ?? '',
      hopNumber: int.tryParse(f['HOP_NUMBER'] ?? '') ?? hopFallback,
      signature: f['signature'] ?? '',
    );
  }

  static PostcardDeliveryReceipt _receiptFromBlock(Map<String, String> f) {
    final coords = (f['COORDINATES'] ?? '').split(',');
    final lat = coords.length == 2
        ? (double.tryParse(coords[0].trim()) ?? 0.0)
        : 0.0;
    final lon = coords.length == 2
        ? (double.tryParse(coords[1].trim()) ?? 0.0)
        : 0.0;
    return PostcardDeliveryReceipt(
      recipientNpub: f['RECIPIENT_NPUB'] ?? '',
      timestamp: f['DELIVERED_AT'] ?? '',
      carrierCallsign: f['CARRIER_CALLSIGN'] ?? '',
      carrierNpub: f['DELIVERED_BY'] ?? f['CARRIER_NPUB'] ?? '',
      deliveryLatitude: lat,
      deliveryLongitude: lon,
      deliveryLocationName: f['LOCATION_NAME'],
      deliveryNote: f['NOTE'],
      signature: f['signature'] ?? '',
    );
  }

  static PostcardAcknowledgment _ackFromBlock(Map<String, String> f) {
    return PostcardAcknowledgment(
      senderNpub: f['SENDER_NPUB'] ?? '',
      timestamp: f['ACKNOWLEDGED_AT'] ?? '',
      acknowledgmentNote: f['NOTE'],
      signature: f['signature'] ?? '',
    );
  }

  static List<RecipientLocation> _parseRecipientLocations(String value) {
    final out = <RecipientLocation>[];
    if (value.trim().isEmpty) return out;
    for (final chunk in value.split(';')) {
      final parts = chunk.trim().split(',');
      if (parts.length < 2) continue;
      final lat = double.tryParse(parts[0].trim());
      final lon = double.tryParse(parts[1].trim());
      if (lat == null || lon == null) continue;
      out.add(RecipientLocation(latitude: lat, longitude: lon));
    }
    return out;
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdTimestamp': createdTimestamp,
        'senderCallsign': senderCallsign,
        'senderNpub': senderNpub,
        if (recipientCallsign != null) 'recipientCallsign': recipientCallsign,
        'recipientNpub': recipientNpub,
        'recipientLocations':
            recipientLocations.map((loc) => loc.toJson()).toList(),
        'type': type,
        'status': status,
        if (ttl != null) 'ttl': ttl,
        'priority': priority,
        'content': content,
        'metadata': metadata,
        'stamps': stamps.map((s) => s.toJson()).toList(),
        if (deliveryReceipt != null)
          'deliveryReceipt': deliveryReceipt!.toJson(),
        'returnStamps': returnStamps.map((s) => s.toJson()).toList(),
        if (acknowledgment != null) 'acknowledgment': acknowledgment!.toJson(),
        'attachments': attachments,
        'contributorCounts': contributorCounts,
      };

  /// Create from JSON
  factory Postcard.fromJson(Map<String, dynamic> json) {
    return Postcard(
      id: json['id'] as String,
      title: json['title'] as String,
      createdTimestamp: json['createdTimestamp'] as String,
      senderCallsign: json['senderCallsign'] as String,
      senderNpub: json['senderNpub'] as String,
      recipientCallsign: json['recipientCallsign'] as String?,
      recipientNpub: json['recipientNpub'] as String,
      recipientLocations: (json['recipientLocations'] as List<dynamic>?)
              ?.map((loc) => RecipientLocation.fromJson(loc))
              .toList() ??
          [],
      type: json['type'] as String? ?? 'open',
      status: json['status'] as String? ?? 'in-transit',
      ttl: json['ttl'] as int?,
      priority: json['priority'] as String? ?? 'normal',
      content: json['content'] as String,
      metadata: Map<String, String>.from(json['metadata'] as Map? ?? {}),
      stamps: (json['stamps'] as List<dynamic>?)
              ?.map((s) => PostcardStamp.fromJson(s))
              .toList() ??
          [],
      deliveryReceipt: json['deliveryReceipt'] != null
          ? PostcardDeliveryReceipt.fromJson(json['deliveryReceipt'])
          : null,
      returnStamps: (json['returnStamps'] as List<dynamic>?)
              ?.map((s) => PostcardStamp.fromJson(s))
              .toList() ??
          [],
      acknowledgment: json['acknowledgment'] != null
          ? PostcardAcknowledgment.fromJson(json['acknowledgment'])
          : null,
      attachments: (json['attachments'] as List<dynamic>?)
              ?.map((a) => a as String)
              .toList() ??
          [],
      contributorCounts: Map<String, int>.from(
          json['contributorCounts'] as Map? ?? {}),
    );
  }

  @override
  String toString() {
    final recipient = recipientCallsign ??
        (recipientNpub.length >= 12
            ? recipientNpub.substring(0, 12)
            : (recipientNpub.isEmpty ? '(none)' : recipientNpub));
    return 'Postcard(id: $id, title: $title, sender: $senderCallsign, '
        'recipient: $recipient, status: $status, hops: ${stamps.length})';
  }
}
