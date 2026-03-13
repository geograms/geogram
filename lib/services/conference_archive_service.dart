library;

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/chat_message.dart';
import '../models/conference_archive_entry.dart';
import '../util/zip_storage.dart';
import '../work/models/meeting_content.dart';
import '../work/models/ndf_document.dart';
import '../work/models/ndf_permission.dart';
import 'app_service.dart';
import 'chat_service.dart';
import 'log_service.dart';
import 'profile_storage.dart';

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

    // Write meeting.json for fast loading
    await zipStorage.writeJson(metadataFileName, entry.toJson());
    await zipStorage.flush();

    _activeNdfStorages[relativePath] = zipStorage;
    _activeArchivePathsByRoom[roomId] = relativePath;
    return entry;
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
    // End the current session
    final sessions = List<MeetingSession>.from(entry.sessions);
    if (sessions.isNotEmpty && sessions.last.endedAt == null) {
      final last = sessions.last;
      sessions[sessions.length - 1] = MeetingSession(
        id: last.id,
        startedAt: last.startedAt,
        endedAt: DateTime.now().toLocal(),
      );
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
    return storage.listDirectory(recordingsDirectoryName);
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
    final session = MeetingSession.create();
    final sessions = List<MeetingSession>.from(entry.sessions)..add(session);
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
    final directoryName = recording
        ? recordingsDirectoryName
        : filesDirectoryName;
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
    final recordings = await storage.listDirectory(recordingsDirectoryName);

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
    final recordingAssets = recordings
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
