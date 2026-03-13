library;

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/chat_message.dart';
import '../models/conference_archive_entry.dart';
import '../work/models/meeting_content.dart';
import '../work/models/ndf_document.dart';
import '../work/models/ndf_permission.dart';
import '../work/services/ndf_service.dart';
import 'app_service.dart';
import 'chat_service.dart';
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

  final Map<String, String> _activeArchivePathsByRoom = {};

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

    final folderName = await _nextArchiveFolderName(
      storage,
      roomName: roomName,
      startedAt: startedAt,
    );
    final relativePath = '$archiveRoot/$folderName';
    await storage.createDirectory(relativePath);
    await storage.createDirectory('$relativePath/$chatDirectoryName');
    await storage.createDirectory('$relativePath/$filesDirectoryName');
    await storage.createDirectory('$relativePath/$recordingsDirectoryName');
    await storage.createDirectory('$relativePath/$transcriptsDirectoryName');

    final yearTag = startedAt.toLocal().year.toString();
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
      signalingMode:
          signalingMode ?? (stationMeetUrl != null ? 'station' : 'lan'),
      stationMeetUrl: stationMeetUrl,
      meetUrls: _sortedUnique(meetUrls),
      transcriptRelativePath:
          '$relativePath/$chatDirectoryName/$transcriptFileName',
      messageCount: 0,
      tags: [yearTag],
    );

    await _writeEntry(entry);
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
    final updated = await updateArchive(
      entry,
      participants: participants,
      speakers: speakers,
      endedAt: DateTime.now().toLocal(),
    );
    _activeArchivePathsByRoom.remove(updated.roomId);
    return updated;
  }

  Future<List<ConferenceArchiveEntry>> listArchives() async {
    final storage = _rootStorage();
    if (!await storage.directoryExists(archiveRoot)) {
      return const <ConferenceArchiveEntry>[];
    }

    final entries = await storage.listDirectory(archiveRoot);
    final archives = <ConferenceArchiveEntry>[];
    for (final entry in entries.where((entry) => entry.isDirectory)) {
      final loaded = await _loadEntry('$archiveRoot/${entry.name}');
      if (loaded != null) {
        archives.add(await _recalculateCounts(loaded));
      }
    }

    archives.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return archives;
  }

  Future<List<ChatMessage>> loadMessages(
    ConferenceArchiveEntry entry, {
    int limit = defaultTranscriptLimit,
  }) async {
    final content = await _rootStorage().readString(
      entry.transcriptRelativePath,
    );
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
    final storage = _rootStorage();
    final transcriptPath = entry.transcriptRelativePath;
    final transcriptExists = await storage.exists(transcriptPath);

    final buffer = StringBuffer();
    if (!transcriptExists) {
      buffer.writeln('# Transcript for ${entry.roomName} (${entry.roomId})');
    }
    buffer.writeln();
    buffer.writeln(message.exportAsText());
    await storage.appendString(transcriptPath, buffer.toString());

    return updateArchive(entry);
  }

  String transcriptAbsolutePath(ConferenceArchiveEntry entry) {
    return _rootStorage().getAbsolutePath(entry.transcriptRelativePath);
  }

  String archiveAbsolutePath(ConferenceArchiveEntry entry) {
    return _rootStorage().getAbsolutePath(entry.relativePath);
  }

  Future<List<StorageEntry>> listArchiveFiles(ConferenceArchiveEntry entry) {
    return _archiveStorage(entry).listDirectory(filesDirectoryName);
  }

  Future<List<StorageEntry>> listArchiveRecordings(
    ConferenceArchiveEntry entry,
  ) {
    return _archiveStorage(entry).listDirectory(recordingsDirectoryName);
  }

  Future<void> deleteArchive(ConferenceArchiveEntry entry) async {
    final storage = _rootStorage();
    _activeArchivePathsByRoom.remove(entry.roomId);
    await storage.deleteDirectory(entry.relativePath, recursive: true);
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
    return _rootStorage().readString(entry.transcriptRelativePath);
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
    final storage = _rootStorage();
    await storage.appendString(entry.transcriptRelativePath, content);
  }

  String? transcriptAbsolutePathForRoom(String roomId) {
    final relativePath = _activeArchivePathsByRoom[roomId];
    if (relativePath == null) {
      return null;
    }
    return _rootStorage().getAbsolutePath(
      '$relativePath/$chatDirectoryName/$transcriptFileName',
    );
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
    final uniqueFileName = await _nextUniqueAssetName(
      _archiveStorage(entry),
      directoryName,
      fileName,
    );
    await _archiveStorage(
      entry,
    ).copyFromExternal(externalPath, '$directoryName/$uniqueFileName');
    return updateArchive(entry);
  }

  Future<Uint8List?> readArchiveFileBytes(
    ConferenceArchiveEntry entry,
    String relativeFilePath,
  ) {
    return _archiveStorage(entry).readBytes(relativeFilePath);
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
    final storage = _archiveStorage(entry);
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
    return _archiveStorage(entry).readString(
      '$transcriptsDirectoryName/$baseName.txt',
    );
  }

  Future<void> writeTranscriptForRecording(
    ConferenceArchiveEntry entry,
    String recordingName,
    String content,
  ) async {
    final storage = _archiveStorage(entry);
    if (!await storage.directoryExists(transcriptsDirectoryName)) {
      await storage.createDirectory(transcriptsDirectoryName);
    }
    final baseName = p.basenameWithoutExtension(recordingName);
    await storage.writeString(
      '$transcriptsDirectoryName/$baseName.txt',
      content,
    );
  }

  Future<String> exportAsNdf(
    ConferenceArchiveEntry entry,
    String outputPath,
  ) async {
    // Lazy-import to avoid circular deps at load time
    final ndfService = _getNdfService();

    final metadata = NdfDocument.create(
      type: NdfDocumentType.meeting,
      title: entry.roomName,
      description:
          'Meeting archive from ${_formatDate(entry.startedAt)}',
    );

    final permissions = NdfPermission.create(
      documentId: metadata.id,
      ownerNpub: '',
      ownerCallsign: entry.localCallsign,
    );

    // Build MeetingContent from archive entry
    final meetingContent = MeetingContent(
      id: 'meeting-${entry.startedAt.millisecondsSinceEpoch.toRadixString(36)}',
      title: entry.roomName,
      created: entry.startedAt,
      modified: entry.updatedAt,
      roomId: entry.roomId,
      hostCallsign: entry.hostCallsign,
      localCallsign: entry.localCallsign,
      signalingMode: entry.signalingMode,
      participants: List.from(entry.participants),
      speakers: List.from(entry.speakers),
      tags: List.from(entry.tags),
    );

    // Create recordings list and collect video data
    final recordings = <MeetingRecording>[];
    final videoAssets = <String, Uint8List>{};

    for (final rec in entry.recordings) {
      final recId = 'rec-${rec.name.hashCode.toRadixString(36)}';
      final recording = MeetingRecording(
        id: recId,
        title: rec.name,
        recordedAt: rec.modifiedAt ?? entry.startedAt,
        durationMs: 0,
        videoFile: 'video/$recId.mp4',
        fileSize: rec.size,
      );

      // Check for transcript
      final transcript = await readTranscriptForRecording(entry, rec.name);
      if (transcript != null) {
        recording.transcript = MeetingTranscript(
          text: transcript,
          model: 'whisper',
          transcribedAt: DateTime.now(),
        );
      }

      recordings.add(recording);
      meetingContent.addRecording(recId);

      // Read video bytes
      final videoBytes = await readArchiveFileBytes(entry, rec.relativePath);
      if (videoBytes != null) {
        videoAssets['assets/video/$recId.mp4'] = videoBytes;
      }
    }

    // Create NDF document
    await ndfService.createDocument(
      outputPath: outputPath,
      metadata: metadata,
      permissions: permissions,
      mainContent: meetingContent.toJson(),
    );

    // Add recording metadata files
    final recordingFiles = <String, String>{};
    for (final rec in recordings) {
      recordingFiles['content/recordings/${rec.id}.json'] = rec.toJsonString();
    }
    if (recordingFiles.isNotEmpty) {
      await ndfService.updateArchiveFilesPublic(outputPath, recordingFiles);
    }

    // Add video assets
    if (videoAssets.isNotEmpty) {
      await ndfService.updateArchiveFilesBytesPublic(outputPath, videoAssets);
    }

    return outputPath;
  }

  // Lazy NDF service getter to avoid import issues
  NdfService? _ndfServiceCache;
  NdfService _getNdfService() {
    return _ndfServiceCache ??= NdfService();
  }

  static String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  Future<ConferenceArchiveEntry?> _loadEntry(String relativePath) async {
    final json = await _rootStorage().readJson(
      '$relativePath/$metadataFileName',
    );
    if (json == null) {
      return null;
    }
    return ConferenceArchiveEntry.fromJson(json);
  }

  Future<void> _writeEntry(ConferenceArchiveEntry entry) {
    return _rootStorage().writeJson(
      '${entry.relativePath}/$metadataFileName',
      entry.toJson(),
    );
  }

  Future<ConferenceArchiveEntry> _recalculateCounts(
    ConferenceArchiveEntry entry,
  ) async {
    // Re-read from disk to pick up any out-of-band changes (e.g. tags)
    final fresh = await _loadEntry(entry.relativePath);
    final base = fresh ?? entry;
    final files = await listArchiveFiles(base);
    final recordings = await listArchiveRecordings(base);
    final transcripts = await listArchiveTranscripts(base);
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

  Future<String> _nextArchiveFolderName(
    ProfileStorage storage, {
    required String roomName,
    required DateTime startedAt,
  }) async {
    final localStart = startedAt.toLocal();
    final datePrefix =
        '${localStart.year.toString().padLeft(4, '0')}-'
        '${localStart.month.toString().padLeft(2, '0')}-'
        '${localStart.day.toString().padLeft(2, '0')}';
    final baseName = _sanitizeFolderName(roomName);
    var candidate = '${datePrefix}_$baseName';
    var suffix = 2;
    while (await storage.directoryExists('$archiveRoot/$candidate')) {
      candidate = '${datePrefix}_${baseName}_$suffix';
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

  ProfileStorage _archiveStorage(ConferenceArchiveEntry entry) {
    return ScopedProfileStorage(_rootStorage(), entry.relativePath);
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

String _sanitizeFolderName(String roomName) {
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
