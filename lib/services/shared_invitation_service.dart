/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Issue and redeem invitations for the Shared app.
 *
 * This is intentionally independent from MirrorInvitationService — Shared is
 * its own feature. An invitation grants a guest access to one specific shared
 * folder; once redeemed, the host hands back the folder metadata and a
 * per-participant access token that future requests must present.
 */

library;

import 'dart:math';

import 'package:uuid/uuid.dart';

import '../models/shared_invitation.dart';
import 'app_service.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'profile_storage.dart';
import 'shared_folder_service.dart';

const _kInvitationsPath = 'invitations.json';

class SharedInvitationResult {
  final bool success;
  final String status;
  final String? error;
  final SharedInvitation? invitation;

  const SharedInvitationResult({
    required this.success,
    required this.status,
    this.error,
    this.invitation,
  });
}

class SharedInvitationService {
  static final SharedInvitationService _instance =
      SharedInvitationService._internal();
  static SharedInvitationService get instance => _instance;
  SharedInvitationService._internal();

  final _uuid = const Uuid();
  List<SharedInvitation> _invitations = const [];
  bool _loaded = false;
  ProfileStorage? _storage;

  /// Lazily resolve the Shared app's storage. Each call re-checks because
  /// the active profile can change.
  Future<ProfileStorage?> _ensureStorage() async {
    final service = await SharedFolderService.forCurrentProfile();
    if (service == null || service.appPath == null) return null;
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null) return null;
    _storage = ScopedProfileStorage.fromAbsolutePath(
      profileStorage,
      service.appPath!,
    );
    return _storage;
  }

  Future<List<SharedInvitation>> _load() async {
    final storage = await _ensureStorage();
    if (storage == null) {
      _invitations = const [];
      _loaded = true;
      return _invitations;
    }
    try {
      final json = await storage.readJson(_kInvitationsPath);
      final raw = (json?['invitations'] as List<dynamic>?) ?? const [];
      _invitations =
          raw
              .whereType<Map<String, dynamic>>()
              .map(SharedInvitation.fromJson)
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      LogService().log('SharedInvitations: load failed: $e');
      _invitations = const [];
    }
    _loaded = true;
    return _invitations;
  }

  Future<void> _save() async {
    final storage = _storage ?? await _ensureStorage();
    if (storage == null) {
      LogService().log('SharedInvitations: no storage available');
      return;
    }
    await storage.writeJson(_kInvitationsPath, {
      'version': 1,
      'invitations': _invitations.map((i) => i.toJson()).toList(),
    });
  }

  Future<List<SharedInvitation>> listInvitations({String? folderId}) async {
    if (!_loaded) await _load();
    if (folderId == null) return List.unmodifiable(_invitations);
    return _invitations
        .where((invite) => invite.folderId == folderId)
        .toList(growable: false);
  }

  Future<SharedInvitation> createInvite({required String folderId}) async {
    if (!_loaded) await _load();
    final profile = ProfileService().getProfile();
    if (profile.callsign.isEmpty) {
      throw StateError('No active profile callsign');
    }

    String token;
    String code;
    do {
      token = _generateToken();
      code = '${profile.callsign.toUpperCase()}-$token';
    } while (_invitations.any((invite) => invite.code.toUpperCase() == code));

    final invite = SharedInvitation(
      code: code,
      folderId: folderId,
      hostCallsign: profile.callsign.toUpperCase(),
      hostNpub: profile.npub,
      token: token,
      status: SharedInvitationStatus.pending,
      createdAt: DateTime.now().toUtc(),
    );

    _invitations = [invite, ..._invitations];
    await _save();
    return invite;
  }

  Future<SharedInvitationResult> validateInvite(String code) async {
    if (!_loaded) await _load();
    final normalized = code.trim().toUpperCase();
    final parsed = _parseCode(normalized);
    if (parsed == null) {
      return const SharedInvitationResult(
        success: false,
        status: 'invalid',
        error: 'Invalid invitation code format',
      );
    }
    final invite = _findByCode(normalized);
    if (invite == null) {
      return const SharedInvitationResult(
        success: false,
        status: 'missing',
        error: 'Invitation not found',
      );
    }
    return SharedInvitationResult(
      success: invite.isPending,
      status: invite.status.name,
      invitation: invite,
      error: invite.isPending ? null : 'Invitation is ${invite.status.name}',
    );
  }

  Future<SharedInvitationResult> redeemInvite({
    required String code,
    required String guestNpub,
    required String guestCallsign,
    required String guestName,
    String? guestPlatform,
  }) async {
    if (!_loaded) await _load();
    if (guestNpub.trim().isEmpty) {
      return const SharedInvitationResult(
        success: false,
        status: 'invalid',
        error: 'Missing guest npub',
      );
    }
    final normalized = code.trim().toUpperCase();
    if (_parseCode(normalized) == null) {
      return const SharedInvitationResult(
        success: false,
        status: 'invalid',
        error: 'Invalid invitation code format',
      );
    }
    final index = _invitations.indexWhere(
      (entry) => entry.code.toUpperCase() == normalized,
    );
    if (index < 0) {
      return const SharedInvitationResult(
        success: false,
        status: 'missing',
        error: 'Invitation not found',
      );
    }
    final invite = _invitations[index];
    if (!invite.isPending) {
      return SharedInvitationResult(
        success: false,
        status: invite.status.name,
        invitation: invite,
        error: 'Invitation is ${invite.status.name}',
      );
    }

    final accessToken = _generateAccessToken();
    final updated = invite.copyWith(
      status: SharedInvitationStatus.accepted,
      resolvedAt: DateTime.now().toUtc(),
      guestNpub: guestNpub,
      guestCallsign: guestCallsign.toUpperCase(),
      guestName: guestName,
      guestPlatform: guestPlatform,
      accessToken: accessToken,
    );
    _invitations[index] = updated;
    await _save();
    return SharedInvitationResult(
      success: true,
      status: 'accepted',
      invitation: updated,
    );
  }

  Future<SharedInvitationResult> denyInvite(String code) async {
    if (!_loaded) await _load();
    final normalized = code.trim().toUpperCase();
    final index = _invitations.indexWhere(
      (entry) => entry.code.toUpperCase() == normalized,
    );
    if (index < 0) {
      return const SharedInvitationResult(
        success: false,
        status: 'missing',
        error: 'Invitation not found',
      );
    }
    final invite = _invitations[index];
    if (!invite.isPending) {
      return SharedInvitationResult(
        success: false,
        status: invite.status.name,
        invitation: invite,
        error: 'Invitation is ${invite.status.name}',
      );
    }
    final updated = invite.copyWith(
      status: SharedInvitationStatus.denied,
      resolvedAt: DateTime.now().toUtc(),
    );
    _invitations[index] = updated;
    await _save();
    return SharedInvitationResult(
      success: true,
      status: 'denied',
      invitation: updated,
    );
  }

  /// Revoke a previously-granted access by guest npub. Marks every accepted
  /// invitation for that npub on the given folder as revoked.
  Future<int> revokeAccess({
    required String folderId,
    required String guestNpub,
  }) async {
    if (!_loaded) await _load();
    var revoked = 0;
    for (var i = 0; i < _invitations.length; i++) {
      final entry = _invitations[i];
      if (entry.folderId != folderId) continue;
      if (entry.guestNpub != guestNpub) continue;
      if (entry.status != SharedInvitationStatus.accepted) continue;
      _invitations[i] = entry.copyWith(
        status: SharedInvitationStatus.revoked,
        resolvedAt: DateTime.now().toUtc(),
      );
      revoked++;
    }
    if (revoked > 0) await _save();
    return revoked;
  }

  /// Look up the access-control record by the per-participant access token
  /// included in `X-Shared-Token` headers.
  Future<SharedInvitation?> findByAccessToken(String accessToken) async {
    if (!_loaded) await _load();
    for (final invite in _invitations) {
      if (invite.accessToken == accessToken &&
          invite.status == SharedInvitationStatus.accepted) {
        return invite;
      }
    }
    return null;
  }

  SharedInvitation? _findByCode(String code) {
    for (final invite in _invitations) {
      if (invite.code.toUpperCase() == code.toUpperCase()) return invite;
    }
    return null;
  }

  ({String hostCallsign, String token})? _parseCode(String code) {
    final parts = code.split('-');
    if (parts.length != 2) return null;
    final host = parts[0].trim().toUpperCase();
    final token = parts[1].trim().toUpperCase();
    if (host.isEmpty || token.length != 4) return null;
    return (hostCallsign: host, token: token);
  }

  String _generateToken() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 4; i++) {
      buffer.write(alphabet[random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }

  String _generateAccessToken() {
    return '${_uuid.v4().replaceAll('-', '')}${_uuid.v4().replaceAll('-', '')}';
  }
}
