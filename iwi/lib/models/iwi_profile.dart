/*
 * IwiProfile — slimmed-down profile model for the iwi launcher.
 *
 * Ported shape from geogram/lib/models/profile.dart but stripped to the
 * fields that the launcher actually cares about. The parent project's
 * Profile carries ~20 station/location/relay fields that iwi doesn't
 * need. If iwi ever needs them, add them here rather than importing
 * the parent class — the two lifecycles are intentionally decoupled.
 *
 * Persistence: written as a JSON entry inside `profiles.json` at the
 * geogram root by [ProfileService]. Never persist [nsec] anywhere
 * outside this file — it is the private signing key and must stay
 * inside the profile folder.
 */

class IwiProfile {
  /// Stable identifier. We use the callsign so paths on disk are
  /// human-readable (`profiles/X1ABCD/`) and a profile can be swapped
  /// across machines by copying its folder name.
  final String id;

  /// Display label shown in the launcher AppBar and the welcome card.
  /// Free text chosen by the user. Falls back to [callsign] if empty.
  final String nickname;

  /// Callsign derived from the npub (X1 + first 4 bech32 chars). Stays
  /// stable for the life of the profile because it is also the [id].
  final String callsign;

  /// Bech32-encoded Nostr public key (`npub1...`). Shown to users,
  /// safe to share, used as the publisher identity when signing wapps.
  final String npub;

  /// Bech32-encoded Nostr private key (`nsec1...`). **Secret**. Kept
  /// only in the profile's own JSON entry so a profile export/backup
  /// is a single file copy.
  final String nsec;

  /// Unix epoch ms of creation. Used to sort profiles in the switcher.
  final int createdAt;

  const IwiProfile({
    required this.id,
    required this.nickname,
    required this.callsign,
    required this.npub,
    required this.nsec,
    required this.createdAt,
  });

  String get displayName => nickname.isNotEmpty ? nickname : callsign;

  IwiProfile copyWith({
    String? id,
    String? nickname,
    String? callsign,
    String? npub,
    String? nsec,
    int? createdAt,
  }) {
    return IwiProfile(
      id: id ?? this.id,
      nickname: nickname ?? this.nickname,
      callsign: callsign ?? this.callsign,
      npub: npub ?? this.npub,
      nsec: nsec ?? this.nsec,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'nickname': nickname,
        'callsign': callsign,
        'npub': npub,
        'nsec': nsec,
        'createdAt': createdAt,
      };

  factory IwiProfile.fromJson(Map<String, dynamic> json) {
    return IwiProfile(
      id: json['id'] as String,
      nickname: (json['nickname'] as String?) ?? '',
      callsign: json['callsign'] as String,
      npub: json['npub'] as String,
      nsec: json['nsec'] as String,
      createdAt: (json['createdAt'] as int?) ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }
}
