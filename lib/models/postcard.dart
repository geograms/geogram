/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

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
  final bool paymentRequested;
  final String content; // Plain text or encrypted content
  final Map<String, String> metadata; // npub, signature

  // Journey tracking
  final List<PostcardStamp> stamps; // Outbound stamps
  final PostcardDeliveryReceipt? deliveryReceipt;
  final List<PostcardStamp> returnStamps; // Return journey stamps
  final PostcardAcknowledgment? acknowledgment;

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
    this.paymentRequested = false,
    required this.content,
    this.metadata = const {},
    this.stamps = const [],
    this.deliveryReceipt,
    this.returnStamps = const [],
    this.acknowledgment,
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
    bool? paymentRequested,
    String? content,
    Map<String, String>? metadata,
    List<PostcardStamp>? stamps,
    PostcardDeliveryReceipt? deliveryReceipt,
    List<PostcardStamp>? returnStamps,
    PostcardAcknowledgment? acknowledgment,
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
      paymentRequested: paymentRequested ?? this.paymentRequested,
      content: content ?? this.content,
      metadata: metadata ?? this.metadata,
      stamps: stamps ?? this.stamps,
      deliveryReceipt: deliveryReceipt ?? this.deliveryReceipt,
      returnStamps: returnStamps ?? this.returnStamps,
      acknowledgment: acknowledgment ?? this.acknowledgment,
      attachments: attachments ?? this.attachments,
      contributorCounts: contributorCounts ?? this.contributorCounts,
    );
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
    buffer.writeln('PAYMENT_REQUESTED: $paymentRequested');
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

  /// Parse postcard from postcard.txt file text
  static Postcard fromText(String text, String postcardId) {
    // Stub implementation - full parser would be more complex
    // For now, return a basic postcard
    throw UnimplementedError(
        'Postcard.fromText parsing not yet implemented');
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
        'paymentRequested': paymentRequested,
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
      paymentRequested: json['paymentRequested'] as bool? ?? false,
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
    return 'Postcard(id: $id, title: $title, sender: $senderCallsign, recipient: ${recipientCallsign ?? recipientNpub.substring(0, 12)}, status: $status, hops: ${stamps.length})';
  }
}
