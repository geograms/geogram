library;

import '../models/chat_message.dart';
import 'chat_service.dart';
import 'conference_archive_service.dart';

/// Stores per-meeting chat transcripts inside the meeting archive folder.
class ConferenceChatStore {
  static const int defaultLimit = 200;
  final ConferenceArchiveService _archiveService = ConferenceArchiveService();

  Future<List<ChatMessage>> loadMessages(
    String roomId, {
    required String roomName,
    int limit = defaultLimit,
  }) async {
    final content = await _archiveService.readTranscriptByRoomId(roomId);
    if (content == null || content.trim().isEmpty) {
      return [];
    }

    var messages = ChatService.parseMessageText(
      content,
    ).where((message) => message.getMeta('room_id') == roomId).toList()..sort();
    if (messages.length > limit) {
      messages = messages.sublist(messages.length - limit);
    }
    return messages;
  }

  Future<void> saveMessage(
    String roomId,
    String roomName,
    ChatMessage message,
  ) async {
    final archiveEntry = await _archiveService.findArchiveByRoomId(roomId);
    final transcriptExists = archiveEntry != null
        ? await _archiveService.readTranscriptByRoomId(roomId) != null
        : false;
    final buffer = StringBuffer();
    if (!transcriptExists) {
      buffer.writeln('# Transcript for $roomName ($roomId)');
    }
    buffer.writeln();
    buffer.writeln(message.exportAsText());
    await _archiveService.appendTranscript(roomId, roomName, buffer.toString());
  }

  String transcriptAbsolutePath(String roomId) {
    final path = _archiveService.transcriptAbsolutePathForRoom(roomId);
    if (path == null) {
      throw StateError('Transcript archive not initialized for room $roomId');
    }
    return path;
  }
}
