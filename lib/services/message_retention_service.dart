/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Message Retention Service — shared retention logic for DMs and group chat.
 * Handles retention period configuration, message purging, and periodic cleanup.
 */

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'chat_service.dart';
import 'direct_message_service.dart';
import 'log_service.dart';
import 'profile_storage.dart';

/// Supported message retention periods
enum RetentionPeriod { oneDay, oneWeek, oneMonth, oneYear, forever }

/// Human-readable labels for retention periods
String retentionLabel(RetentionPeriod period) {
  switch (period) {
    case RetentionPeriod.oneDay:
      return '1 day';
    case RetentionPeriod.oneWeek:
      return '1 week';
    case RetentionPeriod.oneMonth:
      return '1 month';
    case RetentionPeriod.oneYear:
      return '1 year';
    case RetentionPeriod.forever:
      return 'Off (keep forever)';
  }
}

/// Convert retention period to a Duration (forever returns null)
Duration? retentionToDuration(RetentionPeriod period) {
  switch (period) {
    case RetentionPeriod.oneDay:
      return const Duration(days: 1);
    case RetentionPeriod.oneWeek:
      return const Duration(days: 7);
    case RetentionPeriod.oneMonth:
      return const Duration(days: 30);
    case RetentionPeriod.oneYear:
      return const Duration(days: 365);
    case RetentionPeriod.forever:
      return null;
  }
}

/// Serialize retention period to a short key for JSON storage
String? retentionToKey(RetentionPeriod period) {
  switch (period) {
    case RetentionPeriod.oneDay:
      return '1d';
    case RetentionPeriod.oneWeek:
      return '1w';
    case RetentionPeriod.oneMonth:
      return '1m';
    case RetentionPeriod.oneYear:
      return '1y';
    case RetentionPeriod.forever:
      return null;
  }
}

/// Deserialize retention period from a short key
RetentionPeriod keyToRetention(String? key) {
  switch (key) {
    case '1d':
      return RetentionPeriod.oneDay;
    case '1w':
      return RetentionPeriod.oneWeek;
    case '1m':
      return RetentionPeriod.oneMonth;
    case '1y':
      return RetentionPeriod.oneYear;
    default:
      return RetentionPeriod.forever;
  }
}

/// Shared singleton service for message retention logic.
/// Reusable across DMs and group chat rooms.
class MessageRetentionService {
  static final MessageRetentionService _instance =
      MessageRetentionService._internal();
  factory MessageRetentionService() => _instance;
  MessageRetentionService._internal();

  Timer? _cleanupTimer;

  /// Pure function: purge expired messages from raw text content.
  /// Returns the filtered content string with only surviving messages.
  String purgeExpiredMessages(String messagesContent, RetentionPeriod period) {
    final duration = retentionToDuration(period);
    if (duration == null) return messagesContent; // forever — keep all

    final cutoff = DateTime.now().subtract(duration);
    final messages = ChatService.parseMessageText(messagesContent);

    if (messages.isEmpty) return messagesContent;

    final surviving = messages.where((m) => m.dateTime.isAfter(cutoff)).toList();

    if (surviving.length == messages.length) {
      return messagesContent; // nothing to purge
    }

    if (surviving.isEmpty) return '';

    // Re-export surviving messages
    final buffer = StringBuffer();
    buffer.writeln('# DM: Direct Chat from ${surviving.first.datePortion}');
    buffer.writeln();
    for (final msg in surviving) {
      buffer.writeln(msg.exportAsText());
      buffer.writeln();
    }
    return buffer.toString().trimRight();
  }

  /// Read retention period from a config.json map
  RetentionPeriod getRetentionForConfig(Map<String, dynamic> config) {
    return keyToRetention(config['message_retention'] as String?);
  }

  /// Set retention period in a config.json map (returns the modified map)
  Map<String, dynamic> setRetentionInConfig(
      Map<String, dynamic> config, RetentionPeriod period) {
    final key = retentionToKey(period);
    if (key == null) {
      config.remove('message_retention');
    } else {
      config['message_retention'] = key;
    }
    return config;
  }

  /// Purge a single conversation's messages.txt based on its retention setting.
  /// [storage] — ProfileStorage for the chat directory.
  /// [relativePath] — conversation folder relative to storage base (e.g. "CALLSIGN").
  /// Returns true if any messages were removed.
  Future<bool> purgeConversation(
      ProfileStorage storage, String relativePath, RetentionPeriod period) async {
    if (period == RetentionPeriod.forever) return false;

    final messagesPath = '$relativePath/messages.txt';
    try {
      final content = await storage.readString(messagesPath);
      if (content == null || content.isEmpty) return false;

      final purged = purgeExpiredMessages(content, period);
      if (purged == content) return false; // nothing changed

      if (purged.isEmpty) {
        // All messages expired — write empty file
        await storage.writeString(messagesPath, '');
      } else {
        await storage.writeString(messagesPath, purged);
      }
      return true;
    } catch (e) {
      LogService().log('MessageRetentionService: Error purging $relativePath: $e');
      return false;
    }
  }

  /// Start the periodic cleanup timer (every 30 minutes).
  /// Scans all DM conversations and purges expired messages.
  void startCleanupTimer() {
    stopCleanupTimer();
    // Run once at startup after a short delay, then every 30 min
    _cleanupTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      _runCleanupCycle();
    });
    // Initial run after 10 seconds (let the app finish loading)
    Future.delayed(const Duration(seconds: 10), _runCleanupCycle);
  }

  /// Stop the periodic cleanup timer.
  void stopCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  /// Run a full cleanup cycle across all DM conversations.
  Future<void> _runCleanupCycle() async {
    if (kIsWeb) return; // no filesystem on web

    try {
      final dmService = DirectMessageService();
      await dmService.initialize();

      final storage = dmService.storage;
      if (storage == null) return;

      final conversations = await dmService.listConversations();
      for (final convo in conversations) {
        final relativePath = convo.otherCallsign.toUpperCase();
        final configPath = '$relativePath/config.json';

        try {
          final configContent = await storage.readString(configPath);
          if (configContent == null) continue;

          final config = json.decode(configContent) as Map<String, dynamic>;
          final period = getRetentionForConfig(config);

          if (period == RetentionPeriod.forever) continue;

          final purged = await purgeConversation(storage, relativePath, period);
          if (purged) {
            LogService().log(
                'MessageRetentionService: Purged expired messages from $relativePath');
            // Invalidate cache so UI reloads
            dmService.invalidateCache(convo.otherCallsign);
          }
        } catch (e) {
          LogService().log(
              'MessageRetentionService: Error processing $relativePath: $e');
        }
      }
    } catch (e) {
      LogService().log('MessageRetentionService: Cleanup cycle error: $e');
    }
  }
}
