/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'chat_message.dart';

/// Represents a 1:1 direct message conversation between two callsigns
class DMConversation {
  /// The other party's callsign (the person we're chatting with)
  final String otherCallsign;

  /// Our callsign (the local user)
  final String myCallsign;

  /// Path to the conversation folder
  /// Format: devices/{otherCallsign}/chat/{myCallsign}
  final String path;

  /// The other party's NOSTR public key (npub) - cryptographically binds the
  /// conversation to a specific identity. Once set, messages from a different
  /// npub claiming the same callsign will be rejected.
  String? otherNpub;

  /// Last message timestamp (for sorting)
  DateTime? lastMessageTime;

  /// Unread message count
  int unreadCount;

  /// Last sync timestamp (when we last synced with the other device)
  DateTime? lastSyncTime;

  /// Whether the other party is currently online
  bool isOnline;

  /// Most recent message preview
  String? lastMessagePreview;

  /// Most recent message author
  String? lastMessageAuthor;

  DMConversation({
    required this.otherCallsign,
    required this.myCallsign,
    required this.path,
    this.otherNpub,
    this.lastMessageTime,
    this.unreadCount = 0,
    this.lastSyncTime,
    this.isOnline = false,
    this.lastMessagePreview,
    this.lastMessageAuthor,
  });

  /// Get the display name for this conversation
  String get displayName => otherCallsign;

  /// Get the subtitle (last message preview or sync status)
  String get subtitle {
    if (lastMessagePreview != null && lastMessagePreview!.isNotEmpty) {
      final prefix = lastMessageAuthor == myCallsign ? 'You: ' : '';
      final preview = lastMessagePreview!.length > 40
          ? '${lastMessagePreview!.substring(0, 40)}...'
          : lastMessagePreview!;
      return '$prefix$preview';
    }
    return 'No messages yet';
  }

  /// Get last activity time as a human-readable string
  String get lastActivityText {
    final time = lastMessageTime;
    if (time == null) return 'Never';

    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${time.day}/${time.month}/${time.year}';
  }

  /// Get sync status text
  String get syncStatusText {
    if (lastSyncTime == null) return 'Never synced';

    final diff = DateTime.now().difference(lastSyncTime!);
    if (diff.inMinutes < 1) return 'Synced just now';
    if (diff.inMinutes < 60) return 'Synced ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Synced ${diff.inHours}h ago';
    return 'Synced ${diff.inDays}d ago';
  }

  /// Update from a message list
  void updateFromMessages(List<ChatMessage> messages) {
    if (messages.isEmpty) return;

    // Sort by timestamp to get the latest
    messages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final latest = messages.first;

    lastMessageTime = latest.dateTime;
    lastMessagePreview = latest.content;
    lastMessageAuthor = latest.author;
  }

  /// Create from JSON
  factory DMConversation.fromJson(Map<String, dynamic> json, String myCallsign) {
    return DMConversation(
      otherCallsign: json['otherCallsign'] as String,
      myCallsign: myCallsign,
      path: json['path'] as String,
      otherNpub: json['otherNpub'] as String?,
      lastMessageTime: json['lastMessageTime'] != null
          ? DateTime.parse(json['lastMessageTime'] as String)
          : null,
      unreadCount: json['unreadCount'] as int? ?? 0,
      lastSyncTime: json['lastSyncTime'] != null
          ? DateTime.parse(json['lastSyncTime'] as String)
          : null,
      isOnline: json['isOnline'] as bool? ?? false,
      lastMessagePreview: json['lastMessagePreview'] as String?,
      lastMessageAuthor: json['lastMessageAuthor'] as String?,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'otherCallsign': otherCallsign,
      'path': path,
      if (otherNpub != null) 'otherNpub': otherNpub,
      if (lastMessageTime != null)
        'lastMessageTime': lastMessageTime!.toIso8601String(),
      'unreadCount': unreadCount,
      if (lastSyncTime != null)
        'lastSyncTime': lastSyncTime!.toIso8601String(),
      'isOnline': isOnline,
      if (lastMessagePreview != null) 'lastMessagePreview': lastMessagePreview,
      if (lastMessageAuthor != null) 'lastMessageAuthor': lastMessageAuthor,
    };
  }

  /// Create a copy with modified fields
  DMConversation copyWith({
    String? otherCallsign,
    String? myCallsign,
    String? path,
    String? otherNpub,
    DateTime? lastMessageTime,
    int? unreadCount,
    DateTime? lastSyncTime,
    bool? isOnline,
    String? lastMessagePreview,
    String? lastMessageAuthor,
  }) {
    return DMConversation(
      otherCallsign: otherCallsign ?? this.otherCallsign,
      myCallsign: myCallsign ?? this.myCallsign,
      path: path ?? this.path,
      otherNpub: otherNpub ?? this.otherNpub,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      isOnline: isOnline ?? this.isOnline,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      lastMessageAuthor: lastMessageAuthor ?? this.lastMessageAuthor,
    );
  }

  @override
  String toString() {
    return 'DMConversation(with: $otherCallsign, unread: $unreadCount, online: $isOnline)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DMConversation &&
        other.otherCallsign == otherCallsign &&
        other.myCallsign == myCallsign;
  }

  @override
  int get hashCode => Object.hash(otherCallsign, myCallsign);
}

/// Result of a DM sync operation
class DMSyncResult {
  final String otherCallsign;
  final int messagesReceived;
  final int messagesSent;
  final bool success;
  final String? error;
  final DateTime syncTime;

  DMSyncResult({
    required this.otherCallsign,
    required this.messagesReceived,
    required this.messagesSent,
    required this.success,
    this.error,
    DateTime? syncTime,
  }) : syncTime = syncTime ?? DateTime.now();

  @override
  String toString() {
    if (success) {
      return 'Sync with $otherCallsign: received $messagesReceived, sent $messagesSent';
    } else {
      return 'Sync with $otherCallsign failed: $error';
    }
  }
}
