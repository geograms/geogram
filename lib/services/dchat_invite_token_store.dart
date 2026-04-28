/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Host-local registry of one-time invite tokens for distributed chat rooms.
 *
 * The token is just a random opaque string carried inside the
 * `DistributedChatInvite` payload (`one_time_token`). The host stamps it onto
 * an issued invite, persists `{token, room_id, status}` here, and on receiving
 * a `joinRequested` event with a matching pending token auto-approves the
 * applicant and flips the entry to `consumed`. Subsequent uses of the same
 * token are rejected.
 *
 * Storage shape mirrors `SharedInvitationService` (see
 * `lib/services/shared_invitation_service.dart`) intentionally — same idea,
 * different transport.
 */

library;

import 'dart:math';

import 'profile_storage.dart';

const String _kTokensRelativePath = 'dchat/invite_tokens.json';
const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

enum DChatInviteTokenStatus { pending, consumed, revoked }

class DChatInviteTokenRecord {
  final String token;
  final String roomId;
  final DChatInviteTokenStatus status;
  final DateTime createdAt;
  final int? expiresAt;
  final String? consumedByNpub;
  final DateTime? consumedAt;

  const DChatInviteTokenRecord({
    required this.token,
    required this.roomId,
    required this.status,
    required this.createdAt,
    this.expiresAt,
    this.consumedByNpub,
    this.consumedAt,
  });

  bool get isPending => status == DChatInviteTokenStatus.pending;

  bool get isExpired {
    final exp = expiresAt;
    if (exp == null) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 > exp;
  }

  factory DChatInviteTokenRecord.fromJson(Map<String, dynamic> json) {
    return DChatInviteTokenRecord(
      token: json['token'] as String,
      roomId: json['room_id'] as String,
      status: DChatInviteTokenStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => DChatInviteTokenStatus.pending,
      ),
      createdAt: DateTime.parse(json['created_at'] as String),
      expiresAt: (json['expires_at'] as num?)?.toInt(),
      consumedByNpub: json['consumed_by_npub'] as String?,
      consumedAt: json['consumed_at'] != null
          ? DateTime.parse(json['consumed_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'token': token,
    'room_id': roomId,
    'status': status.name,
    'created_at': createdAt.toIso8601String(),
    if (expiresAt != null) 'expires_at': expiresAt,
    if (consumedByNpub != null) 'consumed_by_npub': consumedByNpub,
    if (consumedAt != null) 'consumed_at': consumedAt!.toIso8601String(),
  };

  DChatInviteTokenRecord copyWith({
    DChatInviteTokenStatus? status,
    String? consumedByNpub,
    DateTime? consumedAt,
  }) {
    return DChatInviteTokenRecord(
      token: token,
      roomId: roomId,
      status: status ?? this.status,
      createdAt: createdAt,
      expiresAt: expiresAt,
      consumedByNpub: consumedByNpub ?? this.consumedByNpub,
      consumedAt: consumedAt ?? this.consumedAt,
    );
  }
}

class DChatInviteTokenStore {
  final ProfileStorage storage;

  DChatInviteTokenStore({required this.storage});

  List<DChatInviteTokenRecord>? _cached;

  Future<List<DChatInviteTokenRecord>> _load() async {
    final cached = _cached;
    if (cached != null) return cached;
    final json = await storage.readJson(_kTokensRelativePath);
    final raw = (json?['tokens'] as List<dynamic>?) ?? const [];
    final tokens = raw
        .whereType<Map<String, dynamic>>()
        .map(DChatInviteTokenRecord.fromJson)
        .toList(growable: true);
    _cached = tokens;
    return tokens;
  }

  Future<void> _save(List<DChatInviteTokenRecord> tokens) async {
    _cached = tokens;
    await storage.writeJson(_kTokensRelativePath, {
      'version': 1,
      'tokens': tokens.map((t) => t.toJson()).toList(),
    });
  }

  /// Issue a new pending one-time token bound to [roomId]. Returns the random
  /// opaque token to embed in `DistributedChatInvite.oneTimeToken`.
  Future<DChatInviteTokenRecord> issue({
    required String roomId,
    int? expiresAt,
  }) async {
    final tokens = await _load();
    String token;
    do {
      token = _generateToken();
    } while (tokens.any((t) => t.token == token));
    final record = DChatInviteTokenRecord(
      token: token,
      roomId: roomId,
      status: DChatInviteTokenStatus.pending,
      createdAt: DateTime.now().toUtc(),
      expiresAt: expiresAt,
    );
    tokens.insert(0, record);
    await _save(tokens);
    return record;
  }

  /// Atomic check-and-consume. Returns the consumed record on success, or
  /// `null` if the token is unknown, expired, revoked, already consumed, or
  /// bound to a different room.
  Future<DChatInviteTokenRecord?> tryConsume({
    required String token,
    required String roomId,
    required String applicantNpub,
  }) async {
    final tokens = await _load();
    final index = tokens.indexWhere((t) => t.token == token);
    if (index < 0) return null;
    final entry = tokens[index];
    if (entry.roomId != roomId) return null;
    if (!entry.isPending) return null;
    if (entry.isExpired) return null;
    final updated = entry.copyWith(
      status: DChatInviteTokenStatus.consumed,
      consumedByNpub: applicantNpub,
      consumedAt: DateTime.now().toUtc(),
    );
    tokens[index] = updated;
    await _save(tokens);
    return updated;
  }

  Future<DChatInviteTokenRecord?> revoke(String token) async {
    final tokens = await _load();
    final index = tokens.indexWhere((t) => t.token == token);
    if (index < 0) return null;
    final entry = tokens[index];
    if (entry.status == DChatInviteTokenStatus.revoked) return entry;
    final updated = entry.copyWith(status: DChatInviteTokenStatus.revoked);
    tokens[index] = updated;
    await _save(tokens);
    return updated;
  }

  Future<List<DChatInviteTokenRecord>> listForRoom(String roomId) async {
    final tokens = await _load();
    return tokens.where((t) => t.roomId == roomId).toList(growable: false);
  }

  /// Wipe in-memory cache so the next call re-reads from disk.
  void invalidateCache() {
    _cached = null;
  }

  static String _generateToken() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 12; i++) {
      buffer.write(_alphabet[random.nextInt(_alphabet.length)]);
    }
    return buffer.toString();
  }
}
