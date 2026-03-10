/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';
import '../models/chat_message.dart';
import '../util/reaction_utils.dart';
import '../services/cache_service_base.dart';
import 'pure_storage_config.dart';

/// Pure Dart CLI relay cache service.
/// Extends CacheServiceBase with CLI-specific initialization and message parsing.
class CliRelayCacheService extends CacheServiceBase {
  static final CliRelayCacheService _instance = CliRelayCacheService._internal();
  factory CliRelayCacheService() => _instance;
  CliRelayCacheService._internal();

  String? _basePath;
  bool _initialized = false;

  @override
  String? get basePath => _basePath;

  @override
  bool get isWeb => false;

  @override
  void log(String message) => stderr.writeln(message);

  @override
  List<ChatMessage> parseMessageText(String content) =>
      _parseMessageText(content);

  /// Initialize the cache service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      final config = PureStorageConfig();
      if (!config.isInitialized) {
        stderr.writeln('CliRelayCacheService: PureStorageConfig not initialized');
        return;
      }

      _basePath = config.devicesDir;

      final devicesDir = Directory(_basePath!);
      if (!await devicesDir.exists()) {
        await devicesDir.create(recursive: true);
      }

      _initialized = true;
      stderr.writeln('CliRelayCacheService initialized at: $_basePath');
    } catch (e) {
      stderr.writeln('Error initializing CliRelayCacheService: $e');
    }
  }

  // ==========================================================================
  // CLI-only: Pure Dart message parser (no Flutter dependency)
  // ==========================================================================

  List<ChatMessage> _parseMessageText(String content) {
    final sections = content.split('> 2');
    List<ChatMessage> messages = [];

    for (int i = 1; i < sections.length; i++) {
      try {
        final section = '2${sections[i]}';
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

  ChatMessage? _parseMessageSection(String section) {
    final lines = section.split('\n');
    if (lines.isEmpty) return null;

    final header = lines[0].trim();
    if (header.length < 23) return null;

    final timestamp = header.substring(0, 19).trim();
    final author = header.substring(23).trim();

    if (timestamp.isEmpty || author.isEmpty) return null;

    StringBuffer contentBuffer = StringBuffer();
    Map<String, String> metadata = {};
    final Map<String, List<String>> reactions = {};
    bool inContent = true;

    for (int i = 1; i < lines.length; i++) {
      final line = lines[i];

      if (line.trim().startsWith('~~> ')) {
        final unsignedLine = line.trim().substring(4);
        if (unsignedLine.startsWith('reaction:')) {
          final reactionLine = unsignedLine.substring('reaction:'.length).trim();
          final eqIndex = reactionLine.indexOf('=');
          if (eqIndex > 0) {
            final reaction = ReactionUtils.normalizeReactionKey(
              reactionLine.substring(0, eqIndex).trim(),
            );
            final usersPart = reactionLine.substring(eqIndex + 1).trim();
            final users = usersPart.isEmpty
                ? <String>[]
                : usersPart
                    .split(',')
                    .map((u) => u.trim().toUpperCase())
                    .where((u) => u.isNotEmpty)
                    .toSet()
                    .toList();
            if (reaction.isNotEmpty) {
              final existing = reactions[reaction] ?? [];
              final merged = {...existing, ...users}.toList();
              reactions[reaction] = merged;
            }
          }
        }
        continue;
      }

      if (line.trim().startsWith('--> ')) {
        inContent = false;
        final metaLine = line.trim().substring(4);
        final colonIndex = metaLine.indexOf(': ');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex);
          final value = metaLine.substring(colonIndex + 2);
          metadata[key] = value;
        }
      } else if (inContent && line.trim().isNotEmpty) {
        if (contentBuffer.isNotEmpty) {
          contentBuffer.writeln();
        }
        contentBuffer.write(line);
      }
    }

    return ChatMessage(
      author: author,
      timestamp: timestamp,
      content: contentBuffer.toString().trim(),
      metadata: metadata,
      reactions: reactions,
    );
  }
}
