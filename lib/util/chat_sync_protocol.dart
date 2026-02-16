/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Parsed chat sync payload that supports full and compact API responses.
class ChatSyncPayload {
  final List<Map<String, dynamic>> messages;
  final int? latestId;
  final int? latestTimestamp;
  final bool compact;

  const ChatSyncPayload({
    required this.messages,
    this.latestId,
    this.latestTimestamp,
    this.compact = false,
  });

  factory ChatSyncPayload.fromResponse(dynamic responseBody) {
    if (responseBody is List) {
      return ChatSyncPayload(messages: _normalizeMessageList(responseBody));
    }

    if (responseBody is Map) {
      final map = responseBody.cast<String, dynamic>();
      final rawMessages = map['messages'] ?? map['m'] ?? const <dynamic>[];
      final messages = rawMessages is List
          ? _normalizeMessageList(rawMessages)
          : const <Map<String, dynamic>>[];

      int? latestTimestamp = parseEpochSeconds(
        map['latest_timestamp'] ?? map['latestTimestamp'] ?? map['lt'],
      );
      latestTimestamp ??= _maxMessageTimestamp(messages);

      return ChatSyncPayload(
        messages: messages,
        latestId: _parseInt(map['latest_id'] ?? map['latestId'] ?? map['li']),
        latestTimestamp: latestTimestamp,
        compact:
            map['compact'] == true ||
            map['compact'] == 1 ||
            map.containsKey('m'),
      );
    }

    return const ChatSyncPayload(messages: <Map<String, dynamic>>[]);
  }

  static List<Map<String, dynamic>> _normalizeMessageList(List<dynamic> raw) {
    final out = <Map<String, dynamic>>[];
    for (final item in raw) {
      final normalized = _normalizeMessage(item);
      if (normalized != null) {
        out.add(normalized);
      }
    }
    return out;
  }

  static Map<String, dynamic>? _normalizeMessage(dynamic item) {
    if (item is Map) {
      final map = item.cast<String, dynamic>();
      if (map.containsKey('i') ||
          map.containsKey('a') ||
          map.containsKey('c') ||
          map.containsKey('t')) {
        final msg = <String, dynamic>{
          'id': map['i'] ?? map['id'],
          'author': map['a'] ?? map['author'] ?? map['callsign'],
          'content': map['c'] ?? map['content'] ?? map['text'],
          'timestamp': map['t'] ?? map['timestamp'],
          if (map['r'] != null || map['roomId'] != null)
            'roomId': map['r'] ?? map['roomId'],
          if (map['reactions'] != null) 'reactions': map['reactions'],
        };

        final file = map['f'] ?? map['file'];
        if (file is Map) {
          final fileMap = file.cast<String, dynamic>();
          msg['file'] = {
            'sha1': fileMap['s'] ?? fileMap['sha1'],
            'name': fileMap['n'] ?? fileMap['name'],
            'size': fileMap['z'] ?? fileMap['size'],
            'mime': fileMap['m'] ?? fileMap['mime'],
          };
          msg['hasFile'] = true;
        } else if (file != null) {
          msg['file'] = file;
          msg['hasFile'] = true;
        }

        return msg;
      }

      return map;
    }

    if (item is List && item.length >= 4) {
      final msg = <String, dynamic>{
        'id': item[0],
        'timestamp': item[1],
        'author': item[2],
        'content': item[3],
      };

      if (item.length >= 5 && item[4] is Map) {
        final fileMap = (item[4] as Map).cast<String, dynamic>();
        msg['file'] = {
          'sha1': fileMap['s'] ?? fileMap['sha1'],
          'name': fileMap['n'] ?? fileMap['name'],
          'size': fileMap['z'] ?? fileMap['size'],
          'mime': fileMap['m'] ?? fileMap['mime'],
        };
        msg['hasFile'] = true;
      }

      return msg;
    }

    return null;
  }

  static int? _parseInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static int? _maxMessageTimestamp(List<Map<String, dynamic>> messages) {
    int? maxTs;
    for (final msg in messages) {
      final ts = parseEpochSeconds(msg['timestamp']);
      if (ts == null) continue;
      if (maxTs == null || ts > maxTs) {
        maxTs = ts;
      }
    }
    return maxTs;
  }

  /// Parse timestamp-like value into Unix seconds.
  /// Supports unix seconds, unix milliseconds, geogram chat format, and ISO strings.
  static int? parseEpochSeconds(dynamic raw) {
    if (raw == null) return null;

    if (raw is num) {
      var value = raw.toInt();
      if (value > 1000000000000) {
        value = (value / 1000).round();
      }
      return value > 0 ? value : null;
    }

    if (raw is! String) return null;
    final value = raw.trim();
    if (value.isEmpty) return null;

    final asInt = int.tryParse(value);
    if (asInt != null) {
      return parseEpochSeconds(asInt);
    }

    final chatLike = value.contains('_') ? value.replaceFirst('_', ':') : value;
    if (chatLike.contains(' ') && !chatLike.contains('T')) {
      final iso = chatLike.replaceFirst(' ', 'T');
      final dt = DateTime.tryParse(iso);
      if (dt != null) {
        return dt.millisecondsSinceEpoch ~/ 1000;
      }
    }

    final dt = DateTime.tryParse(chatLike);
    if (dt != null) {
      return dt.millisecondsSinceEpoch ~/ 1000;
    }

    return null;
  }
}
