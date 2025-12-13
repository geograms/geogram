/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Status of station share for an alert
enum StationShareStatusType {
  pending,
  confirmed,
  failed;

  static StationShareStatusType fromString(String value) {
    return StationShareStatusType.values.firstWhere(
      (e) => e.name == value.toLowerCase(),
      orElse: () => StationShareStatusType.pending,
    );
  }
}

/// Tracks the status of sharing an alert to a specific station
class StationShareStatus {
  final String stationUrl;
  final DateTime sentAt;
  final StationShareStatusType status;

  StationShareStatus({
    required this.stationUrl,
    required this.sentAt,
    required this.status,
  });

  /// Parse from text line: "wss://station.example.com,2025-12-06T10:30:00Z,confirmed"
  factory StationShareStatus.fromLine(String line) {
    final parts = line.split(',');
    if (parts.length >= 3) {
      return StationShareStatus(
        stationUrl: parts[0].trim(),
        sentAt: DateTime.tryParse(parts[1].trim()) ?? DateTime.now(),
        status: StationShareStatusType.fromString(parts[2].trim()),
      );
    }
    throw FormatException('Invalid station_sent format: $line');
  }

  /// Export to text line
  String toLine() => '$stationUrl,${sentAt.toUtc().toIso8601String()},${status.name}';

  /// Create copy with updated status
  StationShareStatus copyWith({
    String? stationUrl,
    DateTime? sentAt,
    StationShareStatusType? status,
  }) {
    return StationShareStatus(
      stationUrl: stationUrl ?? this.stationUrl,
      sentAt: sentAt ?? this.sentAt,
      status: status ?? this.status,
    );
  }

  @override
  String toString() => 'StationShareStatus($stationUrl, ${status.name})';
}

/// Severity levels for reports
enum ReportSeverity {
  emergency,
  urgent,
  attention,
  info;

  static ReportSeverity fromString(String value) {
    return ReportSeverity.values.firstWhere(
      (e) => e.name == value.toLowerCase(),
      orElse: () => ReportSeverity.info,
    );
  }
}

/// Status of a report
enum ReportStatus {
  open,
  inProgress,
  resolved,
  closed;

  static ReportStatus fromString(String value) {
    final normalized = value.toLowerCase().replaceAll('-', '');
    return ReportStatus.values.firstWhere(
      (e) => e.name.toLowerCase() == normalized,
      orElse: () => ReportStatus.open,
    );
  }

  String toFileString() {
    switch (this) {
      case ReportStatus.inProgress:
        return 'in-progress';
      default:
        return name;
    }
  }
}

/// Model representing a report
class Report {
  final String folderName;
  final String created;
  final String author;
  final double latitude;
  final double longitude;
  final ReportSeverity severity;
  final String type;
  final ReportStatus status;
  final String? address;
  final String? contact;
  final List<String> verifiedBy;
  final int verificationCount;
  final String? duplicateOf;
  final List<String> relatedReports;
  final String? officialCase;
  final String? authorityNotified;
  final int? ttl;
  final String? expires;
  final List<String> admins;
  final List<String> moderators;
  final List<String> updateAuthorized;
  final List<String> subscribers;
  final int subscriberCount;
  final List<String> pointedBy;
  final int pointCount;
  final Map<String, String> titles;
  final Map<String, String> descriptions;
  final Map<String, String> metadata;
  final List<StationShareStatus> stationShares;
  final String? nostrEventId;
  final String? lastModified; // ISO 8601 format timestamp of last modification

  Report({
    required this.folderName,
    required this.created,
    required this.author,
    required this.latitude,
    required this.longitude,
    required this.severity,
    required this.type,
    required this.status,
    this.address,
    this.contact,
    this.verifiedBy = const [],
    this.verificationCount = 0,
    this.duplicateOf,
    this.relatedReports = const [],
    this.officialCase,
    this.authorityNotified,
    this.ttl,
    this.expires,
    this.admins = const [],
    this.moderators = const [],
    this.updateAuthorized = const [],
    this.subscribers = const [],
    this.subscriberCount = 0,
    this.pointedBy = const [],
    this.pointCount = 0,
    this.titles = const {},
    this.descriptions = const {},
    this.metadata = const {},
    this.stationShares = const [],
    this.nostrEventId,
    this.lastModified,
  });

  /// Check if user has pointed this report
  bool hasPointFrom(String npub) {
    if (npub.isEmpty) return false;
    return pointedBy.contains(npub);
  }

  /// Parse timestamp to DateTime
  DateTime get dateTime {
    try {
      final normalized = created.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Parse expiration timestamp to DateTime
  DateTime? get expirationDateTime {
    if (expires == null) return null;
    try {
      final normalized = expires!.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return null;
    }
  }

  /// Check if report has expired
  bool get isExpired {
    final expDate = expirationDateTime;
    if (expDate == null) return false;
    return DateTime.now().isAfter(expDate);
  }

  /// Parse last modified timestamp to DateTime
  DateTime? get lastModifiedDateTime {
    if (lastModified == null) return null;
    try {
      return DateTime.parse(lastModified!);
    } catch (e) {
      return null;
    }
  }

  /// Get NOSTR public key
  String? get npub => metadata['npub'];

  /// Get signature
  String? get signature => metadata['signature'];

  /// Get signed timestamp (Unix seconds)
  int? get signedAt {
    final value = metadata['signed_at'];
    if (value == null) return null;
    return int.tryParse(value);
  }

  /// Check if report is signed with NOSTR
  bool get isSigned => metadata.containsKey('signature');

  /// Get title for a specific language with fallback
  String getTitle(String lang) {
    return titles[lang.toUpperCase()] ??
           titles['EN'] ??
           titles.values.firstOrNull ??
           'Untitled Report';
  }

  /// Get description for a specific language with fallback
  String getDescription(String lang) {
    return descriptions[lang.toUpperCase()] ??
           descriptions['EN'] ??
           descriptions.values.firstOrNull ??
           '';
  }

  /// Get coordinates as string
  String get coordinatesString => '$latitude,$longitude';

  /// Get region folder (rounded to 1 decimal)
  String get regionFolder {
    final roundedLat = (latitude * 10).round() / 10;
    final roundedLon = (longitude * 10).round() / 10;
    return '${roundedLat}_$roundedLon';
  }

  /// Check if user is admin
  bool isAdmin(String npub) {
    if (npub.isEmpty) return false;
    return metadata['npub'] == npub || admins.contains(npub);
  }

  /// Check if user is moderator
  bool isModerator(String npub) {
    if (npub.isEmpty) return false;
    return moderators.contains(npub);
  }

  /// Check if user can update
  bool canUpdate(String npub) {
    if (npub.isEmpty) return false;
    return isAdmin(npub) || updateAuthorized.contains(npub);
  }

  /// Check if user is subscribed
  bool isSubscribed(String npub) {
    if (npub.isEmpty) return false;
    return subscribers.contains(npub);
  }

  /// Check if alert has been shared to any station
  bool get isSharedToStations => stationShares.isNotEmpty;

  /// Check if alert has been shared to a specific station
  bool isSharedToRelay(String stationUrl) {
    return stationShares.any((s) => s.stationUrl == stationUrl);
  }

  /// Check if alert needs sharing to a specific station (not confirmed)
  bool needsSharingToRelay(String stationUrl) {
    final share = stationShares.where((s) => s.stationUrl == stationUrl).firstOrNull;
    if (share == null) return true;
    return share.status != StationShareStatusType.confirmed;
  }

  /// Get share status for a specific station
  StationShareStatus? getRelayShareStatus(String stationUrl) {
    return stationShares.where((s) => s.stationUrl == stationUrl).firstOrNull;
  }

  /// Get count of confirmed stations
  int get confirmedRelayCount {
    return stationShares.where((s) => s.status == StationShareStatusType.confirmed).length;
  }

  /// Get count of failed stations
  int get failedRelayCount {
    return stationShares.where((s) => s.status == StationShareStatusType.failed).length;
  }

  /// Parse report from text
  static Report fromText(String text, String folderName) {
    final lines = text.split('\n');
    if (lines.isEmpty) {
      throw Exception('Empty report file');
    }

    // Parse titles
    final titles = <String, String>{};
    int headerEnd = 0;
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('# REPORT_')) {
        final langMatch = RegExp(r'# REPORT_([A-Z]{2}): (.+)').firstMatch(line);
        if (langMatch != null) {
          titles[langMatch.group(1)!] = langMatch.group(2)!;
        }
      } else if (line.startsWith('# REPORT: ')) {
        titles['EN'] = line.substring(10);
      } else if (line.trim().isNotEmpty && !line.startsWith('#')) {
        headerEnd = i;
        break;
      }
    }

    // Parse header fields
    String? created;
    String? author;
    double? latitude;
    double? longitude;
    ReportSeverity severity = ReportSeverity.info;
    String type = 'other';
    ReportStatus status = ReportStatus.open;
    String? address;
    String? contact;
    List<String> verifiedBy = [];
    int verificationCount = 0;
    String? duplicateOf;
    List<String> relatedReports = [];
    String? officialCase;
    String? authorityNotified;
    int? ttl;
    String? expires;
    List<String> admins = [];
    List<String> moderators = [];
    List<String> updateAuthorized = [];
    List<String> subscribers = [];
    int subscriberCount = 0;
    List<String> pointedBy = [];
    int pointCount = 0;
    Map<String, String> metadata = {};
    List<StationShareStatus> stationShares = [];
    String? nostrEventId;
    String? lastModified;

    int contentStart = headerEnd;
    for (int i = headerEnd; i < lines.length; i++) {
      final line = lines[i];

      if (line.startsWith('CREATED: ')) {
        created = line.substring(9).trim();
      } else if (line.startsWith('AUTHOR: ')) {
        author = line.substring(8).trim();
      } else if (line.startsWith('COORDINATES: ')) {
        final coords = line.substring(13).split(',');
        if (coords.length == 2) {
          latitude = double.tryParse(coords[0].trim());
          longitude = double.tryParse(coords[1].trim());
        }
      } else if (line.startsWith('SEVERITY: ')) {
        severity = ReportSeverity.fromString(line.substring(10).trim());
      } else if (line.startsWith('TYPE: ')) {
        type = line.substring(6).trim();
      } else if (line.startsWith('STATUS: ')) {
        status = ReportStatus.fromString(line.substring(8).trim());
      } else if (line.startsWith('ADDRESS: ')) {
        address = line.substring(9).trim();
      } else if (line.startsWith('CONTACT: ')) {
        contact = line.substring(9).trim();
      } else if (line.startsWith('VERIFIED_BY: ')) {
        verifiedBy = line.substring(13).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      } else if (line.startsWith('VERIFICATION_COUNT: ')) {
        verificationCount = int.tryParse(line.substring(20).trim()) ?? 0;
      } else if (line.startsWith('DUPLICATE_OF: ')) {
        duplicateOf = line.substring(14).trim();
      } else if (line.startsWith('RELATED_REPORTS: ')) {
        relatedReports = line.substring(17).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      } else if (line.startsWith('OFFICIAL_CASE: ')) {
        officialCase = line.substring(15).trim();
      } else if (line.startsWith('AUTHORITY_NOTIFIED: ')) {
        authorityNotified = line.substring(20).trim();
      } else if (line.startsWith('TTL: ')) {
        ttl = int.tryParse(line.substring(5).trim());
      } else if (line.startsWith('EXPIRES: ')) {
        expires = line.substring(9).trim();
      } else if (line.startsWith('ADMINS: ')) {
        admins = line.substring(8).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      } else if (line.startsWith('MODERATORS: ')) {
        moderators = line.substring(12).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      } else if (line.startsWith('UPDATE_AUTHORIZED: ')) {
        updateAuthorized = line.substring(19).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      } else if (line.startsWith('SUBSCRIBERS: ')) {
        subscribers = line.substring(13).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      } else if (line.startsWith('SUBSCRIBER_COUNT: ')) {
        subscriberCount = int.tryParse(line.substring(18).trim()) ?? 0;
      } else if (line.startsWith('POINTED_BY: ')) {
        pointedBy = line.substring(12).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      } else if (line.startsWith('POINT_COUNT: ')) {
        pointCount = int.tryParse(line.substring(13).trim()) ?? 0;
      } else if (line.startsWith('LAST_MODIFIED: ')) {
        lastModified = line.substring(15).trim();
      } else if (line.startsWith('-->')) {
        final metaLine = line.substring(3).trim();
        final colonIndex = metaLine.indexOf(':');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex).trim();
          final value = metaLine.substring(colonIndex + 1).trim();
          // Handle special station sharing metadata
          if (key == 'station_sent') {
            try {
              stationShares.add(StationShareStatus.fromLine(value));
            } catch (_) {
              // Ignore malformed station_sent entries
            }
          } else if (key == 'nostr_event_id') {
            nostrEventId = value;
          } else {
            metadata[key] = value;
          }
        }
      } else if (line.trim().isEmpty && i > headerEnd) {
        contentStart = i + 1;
        break;
      }
    }

    // Parse descriptions
    final descriptions = <String, String>{};
    int metadataStart = lines.length;
    if (contentStart < lines.length) {
      String? currentLang;
      final descLines = <String>[];

      for (int i = contentStart; i < lines.length; i++) {
        final line = lines[i];

        if (line.startsWith('[') && line.endsWith(']')) {
          // Save previous language
          if (currentLang != null && descLines.isNotEmpty) {
            descriptions[currentLang] = descLines.join('\n').trim();
            descLines.clear();
          }
          currentLang = line.substring(1, line.length - 1).toUpperCase();
        } else if (line.startsWith('-->')) {
          // Metadata section, stop parsing descriptions but remember where it starts
          metadataStart = i;
          break;
        } else if (currentLang != null) {
          descLines.add(line);
        } else if (line.trim().isNotEmpty) {
          // Single language format (no language marker)
          descLines.add(line);
        }
      }

      // Save last language or single language
      if (descLines.isNotEmpty) {
        descriptions[currentLang ?? 'EN'] = descLines.join('\n').trim();
      }
    }

    // Parse trailing metadata after descriptions (npub, signature, station_sent, nostr_event_id)
    for (int i = metadataStart; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('-->')) {
        final metaLine = line.substring(3).trim();
        final colonIndex = metaLine.indexOf(':');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex).trim();
          final value = metaLine.substring(colonIndex + 1).trim();
          // Handle special station sharing metadata
          if (key == 'station_sent') {
            try {
              stationShares.add(StationShareStatus.fromLine(value));
            } catch (_) {
              // Ignore malformed station_sent entries
            }
          } else if (key == 'nostr_event_id') {
            nostrEventId = value;
          } else {
            metadata[key] = value;
          }
        }
      }
    }

    // Validate required fields
    if (created == null || author == null || latitude == null || longitude == null) {
      throw Exception('Missing required report fields');
    }

    return Report(
      folderName: folderName,
      created: created,
      author: author,
      latitude: latitude,
      longitude: longitude,
      severity: severity,
      type: type,
      status: status,
      address: address,
      contact: contact,
      verifiedBy: verifiedBy,
      verificationCount: verificationCount,
      duplicateOf: duplicateOf,
      relatedReports: relatedReports,
      officialCase: officialCase,
      authorityNotified: authorityNotified,
      ttl: ttl,
      expires: expires,
      admins: admins,
      moderators: moderators,
      updateAuthorized: updateAuthorized,
      subscribers: subscribers,
      subscriberCount: subscriberCount,
      pointedBy: pointedBy,
      pointCount: pointCount,
      titles: titles,
      descriptions: descriptions,
      metadata: metadata,
      stationShares: stationShares,
      nostrEventId: nostrEventId,
      lastModified: lastModified,
    );
  }

  /// Export report as text
  String exportAsText() {
    final buffer = StringBuffer();

    // Titles
    if (titles.length == 1) {
      buffer.writeln('# REPORT: ${titles.values.first}');
    } else {
      for (var entry in titles.entries) {
        buffer.writeln('# REPORT_${entry.key}: ${entry.value}');
      }
    }

    buffer.writeln();

    // Required fields
    buffer.writeln('CREATED: $created');
    buffer.writeln('AUTHOR: $author');
    buffer.writeln('COORDINATES: $coordinatesString');
    buffer.writeln('SEVERITY: ${severity.name}');
    buffer.writeln('TYPE: $type');
    buffer.writeln('STATUS: ${status.toFileString()}');

    // Optional fields
    if (address != null && address!.isNotEmpty) {
      buffer.writeln('ADDRESS: $address');
    }
    if (contact != null && contact!.isNotEmpty) {
      buffer.writeln('CONTACT: $contact');
    }
    if (verifiedBy.isNotEmpty) {
      buffer.writeln('VERIFIED_BY: ${verifiedBy.join(', ')}');
    }
    if (verificationCount > 0) {
      buffer.writeln('VERIFICATION_COUNT: $verificationCount');
    }
    if (duplicateOf != null && duplicateOf!.isNotEmpty) {
      buffer.writeln('DUPLICATE_OF: $duplicateOf');
    }
    if (relatedReports.isNotEmpty) {
      buffer.writeln('RELATED_REPORTS: ${relatedReports.join(', ')}');
    }
    if (officialCase != null && officialCase!.isNotEmpty) {
      buffer.writeln('OFFICIAL_CASE: $officialCase');
    }
    if (authorityNotified != null && authorityNotified!.isNotEmpty) {
      buffer.writeln('AUTHORITY_NOTIFIED: $authorityNotified');
    }
    if (ttl != null) {
      buffer.writeln('TTL: $ttl');
    }
    if (expires != null && expires!.isNotEmpty) {
      buffer.writeln('EXPIRES: $expires');
    }
    if (admins.isNotEmpty) {
      buffer.writeln('ADMINS: ${admins.join(', ')}');
    }
    if (moderators.isNotEmpty) {
      buffer.writeln('MODERATORS: ${moderators.join(', ')}');
    }
    if (updateAuthorized.isNotEmpty) {
      buffer.writeln('UPDATE_AUTHORIZED: ${updateAuthorized.join(', ')}');
    }
    if (subscribers.isNotEmpty) {
      buffer.writeln('SUBSCRIBERS: ${subscribers.join(', ')}');
    }
    if (subscriberCount > 0) {
      buffer.writeln('SUBSCRIBER_COUNT: $subscriberCount');
    }
    if (pointedBy.isNotEmpty) {
      buffer.writeln('POINTED_BY: ${pointedBy.join(', ')}');
    }
    if (pointCount > 0) {
      buffer.writeln('POINT_COUNT: $pointCount');
    }
    if (lastModified != null && lastModified!.isNotEmpty) {
      buffer.writeln('LAST_MODIFIED: $lastModified');
    }

    buffer.writeln();

    // Descriptions
    if (descriptions.length == 1) {
      buffer.writeln(descriptions.values.first);
    } else {
      for (var entry in descriptions.entries) {
        buffer.writeln('[${entry.key}]');
        buffer.writeln(entry.value);
        buffer.writeln();
      }
    }

    // Metadata
    final regularMetadata = Map<String, String>.from(metadata);
    final sig = regularMetadata.remove('signature');

    for (var entry in regularMetadata.entries) {
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    if (sig != null) {
      buffer.writeln('--> signature: $sig');
    }

    // Station sharing metadata (after signature)
    if (nostrEventId != null && nostrEventId!.isNotEmpty) {
      buffer.writeln('--> nostr_event_id: $nostrEventId');
    }
    for (final share in stationShares) {
      buffer.writeln('--> station_sent: ${share.toLine()}');
    }

    return buffer.toString();
  }

  /// Create copy with updated fields
  Report copyWith({
    String? folderName,
    String? created,
    String? author,
    double? latitude,
    double? longitude,
    ReportSeverity? severity,
    String? type,
    ReportStatus? status,
    String? address,
    String? contact,
    List<String>? verifiedBy,
    int? verificationCount,
    String? duplicateOf,
    List<String>? relatedReports,
    String? officialCase,
    String? authorityNotified,
    int? ttl,
    String? expires,
    List<String>? admins,
    List<String>? moderators,
    List<String>? updateAuthorized,
    List<String>? subscribers,
    int? subscriberCount,
    List<String>? pointedBy,
    int? pointCount,
    Map<String, String>? titles,
    Map<String, String>? descriptions,
    Map<String, String>? metadata,
    List<StationShareStatus>? stationShares,
    String? nostrEventId,
    String? lastModified,
  }) {
    return Report(
      folderName: folderName ?? this.folderName,
      created: created ?? this.created,
      author: author ?? this.author,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      severity: severity ?? this.severity,
      type: type ?? this.type,
      status: status ?? this.status,
      address: address ?? this.address,
      contact: contact ?? this.contact,
      verifiedBy: verifiedBy ?? this.verifiedBy,
      verificationCount: verificationCount ?? this.verificationCount,
      duplicateOf: duplicateOf ?? this.duplicateOf,
      relatedReports: relatedReports ?? this.relatedReports,
      officialCase: officialCase ?? this.officialCase,
      authorityNotified: authorityNotified ?? this.authorityNotified,
      ttl: ttl ?? this.ttl,
      expires: expires ?? this.expires,
      admins: admins ?? this.admins,
      moderators: moderators ?? this.moderators,
      updateAuthorized: updateAuthorized ?? this.updateAuthorized,
      subscribers: subscribers ?? this.subscribers,
      subscriberCount: subscriberCount ?? this.subscriberCount,
      pointedBy: pointedBy ?? this.pointedBy,
      pointCount: pointCount ?? this.pointCount,
      titles: titles ?? this.titles,
      descriptions: descriptions ?? this.descriptions,
      metadata: metadata ?? this.metadata,
      stationShares: stationShares ?? this.stationShares,
      nostrEventId: nostrEventId ?? this.nostrEventId,
      lastModified: lastModified ?? this.lastModified,
    );
  }

  @override
  String toString() {
    return 'Report(folder: $folderName, severity: ${severity.name}, status: ${status.name})';
  }

  /// Create Report from API JSON (from toApiJson output)
  factory Report.fromApiJson(Map<String, dynamic> json) {
    // Parse titles from translations or single title
    final titles = <String, String>{};
    final titleTranslations = json['title_translations'] as Map<String, dynamic>?;
    if (titleTranslations != null) {
      for (final entry in titleTranslations.entries) {
        titles[entry.key] = entry.value as String;
      }
    } else if (json['title'] != null) {
      titles['EN'] = json['title'] as String;
    }

    // Parse descriptions from translations or single description
    final descriptions = <String, String>{};
    final descTranslations = json['description_translations'] as Map<String, dynamic>?;
    if (descTranslations != null) {
      for (final entry in descTranslations.entries) {
        descriptions[entry.key] = entry.value as String;
      }
    } else if (json['description'] != null) {
      descriptions['EN'] = json['description'] as String;
    }

    // Parse verified_by list
    final verifiedBy = (json['verified_by'] as List<dynamic>?)
        ?.map((e) => e as String)
        .toList() ?? [];

    // Parse pointed_by list
    final pointedBy = (json['pointed_by'] as List<dynamic>?)
        ?.map((e) => e as String)
        .toList() ?? [];

    // Parse admins list
    final admins = (json['admins'] as List<dynamic>?)
        ?.map((e) => e as String)
        .toList() ?? [];

    // Parse moderators list
    final moderators = (json['moderators'] as List<dynamic>?)
        ?.map((e) => e as String)
        .toList() ?? [];

    // Build metadata for signature/npub
    final metadata = <String, String>{};
    if (json['npub'] != null) {
      metadata['npub'] = json['npub'] as String;
    }
    if (json['signature'] != null) {
      metadata['signature'] = json['signature'] as String;
    }

    return Report(
      folderName: json['id'] as String? ?? '',
      created: json['created'] as String? ?? '',
      author: json['author'] as String? ?? '',
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      severity: ReportSeverity.fromString(json['severity'] as String? ?? 'info'),
      type: json['type'] as String? ?? 'other',
      status: ReportStatus.fromString(json['status'] as String? ?? 'open'),
      address: json['address'] as String?,
      contact: json['contact'] as String?,
      verifiedBy: verifiedBy,
      verificationCount: json['verification_count'] as int? ?? verifiedBy.length,
      pointedBy: pointedBy,
      pointCount: json['point_count'] as int? ?? pointedBy.length,
      admins: admins,
      moderators: moderators,
      ttl: json['ttl'] as int?,
      expires: json['expires'] as String?,
      titles: titles,
      descriptions: descriptions,
      metadata: metadata,
      lastModified: json['last_modified'] as String?,
    );
  }

  /// Generate API ID from created timestamp and title (YYYY-MM-DD_title-slug)
  /// This matches the Events API ID format
  String get apiId {
    // Extract date from created timestamp (format: "YYYY-MM-DD HH:MM_ss")
    final datePart = created.split(' ').first; // "YYYY-MM-DD"

    // Get title and slugify it
    final title = getTitle('EN');
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');

    return '${datePart}_$slug';
  }

  /// Helper to truncate coordinate to 4 decimal places (≈11m precision)
  double _truncateCoord(double coord) {
    return (coord * 10000).truncateToDouble() / 10000;
  }

  /// Convert to API JSON for alerts
  ///
  /// When [summary] is true, returns minimal data for list views.
  /// When [summary] is false, returns full alert detail.
  Map<String, dynamic> toApiJson({bool summary = false, bool hasPhotos = false}) {
    // Truncate coordinates to 4 decimal places for privacy
    final lat = _truncateCoord(latitude);
    final lon = _truncateCoord(longitude);

    if (summary) {
      return {
        'id': apiId,
        'title': getTitle('EN'),
        'author': author,
        'created': created,
        'latitude': lat,
        'longitude': lon,
        'severity': severity.name,
        'type': type,
        'status': status.toFileString(),
        'address': address,
        'verification_count': verificationCount,
        'point_count': pointCount,
        'has_photos': hasPhotos,
        'last_modified': lastModified,
      };
    }
    // Full JSON for detail view
    return {
      'id': apiId,
      'title': getTitle('EN'),
      'title_translations': titles,
      'description': getDescription('EN'),
      'description_translations': descriptions,
      'author': author,
      'created': created,
      'latitude': lat,
      'longitude': lon,
      'severity': severity.name,
      'type': type,
      'status': status.toFileString(),
      'address': address,
      'contact': contact,
      'verified_by': verifiedBy,
      'verification_count': verificationCount,
      'pointed_by': pointedBy,
      'point_count': pointCount,
      'admins': admins,
      'moderators': moderators,
      'ttl': ttl,
      'expires': expires,
      'npub': npub,
      'signature': signature,
      'last_modified': lastModified,
    };
  }
}
