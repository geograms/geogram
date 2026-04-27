/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

library;

/// Status for a Shared-app invitation.
enum SharedInvitationStatus { pending, accepted, denied, revoked }

/// One-time (or limited-use) invite issued by the host of a shared folder.
///
/// The code is `<HOST_CALLSIGN>-<4-char-token>`. A guest typing this code
/// into their Shared app is enough to discover the host (via
/// `ConnectionManager`) and join the folder — no Mirror pairing or prior
/// device knowledge required.
class SharedInvitation {
  final String code;
  final String folderId;
  final String hostCallsign;
  final String hostNpub;
  final String token;
  final SharedInvitationStatus status;
  final DateTime createdAt;
  final DateTime? resolvedAt;
  final String? guestNpub;
  final String? guestCallsign;
  final String? guestName;
  final String? guestPlatform;
  final String? accessToken;

  const SharedInvitation({
    required this.code,
    required this.folderId,
    required this.hostCallsign,
    required this.hostNpub,
    required this.token,
    required this.status,
    required this.createdAt,
    this.resolvedAt,
    this.guestNpub,
    this.guestCallsign,
    this.guestName,
    this.guestPlatform,
    this.accessToken,
  });

  bool get isPending => status == SharedInvitationStatus.pending;

  factory SharedInvitation.fromJson(Map<String, dynamic> json) {
    return SharedInvitation(
      code: json['code'] as String,
      folderId: json['folder_id'] as String,
      hostCallsign: json['host_callsign'] as String,
      hostNpub: json['host_npub'] as String? ?? '',
      token: json['token'] as String,
      status: SharedInvitationStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => SharedInvitationStatus.pending,
      ),
      createdAt: DateTime.parse(json['created_at'] as String),
      resolvedAt: json['resolved_at'] != null
          ? DateTime.parse(json['resolved_at'] as String)
          : null,
      guestNpub: json['guest_npub'] as String?,
      guestCallsign: json['guest_callsign'] as String?,
      guestName: json['guest_name'] as String?,
      guestPlatform: json['guest_platform'] as String?,
      accessToken: json['access_token'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'code': code,
    'folder_id': folderId,
    'host_callsign': hostCallsign,
    'host_npub': hostNpub,
    'token': token,
    'status': status.name,
    'created_at': createdAt.toIso8601String(),
    if (resolvedAt != null) 'resolved_at': resolvedAt!.toIso8601String(),
    if (guestNpub != null) 'guest_npub': guestNpub,
    if (guestCallsign != null) 'guest_callsign': guestCallsign,
    if (guestName != null) 'guest_name': guestName,
    if (guestPlatform != null) 'guest_platform': guestPlatform,
    if (accessToken != null) 'access_token': accessToken,
  };

  SharedInvitation copyWith({
    SharedInvitationStatus? status,
    DateTime? resolvedAt,
    String? guestNpub,
    String? guestCallsign,
    String? guestName,
    String? guestPlatform,
    String? accessToken,
  }) {
    return SharedInvitation(
      code: code,
      folderId: folderId,
      hostCallsign: hostCallsign,
      hostNpub: hostNpub,
      token: token,
      status: status ?? this.status,
      createdAt: createdAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      guestNpub: guestNpub ?? this.guestNpub,
      guestCallsign: guestCallsign ?? this.guestCallsign,
      guestName: guestName ?? this.guestName,
      guestPlatform: guestPlatform ?? this.guestPlatform,
      accessToken: accessToken ?? this.accessToken,
    );
  }
}
