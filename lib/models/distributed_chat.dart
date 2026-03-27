import 'dart:convert';

import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';

enum DistributedChatControlType {
  roomCreated,
  joinRequested,
  joinApproved,
  joinRejected,
  roomKeyShared,
  epochRotated,
  memberRemoved,
  memberBanned,
  memberUnbanned,
  moderatorGranted,
  moderatorRevoked,
  adminGranted,
  adminRevoked,
  roomPaused,
  roomResumed,
  roomClosed,
  messageDeleted,
}

extension DistributedChatControlTypeX on DistributedChatControlType {
  String get wireName {
    switch (this) {
      case DistributedChatControlType.roomCreated:
        return 'room_created';
      case DistributedChatControlType.joinRequested:
        return 'join_requested';
      case DistributedChatControlType.joinApproved:
        return 'join_approved';
      case DistributedChatControlType.joinRejected:
        return 'join_rejected';
      case DistributedChatControlType.roomKeyShared:
        return 'room_key_shared';
      case DistributedChatControlType.epochRotated:
        return 'epoch_rotated';
      case DistributedChatControlType.memberRemoved:
        return 'member_removed';
      case DistributedChatControlType.memberBanned:
        return 'member_banned';
      case DistributedChatControlType.memberUnbanned:
        return 'member_unbanned';
      case DistributedChatControlType.moderatorGranted:
        return 'moderator_granted';
      case DistributedChatControlType.moderatorRevoked:
        return 'moderator_revoked';
      case DistributedChatControlType.adminGranted:
        return 'admin_granted';
      case DistributedChatControlType.adminRevoked:
        return 'admin_revoked';
      case DistributedChatControlType.roomPaused:
        return 'room_paused';
      case DistributedChatControlType.roomResumed:
        return 'room_resumed';
      case DistributedChatControlType.roomClosed:
        return 'room_closed';
      case DistributedChatControlType.messageDeleted:
        return 'message_deleted';
    }
  }

  static DistributedChatControlType fromWireName(String wireName) {
    return DistributedChatControlType.values.firstWhere(
      (value) => value.wireName == wireName,
      orElse: () =>
          throw ArgumentError('Unknown distributed control type: $wireName'),
    );
  }
}

class DistributedChatInvite {
  final String roomId;
  final String roomName;
  final String? roomDescription;
  final String ownerNpub;
  final String roomNpub;
  final String joinPolicy;
  final String distributionMode;
  final String? hostCallsign;
  final List<String> seedPeerHints;

  const DistributedChatInvite({
    required this.roomId,
    required this.roomName,
    this.roomDescription,
    required this.ownerNpub,
    required this.roomNpub,
    this.joinPolicy = 'approval_required',
    this.distributionMode = 'distributed',
    this.hostCallsign,
    this.seedPeerHints = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'room_id': roomId,
      'room_name': roomName,
      if (roomDescription != null) 'room_description': roomDescription,
      'owner_npub': ownerNpub,
      'room_npub': roomNpub,
      'join_policy': joinPolicy,
      'distribution_mode': distributionMode,
      if (hostCallsign != null) 'host_callsign': hostCallsign,
      if (seedPeerHints.isNotEmpty) 'seed_peer_hints': seedPeerHints,
    };
  }

  factory DistributedChatInvite.fromJson(Map<String, dynamic> json) {
    return DistributedChatInvite(
      roomId: json['room_id'] as String,
      roomName: json['room_name'] as String,
      roomDescription: json['room_description'] as String?,
      ownerNpub: json['owner_npub'] as String,
      roomNpub: json['room_npub'] as String,
      joinPolicy: json['join_policy'] as String? ?? 'approval_required',
      distributionMode: json['distribution_mode'] as String? ?? 'distributed',
      hostCallsign: json['host_callsign'] as String?,
      seedPeerHints: List<String>.from(
        json['seed_peer_hints'] as List? ?? const [],
      ),
    );
  }

  String encode() {
    final payload = base64Url.encode(utf8.encode(jsonEncode(toJson())));
    return 'geogram://dchat?payload=$payload';
  }

  static DistributedChatInvite decode(String encoded) {
    final uri = Uri.parse(encoded);
    final payload = uri.queryParameters['payload'] ?? encoded;
    final normalized = base64Url.normalize(payload);
    final json =
        jsonDecode(utf8.decode(base64Url.decode(normalized)))
            as Map<String, dynamic>;
    return DistributedChatInvite.fromJson(json);
  }
}

class DistributedChatAdmission {
  final NostrEvent event;

  const DistributedChatAdmission(this.event);

  factory DistributedChatAdmission.create({
    required String roomId,
    required String roomNsec,
    required String memberNpub,
    required String approvedByNpub,
    int? expiresAt,
  }) {
    final roomPrivateKeyHex = NostrCrypto.decodeNsec(roomNsec);
    final roomPubkeyHex = NostrCrypto.derivePublicKey(roomPrivateKeyHex);
    final tags = <List<String>>[
      ['t', 'dchat_admission'],
      ['room', roomId],
      ['member', memberNpub],
      ['approved_by', approvedByNpub],
      if (expiresAt != null) ['expires', expiresAt.toString()],
    ];
    final event = NostrEvent.textNote(
      pubkeyHex: roomPubkeyHex,
      content: '',
      tags: tags,
    );
    event.signWithNsec(roomNsec);
    return DistributedChatAdmission(event);
  }

  factory DistributedChatAdmission.fromJson(Map<String, dynamic> json) {
    return DistributedChatAdmission(NostrEvent.fromJson(json));
  }

  Map<String, dynamic> toJson() => event.toJson();

  bool verify({
    required String roomNpub,
    required String roomId,
    required String memberNpub,
  }) {
    if (!event.verify()) return false;
    if (NostrCrypto.encodeNpub(event.pubkey) != roomNpub) return false;
    if (_tagValue(event.tags, 'room') != roomId) return false;
    if (_tagValue(event.tags, 'member') != memberNpub) return false;
    final expires = int.tryParse(_tagValue(event.tags, 'expires') ?? '');
    if (expires != null) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (now > expires) return false;
    }
    return true;
  }
}

class DistributedChatControlEvent {
  final NostrEvent event;
  final DistributedChatControlType type;
  final Map<String, dynamic> payload;

  const DistributedChatControlEvent({
    required this.event,
    required this.type,
    this.payload = const {},
  });

  factory DistributedChatControlEvent.create({
    required DistributedChatControlType type,
    required String roomId,
    required String actorNsec,
    required String actorCallsign,
    String? targetNpub,
    String? role,
    String? state,
    String? messageTimestamp,
    String? messageAuthor,
    Map<String, dynamic>? payload,
    int? createdAt,
  }) {
    final privateKeyHex = NostrCrypto.decodeNsec(actorNsec);
    final pubkeyHex = NostrCrypto.derivePublicKey(privateKeyHex);
    final event = NostrEvent.textNote(
      pubkeyHex: pubkeyHex,
      content: jsonEncode(payload ?? const {}),
      createdAt: createdAt,
      tags: [
        ['t', 'dchat_control'],
        ['room', roomId],
        ['control', type.wireName],
        ['callsign', actorCallsign],
        if (targetNpub != null) ['target', targetNpub],
        if (role != null) ['role', role],
        if (state != null) ['state', state],
        if (messageTimestamp != null) ['timestamp', messageTimestamp],
        if (messageAuthor != null) ['author', messageAuthor],
      ],
    );
    event.signWithNsec(actorNsec);
    return DistributedChatControlEvent(
      event: event,
      type: type,
      payload: payload ?? const {},
    );
  }

  factory DistributedChatControlEvent.fromEvent(NostrEvent event) {
    final typeName = _tagValue(event.tags, 'control');
    if (typeName == null || typeName.isEmpty) {
      throw ArgumentError('Missing distributed control type');
    }
    final payload = _decodePayload(event.content);
    return DistributedChatControlEvent(
      event: event,
      type: DistributedChatControlTypeX.fromWireName(typeName),
      payload: payload,
    );
  }

  factory DistributedChatControlEvent.fromJson(Map<String, dynamic> json) {
    return DistributedChatControlEvent.fromEvent(NostrEvent.fromJson(json));
  }

  Map<String, dynamic> toJson() => event.toJson();

  String get roomId => _tagValue(event.tags, 'room') ?? '';

  String get actorNpub => NostrCrypto.encodeNpub(event.pubkey);

  String? get actorCallsign => _tagValue(event.tags, 'callsign');

  String? get targetNpub => _tagValue(event.tags, 'target');

  String? get role => _tagValue(event.tags, 'role');

  String? get state => _tagValue(event.tags, 'state');

  String? get messageTimestamp => _tagValue(event.tags, 'timestamp');

  String? get messageAuthor => _tagValue(event.tags, 'author');

  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(
    event.createdAt * 1000,
    isUtc: true,
  ).toLocal();

  DistributedChatAdmission? get admission {
    final raw = payload['admission'];
    if (raw is Map<String, dynamic>) {
      return DistributedChatAdmission.fromJson(raw);
    }
    return null;
  }

  String? get encryptedRoomSecretBase64 =>
      payload['encrypted_room_nsec'] as String?;

  int? get epoch {
    final raw = payload['epoch'];
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    if (raw is String) {
      return int.tryParse(raw);
    }
    return null;
  }

  String? get epochSummary => payload['summary'] as String?;

  List<Map<String, String>> get epochKeyBoxes {
    final rawBoxes = payload['boxes'];
    if (rawBoxes is! List) {
      return const [];
    }
    final boxes = <Map<String, String>>[];
    for (final rawBox in rawBoxes) {
      if (rawBox is! Map) {
        continue;
      }
      final recipient = rawBox['recipient_npub']?.toString();
      final envelope = rawBox['envelope']?.toString();
      if (recipient == null || recipient.isEmpty) {
        continue;
      }
      if (envelope == null || envelope.isEmpty) {
        continue;
      }
      boxes.add({'recipient_npub': recipient, 'envelope': envelope});
    }
    return boxes;
  }

  bool verify() => event.verify();

  static Map<String, dynamic> _decodePayload(String content) {
    if (content.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return const {};
  }
}

String? _tagValue(List<List<String>> tags, String key) {
  for (final tag in tags) {
    if (tag.isNotEmpty && tag.first == key && tag.length > 1) {
      return tag[1];
    }
  }
  return null;
}
