/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Email Format Parser/Writer - Handles thread.md files for email threads
 */

import '../models/email_message.dart';
import '../models/email_thread.dart';
import 'reaction_utils.dart';

/// Email thread file format parser and exporter.
///
/// Thread file format (thread.md):
/// ```
/// # EMAIL: Subject Line
///
/// STATION: p2p.radio
/// FROM: alice@p2p.radio
/// TO: bob@example.com, charlie@example.com
/// CC: dave@example.com
/// SUBJECT: Subject Line
/// CREATED: 2025-01-15 14:30_00
/// STATUS: received
/// THREAD_ID: abc123def456
/// LABELS: work, important
/// PRIORITY: high
/// IN_REPLY_TO: parent123
///
///
/// > 2025-01-15 14:30_00 -- X1ALICE
/// First message content...
/// --> file: {sha1}_attachment.pdf
/// --> npub: npub1...
/// --> signature: hex...
///
///
/// > 2025-01-15 15:45_00 -- X1BOB
/// Reply content...
/// --> npub: npub1...
/// --> signature: hex...
/// ```
class EmailFormat {
  /// Parse email thread from file content
  static EmailThread? parse(String content) {
    if (content.trim().isEmpty) return null;

    final lines = content.split('\n');
    if (lines.isEmpty) return null;

    // Parse header section (before first message)
    String? station;
    String? from;
    List<String> to = [];
    List<String> cc = [];
    List<String> bcc = [];
    String? subject;
    String? created;
    EmailStatus status = EmailStatus.draft;
    String? threadId;
    List<String> labels = [];
    EmailPriority priority = EmailPriority.normal;
    String? inReplyTo;
    bool? isRead;

    int headerEndIndex = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      // Skip empty lines and title line
      if (line.isEmpty || line.startsWith('# EMAIL:')) continue;

      // Message section starts with "> 2" (timestamp)
      if (line.startsWith('> 2')) {
        headerEndIndex = i;
        break;
      }

      // Parse header fields
      final colonIdx = line.indexOf(': ');
      if (colonIdx > 0) {
        final key = line.substring(0, colonIdx).toUpperCase();
        final value = line.substring(colonIdx + 2).trim();

        switch (key) {
          case 'STATION':
            station = value;
            break;
          case 'FROM':
            from = value;
            break;
          case 'TO':
            to = value.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
            break;
          case 'CC':
            cc = value.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
            break;
          case 'BCC':
            bcc = value.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
            break;
          case 'SUBJECT':
            subject = value;
            break;
          case 'CREATED':
            created = value;
            break;
          case 'STATUS':
            status = EmailStatus.values.firstWhere(
              (s) => s.name == value.toLowerCase(),
              orElse: () => EmailStatus.draft,
            );
            break;
          case 'THREAD_ID':
            threadId = value;
            break;
          case 'READ':
            final normalized = value.toLowerCase();
            isRead = normalized == 'true' || normalized == '1' || normalized == 'yes';
            break;
          case 'LABELS':
            labels = value.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
            break;
          case 'PRIORITY':
            priority = EmailPriority.values.firstWhere(
              (p) => p.name == value.toLowerCase(),
              orElse: () => EmailPriority.normal,
            );
            break;
          case 'IN_REPLY_TO':
            inReplyTo = value;
            break;
        }
      }
    }

    // Validate required fields
    if (from == null || to.isEmpty || subject == null || created == null || threadId == null) {
      return null;
    }

    // Parse messages using ChatFormat pattern
    final messagesContent = lines.sublist(headerEndIndex).join('\n');
    final parsedMessages = _parseMessages(messagesContent);

    return EmailThread(
      station: station ?? 'local',
      from: from,
      to: to,
      cc: cc,
      bcc: bcc,
      subject: subject,
      created: created,
      status: status,
      isRead: isRead ?? (status != EmailStatus.received),
      threadId: threadId,
      labels: labels,
      priority: priority,
      inReplyTo: inReplyTo,
      messages: parsedMessages,
    );
  }

  /// Parse messages section (reuses ChatFormat logic)
  static List<EmailMessage> _parseMessages(String content) {
    // Split by message header pattern: "> 2" (year 2xxx)
    final sections = content.split(RegExp(r'\n> 2'));
    final messages = <EmailMessage>[];

    for (int i = 0; i < sections.length; i++) {
      try {
        String section = sections[i];
        // First section starts with "> 2" (full prefix), subsequent sections need "2" prepended
        if (i == 0) {
          // First section: handle both "> 2..." and "2..." formats
          if (section.startsWith('> 2')) {
            section = section.substring(2); // Remove "> " prefix
          } else if (!section.startsWith('2')) {
            continue; // Skip non-message content
          }
        } else {
          // Subsequent sections: prepend "2" that was removed by split
          section = '2$section';
        }

        final message = _parseMessageSection(section);
        if (message != null) {
          messages.add(message);
        }
      } catch (e) {
        continue;
      }
    }

    return messages;
  }

  /// Parse a single message section
  static EmailMessage? _parseMessageSection(String section) {
    final lines = section.split('\n');
    if (lines.isEmpty) return null;

    // Parse header: "YYYY-MM-DD HH:MM_ss -- CALLSIGN"
    final header = lines[0].trim();
    if (header.length < 23) return null;

    final separatorIdx = header.indexOf(' -- ');
    if (separatorIdx < 19) return null;

    final timestamp = header.substring(0, 19).trim();
    final author = header.substring(separatorIdx + 4).trim();

    if (timestamp.isEmpty || author.isEmpty) return null;

    // Parse content and metadata
    final contentBuffer = StringBuffer();
    final metadata = <String, String>{};
    final reactions = <String, List<String>>{};
    bool inContent = true;

    for (int i = 1; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      // Unsigned reaction line: ~~> reaction: emoji=USER1,USER2
      if (trimmed.startsWith('~~> ')) {
        final unsignedLine = trimmed.substring(4);
        if (unsignedLine.startsWith('reaction:')) {
          _parseReaction(unsignedLine.substring(9).trim(), reactions);
        }
        continue;
      }

      // Metadata line: --> key: value
      if (trimmed.startsWith('--> ')) {
        inContent = false;
        final metaLine = trimmed.substring(4);
        final colonIdx = metaLine.indexOf(': ');
        if (colonIdx > 0) {
          final key = metaLine.substring(0, colonIdx).trim();
          final value = metaLine.substring(colonIdx + 2).trim();

          if (key == 'reaction') {
            _parseReaction(value, reactions);
          } else {
            metadata[key] = value;
          }
        }
        continue;
      }

      // Content line
      if (inContent && trimmed.isNotEmpty) {
        if (contentBuffer.isNotEmpty) {
          contentBuffer.write('\n');
        }
        contentBuffer.write(line);
      }
    }

    return EmailMessage(
      author: author,
      timestamp: timestamp,
      content: contentBuffer.toString().trim(),
      metadata: metadata,
      reactions: ReactionUtils.normalizeReactionMap(reactions),
    );
  }

  /// Parse reaction string
  static void _parseReaction(String value, Map<String, List<String>> reactions) {
    final eqIdx = value.indexOf('=');
    if (eqIdx <= 0) return;

    final emoji = ReactionUtils.normalizeReactionKey(value.substring(0, eqIdx).trim());
    final usersPart = value.substring(eqIdx + 1).trim();

    if (emoji.isEmpty) return;

    final users = usersPart.isEmpty
        ? <String>[]
        : usersPart
            .split(',')
            .map((u) => u.trim().toUpperCase())
            .where((u) => u.isNotEmpty)
            .toSet()
            .toList();

    if (users.isNotEmpty) {
      final existing = reactions[emoji] ?? [];
      reactions[emoji] = {...existing, ...users}.toList();
    }
  }

  /// Export email thread to file content
  static String export(EmailThread thread) {
    final buffer = StringBuffer();

    // Title
    buffer.writeln('# EMAIL: ${thread.subject}');
    buffer.writeln();

    // Header fields
    buffer.writeln('STATION: ${thread.station}');
    buffer.writeln('FROM: ${thread.from}');
    buffer.writeln('TO: ${thread.to.join(', ')}');
    if (thread.cc.isNotEmpty) {
      buffer.writeln('CC: ${thread.cc.join(', ')}');
    }
    if (thread.bcc.isNotEmpty) {
      buffer.writeln('BCC: ${thread.bcc.join(', ')}');
    }
    buffer.writeln('SUBJECT: ${thread.subject}');
    buffer.writeln('CREATED: ${thread.created}');
    buffer.writeln('STATUS: ${thread.status.name}');
    buffer.writeln('READ: ${thread.isRead}');
    buffer.writeln('THREAD_ID: ${thread.threadId}');
    if (thread.labels.isNotEmpty) {
      buffer.writeln('LABELS: ${thread.labels.join(', ')}');
    }
    if (thread.priority != EmailPriority.normal) {
      buffer.writeln('PRIORITY: ${thread.priority.name}');
    }
    if (thread.inReplyTo != null) {
      buffer.writeln('IN_REPLY_TO: ${thread.inReplyTo}');
    }

    // Messages with two empty lines between each
    for (final message in thread.messages) {
      buffer.writeln();
      buffer.writeln();
      buffer.write(message.exportAsText());
    }

    return buffer.toString();
  }

  /// Generate thread folder name
  static String generateFolderName(EmailThread thread) {
    return thread.generateFolderName();
  }

  /// Get the folder path for a thread based on its status
  /// Uses unified folder structure (no per-station folders)
  static String getThreadPath(EmailThread thread, {String? year}) {
    final yearStr = year ?? thread.created.substring(0, 4);
    final folderName = generateFolderName(thread);

    switch (thread.status) {
      case EmailStatus.draft:
        return 'drafts/$folderName';
      case EmailStatus.pending:
      case EmailStatus.failed:
        return 'outbox/$folderName';
      case EmailStatus.sent:
        return 'sent/$yearStr/$folderName';
      case EmailStatus.received:
        return 'inbox/$yearStr/$folderName';
      case EmailStatus.spam:
        return 'spam/$yearStr/$folderName';
      case EmailStatus.deleted:
        return 'garbage/$yearStr/$folderName';
      case EmailStatus.archived:
        return 'archive/$yearStr/$folderName';
    }
  }
}
