import 'dart:typed_data';

enum DChatMediaKind {
  image('images'),
  video('video'),
  audio('audio'),
  file('files'),
  thumb('thumbs');

  const DChatMediaKind(this.folderName);

  final String folderName;

  static DChatMediaKind fromStorageValue(String value) {
    return DChatMediaKind.values.firstWhere(
      (kind) => kind.name == value || kind.folderName == value,
      orElse: () => throw ArgumentError('Unknown dchat media kind: $value'),
    );
  }
}

class DChatRoomMetadata {
  final String roomId;
  final String title;
  final String? description;
  final String? icon;
  final String ownerNpub;
  final String? roomNpub;
  final List<String> seedPeerHints;
  final int currentEpoch;
  final int? snapshotStart;
  final String state;
  final String joinPolicy;
  final DateTime createdAt;
  final DateTime updatedAt;

  const DChatRoomMetadata({
    required this.roomId,
    required this.title,
    this.description,
    this.icon,
    required this.ownerNpub,
    this.roomNpub,
    this.seedPeerHints = const [],
    this.currentEpoch = 0,
    this.snapshotStart,
    this.state = 'active',
    this.joinPolicy = 'approval_required',
    required this.createdAt,
    required this.updatedAt,
  });

  DChatRoomMetadata copyWith({
    String? roomId,
    String? title,
    String? description,
    bool clearDescription = false,
    String? icon,
    bool clearIcon = false,
    String? ownerNpub,
    String? roomNpub,
    bool clearRoomNpub = false,
    List<String>? seedPeerHints,
    int? currentEpoch,
    int? snapshotStart,
    bool clearSnapshotStart = false,
    String? state,
    String? joinPolicy,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return DChatRoomMetadata(
      roomId: roomId ?? this.roomId,
      title: title ?? this.title,
      description: clearDescription ? null : (description ?? this.description),
      icon: clearIcon ? null : (icon ?? this.icon),
      ownerNpub: ownerNpub ?? this.ownerNpub,
      roomNpub: clearRoomNpub ? null : (roomNpub ?? this.roomNpub),
      seedPeerHints: seedPeerHints ?? List<String>.from(this.seedPeerHints),
      currentEpoch: currentEpoch ?? this.currentEpoch,
      snapshotStart: clearSnapshotStart
          ? null
          : (snapshotStart ?? this.snapshotStart),
      state: state ?? this.state,
      joinPolicy: joinPolicy ?? this.joinPolicy,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class DChatTopicRecord {
  final String topicId;
  final String title;
  final String? description;
  final String? icon;
  final String createdByNpub;
  final DateTime createdAt;
  final DateTime updatedAt;

  const DChatTopicRecord({
    required this.topicId,
    required this.title,
    this.description,
    this.icon,
    required this.createdByNpub,
    required this.createdAt,
    required this.updatedAt,
  });
}

class DChatMemberRecord {
  final String memberNpub;
  final String role;
  final String status;
  final DateTime? joinedAt;
  final DateTime? removedAt;
  final String? addedBy;
  final DateTime updatedAt;

  const DChatMemberRecord({
    required this.memberNpub,
    required this.role,
    this.status = 'active',
    this.joinedAt,
    this.removedAt,
    this.addedBy,
    required this.updatedAt,
  });
}

class DChatEpochRecord {
  final int epoch;
  final String rotatedByNpub;
  final DateTime createdAt;
  final String? controlEventId;
  final String? summary;

  const DChatEpochRecord({
    required this.epoch,
    required this.rotatedByNpub,
    required this.createdAt,
    this.controlEventId,
    this.summary,
  });
}

class DChatEpochKeyBox {
  final int epoch;
  final String recipientNpub;
  final String envelope;
  final DateTime createdAt;

  const DChatEpochKeyBox({
    required this.epoch,
    required this.recipientNpub,
    required this.envelope,
    required this.createdAt,
  });
}

class DChatMessageRecord {
  final String messageId;
  final String topicId;
  final int epoch;
  final int lamport;
  final String authorNpub;
  final DateTime authoredAt;
  final Uint8List ciphertext;
  final Uint8List? nonce;
  final String? encryptionScheme;
  final String ciphertextSha1;
  final String rawEventJson;
  final DateTime? deletedAt;

  const DChatMessageRecord({
    required this.messageId,
    this.topicId = 'general',
    required this.epoch,
    required this.lamport,
    required this.authorNpub,
    required this.authoredAt,
    required this.ciphertext,
    this.nonce,
    this.encryptionScheme,
    required this.ciphertextSha1,
    required this.rawEventJson,
    this.deletedAt,
  });
}

class DChatMediaRecord {
  final String sha1;
  final DChatMediaKind kind;
  final String extension;
  final String relativePath;
  final String? mimeType;
  final String? originalName;
  final int sizeBytes;
  final DateTime createdAt;

  const DChatMediaRecord({
    required this.sha1,
    required this.kind,
    required this.extension,
    required this.relativePath,
    this.mimeType,
    this.originalName,
    required this.sizeBytes,
    required this.createdAt,
  });
}

class DChatSyncCursor {
  final String peerNpub;
  final int lastControlLamport;
  final int lastMessageLamport;
  final DateTime? lastSyncedAt;

  const DChatSyncCursor({
    required this.peerNpub,
    this.lastControlLamport = 0,
    this.lastMessageLamport = 0,
    this.lastSyncedAt,
  });
}

class DChatLocalSyncState {
  final String peerNpub;
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;
  final String? lastError;

  const DChatLocalSyncState({
    required this.peerNpub,
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.lastError,
  });
}
