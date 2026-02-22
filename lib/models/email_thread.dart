/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Email Thread Model - Represents an email conversation with header and messages
 */

import '../util/chat_format.dart';
import 'email_message.dart';

/// Email status values
enum EmailStatus {
  draft,
  pending,
  sent,
  received,
  failed,
  spam,
  deleted,
  archived,
}

/// Email priority levels
enum EmailPriority {
  low,
  normal,
  high,
}

/// Represents an email thread (conversation) with header fields and messages.
///
/// Thread format (thread.md):
/// ```
/// # EMAIL: Subject Line
///
/// STATION: p2p.radio
/// FROM: alice@p2p.radio
/// TO: bob@example.com
/// CC: charlie@p2p.radio
/// SUBJECT: Subject Line
/// CREATED: 2025-01-15 14:30_00
/// STATUS: received
/// THREAD_ID: abc123def456
/// LABELS: work, important
///
/// > 2025-01-15 14:30_00 -- X1ALICE
/// First message content...
/// --> npub: npub1...
/// --> signature: hex...
///
/// > 2025-01-15 15:45_00 -- X1BOB
/// Reply content...
/// ```
class EmailThread implements Comparable<EmailThread> {
  /// Station domain this email belongs to
  final String station;

  /// Sender email address
  final String from;

  /// Primary recipients (comma-separated in file)
  final List<String> to;

  /// Carbon copy recipients
  final List<String> cc;

  /// Blind carbon copy (stored locally only)
  final List<String> bcc;

  /// Email subject line
  final String subject;

  /// Thread creation timestamp
  final String created;

  /// Email status
  EmailStatus status;

  /// Read state for inbox threads
  bool isRead;

  /// Unique thread identifier
  final String threadId;

  /// User-defined labels
  List<String> labels;

  /// Email priority
  EmailPriority priority;

  /// Parent thread ID (for replies)
  final String? inReplyTo;

  /// Messages in this thread
  final List<EmailMessage> messages;

  /// Thread folder path (relative to email/ base directory)
  String? folderPath;

  EmailThread({
    required this.station,
    required this.from,
    required this.to,
    this.cc = const [],
    this.bcc = const [],
    required this.subject,
    required this.created,
    this.status = EmailStatus.draft,
    bool? isRead,
    required this.threadId,
    this.labels = const [],
    this.priority = EmailPriority.normal,
    this.inReplyTo,
    List<EmailMessage>? messages,
    this.folderPath,
  })  : isRead = isRead ?? (status != EmailStatus.received),
        messages = messages ?? [];

  /// Create a new draft thread
  factory EmailThread.draft({
    required String from,
    required List<String> to,
    required String subject,
    List<String>? cc,
    List<String>? bcc,
    String? station,
  }) {
    final now = DateTime.now();
    return EmailThread(
      station: station ?? 'local',
      from: from,
      to: to,
      cc: cc ?? [],
      bcc: bcc ?? [],
      subject: subject,
      created: ChatFormat.formatTimestamp(now),
      status: EmailStatus.draft,
      threadId: _generateThreadId(),
      labels: [],
    );
  }

  /// Generate unique thread ID
  static String _generateThreadId() {
    final now = DateTime.now();
    final timestamp = now.millisecondsSinceEpoch.toRadixString(36);
    final random = (now.microsecond * 1000 + now.millisecond).toRadixString(36);
    return '$timestamp$random';
  }

  /// Parse created timestamp to DateTime
  DateTime get createdDateTime {
    try {
      final datePart = created.substring(0, 10);
      final timePart = created.substring(11);
      final dateParts = datePart.split('-');
      final timeParts = timePart.split(RegExp(r'[_:]'));
      return DateTime(
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(dateParts[2]),
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
        int.parse(timeParts[2]),
      );
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Get last message timestamp
  DateTime get lastMessageTime {
    if (messages.isEmpty) return createdDateTime;
    return messages.last.dateTime;
  }

  /// Get last message preview (first 100 chars)
  String get preview {
    if (messages.isEmpty) return '';
    final content = messages.last.content;
    if (content.length <= 100) return content;
    return '${content.substring(0, 100)}...';
  }

  /// Get all participants (from, to, cc)
  Set<String> get participants {
    return {from, ...to, ...cc};
  }

  /// Check if thread has unread messages
  bool get isUnread => status == EmailStatus.received && !isRead;

  /// Check if thread is a draft
  bool get isDraft => status == EmailStatus.draft;

  /// Check if thread is pending delivery
  bool get isPending => status == EmailStatus.pending;

  /// Check if thread was sent
  bool get isSent => status == EmailStatus.sent;

  /// Check if thread is spam
  bool get isSpam => status == EmailStatus.spam;

  /// Check if thread is deleted
  bool get isDeleted => status == EmailStatus.deleted;

  /// Get folder name based on status
  String get folder {
    switch (status) {
      case EmailStatus.draft:
        return 'drafts';
      case EmailStatus.pending:
        return 'outbox';
      case EmailStatus.sent:
        return 'sent';
      case EmailStatus.received:
        return 'inbox';
      case EmailStatus.failed:
        return 'outbox';
      case EmailStatus.spam:
        return 'spam';
      case EmailStatus.deleted:
        return 'garbage';
      case EmailStatus.archived:
        return 'archive';
    }
  }

  /// Generate folder name for this thread
  String generateFolderName() {
    final date = created.substring(0, 10);
    final direction = (status == EmailStatus.received)
        ? 'from-${_extractLocalPart(from)}'
        : 'to-${_extractLocalPart(to.first)}';
    final slug = _slugify(subject);
    return '${date}_${direction}_$slug';
  }

  /// Extract local part from email address
  static String _extractLocalPart(String email) {
    final atIndex = email.indexOf('@');
    if (atIndex > 0) {
      return email.substring(0, atIndex).toLowerCase();
    }
    return email.toLowerCase();
  }

  /// Convert subject to URL-safe slug
  static String _slugify(String text) {
    final slug = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isEmpty) return 'no-subject';
    return slug.length > 30 ? slug.substring(0, 30) : slug;
  }

  /// Add a message to the thread
  void addMessage(EmailMessage message) {
    messages.add(message);
    messages.sort();
  }

  /// Get message count
  int get messageCount => messages.length;

  /// Check if thread has attachments
  bool get hasAttachments => messages.any(
        (m) => m.hasFile || m.hasImage || m.hasMeta('files'));

  /// Sort threads by last message time (newest first)
  @override
  int compareTo(EmailThread other) {
    return other.lastMessageTime.compareTo(lastMessageTime);
  }

  /// Create from JSON
  factory EmailThread.fromJson(Map<String, dynamic> json) {
    final parsedStatus = EmailStatus.values.firstWhere(
      (s) => s.name == (json['status'] as String? ?? 'draft'),
      orElse: () => EmailStatus.draft,
    );
    return EmailThread(
      station: json['station'] as String? ?? 'local',
      from: json['from'] as String,
      to: (json['to'] as List?)?.cast<String>() ?? [],
      cc: (json['cc'] as List?)?.cast<String>() ?? [],
      bcc: (json['bcc'] as List?)?.cast<String>() ?? [],
      subject: json['subject'] as String,
      created: json['created'] as String,
      status: parsedStatus,
      isRead: json['isRead'] as bool? ?? (parsedStatus != EmailStatus.received),
      threadId: json['threadId'] as String,
      labels: (json['labels'] as List?)?.cast<String>() ?? [],
      priority: EmailPriority.values.firstWhere(
        (p) => p.name == (json['priority'] as String? ?? 'normal'),
        orElse: () => EmailPriority.normal,
      ),
      inReplyTo: json['inReplyTo'] as String?,
      messages: (json['messages'] as List?)
              ?.map((m) => EmailMessage.fromJson(m as Map<String, dynamic>))
              .toList() ??
          [],
      folderPath: json['folderPath'] as String?,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
        'station': station,
        'from': from,
        'to': to,
        'cc': cc,
        'bcc': bcc,
        'subject': subject,
        'created': created,
        'status': status.name,
        'isRead': isRead,
        'threadId': threadId,
        'labels': labels,
        'priority': priority.name,
        'inReplyTo': inReplyTo,
        'messages': messages.map((m) => m.toJson()).toList(),
        'folderPath': folderPath,
      };

  /// Create a copy with modified fields
  EmailThread copyWith({
    String? station,
    String? from,
    List<String>? to,
    List<String>? cc,
    List<String>? bcc,
    String? subject,
    String? created,
    EmailStatus? status,
    bool? isRead,
    String? threadId,
    List<String>? labels,
    EmailPriority? priority,
    String? inReplyTo,
    List<EmailMessage>? messages,
    String? folderPath,
  }) {
    return EmailThread(
      station: station ?? this.station,
      from: from ?? this.from,
      to: to ?? List<String>.from(this.to),
      cc: cc ?? List<String>.from(this.cc),
      bcc: bcc ?? List<String>.from(this.bcc),
      subject: subject ?? this.subject,
      created: created ?? this.created,
      status: status ?? this.status,
      isRead: isRead ?? this.isRead,
      threadId: threadId ?? this.threadId,
      labels: labels ?? List<String>.from(this.labels),
      priority: priority ?? this.priority,
      inReplyTo: inReplyTo ?? this.inReplyTo,
      messages: messages ?? List<EmailMessage>.from(this.messages),
      folderPath: folderPath ?? this.folderPath,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EmailThread && other.threadId == threadId;
  }

  @override
  int get hashCode => threadId.hashCode;

  @override
  String toString() =>
      'EmailThread(threadId: $threadId, subject: $subject, '
      'status: ${status.name}, isRead: $isRead, messages: ${messages.length})';
}
