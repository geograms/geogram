library;

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/chat_message.dart';
import '../models/conference_archive_entry.dart';
import '../util/reaction_utils.dart';
import '../util/zip_storage.dart';
import '../work/models/meeting_content.dart';
import '../work/models/ndf_document.dart';
import '../work/models/ndf_permission.dart';
import 'app_service.dart';
import 'chat_service.dart';
import 'log_service.dart';
import 'profile_storage.dart';
import 'signing_service.dart';

class ConferenceArchiveService {
  static final ConferenceArchiveService _instance =
      ConferenceArchiveService._internal();
  factory ConferenceArchiveService() => _instance;
  ConferenceArchiveService._internal();

  static const int defaultTranscriptLimit = 200;
  static const String archiveRoot = 'meetings/archive';
  static const String metadataFileName = 'meeting.json';
  static const String chatDirectoryName = 'chat';
  static const String transcriptFileName = 'messages.txt';
  static const String filesDirectoryName = 'files';
  static const String recordingsDirectoryName = 'recordings';
  static const String transcriptsDirectoryName = 'transcripts';
  static const String _chatTranscriptPath =
      '$chatDirectoryName/$transcriptFileName';

  final Map<String, String> _activeArchivePathsByRoom = {};
  final Map<String, ZipProfileStorage> _activeNdfStorages = {};
  final LogService _log = LogService();

  // ============ Public API ============

  Future<ConferenceArchiveEntry> ensureArchive({
    required String roomId,
    required String roomName,
    required String hostCallsign,
    required String localCallsign,
    required DateTime startedAt,
    required bool hostedByMe,
    List<String> participants = const <String>[],
    List<String> speakers = const <String>[],
    String? activeScreenSharer,
    String? signalingMode,
    String? stationMeetUrl,
    List<String> meetUrls = const <String>[],
  }) async {
    final existingPath =
        _activeArchivePathsByRoom[roomId] ??
        await _latestArchivePathForRoom(roomId);
    if (existingPath != null) {
      final existing = await _loadEntry(existingPath);
      if (existing != null) {
        _activeArchivePathsByRoom[roomId] = existing.relativePath;
        return updateArchive(
          existing,
          roomName: roomName,
          hostCallsign: hostCallsign,
          localCallsign: localCallsign,
          hostedByMe: hostedByMe,
          participants: participants,
          speakers: speakers,
          activeScreenSharer: activeScreenSharer,
          clearActiveScreenSharer: activeScreenSharer == null,
          signalingMode: signalingMode,
          stationMeetUrl: stationMeetUrl,
          meetUrls: meetUrls,
        );
      }
    }

    final storage = _rootStorage();
    await storage.createDirectory(archiveRoot);

    // Generate NDF filename
    final fileName = await _nextArchiveFileName(
      storage,
      roomName: roomName,
      startedAt: startedAt,
    );
    final relativePath = '$archiveRoot/$fileName';
    final absolutePath = storage.getAbsolutePath(relativePath);

    // Create ZipProfileStorage
    final zipStorage = await ZipProfileStorage.open(absolutePath);

    final resolvedMode =
        signalingMode ?? (stationMeetUrl != null ? 'station' : 'lan');
    final yearTag = startedAt.toLocal().year.toString();

    // Build MeetingContent
    final meetingContent = MeetingContent(
      id: 'meeting-${startedAt.millisecondsSinceEpoch.toRadixString(36)}',
      title: roomName,
      created: startedAt.toLocal(),
      modified: DateTime.now().toLocal(),
      roomId: roomId,
      hostCallsign: hostCallsign,
      localCallsign: localCallsign,
      signalingMode: resolvedMode,
      participants: _sortedUnique(participants),
      speakers: _sortedUnique(speakers),
      tags: [yearTag],
      endedAt: null,
      hostedByMe: hostedByMe,
      activeScreenSharer: activeScreenSharer,
      stationMeetUrl: stationMeetUrl,
      meetUrls: _sortedUnique(meetUrls),
    );

    // Build NDF metadata
    final metadata = NdfDocument.create(
      type: NdfDocumentType.meeting,
      title: roomName,
      description: 'Meeting archive from ${_formatDate(startedAt)}',
    );
    final permissions = NdfPermission.create(
      documentId: metadata.id,
      ownerNpub: '',
      ownerCallsign: localCallsign,
    );

    // Write NDF structure into ZIP
    await zipStorage.writeString('ndf.json', metadata.toJsonString());
    await zipStorage.writeString(
      'permissions.json',
      permissions.toJsonString(),
    );
    await zipStorage.writeString(
      'content/main.json',
      meetingContent.toJsonString(),
    );

    // Build ConferenceArchiveEntry (with initial session)
    final initialSession = MeetingSession(
      id: 'session-${startedAt.millisecondsSinceEpoch.toRadixString(36)}',
      startedAt: startedAt.toLocal(),
    );
    final entry = ConferenceArchiveEntry(
      roomId: roomId,
      roomName: roomName,
      hostCallsign: hostCallsign,
      localCallsign: localCallsign,
      relativePath: relativePath,
      startedAt: startedAt.toLocal(),
      updatedAt: DateTime.now().toLocal(),
      hostedByMe: hostedByMe,
      participants: _sortedUnique(participants),
      speakers: _sortedUnique(speakers),
      activeScreenSharer: activeScreenSharer,
      signalingMode: resolvedMode,
      stationMeetUrl: stationMeetUrl,
      meetUrls: _sortedUnique(meetUrls),
      transcriptRelativePath: _chatTranscriptPath,
      messageCount: 0,
      tags: [yearTag],
      sessions: [initialSession],
    );

    // Generate default cover image
    const coverName = 'cover.jpg';
    final coverBytes = generateCoverImage(
      roomName: roomName,
      startedAt: startedAt,
      hostCallsign: hostCallsign,
    );
    await zipStorage.writeBytes(coverName, coverBytes);
    final entryWithCover = entry.copyWith(coverImagePath: coverName);

    // Write meeting.json for fast loading
    await zipStorage.writeJson(metadataFileName, entryWithCover.toJson());
    await zipStorage.flush();

    _activeNdfStorages[relativePath] = zipStorage;
    _activeArchivePathsByRoom[roomId] = relativePath;
    return entryWithCover;
  }

  Future<ConferenceArchiveEntry> updateArchive(
    ConferenceArchiveEntry entry, {
    String? roomName,
    String? hostCallsign,
    String? localCallsign,
    bool? hostedByMe,
    List<String>? participants,
    List<String>? speakers,
    String? activeScreenSharer,
    bool clearActiveScreenSharer = false,
    String? signalingMode,
    String? stationMeetUrl,
    List<String>? meetUrls,
    DateTime? endedAt,
    Map<String, String>? participantNicknames,
  }) async {
    final refreshed = await _recalculateCounts(entry);
    final updated = refreshed.copyWith(
      roomName: roomName,
      hostCallsign: hostCallsign,
      localCallsign: localCallsign,
      hostedByMe: hostedByMe,
      participants: participants == null ? null : _sortedUnique(participants),
      speakers: speakers == null ? null : _sortedUnique(speakers),
      activeScreenSharer: activeScreenSharer,
      clearActiveScreenSharer: clearActiveScreenSharer,
      signalingMode: signalingMode,
      stationMeetUrl: stationMeetUrl,
      meetUrls: meetUrls == null ? null : _sortedUnique(meetUrls),
      updatedAt: DateTime.now().toLocal(),
      endedAt: endedAt,
      participantNicknames: participantNicknames,
    );
    await _writeEntry(updated);
    _activeArchivePathsByRoom[updated.roomId] = updated.relativePath;
    return updated;
  }

  Future<ConferenceArchiveEntry> markEnded(
    ConferenceArchiveEntry entry, {
    List<String>? participants,
    List<String>? speakers,
  }) async {
    // End the current session (preserve name)
    final sessions = List<MeetingSession>.from(entry.sessions);
    if (sessions.isNotEmpty && sessions.last.endedAt == null) {
      sessions.last.endedAt = DateTime.now().toLocal();
    }
    final updated = await updateArchive(
      entry,
      participants: participants,
      speakers: speakers,
      endedAt: DateTime.now().toLocal(),
    );
    final withSessions = updated.copyWith(sessions: sessions);
    await _writeEntry(withSessions);
    _activeArchivePathsByRoom.remove(withSessions.roomId);

    // Close and release the NDF storage
    final storage = _activeNdfStorages.remove(withSessions.relativePath);
    if (storage != null) {
      await storage.close();
    }

    return withSessions;
  }

  Future<List<ConferenceArchiveEntry>> listArchives() async {
    final storage = _rootStorage();
    if (!await storage.directoryExists(archiveRoot)) {
      return const <ConferenceArchiveEntry>[];
    }

    final entries = await storage.listDirectory(archiveRoot);
    final archives = <ConferenceArchiveEntry>[];

    for (final entry in entries) {
      if (!entry.isDirectory && entry.name.endsWith('.meeting.ndf')) {
        final loaded = await _loadEntry('$archiveRoot/${entry.name}');
        if (loaded != null) {
          archives.add(await _recalculateCounts(loaded));
        }
      }
    }

    archives.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return archives;
  }

  Future<List<ChatMessage>> loadMessages(
    ConferenceArchiveEntry entry, {
    int limit = defaultTranscriptLimit,
  }) async {
    final storage = await _archiveStorage(entry);
    final content = await storage.readString(_chatTranscriptPath);
    if (content == null || content.trim().isEmpty) {
      return const <ChatMessage>[];
    }

    var messages = ChatService.parseMessageText(content)..sort();
    if (messages.length > limit) {
      messages = messages.sublist(messages.length - limit);
    }

    // Verify NOSTR signatures (same pattern as ChatService.loadMessages)
    for (final msg in messages) {
      if (msg.isSigned) {
        SigningService().verifyMessageSignature(msg, roomId: entry.roomId);
      }
    }

    return messages;
  }

  Future<ConferenceArchiveEntry> saveMessage(
    ConferenceArchiveEntry entry,
    ChatMessage message,
  ) async {
    final storage = await _archiveStorage(entry);
    final transcriptExists = await storage.exists(_chatTranscriptPath);

    final buffer = StringBuffer();
    if (!transcriptExists) {
      buffer.writeln('# Transcript for ${entry.roomName} (${entry.roomId})');
    }
    buffer.writeln();
    buffer.writeln(message.exportAsText());
    await storage.appendString(_chatTranscriptPath, buffer.toString());
    await _flushNdfStorage(entry.relativePath);

    return updateArchive(entry);
  }

  String transcriptAbsolutePath(ConferenceArchiveEntry entry) {
    final absPath = _rootStorage().getAbsolutePath(entry.relativePath);
    return '$absPath!/$_chatTranscriptPath';
  }

  String archiveAbsolutePath(ConferenceArchiveEntry entry) {
    return _rootStorage().getAbsolutePath(entry.relativePath);
  }

  Future<List<StorageEntry>> listArchiveFiles(
    ConferenceArchiveEntry entry,
  ) async {
    final storage = await _archiveStorage(entry);
    return storage.listDirectory(filesDirectoryName);
  }

  Future<List<StorageEntry>> listArchiveRecordings(
    ConferenceArchiveEntry entry,
  ) async {
    final storage = await _archiveStorage(entry);
    return storage.listDirectory(recordingsDirectoryName, recursive: true);
  }

  Future<void> deleteArchive(ConferenceArchiveEntry entry) async {
    _activeArchivePathsByRoom.remove(entry.roomId);

    final storage = _activeNdfStorages.remove(entry.relativePath);
    if (storage != null) {
      // Don't flush — we're deleting
      storage.close().catchError((_) {});
    }
    await _rootStorage().delete(entry.relativePath);
  }

  Future<ConferenceArchiveEntry> deleteRecording(
    ConferenceArchiveEntry entry,
    ConferenceArchiveAsset recording,
  ) async {
    final storage = await _getNdfStorage(entry.relativePath);
    await storage.delete(recording.relativePath);
    await storage.flush();
    return _recalculateCounts(entry);
  }

  Future<ConferenceArchiveEntry> updateTags(
    ConferenceArchiveEntry entry,
    List<String> tags,
  ) async {
    final updated = entry.copyWith(
      tags: _sortedUnique(tags),
      updatedAt: DateTime.now().toLocal(),
    );
    await _writeEntry(updated);
    return updated;
  }

  Future<ConferenceArchiveEntry> renameSession(
    ConferenceArchiveEntry entry,
    String sessionId,
    String name,
  ) async {
    final sessions = entry.sessions.map((s) {
      if (s.id == sessionId) s.name = name.trim().isEmpty ? null : name.trim();
      return s;
    }).toList();
    final updated = entry.copyWith(
      sessions: sessions,
      updatedAt: DateTime.now().toLocal(),
    );
    await _writeEntry(updated);
    return updated;
  }

  Future<List<String>> listAllTags() async {
    final archives = await listArchives();
    final tags = <String>{};
    for (final entry in archives) {
      tags.addAll(entry.tags);
    }
    final sorted = tags.toList()..sort();
    return sorted;
  }

  Future<ConferenceArchiveEntry> refreshArchive(ConferenceArchiveEntry entry) {
    return _recalculateCounts(entry);
  }

  /// Resume a previously ended meeting by adding a new session and clearing
  /// the endedAt timestamp. Returns the updated archive entry.
  Future<ConferenceArchiveEntry> resumeSession(
    ConferenceArchiveEntry entry,
  ) async {
    // Close any unclosed prior session (preserve name).
    final sessions = List<MeetingSession>.from(entry.sessions);
    if (sessions.isNotEmpty && sessions.last.endedAt == null) {
      sessions.last.endedAt = DateTime.now().toLocal();
    }
    final session = MeetingSession.create();
    sessions.add(session);
    final updated = entry.copyWith(
      sessions: sessions,
      clearEndedAt: true,
      updatedAt: DateTime.now().toLocal(),
    );
    await _writeEntry(updated);
    _activeArchivePathsByRoom[updated.roomId] = updated.relativePath;
    return updated;
  }

  /// End the current session within a meeting archive.
  Future<ConferenceArchiveEntry> endCurrentSession(
    ConferenceArchiveEntry entry,
  ) async {
    if (entry.sessions.isEmpty) return entry;
    final sessions = List<MeetingSession>.from(entry.sessions);
    final last = sessions.last;
    if (last.endedAt == null) {
      sessions[sessions.length - 1] = MeetingSession(
        id: last.id,
        startedAt: last.startedAt,
        endedAt: DateTime.now().toLocal(),
      );
    }
    final updated = entry.copyWith(sessions: sessions);
    await _writeEntry(updated);
    return updated;
  }

  Future<ConferenceArchiveEntry?> findArchiveByRoomId(String roomId) async {
    final path = await _latestArchivePathForRoom(roomId);
    if (path == null) {
      return null;
    }
    final entry = await _loadEntry(path);
    if (entry == null) {
      return null;
    }
    return _recalculateCounts(entry);
  }

  Future<String?> readTranscriptByRoomId(String roomId) async {
    final entry = await findArchiveByRoomId(roomId);
    if (entry == null) {
      return null;
    }
    final storage = await _archiveStorage(entry);
    return storage.readString(_chatTranscriptPath);
  }

  Future<void> appendTranscript(
    String roomId,
    String roomName,
    String content,
  ) async {
    final existing = await findArchiveByRoomId(roomId);
    final entry =
        existing ??
        await ensureArchive(
          roomId: roomId,
          roomName: roomName,
          hostCallsign: '',
          localCallsign: '',
          startedAt: DateTime.now().toLocal(),
          hostedByMe: false,
        );
    final storage = await _archiveStorage(entry);
    await storage.appendString(_chatTranscriptPath, content);
    await _flushNdfStorage(entry.relativePath);
  }

  String? transcriptAbsolutePathForRoom(String roomId) {
    final relativePath = _activeArchivePathsByRoom[roomId];
    if (relativePath == null) {
      return null;
    }
    final absPath = _rootStorage().getAbsolutePath(relativePath);
    return '$absPath!/$_chatTranscriptPath';
  }

  Future<ConferenceArchiveEntry> importFileFromExternal(
    ConferenceArchiveEntry entry,
    String externalPath, {
    bool recording = false,
  }) async {
    String directoryName;
    if (recording) {
      // Store recordings in session sub-folders: recordings/<sessionId>/
      final sessionId = entry.sessions.isNotEmpty
          ? entry.sessions.last.id
          : 'default';
      directoryName = '$recordingsDirectoryName/$sessionId';
    } else {
      directoryName = filesDirectoryName;
    }
    final fileName = p.basename(externalPath);
    final storage = await _archiveStorage(entry);
    final uniqueFileName = await _nextUniqueAssetName(
      storage,
      directoryName,
      fileName,
    );
    await storage.copyFromExternal(
      externalPath,
      '$directoryName/$uniqueFileName',
    );
    await _flushNdfStorage(entry.relativePath);

    return updateArchive(entry);
  }

  /// Set a cover image for the meeting archive from an external file path.
  /// The image is stored as `cover.<ext>` at the root of the NDF archive.
  Future<ConferenceArchiveEntry> setCoverImage(
    ConferenceArchiveEntry entry,
    String externalPath,
  ) async {
    final ext = p.extension(externalPath).toLowerCase();
    final coverName = 'cover$ext';
    final storage = await _archiveStorage(entry);

    // Remove any existing cover image
    if (entry.coverImagePath != null) {
      await storage.delete(entry.coverImagePath!);
    }

    await storage.copyFromExternal(externalPath, coverName);
    await _flushNdfStorage(entry.relativePath);

    final updated = entry.copyWith(
      coverImagePath: coverName,
      updatedAt: DateTime.now().toLocal(),
    );
    await _writeEntry(updated);
    return updated;
  }

  Future<NdfPermission?> loadPermissions(ConferenceArchiveEntry entry) async {
    try {
      final storage = await _archiveStorage(entry);
      final json = await storage.readJson('permissions.json');
      if (json == null) return null;
      return NdfPermission.fromJson(json);
    } catch (e) {
      _log.log('ConferenceArchiveService: Error reading permissions for '
          '${entry.relativePath}: $e');
      return null;
    }
  }

  Future<Uint8List?> readArchiveFileBytes(
    ConferenceArchiveEntry entry,
    String relativeFilePath,
  ) async {
    final storage = await _archiveStorage(entry);
    return storage.readBytes(relativeFilePath);
  }

  Future<String?> exportArchiveFileToTemporaryPath(
    ConferenceArchiveEntry entry,
    String relativeFilePath,
  ) async {
    final bytes = await readArchiveFileBytes(entry, relativeFilePath);
    if (bytes == null) {
      return null;
    }
    final tempDir = await getTemporaryDirectory();
    final outputPath = p.join(
      tempDir.path,
      'conference-archive',
      p.basename(relativeFilePath),
    );
    final outputFile = File(outputPath);
    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsBytes(bytes, flush: true);
    return outputFile.path;
  }

  Future<List<StorageEntry>> listArchiveTranscripts(
    ConferenceArchiveEntry entry,
  ) async {
    final storage = await _archiveStorage(entry);
    if (!await storage.directoryExists(transcriptsDirectoryName)) {
      return const <StorageEntry>[];
    }
    return storage.listDirectory(transcriptsDirectoryName);
  }

  Future<String?> readTranscriptForRecording(
    ConferenceArchiveEntry entry,
    String recordingName,
  ) async {
    final baseName = p.basenameWithoutExtension(recordingName);
    final storage = await _archiveStorage(entry);
    return storage.readString('$transcriptsDirectoryName/$baseName.txt');
  }

  Future<void> writeTranscriptForRecording(
    ConferenceArchiveEntry entry,
    String recordingName,
    String content,
  ) async {
    final storage = await _archiveStorage(entry);
    if (!await storage.directoryExists(transcriptsDirectoryName)) {
      await storage.createDirectory(transcriptsDirectoryName);
    }
    final baseName = p.basenameWithoutExtension(recordingName);
    await storage.writeString(
      '$transcriptsDirectoryName/$baseName.txt',
      content,
    );
    await _flushNdfStorage(entry.relativePath);
  }

  Future<String> exportAsNdf(
    ConferenceArchiveEntry entry,
    String outputPath,
  ) async {
    // Archive is already NDF — just copy the file
    await _rootStorage().copyToExternal(entry.relativePath, outputPath);
    return outputPath;
  }

  /// Toggle a reaction on a recording asset.
  Future<ConferenceArchiveEntry> toggleRecordingReaction(
    ConferenceArchiveEntry entry,
    String recordingRelativePath,
    String reactionKey,
    String callsign,
  ) async {
    final normalizedKey = ReactionUtils.normalizeReactionKey(reactionKey);
    final normalizedCallsign = callsign.trim().toUpperCase();
    if (normalizedKey.isEmpty || normalizedCallsign.isEmpty) return entry;

    final recordings = List<ConferenceArchiveAsset>.from(entry.recordings);
    final idx = recordings.indexWhere(
      (r) => r.relativePath == recordingRelativePath,
    );
    if (idx == -1) return entry;

    final recording = recordings[idx];
    final reactions = <String, List<String>>{};
    recording.reactions.forEach((key, users) {
      reactions[key] = List<String>.from(users);
    });

    final currentList = reactions[normalizedKey] ?? <String>[];
    final alreadyReacted =
        currentList.any((u) => u.toUpperCase() == normalizedCallsign);

    // Remove from all reactions (one reaction per user)
    for (final key in reactions.keys.toList()) {
      reactions[key]?.removeWhere((u) => u.toUpperCase() == normalizedCallsign);
      if (reactions[key]?.isEmpty ?? true) reactions.remove(key);
    }

    if (!alreadyReacted) {
      final list = reactions[normalizedKey] ?? <String>[];
      list.add(normalizedCallsign);
      reactions[normalizedKey] = list;
    }

    recordings[idx] = recording.copyWith(reactions: reactions);
    final updated = entry.copyWith(recordings: recordings);
    await _writeEntry(updated);
    return updated;
  }

  /// Increment the view count on a recording asset.
  Future<ConferenceArchiveEntry> incrementViewCount(
    ConferenceArchiveEntry entry,
    String recordingRelativePath,
  ) async {
    final recordings = List<ConferenceArchiveAsset>.from(entry.recordings);
    final idx = recordings.indexWhere(
      (r) => r.relativePath == recordingRelativePath,
    );
    if (idx == -1) return entry;

    recordings[idx] = recordings[idx].copyWith(
      viewCount: recordings[idx].viewCount + 1,
    );
    final updated = entry.copyWith(recordings: recordings);
    await _writeEntry(updated);
    return updated;
  }

  /// Toggle a reaction on a chat message inside the archive.
  Future<(ConferenceArchiveEntry, List<ChatMessage>)> toggleChatReaction(
    ConferenceArchiveEntry entry,
    String timestamp,
    String author,
    String reactionKey,
    String callsign,
  ) async {
    final normalizedKey = ReactionUtils.normalizeReactionKey(reactionKey);
    final normalizedCallsign = callsign.trim().toUpperCase();
    if (normalizedKey.isEmpty || normalizedCallsign.isEmpty) {
      final msgs = await loadMessages(entry, limit: 1 << 20);
      return (entry, msgs);
    }

    final storage = await _archiveStorage(entry);
    final content = await storage.readString(_chatTranscriptPath);
    if (content == null || content.trim().isEmpty) {
      return (entry, const <ChatMessage>[]);
    }

    final messages = ChatService.parseMessageText(content);
    final idx = messages.indexWhere(
      (m) =>
          m.timestamp == timestamp &&
          m.author.toUpperCase() == author.toUpperCase(),
    );
    if (idx == -1) return (entry, messages);

    messages[idx] = _toggleMessageReaction(
      messages[idx],
      normalizedKey,
      normalizedCallsign,
    );

    // Rewrite the entire chat file
    final buffer = StringBuffer();
    buffer.writeln('# Transcript for ${entry.roomName} (${entry.roomId})');
    for (final msg in messages) {
      buffer.writeln();
      buffer.writeln(msg.exportAsText());
    }
    await storage.writeString(_chatTranscriptPath, buffer.toString());
    await _flushNdfStorage(entry.relativePath);

    return (entry, messages);
  }

  /// Convenience wrapper to load cover image bytes from a meeting archive.
  Future<Uint8List?> loadCoverImageBytes(ConferenceArchiveEntry entry) async {
    if (entry.coverImagePath == null) return null;
    return readArchiveFileBytes(entry, entry.coverImagePath!);
  }

  /// Toggle a reaction on a ChatMessage (same algorithm as ChatService).
  static ChatMessage _toggleMessageReaction(
    ChatMessage message,
    String reactionKey,
    String actorCallsign,
  ) {
    final updatedReactions = <String, List<String>>{};
    final normalizedActor = actorCallsign.trim().toUpperCase();

    message.reactions.forEach((key, users) {
      final normalizedUsers = users
          .map((u) => u.trim().toUpperCase())
          .where((u) => u.isNotEmpty)
          .toSet()
          .toList();
      if (normalizedUsers.isNotEmpty) {
        updatedReactions[ReactionUtils.normalizeReactionKey(key)] =
            normalizedUsers;
      }
    });

    final normalizedKey = ReactionUtils.normalizeReactionKey(reactionKey);
    final currentList = updatedReactions[normalizedKey] ?? <String>[];
    final alreadyHasThisReaction =
        currentList.any((u) => u.toUpperCase() == normalizedActor);

    // Remove user from ALL reaction types (one reaction per user)
    for (final key in updatedReactions.keys.toList()) {
      updatedReactions[key]
          ?.removeWhere((u) => u.toUpperCase() == normalizedActor);
      if (updatedReactions[key]?.isEmpty ?? true) {
        updatedReactions.remove(key);
      }
    }

    if (!alreadyHasThisReaction) {
      final list = updatedReactions[normalizedKey] ?? <String>[];
      list.add(normalizedActor);
      updatedReactions[normalizedKey] = list;
    }

    return ChatMessage(
      author: message.author,
      timestamp: message.timestamp,
      content: message.content,
      messageType: message.messageType,
      metadata: message.metadata,
      reactions: updatedReactions,
    );
  }

  // ============ Private ============

  Future<ZipProfileStorage> _archiveStorage(
    ConferenceArchiveEntry entry,
  ) {
    return _getNdfStorage(entry.relativePath);
  }

  Future<ZipProfileStorage> _getNdfStorage(String relativePath) async {
    var storage = _activeNdfStorages[relativePath];
    if (storage != null) return storage;

    final absPath = _rootStorage().getAbsolutePath(relativePath);
    storage = await ZipProfileStorage.open(absPath);
    _activeNdfStorages[relativePath] = storage;
    return storage;
  }

  Future<void> _flushNdfStorage(String relativePath) async {
    final storage = _activeNdfStorages[relativePath];
    if (storage != null && storage.isDirty) {
      await storage.flush();
    }
  }

  Future<ConferenceArchiveEntry?> _loadEntry(String relativePath) async {
    try {
      final storage = await _getNdfStorage(relativePath);
      final json = await storage.readJson(metadataFileName);
      if (json == null) return null;
      final entry = ConferenceArchiveEntry.fromJson(json);
      return entry.copyWith(relativePath: relativePath);
    } catch (e) {
      _log.log('ConferenceArchiveService: Error loading NDF entry '
          '$relativePath: $e');
      return null;
    }
  }

  Future<void> _writeEntry(ConferenceArchiveEntry entry) async {
    final storage = await _getNdfStorage(entry.relativePath);
    await storage.writeJson(metadataFileName, entry.toJson());

    // Also update content/main.json
    final content = MeetingContent.fromArchiveEntry(entry);
    // Preserve chatTranscript and recording IDs from existing content
    final existingJson = await storage.readJson('content/main.json');
    if (existingJson != null) {
      final existing = MeetingContent.fromJson(existingJson);
      content.chatTranscript = existing.chatTranscript;
      content.recordings = existing.recordings;
    }
    content.touch();
    await storage.writeJson('content/main.json', content.toJson());
    await storage.flush();
  }

  Future<ConferenceArchiveEntry> _recalculateCounts(
    ConferenceArchiveEntry entry,
  ) async {
    // Re-read from disk to pick up any out-of-band changes (e.g. tags)
    final fresh = await _loadEntry(entry.relativePath);
    final base = fresh ?? entry;
    final storage = await _archiveStorage(base);

    final files = await storage.listDirectory(filesDirectoryName);
    final recordings = await storage.listDirectory(
      recordingsDirectoryName, recursive: true);

    List<StorageEntry> transcripts = const [];
    if (await storage.directoryExists(transcriptsDirectoryName)) {
      transcripts = await storage.listDirectory(transcriptsDirectoryName);
    }

    final messages = await loadMessages(base, limit: 1 << 20);

    final fileAssets = files
        .where((file) => !file.isDirectory)
        .map(
          (file) => ConferenceArchiveAsset(
            name: file.name,
            relativePath: file.path,
            size: file.size,
            modifiedAt: file.modified,
          ),
        )
        .toList();
    // Build lookup for existing metadata (reactions, viewCount)
    final existingRecMetadata = <String, ConferenceArchiveAsset>{
      for (final r in base.recordings) r.relativePath: r,
    };
    final recordingAssets = recordings
        .where((file) => !file.isDirectory)
        .map((file) {
          final existing = existingRecMetadata[file.path];
          return ConferenceArchiveAsset(
            name: file.name,
            relativePath: file.path,
            size: file.size,
            modifiedAt: file.modified,
            reactions: existing?.reactions ?? const {},
            viewCount: existing?.viewCount ?? 0,
          );
        })
        .toList();
    final transcriptAssets = transcripts
        .where((file) => !file.isDirectory)
        .map(
          (file) => ConferenceArchiveAsset(
            name: file.name,
            relativePath: file.path,
            size: file.size,
            modifiedAt: file.modified,
          ),
        )
        .toList();
    return base.copyWith(
      messageCount: messages.length,
      files: fileAssets,
      recordings: recordingAssets,
      voiceTranscripts: transcriptAssets,
    );
  }

  Future<String?> _latestArchivePathForRoom(String roomId) async {
    final active = _activeArchivePathsByRoom[roomId];
    if (active != null) {
      return active;
    }

    final archives = await listArchives();
    for (final entry in archives) {
      if (entry.roomId == roomId) {
        return entry.relativePath;
      }
    }
    return null;
  }

  Future<String> _nextArchiveFileName(
    ProfileStorage storage, {
    required String roomName,
    required DateTime startedAt,
  }) async {
    final localStart = startedAt.toLocal();
    final datePrefix =
        '${localStart.year.toString().padLeft(4, '0')}-'
        '${localStart.month.toString().padLeft(2, '0')}-'
        '${localStart.day.toString().padLeft(2, '0')}';
    final baseName = _sanitizeName(roomName);
    var candidate = '${baseName}_$datePrefix.meeting.ndf';
    var suffix = 2;
    while (await storage.exists('$archiveRoot/$candidate')) {
      candidate = '${baseName}_${datePrefix}_$suffix.meeting.ndf';
      suffix += 1;
    }
    return candidate;
  }

  Future<String> _nextUniqueAssetName(
    ProfileStorage storage,
    String directoryPath,
    String fileName,
  ) async {
    final extension = p.extension(fileName);
    final baseName = p.basenameWithoutExtension(fileName);
    var candidate = fileName;
    var suffix = 2;
    while (await storage.exists('$directoryPath/$candidate')) {
      candidate = '${baseName}_$suffix$extension';
      suffix += 1;
    }
    return candidate;
  }

  ProfileStorage _rootStorage() {
    final storage = AppService().profileStorage;
    if (storage == null) {
      throw StateError('Profile storage not initialized');
    }
    return storage;
  }

  static String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  /// Generate a default cover image for a meeting archive.
  /// Creates a 1280x720 image with a dark gradient, meeting title, and date.
  static Uint8List generateCoverImage({
    required String roomName,
    required DateTime startedAt,
    String? hostCallsign,
  }) {
    const w = 1280;
    const h = 720;
    final rng = math.Random(roomName.hashCode ^ startedAt.millisecondsSinceEpoch);

    final image = img.Image(width: w, height: h);

    // Seeded accent hue for consistent per-meeting color
    final hue = rng.nextDouble() * 360;
    final accentR = _hslComponent(hue, 0.35, 0.45, 0);
    final accentG = _hslComponent(hue, 0.35, 0.45, 1);
    final accentB = _hslComponent(hue, 0.35, 0.45, 2);

    // Draw vertical gradient background
    for (var y = 0; y < h; y++) {
      final t = y / h;
      final r = (12 + t * accentR * 0.3).round().clamp(0, 255);
      final g = (12 + t * accentG * 0.25).round().clamp(0, 255);
      final b = (18 + t * accentB * 0.4).round().clamp(0, 255);
      for (var x = 0; x < w; x++) {
        image.setPixelRgb(x, y, r, g, b);
      }
    }

    // ── Side decorations (center kept clear for playback controls) ──

    // Subtle radial glows behind each side icon
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        double glow = 0;
        final dlx = (x - w * 0.15) / (w * 0.18);
        final dly = (y - h * 0.36) / (h * 0.32);
        final distL = math.sqrt(dlx * dlx + dly * dly);
        if (distL < 1.0) glow += (1.0 - distL) * 0.10;
        final drx = (x - w * 0.85) / (w * 0.18);
        final dry = (y - h * 0.36) / (h * 0.32);
        final distR = math.sqrt(drx * drx + dry * dry);
        if (distR < 1.0) glow += (1.0 - distR) * 0.10;
        if (glow > 0) {
          final p = image.getPixel(x, y);
          image.setPixelRgb(x, y,
            (p.r + accentR * glow).round().clamp(0, 255),
            (p.g + accentG * glow).round().clamp(0, 255),
            (p.b + accentB * glow).round().clamp(0, 255),
          );
        }
      }
    }

    final hiR = (accentR * 1.4).round().clamp(0, 255);
    final hiG = (accentG * 1.4).round().clamp(0, 255);
    final hiB = (accentB * 1.4).round().clamp(0, 255);
    final loR = (accentR * 0.6).round().clamp(0, 255);
    final loG = (accentG * 0.6).round().clamp(0, 255);
    final loB = (accentB * 0.6).round().clamp(0, 255);

    // ── Left side: Microphone icon ──
    const micX = w * 0.15;
    const micY = h * 0.33;

    // Capsule body (pill / stadium shape)
    _fillRoundedRect(image,
      (micX - 28).round(), (micY - 50).round(),
      (micX + 28).round(), (micY + 50).round(),
      28, accentR, accentG, accentB, 220);
    // Inner highlight on capsule
    _fillRoundedRect(image,
      (micX - 19).round(), (micY - 40).round(),
      (micX + 19).round(), (micY + 40).round(),
      19, hiR, hiG, hiB, 55);
    // Horizontal grille lines for realism
    for (var i = -4; i <= 4; i++) {
      final ly = (micY + i * 10).round();
      _fillRect(image,
        (micX - 21).round(), ly, (micX + 21).round(), ly,
        loR, loG, loB, 110);
    }
    // U-shaped cradle below capsule
    _drawArcBand(image, micX, micY + 50, 40, 5, true,
        accentR, accentG, accentB, 210);
    // Vertical stem
    _fillRect(image,
      (micX - 2).round(), (micY + 90).round(),
      (micX + 2).round(), (micY + 118).round(),
      accentR, accentG, accentB, 210);
    // Horizontal stand base
    _fillRect(image,
      (micX - 22).round(), (micY + 116).round(),
      (micX + 22).round(), (micY + 121).round(),
      accentR, accentG, accentB, 210);

    // Sound wave arcs emanating right from microphone
    for (var i = 0; i < 3; i++) {
      _drawSoundArc(image, micX + 32, micY, 48.0 + i * 24, 3.5,
          accentR, accentG, accentB, 160 - i * 40);
    }

    // ── Right side: Headphones icon ──
    const hpX = w * 0.85;
    const hpY = h * 0.40;

    // Headband arc (top half of ring)
    _drawArcBand(image, hpX, hpY, 76, 7, false,
        accentR, accentG, accentB, 220);
    // Left ear cup
    _fillRoundedRect(image,
      (hpX - 76 - 17).round(), (hpY - 6).round(),
      (hpX - 76 + 17).round(), (hpY + 60).round(),
      9, accentR, accentG, accentB, 220);
    // Left cup inner pad
    _fillRoundedRect(image,
      (hpX - 76 - 12).round(), (hpY + 1).round(),
      (hpX - 76 + 12).round(), (hpY + 53).round(),
      6, hiR, hiG, hiB, 50);
    // Right ear cup
    _fillRoundedRect(image,
      (hpX + 76 - 17).round(), (hpY - 6).round(),
      (hpX + 76 + 17).round(), (hpY + 60).round(),
      9, accentR, accentG, accentB, 220);
    // Right cup inner pad
    _fillRoundedRect(image,
      (hpX + 76 - 12).round(), (hpY + 1).round(),
      (hpX + 76 + 12).round(), (hpY + 53).round(),
      6, hiR, hiG, hiB, 50);

    // Sound wave arcs arriving at headphones (left-facing)
    for (var i = 0; i < 3; i++) {
      _drawSoundArc(image, hpX - 32, hpY + 27, 48.0 + i * 24, 3.5,
          accentR, accentG, accentB, 160 - i * 40, facingLeft: true);
    }

    // Draw title text using img.drawString
    final font = img.arial48;
    final titleLabel = roomName.length > 30
        ? '${roomName.substring(0, 28)}...'
        : roomName;
    final local = startedAt.toLocal();
    final dateLabel = _formatDate(local);
    final hostLabel = hostCallsign != null ? 'Host: $hostCallsign' : '';

    // Center text manually (approximate char width ~24px for arial48)
    final titleX = (w - titleLabel.length * 24) ~/ 2;
    img.drawString(
      image,
      titleLabel,
      font: font,
      x: titleX.clamp(20, w - 40),
      y: (h * 0.58).round(),
      color: img.ColorRgba8(220, 225, 240, 230),
    );

    final smallFont = img.arial24;
    final dateX = (w - dateLabel.length * 12) ~/ 2;
    img.drawString(
      image,
      dateLabel,
      font: smallFont,
      x: dateX.clamp(20, w - 40),
      y: (h * 0.68).round(),
      color: img.ColorRgba8(150, 160, 180, 200),
    );

    if (hostLabel.isNotEmpty) {
      final hostX = (w - hostLabel.length * 12) ~/ 2;
      img.drawString(
        image,
        hostLabel,
        font: smallFont,
        x: hostX.clamp(20, w - 40),
        y: (h * 0.74).round(),
        color: img.ColorRgba8(130, 140, 160, 180),
      );
    }

    return Uint8List.fromList(img.encodeJpg(image, quality: 85));
  }

  /// Convert HSL to RGB component (channel 0=R, 1=G, 2=B).
  static int _hslComponent(double h, double s, double l, int channel) {
    final c = (1.0 - (2 * l - 1).abs()) * s;
    final x = c * (1.0 - ((h / 60) % 2 - 1).abs());
    final m = l - c / 2;
    double r, g, b;
    if (h < 60) {
      r = c; g = x; b = 0;
    } else if (h < 120) {
      r = x; g = c; b = 0;
    } else if (h < 180) {
      r = 0; g = c; b = x;
    } else if (h < 240) {
      r = 0; g = x; b = c;
    } else if (h < 300) {
      r = x; g = 0; b = c;
    } else {
      r = c; g = 0; b = x;
    }
    final values = [(r + m) * 255, (g + m) * 255, (b + m) * 255];
    return values[channel].round().clamp(0, 255);
  }

  /// Fill a solid rectangle.
  static void _fillRect(img.Image image, int x1, int y1, int x2, int y2,
      int r, int g, int b, int a) {
    for (var y = y1; y <= y2; y++) {
      for (var x = x1; x <= x2; x++) {
        if (x >= 0 && x < image.width && y >= 0 && y < image.height) {
          image.setPixelRgba(x, y, r, g, b, a);
        }
      }
    }
  }

  /// Fill a rounded rectangle with circular corners.
  static void _fillRoundedRect(img.Image image,
      int x1, int y1, int x2, int y2,
      double radius, int r, int g, int b, int a) {
    for (var y = y1; y <= y2; y++) {
      for (var x = x1; x <= x2; x++) {
        if (x < 0 || x >= image.width || y < 0 || y >= image.height) continue;
        final inLeft = x < x1 + radius;
        final inRight = x > x2 - radius;
        final inTop = y < y1 + radius;
        final inBottom = y > y2 - radius;
        if ((inLeft || inRight) && (inTop || inBottom)) {
          final cx = inLeft ? x1 + radius : x2 - radius;
          final cy = inTop ? y1 + radius : y2 - radius;
          final dx = x - cx;
          final dy = y - cy;
          if (dx * dx + dy * dy > radius * radius) continue;
        }
        image.setPixelRgba(x, y, r, g, b, a);
      }
    }
  }

  /// Draw a half-circle arc band (ring segment).
  /// [bottomHalf] true = U-shape, false = top-half headband.
  static void _drawArcBand(img.Image image, double cx, double cy,
      double radius, double thickness, bool bottomHalf,
      int r, int g, int b, int a) {
    final inner = radius - thickness / 2;
    final outer = radius + thickness / 2;
    final inner2 = inner * inner;
    final outer2 = outer * outer;
    for (var y = (cy - outer).round(); y <= (cy + outer).round(); y++) {
      for (var x = (cx - outer).round(); x <= (cx + outer).round(); x++) {
        if (x < 0 || x >= image.width || y < 0 || y >= image.height) continue;
        final dx = (x - cx);
        final dy = (y - cy);
        final d2 = dx * dx + dy * dy;
        if (d2 < inner2 || d2 > outer2) continue;
        if (bottomHalf ? dy >= 0 : dy <= 0) {
          image.setPixelRgba(x, y, r, g, b, a);
        }
      }
    }
  }

  /// Draw a sound-wave arc (right-facing by default, ±40° from horizontal).
  static void _drawSoundArc(img.Image image, double cx, double cy,
      double radius, double thickness,
      int r, int g, int b, int a, {bool facingLeft = false}) {
    final inner = radius - thickness / 2;
    final outer = radius + thickness / 2;
    final inner2 = inner * inner;
    final outer2 = outer * outer;
    for (var y = (cy - outer).round(); y <= (cy + outer).round(); y++) {
      for (var x = (cx - outer).round(); x <= (cx + outer).round(); x++) {
        if (x < 0 || x >= image.width || y < 0 || y >= image.height) continue;
        final dx = (x - cx).toDouble();
        final dy = (y - cy).toDouble();
        final d2 = dx * dx + dy * dy;
        if (d2 < inner2 || d2 > outer2) continue;
        // ±40° from horizontal: |dy| < |dx| * tan(40°) ≈ 0.84
        if (facingLeft) {
          if (dx < 0 && dy.abs() < (-dx) * 0.84) {
            image.setPixelRgba(x, y, r, g, b, a);
          }
        } else {
          if (dx > 0 && dy.abs() < dx * 0.84) {
            image.setPixelRgba(x, y, r, g, b, a);
          }
        }
      }
    }
  }
}

List<String> _sortedUnique(Iterable<String> values) {
  final normalized = values
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList();
  normalized.sort();
  return normalized;
}

String _sanitizeName(String roomName) {
  final sanitized = roomName
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|]+'), ' ')
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
  if (sanitized.isEmpty) {
    return 'Meeting';
  }
  return sanitized.length > 48 ? sanitized.substring(0, 48) : sanitized;
}
