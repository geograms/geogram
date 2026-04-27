library;

import 'dart:math';

import 'package:uuid/uuid.dart';

import '../models/mirror_config.dart';
import '../models/mirror_invitation.dart';
import 'app_service.dart';
import 'log_service.dart';
import 'mirror_config_service.dart';
import 'mirror_sync_service.dart';
import 'profile_service.dart';
import 'profile_storage.dart';

const _mirrorInvitationsPath = 'mirror/invitations.json';

class MirrorInvitationResult {
  final bool success;
  final String status;
  final String? error;
  final MirrorInvitation? invitation;
  final MirrorPeer? peer;

  const MirrorInvitationResult({
    required this.success,
    required this.status,
    this.error,
    this.invitation,
    this.peer,
  });
}

class MirrorInvitationService {
  static final MirrorInvitationService _instance =
      MirrorInvitationService._internal();
  static MirrorInvitationService get instance => _instance;

  MirrorInvitationService._internal();

  final _uuid = const Uuid();
  List<MirrorInvitation> _invitations = const [];
  bool _loaded = false;

  List<MirrorInvitation> get invitations => List.unmodifiable(_invitations);
  List<MirrorInvitation> get pendingInvitations =>
      _invitations.where((invite) => invite.isPending).toList(growable: false);

  ProfileStorage? get _storage => AppService().profileStorage;

  Future<void> initialize() async {
    await loadInvitations();
  }

  Future<List<MirrorInvitation>> loadInvitations() async {
    final storage = _storage;
    if (storage == null) {
      _invitations = const [];
      _loaded = true;
      return invitations;
    }

    try {
      final json = await storage.readJson(_mirrorInvitationsPath);
      final raw = (json?['invitations'] as List<dynamic>?) ?? const [];
      _invitations =
          raw
              .whereType<Map<String, dynamic>>()
              .map(MirrorInvitation.fromJson)
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _loaded = true;
      return invitations;
    } catch (e) {
      LogService().log('MirrorInvitations: Failed to load invites: $e');
      _invitations = const [];
      _loaded = true;
      return invitations;
    }
  }

  Future<void> _saveInvitations() async {
    final storage = _storage;
    if (storage == null) {
      LogService().log('MirrorInvitations: No profile storage available');
      return;
    }

    await storage.writeJson(_mirrorInvitationsPath, {
      'version': 1,
      'invitations': _invitations.map((invite) => invite.toJson()).toList(),
    });
  }

  Future<MirrorInvitation> createInvite() async {
    if (!_loaded) {
      await loadInvitations();
    }

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
    final invite = MirrorInvitation(
      code: code,
      hostCallsign: profile.callsign.toUpperCase(),
      token: token,
      status: MirrorInvitationStatus.pending,
      createdAt: DateTime.now().toUtc(),
    );

    _invitations = [invite, ..._invitations];
    await _saveInvitations();
    return invite;
  }

  Future<MirrorInvitationResult> validateInvite(String code) async {
    if (!_loaded) {
      await loadInvitations();
    }

    final normalized = code.trim().toUpperCase();
    final parsed = _parseCode(normalized);
    if (parsed == null) {
      return const MirrorInvitationResult(
        success: false,
        status: 'invalid',
        error: 'Invalid invitation code format',
      );
    }

    final invite = _findInvite(normalized);
    if (invite == null) {
      return MirrorInvitationResult(
        success: false,
        status: 'missing',
        error: 'Invitation not found',
      );
    }

    return MirrorInvitationResult(
      success: invite.isPending,
      status: invite.status.name,
      invitation: invite,
      error: invite.isPending ? null : 'Invitation is ${invite.status.name}',
    );
  }

  Future<MirrorInvitationResult> redeemInvite({
    required String code,
    required String guestNpub,
    required String guestCallsign,
    required String guestName,
    required String guestPlatform,
    String? guestAddress,
    List<String> apps = const [],
  }) async {
    if (!_loaded) {
      await loadInvitations();
    }

    if (guestNpub.trim().isEmpty) {
      return const MirrorInvitationResult(
        success: false,
        status: 'invalid',
        error: 'Missing guest npub',
      );
    }

    final normalized = code.trim().toUpperCase();
    final parsed = _parseCode(normalized);
    if (parsed == null) {
      return const MirrorInvitationResult(
        success: false,
        status: 'invalid',
        error: 'Invalid invitation code format',
      );
    }

    final inviteIndex = _invitations.indexWhere(
      (entry) => entry.code.toUpperCase() == normalized,
    );
    if (inviteIndex < 0) {
      return MirrorInvitationResult(
        success: false,
        status: 'missing',
        error: 'Invitation not found',
      );
    }

    final invite = _invitations[inviteIndex];
    if (!invite.isPending) {
      return MirrorInvitationResult(
        success: false,
        status: invite.status.name,
        invitation: invite,
        error: 'Invitation is ${invite.status.name}',
      );
    }

    final peer = MirrorPeer(
      peerId: guestNpub.isNotEmpty ? guestNpub : _uuid.v4(),
      npub: guestNpub,
      name: guestName,
      callsign: guestCallsign.toUpperCase(),
      addresses: guestAddress == null || guestAddress.isEmpty
          ? const []
          : [guestAddress],
      apps: {
        for (final appId in apps)
          appId: AppSyncConfig(
            appId: appId,
            style: SyncStyle.sendReceive,
            enabled: true,
          ),
      },
      platform: guestPlatform,
    );

    await MirrorConfigService.instance.addPeer(peer);
    MirrorSyncService.instance.addAllowedPeer(
      guestNpub,
      guestCallsign.toUpperCase(),
    );

    final updated = invite.copyWith(
      status: MirrorInvitationStatus.accepted,
      resolvedAt: DateTime.now().toUtc(),
      guestNpub: guestNpub,
      guestCallsign: guestCallsign.toUpperCase(),
      guestName: guestName,
      guestPlatform: guestPlatform,
    );
    _invitations[inviteIndex] = updated;
    await _saveInvitations();

    if (!MirrorConfigService.instance.isEnabled) {
      await MirrorConfigService.instance.setEnabled(true);
    }

    return MirrorInvitationResult(
      success: true,
      status: 'accepted',
      invitation: updated,
      peer: peer,
    );
  }

  Future<MirrorInvitationResult> denyInvite(String code) async {
    if (!_loaded) {
      await loadInvitations();
    }

    final normalized = code.trim().toUpperCase();
    final inviteIndex = _invitations.indexWhere(
      (entry) => entry.code.toUpperCase() == normalized,
    );
    if (inviteIndex < 0) {
      return MirrorInvitationResult(
        success: false,
        status: 'missing',
        error: 'Invitation not found',
      );
    }

    final invite = _invitations[inviteIndex];
    if (!invite.isPending) {
      return MirrorInvitationResult(
        success: false,
        status: invite.status.name,
        invitation: invite,
        error: 'Invitation is ${invite.status.name}',
      );
    }

    final updated = invite.copyWith(
      status: MirrorInvitationStatus.denied,
      resolvedAt: DateTime.now().toUtc(),
    );
    _invitations[inviteIndex] = updated;
    await _saveInvitations();

    return MirrorInvitationResult(
      success: true,
      status: 'denied',
      invitation: updated,
    );
  }

  Future<MirrorInvitationResult> revokeAccess(String npub) async {
    final config = MirrorConfigService.instance.config;
    if (config == null) {
      return const MirrorInvitationResult(
        success: false,
        status: 'missing',
        error: 'No mirror config loaded',
      );
    }

    MirrorPeer? peer;
    for (final entry in config.peers) {
      if (entry.npub == npub) {
        peer = entry;
        break;
      }
    }
    if (peer == null) {
      return const MirrorInvitationResult(
        success: false,
        status: 'missing',
        error: 'Peer not found',
      );
    }

    await MirrorConfigService.instance.removePeer(peer.peerId);
    MirrorSyncService.instance.removeAllowedPeer(npub);

    return MirrorInvitationResult(success: true, status: 'revoked', peer: peer);
  }

  MirrorInvitation? _findInvite(String code) {
    for (final invite in _invitations) {
      if (invite.code.toUpperCase() == code.toUpperCase()) {
        return invite;
      }
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
    final random = Random();
    final buffer = StringBuffer();
    for (var i = 0; i < 4; i++) {
      final index = random.nextInt(alphabet.length);
      buffer.write(alphabet[index]);
    }
    return buffer.toString();
  }
}
