library;

/// Status for a mirror invitation.
enum MirrorInvitationStatus { pending, accepted, denied, revoked }

/// One-time invite code issued by a host device.
class MirrorInvitation {
  final String code;
  final String hostCallsign;
  final String token;
  final MirrorInvitationStatus status;
  final DateTime createdAt;
  final DateTime? resolvedAt;
  final String? guestNpub;
  final String? guestCallsign;
  final String? guestName;
  final String? guestPlatform;

  const MirrorInvitation({
    required this.code,
    required this.hostCallsign,
    required this.token,
    required this.status,
    required this.createdAt,
    this.resolvedAt,
    this.guestNpub,
    this.guestCallsign,
    this.guestName,
    this.guestPlatform,
  });

  bool get isPending => status == MirrorInvitationStatus.pending;

  factory MirrorInvitation.fromJson(Map<String, dynamic> json) {
    return MirrorInvitation(
      code: json['code'] as String,
      hostCallsign: json['host_callsign'] as String,
      token: json['token'] as String,
      status: MirrorInvitationStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => MirrorInvitationStatus.pending,
      ),
      createdAt: DateTime.parse(json['created_at'] as String),
      resolvedAt: json['resolved_at'] != null
          ? DateTime.parse(json['resolved_at'] as String)
          : null,
      guestNpub: json['guest_npub'] as String?,
      guestCallsign: json['guest_callsign'] as String?,
      guestName: json['guest_name'] as String?,
      guestPlatform: json['guest_platform'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'code': code,
    'host_callsign': hostCallsign,
    'token': token,
    'status': status.name,
    'created_at': createdAt.toIso8601String(),
    if (resolvedAt != null) 'resolved_at': resolvedAt!.toIso8601String(),
    if (guestNpub != null) 'guest_npub': guestNpub,
    if (guestCallsign != null) 'guest_callsign': guestCallsign,
    if (guestName != null) 'guest_name': guestName,
    if (guestPlatform != null) 'guest_platform': guestPlatform,
  };

  MirrorInvitation copyWith({
    MirrorInvitationStatus? status,
    DateTime? resolvedAt,
    String? guestNpub,
    String? guestCallsign,
    String? guestName,
    String? guestPlatform,
  }) {
    return MirrorInvitation(
      code: code,
      hostCallsign: hostCallsign,
      token: token,
      status: status ?? this.status,
      createdAt: createdAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      guestNpub: guestNpub ?? this.guestNpub,
      guestCallsign: guestCallsign ?? this.guestCallsign,
      guestName: guestName ?? this.guestName,
      guestPlatform: guestPlatform ?? this.guestPlatform,
    );
  }
}
