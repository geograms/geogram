/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Feed item that a device publishes to its preferred station.
class StationActivityEvent {
  final String id;
  final String appType;
  final String action;
  final String sourceId;
  final String sourceName;
  final String authorCallsign;
  final String? authorNpub;
  final String summary;
  final String date;
  final String visibility;
  final List<String> allowedGroups;
  final List<String> allowedNpubs;
  final Map<String, dynamic> metadata;
  final int? index;
  final int? receivedAt;

  const StationActivityEvent({
    required this.id,
    required this.appType,
    required this.action,
    required this.sourceId,
    required this.sourceName,
    required this.authorCallsign,
    required this.summary,
    required this.date,
    this.authorNpub,
    this.visibility = 'public',
    this.allowedGroups = const [],
    this.allowedNpubs = const [],
    this.metadata = const {},
    this.index,
    this.receivedAt,
  });

  factory StationActivityEvent.create({
    required String appType,
    required String action,
    required String sourceId,
    required String sourceName,
    required String authorCallsign,
    required String summary,
    required String date,
    String? authorNpub,
    String visibility = 'public',
    List<String>? allowedGroups,
    List<String>? allowedNpubs,
    Map<String, dynamic>? metadata,
  }) {
    final normalized = StationActivityEvent(
      id: '',
      appType: appType.trim(),
      action: action.trim(),
      sourceId: sourceId.trim(),
      sourceName: sourceName.trim().isEmpty
          ? sourceId.trim()
          : sourceName.trim(),
      authorCallsign: authorCallsign.trim(),
      authorNpub: _normalizeOptional(authorNpub),
      summary: summary.trim(),
      date: date.trim(),
      visibility: normalizeVisibility(visibility),
      allowedGroups: _normalizeList(allowedGroups),
      allowedNpubs: _normalizeList(allowedNpubs),
      metadata: metadata == null
          ? const {}
          : Map<String, dynamic>.from(metadata),
    );
    return normalized.copyWith(id: normalized.generateStableId());
  }

  factory StationActivityEvent.fromJson(Map<String, dynamic> json) {
    return StationActivityEvent(
      id: json['id'] as String? ?? '',
      appType: json['app_type'] as String? ?? json['appType'] as String? ?? '',
      action: json['action'] as String? ?? '',
      sourceId:
          json['source_id'] as String? ?? json['sourceId'] as String? ?? '',
      sourceName:
          json['source_name'] as String? ?? json['sourceName'] as String? ?? '',
      authorCallsign:
          json['author_callsign'] as String? ??
          json['authorCallsign'] as String? ??
          '',
      authorNpub: _normalizeOptional(
        json['author_npub'] as String? ?? json['authorNpub'] as String?,
      ),
      summary: json['summary'] as String? ?? '',
      date: json['date'] as String? ?? '',
      visibility: normalizeVisibility(
        json['visibility'] as String? ?? 'public',
      ),
      allowedGroups: _normalizeList(
        (json['allowed_groups'] as List?)?.cast<String>() ??
            (json['allowedGroups'] as List?)?.cast<String>(),
      ),
      allowedNpubs: _normalizeList(
        (json['allowed_npubs'] as List?)?.cast<String>() ??
            (json['allowedNpubs'] as List?)?.cast<String>(),
      ),
      metadata: (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
      index: json['index'] as int? ?? json['idx'] as int?,
      receivedAt: json['received_at'] as int? ?? json['receivedAt'] as int?,
    );
  }

  static String normalizeVisibility(String value) {
    final normalized = value.trim().toLowerCase();
    switch (normalized) {
      case 'public':
        return 'public';
      case 'restricted':
        return 'restricted';
      case 'group':
        return 'group';
      case 'private':
        return 'private';
      default:
        return normalized.isEmpty ? 'private' : normalized;
    }
  }

  bool get isPublic => visibility == 'public';

  bool isVisibleTo(String? requesterNpub, {bool hasAllowedGroup = false}) {
    if (isPublic) return true;

    final normalizedRequester = _normalizeOptional(requesterNpub);
    if (normalizedRequester == null) {
      return false;
    }
    if (authorNpub == normalizedRequester) {
      return true;
    }
    if (allowedNpubs.contains(normalizedRequester)) {
      return true;
    }
    return hasAllowedGroup;
  }

  String generateStableId() {
    final digest = sha256.convert(
      utf8.encode(
        jsonEncode([
          appType,
          action,
          sourceId,
          sourceName,
          authorCallsign,
          authorNpub,
          summary,
          date,
          visibility,
          allowedGroups,
          allowedNpubs,
          metadata,
        ]),
      ),
    );
    return digest.toString();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'app_type': appType,
    'action': action,
    'source_id': sourceId,
    'source_name': sourceName,
    'author_callsign': authorCallsign,
    if (authorNpub != null) 'author_npub': authorNpub,
    'summary': summary,
    'date': date,
    'visibility': visibility,
    'allowed_groups': allowedGroups,
    'allowed_npubs': allowedNpubs,
    'metadata': metadata,
    if (index != null) 'index': index,
    if (receivedAt != null) 'received_at': receivedAt,
  };

  StationActivityEvent copyWith({
    String? id,
    String? appType,
    String? action,
    String? sourceId,
    String? sourceName,
    String? authorCallsign,
    String? authorNpub,
    String? summary,
    String? date,
    String? visibility,
    List<String>? allowedGroups,
    List<String>? allowedNpubs,
    Map<String, dynamic>? metadata,
    int? index,
    int? receivedAt,
    bool clearIndex = false,
    bool clearReceivedAt = false,
  }) {
    return StationActivityEvent(
      id: id ?? this.id,
      appType: appType ?? this.appType,
      action: action ?? this.action,
      sourceId: sourceId ?? this.sourceId,
      sourceName: sourceName ?? this.sourceName,
      authorCallsign: authorCallsign ?? this.authorCallsign,
      authorNpub: authorNpub ?? this.authorNpub,
      summary: summary ?? this.summary,
      date: date ?? this.date,
      visibility: visibility ?? this.visibility,
      allowedGroups: allowedGroups ?? this.allowedGroups,
      allowedNpubs: allowedNpubs ?? this.allowedNpubs,
      metadata: metadata ?? this.metadata,
      index: clearIndex ? null : (index ?? this.index),
      receivedAt: clearReceivedAt ? null : (receivedAt ?? this.receivedAt),
    );
  }

  static String? _normalizeOptional(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  static List<String> _normalizeList(List<String>? values) {
    if (values == null || values.isEmpty) {
      return const [];
    }
    final seen = <String>{};
    final normalized = <String>[];
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isEmpty || seen.contains(trimmed)) {
        continue;
      }
      seen.add(trimmed);
      normalized.add(trimmed);
    }
    return normalized;
  }
}
