/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

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
  final Map<String, String> titles;
  final Map<String, String> descriptions;
  final Map<String, String> metadata;

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
    this.titles = const {},
    this.descriptions = const {},
    this.metadata = const {},
  });

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

  /// Get NOSTR public key
  String? get npub => metadata['npub'];

  /// Get signature
  String? get signature => metadata['signature'];

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
    Map<String, String> metadata = {};

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
      } else if (line.startsWith('-->')) {
        final metaLine = line.substring(3).trim();
        final colonIndex = metaLine.indexOf(':');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex).trim();
          final value = metaLine.substring(colonIndex + 1).trim();
          metadata[key] = value;
        }
      } else if (line.trim().isEmpty && i > headerEnd) {
        contentStart = i + 1;
        break;
      }
    }

    // Parse descriptions
    final descriptions = <String, String>{};
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
          // Metadata section, stop parsing descriptions
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
      titles: titles,
      descriptions: descriptions,
      metadata: metadata,
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
    Map<String, String>? titles,
    Map<String, String>? descriptions,
    Map<String, String>? metadata,
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
      titles: titles ?? this.titles,
      descriptions: descriptions ?? this.descriptions,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  String toString() {
    return 'Report(folder: $folderName, severity: ${severity.name}, status: ${status.name})';
  }
}
