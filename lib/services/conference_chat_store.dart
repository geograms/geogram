library;

import 'dart:convert';

import 'package:path/path.dart' as p;

import '../models/chat_message.dart';
import 'app_service.dart';
import 'chat_service.dart';
import 'profile_storage.dart';

/// Stores per-meeting chat transcripts inside the conference app storage.
class ConferenceChatStore {
  static const int defaultLimit = 200;

  Future<List<ChatMessage>> loadMessages(
    String roomId, {
    required String roomName,
    int limit = defaultLimit,
  }) async {
    final storage = await _storageForConferenceApp();
    final content = await storage.readString(_messagesPath(roomId));
    if (content == null || content.trim().isEmpty) {
      return [];
    }

    var messages = ChatService.parseMessageText(
      content,
    ).where((message) => message.getMeta('room_id') == roomId).toList()..sort();
    if (messages.length > limit) {
      messages = messages.sublist(messages.length - limit);
    }

    await _writeRoomMetadata(storage, roomId, roomName);
    return messages;
  }

  Future<void> saveMessage(
    String roomId,
    String roomName,
    ChatMessage message,
  ) async {
    final storage = await _storageForConferenceApp();
    await storage.createDirectory(_roomFolder(roomId));
    await _writeRoomMetadata(storage, roomId, roomName);

    final messagesPath = _messagesPath(roomId);
    final exists = await storage.exists(messagesPath);
    final buffer = StringBuffer();
    if (!exists) {
      buffer.writeln('# Transcript for $roomName ($roomId)');
    }
    buffer.writeln();
    buffer.writeln(message.exportAsText());
    await storage.appendString(messagesPath, buffer.toString());
  }

  String transcriptAbsolutePath(String roomId) {
    final storage = AppService().profileStorage;
    if (storage == null) {
      throw StateError('Profile storage not initialized');
    }

    final conferenceAppPath =
        AppService().getAppByType('conference')?.storagePath ??
        storage.getAbsolutePath('conference');
    final scoped = ScopedProfileStorage.fromAbsolutePath(
      storage,
      conferenceAppPath,
    );
    return scoped.getAbsolutePath(_messagesPath(roomId));
  }

  Future<ProfileStorage> _storageForConferenceApp() async {
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null) {
      throw StateError('Profile storage not initialized');
    }

    final conferenceAppPath =
        AppService().getAppByType('conference')?.storagePath ??
        profileStorage.getAbsolutePath('conference');

    if (profileStorage.isEncrypted) {
      return ScopedProfileStorage.fromAbsolutePath(
        profileStorage,
        conferenceAppPath,
      );
    }

    return FilesystemProfileStorage(p.normalize(conferenceAppPath));
  }

  Future<void> _writeRoomMetadata(
    ProfileStorage storage,
    String roomId,
    String roomName,
  ) async {
    await storage.createDirectory(_roomFolder(roomId));
    await storage.writeString(
      _metadataPath(roomId),
      const JsonEncoder.withIndent('  ').convert({
        'room_id': roomId,
        'room_name': roomName,
        'updated_at': DateTime.now().toIso8601String(),
      }),
    );
  }

  String _roomFolder(String roomId) => 'history/${_safeRoomId(roomId)}';

  String _messagesPath(String roomId) => '${_roomFolder(roomId)}/messages.txt';

  String _metadataPath(String roomId) => '${_roomFolder(roomId)}/room.json';

  String _safeRoomId(String roomId) =>
      roomId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}
