/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Disk-based chat message store.
 * Shared by both station implementations — no in-memory message lists.
 * Messages are read from and written to daily files on disk.
 */

import 'dart:io';
import 'models/server_chat_message.dart';
import '../util/chat_format.dart';
import '../util/reaction_utils.dart';

/// Disk-based message store for station chat rooms.
/// All reads go to disk. Writes append to the daily file.
class ChatMessageStore {
  final String Function([String? callsign]) getChatPath;
  final void Function(String level, String message) log;

  /// Callback to reconstruct NOSTR event for signature verification.
  /// Set by the station server after initialization.
  NostrEventReconstructor? reconstructNostrEvent;

  ChatMessageStore({required this.getChatPath, required this.log});

  // ---------------------------------------------------------------------------
  // WRITE
  // ---------------------------------------------------------------------------

  /// Append a single message to today's daily file.
  Future<void> appendMessage(String roomId, ServerChatMessage msg, [String? callsign]) async {
    final chatPath = getChatPath(callsign);
    final dateStr = _formatDate(msg.timestamp);
    final year = dateStr.substring(0, 4);

    final yearDir = Directory('$chatPath/$roomId/$year');
    if (!await yearDir.exists()) {
      await yearDir.create(recursive: true);
    }

    final chatFile = File('${yearDir.path}/${dateStr}_chat.txt');
    final exists = await chatFile.exists();

    final buffer = StringBuffer();

    // Write header if new file
    if (!exists) {
      buffer.writeln('# $roomId: Chat from $dateStr');
      buffer.writeln();
    }

    // Write message
    final timeStr = _formatTime(msg.timestamp);
    buffer.writeln('> $dateStr $timeStr -- ${msg.senderCallsign}');
    buffer.writeln(msg.content);

    // Metadata (skip reserved keys)
    const reservedKeys = {'created_at', 'npub', 'signature', 'verified', 'has_signature'};
    for (final entry in msg.metadata.entries) {
      if (reservedKeys.contains(entry.key)) continue;
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    // NOSTR metadata
    if (msg.hasSignature) {
      buffer.writeln('--> created_at: ${msg.timestamp.millisecondsSinceEpoch ~/ 1000}');
    }
    if (msg.senderNpub != null && msg.senderNpub!.isNotEmpty) {
      buffer.writeln('--> npub: ${msg.senderNpub}');
    }
    if (msg.signature != null && msg.signature!.isNotEmpty) {
      buffer.writeln('--> signature: ${msg.signature}');
    }

    // Reactions
    final reactions = ReactionUtils.normalizeReactionMap(msg.reactions);
    if (reactions.isNotEmpty) {
      final entries = reactions.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
      for (final entry in entries) {
        final users = entry.value.map((u) => u.trim().toUpperCase()).where((u) => u.isNotEmpty).toSet().toList()..sort();
        if (users.isNotEmpty) {
          buffer.writeln('~~> reaction: ${entry.key}=${users.join(',')}');
        }
      }
    }

    buffer.writeln();
    buffer.writeln();

    await chatFile.writeAsString(buffer.toString(), mode: FileMode.append);
  }

  /// Delete a message by ID from its daily file.
  /// Rewrites the file without the deleted message.
  Future<bool> deleteMessage(String roomId, String messageId, [String? callsign]) async {
    final messages = await getMessages(roomId, limit: 10000, callsign: callsign);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return false;

    final msg = messages[idx];
    messages.removeAt(idx);

    // Rewrite the day file that contained this message
    final dateStr = _formatDate(msg.timestamp);
    final dayMessages = messages.where((m) => _formatDate(m.timestamp) == dateStr).toList();
    await _rewriteDayFile(roomId, dateStr, dayMessages, callsign);
    return true;
  }

  /// Update a message (e.g., reactions) in its daily file.
  Future<bool> updateMessage(String roomId, String messageId, ServerChatMessage updated, [String? callsign]) async {
    final chatPath = getChatPath(callsign);
    final dateStr = _formatDate(updated.timestamp);
    final year = dateStr.substring(0, 4);
    final chatFile = File('$chatPath/$roomId/$year/${dateStr}_chat.txt');

    if (!await chatFile.exists()) return false;

    // Load all messages for this day, replace the target, rewrite
    final dayMessages = await _loadDayFile(chatFile, roomId);
    final idx = dayMessages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return false;

    dayMessages[idx] = updated;
    await _rewriteDayFile(roomId, dateStr, dayMessages, callsign);
    return true;
  }

  // ---------------------------------------------------------------------------
  // READ
  // ---------------------------------------------------------------------------

  /// Get recent messages, most recent last. Reads from disk.
  Future<List<ServerChatMessage>> getMessages(String roomId, {
    int limit = 20,
    String? before,
    String? callsign,
  }) async {
    final chatPath = getChatPath(callsign);
    final roomDir = Directory('$chatPath/$roomId');
    if (!await roomDir.exists()) return [];

    // Get year directories in reverse order (newest first)
    final yearDirs = await roomDir.list()
        .where((e) => e is Directory && RegExp(r'^\d{4}$').hasMatch(e.path.split('/').last))
        .cast<Directory>()
        .toList();
    if (yearDirs.isEmpty) return [];
    yearDirs.sort((a, b) => b.path.compareTo(a.path)); // newest first

    DateTime? beforeTime;
    if (before != null) {
      beforeTime = DateTime.tryParse(before);
    }

    final collected = <ServerChatMessage>[];

    for (final yearDir in yearDirs) {
      final chatFiles = await yearDir.list()
          .where((e) => e is File && e.path.endsWith('_chat.txt'))
          .cast<File>()
          .toList();
      if (chatFiles.isEmpty) continue;
      chatFiles.sort((a, b) => b.path.compareTo(a.path)); // newest first

      for (final chatFile in chatFiles) {
        final dayMessages = await _loadDayFile(chatFile, roomId);

        // Filter by before timestamp
        var filtered = dayMessages;
        if (beforeTime != null) {
          filtered = dayMessages.where((m) => m.timestamp.isBefore(beforeTime!)).toList();
        }

        // Add in reverse (newest first collection, will reverse at end)
        collected.insertAll(0, filtered);

        if (collected.length >= limit) break;
      }
      if (collected.length >= limit) break;
    }

    // Return last `limit` messages (oldest first for display)
    if (collected.length > limit) {
      return collected.sublist(collected.length - limit);
    }
    return collected;
  }

  /// Count messages in a room by scanning daily files.
  Future<int> getMessageCount(String roomId, [String? callsign]) async {
    final chatPath = getChatPath(callsign);
    final roomDir = Directory('$chatPath/$roomId');
    if (!await roomDir.exists()) return 0;

    int count = 0;
    final yearDirs = await roomDir.list()
        .where((e) => e is Directory && RegExp(r'^\d{4}$').hasMatch(e.path.split('/').last))
        .cast<Directory>()
        .toList();

    for (final yearDir in yearDirs) {
      final chatFiles = await yearDir.list()
          .where((e) => e is File && e.path.endsWith('_chat.txt'))
          .cast<File>()
          .toList();

      for (final chatFile in chatFiles) {
        // Fast count: count lines starting with "> "
        final content = await chatFile.readAsString();
        count += RegExp(r'^> ', multiLine: true).allMatches(content).length;
      }
    }
    return count;
  }

  /// Check if a message is a duplicate of a recent message.
  Future<bool> isDuplicate(String roomId, ServerChatMessage msg, [String? callsign]) async {
    // Only check today's file for performance
    final chatPath = getChatPath(callsign);
    final dateStr = _formatDate(msg.timestamp);
    final year = dateStr.substring(0, 4);
    final chatFile = File('$chatPath/$roomId/$year/${dateStr}_chat.txt');

    if (!await chatFile.exists()) return false;

    final dayMessages = await _loadDayFile(chatFile, roomId);

    for (final existing in dayMessages) {
      // Primary: exact event ID match
      if (msg.id.length > 13 && existing.id == msg.id) return true;
      // Fallback: same sender + content + timestamp within 2s
      if (existing.senderCallsign.toUpperCase() == msg.senderCallsign.toUpperCase() &&
          existing.content == msg.content &&
          existing.timestamp.difference(msg.timestamp).abs().inSeconds <= 2) {
        return true;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Load and parse a single daily file.
  Future<List<ServerChatMessage>> _loadDayFile(File chatFile, String roomId) async {
    try {
      final content = await chatFile.readAsString();
      final parsed = ChatFormat.parse(content);
      final messages = <ServerChatMessage>[];

      for (final p in parsed) {
        final npub = p.getMeta('npub');
        final signature = p.getMeta('signature');
        final createdAtUnix = p.createdAt;
        final hasSig = signature != null && signature.isNotEmpty;

        final timestamp = createdAtUnix != null
            ? DateTime.fromMillisecondsSinceEpoch(createdAtUnix * 1000, isUtc: true)
            : ChatFormat.parseTimestamp(p.timestamp);

        String? eventId;
        bool verified = false;
        if (hasSig && npub != null && reconstructNostrEvent != null) {
          final event = reconstructNostrEvent!(
            npub: npub,
            content: p.content,
            signature: signature,
            roomId: roomId,
            callsign: p.author,
            timestamp: timestamp,
            createdAtUnix: createdAtUnix,
          );
          if (event != null) {
            eventId = event.id;
            verified = event.verify();
          }
        }

        messages.add(ServerChatMessage(
          id: eventId ?? DateTime.now().millisecondsSinceEpoch.toString(),
          roomId: roomId,
          senderCallsign: p.author,
          senderNpub: npub,
          signature: signature,
          content: p.content,
          timestamp: timestamp,
          verified: verified,
          hasSignature: hasSig,
          reactions: p.reactions,
          metadata: p.metadata,
        ));
      }
      return messages;
    } catch (e) {
      log('ERROR', 'Failed to parse chat file ${chatFile.path}: $e');
      return [];
    }
  }

  /// Rewrite a full day file from a list of messages.
  Future<void> _rewriteDayFile(String roomId, String dateStr, List<ServerChatMessage> messages, [String? callsign]) async {
    final chatPath = getChatPath(callsign);
    final year = dateStr.substring(0, 4);
    final chatFile = File('$chatPath/$roomId/$year/${dateStr}_chat.txt');

    if (messages.isEmpty) {
      if (await chatFile.exists()) await chatFile.delete();
      return;
    }

    final buffer = StringBuffer();
    buffer.writeln('# $roomId: Chat from $dateStr');
    buffer.writeln();

    for (final msg in messages) {
      final timeStr = _formatTime(msg.timestamp);
      buffer.writeln('> $dateStr $timeStr -- ${msg.senderCallsign}');
      buffer.writeln(msg.content);

      const reservedKeys = {'created_at', 'npub', 'signature', 'verified', 'has_signature'};
      for (final entry in msg.metadata.entries) {
        if (reservedKeys.contains(entry.key)) continue;
        buffer.writeln('--> ${entry.key}: ${entry.value}');
      }

      if (msg.hasSignature) {
        buffer.writeln('--> created_at: ${msg.timestamp.millisecondsSinceEpoch ~/ 1000}');
      }
      if (msg.senderNpub != null && msg.senderNpub!.isNotEmpty) {
        buffer.writeln('--> npub: ${msg.senderNpub}');
      }
      if (msg.signature != null && msg.signature!.isNotEmpty) {
        buffer.writeln('--> signature: ${msg.signature}');
      }

      final reactions = ReactionUtils.normalizeReactionMap(msg.reactions);
      if (reactions.isNotEmpty) {
        final entries = reactions.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
        for (final entry in entries) {
          final users = entry.value.map((u) => u.trim().toUpperCase()).where((u) => u.isNotEmpty).toSet().toList()..sort();
          if (users.isNotEmpty) {
            buffer.writeln('~~> reaction: ${entry.key}=${users.join(',')}');
          }
        }
      }

      buffer.writeln();
      buffer.writeln();
    }

    await chatFile.writeAsString(buffer.toString());
  }

  String _formatDate(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}_${dt.second.toString().padLeft(2, '0')}';
}

/// Callback type for NOSTR event reconstruction (used for signature verification).
typedef NostrEventReconstructor = dynamic Function({
  required String npub,
  required String content,
  String? signature,
  required String roomId,
  required String callsign,
  required DateTime timestamp,
  int? createdAtUnix,
});
