/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Email Service - Manages email threads across multiple stations
 *
 * NOTE: All file operations now use ProfileStorage abstraction.
 * Never use File() or Directory() directly in this service.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';

import '../models/email_account.dart';
import '../models/email_message.dart';
import '../models/email_thread.dart';
import '../util/backup_encryption.dart';
import '../util/email_format.dart';
import '../util/event_bus.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import 'app_service.dart';
import 'dm_notification_service.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'profile_storage.dart';
import 'signing_service.dart';
import 'station_service.dart';
import 'websocket_service.dart';

/// Event for email changes
class EmailChangeEvent {
  final String station;
  final String threadId;
  final EmailChangeType type;

  EmailChangeEvent(this.station, this.threadId, this.type);
}

enum EmailChangeType { created, updated, deleted, statusChanged, received }

class _OutgoingAttachment {
  final String name;
  final String contentB64;
  final int sizeBytes;

  _OutgoingAttachment({
    required this.name,
    required this.contentB64,
    required this.sizeBytes,
  });
}

class _IncomingAttachment {
  final String name;
  final Uint8List bytes;

  _IncomingAttachment({required this.name, required this.bytes});
}

/// Service for managing emails across multiple stations
class EmailService {
  static final EmailService _instance = EmailService._internal();
  factory EmailService() => _instance;
  EmailService._internal();

  static const int _maxOutgoingMessageSizeBytes = 10 * 1024 * 1024;

  /// Profile storage abstraction - MUST be set before using the service
  late ProfileStorage _storage;
  bool _hasStorage = false;
  String? _storageForCallsign;

  /// Connected email accounts (station -> account)
  final Map<String, EmailAccount> _accounts = {};

  /// Cached threads by station and folder
  final Map<String, Map<String, List<EmailThread>>> _threadCache = {};

  /// Stream controller for email events
  final StreamController<EmailChangeEvent> _eventController =
      StreamController<EmailChangeEvent>.broadcast();

  /// Stream of email change events
  Stream<EmailChangeEvent> get onEmailChange => _eventController.stream;

  /// Whether the service is initialized
  bool _initialized = false;

  /// The callsign for which the service is currently initialized
  String? _initializedForCallsign;

  /// Set the storage implementation
  void setStorage(ProfileStorage storage) {
    _storage = storage;
    _hasStorage = true;
    try {
      _storageForCallsign = ProfileService().getProfile().callsign;
    } catch (_) {
      _storageForCallsign = null;
    }
    // Reset initialization when storage changes
    _initialized = false;
    _initializedForCallsign = null;
    _frequentContacts = null;
  }

  /// Configure storage from the active profile's email collection.
  ///
  /// Uses ProfileStorage/ScopedProfileStorage only (supports encrypted profiles).
  Future<void> _configureStorageForCallsign(String callsign) async {
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null) {
      throw StateError(
        'EmailService: profile storage unavailable for $callsign',
      );
    }

    final emailAppPath =
        AppService().getAppByType('email')?.storagePath ??
        profileStorage.getAbsolutePath('email');

    final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
      profileStorage,
      emailAppPath,
    );
    setStorage(scopedStorage);
    _storageForCallsign = callsign;
    LogService().log(
      'EmailService: storage configured for $callsign at $emailAppPath',
    );
  }

  /// Initialize email service
  Future<void> initialize() async {
    final profile = ProfileService().getProfile();
    final currentCallsign = profile.callsign;

    // Auto-bind storage for the active profile if not configured yet, or if
    // profile switched and stale storage is still bound.
    if (!_hasStorage || _storageForCallsign != currentCallsign) {
      await _configureStorageForCallsign(currentCallsign);
    }

    // Re-initialize if profile changed
    if (_initialized && _initializedForCallsign != currentCallsign) {
      _initialized = false;
      _frequentContacts = null; // Clear cached contacts for new profile
    }

    if (_initialized) return;

    try {
      await _ensureDirectoryStructure();
      _initializedForCallsign = currentCallsign;
      _initialized = true;
    } catch (e) {
      LogService().log('EmailService: initialization failed: $e');
      rethrow;
    }
  }

  /// Ensure base directory structure exists (unified folders)
  Future<void> _ensureDirectoryStructure() async {
    final dirs = [
      '',
      'inbox',
      'outbox',
      'sent',
      'spam',
      'drafts',
      'garbage',
      'archive',
      'labels',
    ];

    for (final dir in dirs) {
      await _storage.createDirectory(dir);
    }
  }

  /// Register an email account for a station
  Future<void> registerAccount(EmailAccount account) async {
    _accounts[account.station] = account;
    // Unified folders are created in _ensureDirectoryStructure()
  }

  /// Unregister an email account
  void unregisterAccount(String station) {
    final account = _accounts[station];
    if (account != null) {
      account.isConnected = false;
    }
  }

  /// Get all registered accounts
  List<EmailAccount> get accounts => _accounts.values.toList();

  /// Get account for a specific station
  EmailAccount? getAccount(String station) => _accounts[station];

  /// Get connected accounts only
  List<EmailAccount> get connectedAccounts =>
      _accounts.values.where((a) => a.isConnected).toList();

  /// Set account connection status
  void setAccountConnected(String station, bool connected) {
    final account = _accounts[station];
    if (account != null) {
      account.isConnected = connected;
    }
  }

  // ============================================================
  // Thread Operations
  // ============================================================

  /// Create a new draft thread
  Future<EmailThread> createDraft({
    required String from,
    required List<String> to,
    required String subject,
    List<String>? cc,
    List<String>? bcc,
    String? station,
  }) async {
    final thread = EmailThread.draft(
      from: from,
      to: to,
      subject: subject,
      cc: cc,
      bcc: bcc,
      station: station,
    );

    await saveThread(thread);
    return thread;
  }

  /// Save a thread to disk
  Future<void> saveThread(EmailThread thread) async {
    await initialize();

    final relativePath = EmailFormat.getThreadPath(thread);

    // Ensure all parent directories exist (including year subdirectories)
    await _storage.createDirectory(relativePath);

    // Write thread.md
    final content = EmailFormat.export(thread);
    final filePath = '$relativePath/thread.md';
    await _storage.writeString(filePath, content);

    thread.folderPath = relativePath;

    // Notify listeners
    _eventController.add(
      EmailChangeEvent(
        thread.station,
        thread.threadId,
        EmailChangeType.updated,
      ),
    );
  }

  /// Get the full folder path for a thread (for attachments)
  Future<String?> getThreadFolderPath(EmailThread thread) async {
    await initialize();
    final relativePath = thread.folderPath ?? EmailFormat.getThreadPath(thread);
    return _storage.getAbsolutePath(relativePath);
  }

  // ============ Attachment Operations ============

  /// Whether the underlying storage is encrypted
  bool get isEncryptedStorage => _hasStorage && _storage.isEncrypted;

  /// Write attachment bytes to a thread's folder via ProfileStorage.
  Future<void> writeAttachment(
    EmailThread thread,
    String filename,
    Uint8List bytes,
  ) async {
    await initialize();
    final relativePath = thread.folderPath ?? EmailFormat.getThreadPath(thread);
    await _storage.writeBytes('$relativePath/$filename', bytes);
  }

  /// Read attachment bytes from a thread's folder via ProfileStorage.
  Future<Uint8List?> readAttachmentBytes(
    EmailThread thread,
    String filename,
  ) async {
    await initialize();
    final relativePath = thread.folderPath ?? EmailFormat.getThreadPath(thread);
    return _storage.readBytes('$relativePath/$filename');
  }

  /// Export an attachment to a real file path for opening in external apps.
  ///
  /// For filesystem storage, returns the direct path (no copy needed).
  /// For encrypted storage, extracts to a temp directory first.
  Future<String?> exportAttachmentToTemp(
    EmailThread thread,
    String filename,
  ) async {
    await initialize();
    final relativePath = thread.folderPath ?? EmailFormat.getThreadPath(thread);
    final fileRelPath = '$relativePath/$filename';

    if (!_storage.isEncrypted) {
      return _storage.getAbsolutePath(fileRelPath);
    }

    // Encrypted: extract to temp directory
    final tempDir = Directory.systemTemp.path;
    final tempPath = '$tempDir/geogram_email_temp/$filename';
    await Directory('$tempDir/geogram_email_temp').create(recursive: true);
    try {
      await _storage.copyToExternal(fileRelPath, tempPath);
      return tempPath;
    } catch (e) {
      LogService().log('Error exporting attachment to temp: $e');
      return null;
    }
  }

  /// Load a thread from disk
  Future<EmailThread?> loadThread(String threadPath) async {
    await initialize();

    final filePath = '$threadPath/thread.md';

    try {
      final content = await _storage.readString(filePath);
      if (content == null) return null;

      final thread = EmailFormat.parse(content);
      if (thread != null) {
        thread.folderPath = threadPath;
      }
      return thread;
    } catch (e) {
      print('Error loading thread: $e');
      return null;
    }
  }

  /// List threads in a folder (unified folder structure)
  Future<List<EmailThread>> listThreads(String folder) async {
    await initialize();

    final threads = <EmailThread>[];

    try {
      if (!await _storage.directoryExists(folder)) return threads;

      // Handle year subdirectories for inbox/sent/spam/garbage
      if (folder == 'inbox' ||
          folder == 'sent' ||
          folder == 'spam' ||
          folder == 'garbage') {
        final yearEntries = await _storage.listDirectory(folder);
        for (final yearEntry in yearEntries) {
          if (yearEntry.isDirectory) {
            final threadEntries = await _storage.listDirectory(yearEntry.path);
            for (final threadEntry in threadEntries) {
              if (threadEntry.isDirectory) {
                final thread = await _loadThreadFromRelativePath(
                  threadEntry.path,
                );
                if (thread != null) threads.add(thread);
              }
            }
          }
        }
      } else {
        // Outbox and drafts don't have year subdirectories
        final entries = await _storage.listDirectory(folder);
        for (final entry in entries) {
          if (entry.isDirectory) {
            final thread = await _loadThreadFromRelativePath(entry.path);
            if (thread != null) threads.add(thread);
          }
        }
      }

      // Sort by last message time (newest first)
      threads.sort();
    } catch (e) {
      print('Error listing threads: $e');
    }

    return threads;
  }

  /// Load thread from relative path
  Future<EmailThread?> _loadThreadFromRelativePath(String relativePath) async {
    final filePath = '$relativePath/thread.md';
    try {
      final content = await _storage.readString(filePath);
      if (content == null) return null;

      final thread = EmailFormat.parse(content);
      if (thread != null) {
        thread.folderPath = relativePath;
      }
      return thread;
    } catch (e) {
      return null;
    }
  }

  /// Find an existing thread by threadId across inbox and sent folders
  Future<EmailThread?> _findThreadById(String threadId) async {
    // Search inbox and sent folders for matching threadId
    for (final folder in ['inbox', 'sent']) {
      final threads = await listThreads(folder);
      for (final thread in threads) {
        if (thread.threadId == threadId) {
          return thread;
        }
      }
    }
    return null;
  }

  /// Get inbox threads (unified)
  Future<List<EmailThread>> getInbox() => listThreads('inbox');

  /// Get sent threads (unified)
  Future<List<EmailThread>> getSent() => listThreads('sent');

  /// Get outbox threads (unified)
  Future<List<EmailThread>> getOutbox() => listThreads('outbox');

  /// Get draft threads
  Future<List<EmailThread>> getDrafts() => listThreads('drafts');

  /// Get spam threads (unified)
  Future<List<EmailThread>> getSpam() => listThreads('spam');

  /// Get deleted threads
  Future<List<EmailThread>> getGarbage() => listThreads('garbage');

  /// Get archived threads
  Future<List<EmailThread>> getArchive() => listThreads('archive');

  // ============================================================
  // Message Operations
  // ============================================================

  /// Add a message to a thread
  Future<void> addMessage(EmailThread thread, EmailMessage message) async {
    thread.addMessage(message);
    await saveThread(thread);
  }

  /// Create and add a signed message
  Future<EmailMessage> createSignedMessage({
    required EmailThread thread,
    required String content,
    Map<String, String>? metadata,
  }) async {
    final profile = ProfileService().getProfile();

    final message = EmailMessage.now(
      author: profile.callsign,
      content: content,
      metadata: metadata,
    );

    // Add NOSTR identity to metadata
    if (profile.npub != null) {
      message.metadata['npub'] = profile.npub!;
    }

    // Sign the message content using NOSTR event signing
    final signingService = SigningService();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Create a NOSTR event for the message
    final event = NostrEvent(
      pubkey: profile.npub != null ? NostrCrypto.decodeNpub(profile.npub!) : '',
      createdAt: now,
      kind: 1, // Text note
      tags: [
        ['t', 'email'],
        ['thread_id', thread.threadId],
        ['callsign', profile.callsign],
      ],
      content: content,
    );

    // Sign the event
    final signedEvent = await signingService.signEvent(event, profile);
    if (signedEvent != null && signedEvent.sig != null) {
      message.metadata['signature'] = signedEvent.sig!;
      if (signedEvent.id != null) {
        message.metadata['event_id'] = signedEvent.id!;
      }
      message.metadata['created_at'] = now.toString();
    }

    thread.addMessage(message);
    await saveThread(thread);

    return message;
  }

  // ============================================================
  // Status Operations
  // ============================================================

  /// Move thread to sent (after successful delivery)
  Future<void> markAsSent(EmailThread thread) async {
    if (thread.status == EmailStatus.sent) return;

    // Delete from current location
    await _deleteThreadFiles(thread);

    // Update status and save to new location
    thread.status = EmailStatus.sent;
    await saveThread(thread);

    _eventController.add(
      EmailChangeEvent(
        thread.station,
        thread.threadId,
        EmailChangeType.statusChanged,
      ),
    );
  }

  /// Move thread to outbox (pending delivery)
  Future<void> markAsPending(EmailThread thread) async {
    if (thread.status == EmailStatus.pending) return;

    await _deleteThreadFiles(thread);
    thread.status = EmailStatus.pending;
    await saveThread(thread);

    _eventController.add(
      EmailChangeEvent(
        thread.station,
        thread.threadId,
        EmailChangeType.statusChanged,
      ),
    );
  }

  /// Move thread to spam
  Future<void> markAsSpam(EmailThread thread) async {
    if (thread.status == EmailStatus.spam) return;

    await _deleteThreadFiles(thread);
    thread.status = EmailStatus.spam;
    await saveThread(thread);

    _eventController.add(
      EmailChangeEvent(
        thread.station,
        thread.threadId,
        EmailChangeType.statusChanged,
      ),
    );
  }

  /// Move thread to garbage
  Future<void> deleteThread(EmailThread thread) async {
    if (thread.status == EmailStatus.deleted) return;

    await _deleteThreadFiles(thread);
    thread.status = EmailStatus.deleted;
    await saveThread(thread);

    _eventController.add(
      EmailChangeEvent(
        thread.station,
        thread.threadId,
        EmailChangeType.deleted,
      ),
    );
  }

  /// Permanently delete thread
  Future<void> permanentlyDelete(EmailThread thread) async {
    await _deleteThreadFiles(thread);

    _eventController.add(
      EmailChangeEvent(
        thread.station,
        thread.threadId,
        EmailChangeType.deleted,
      ),
    );
  }

  /// Delete a single message from a thread. Returns true if the entire
  /// thread was removed because no messages remained.
  Future<bool> deleteMessage(EmailThread thread, EmailMessage message) async {
    final beforeLength = thread.messages.length;
    thread.messages.removeWhere(
      (m) => m.timestamp == message.timestamp && m.author == message.author,
    );
    final removed = beforeLength - thread.messages.length;

    if (removed == 0) return false;

    if (thread.messages.isEmpty) {
      await deleteThread(thread);
      return true;
    }

    await saveThread(thread);
    return false;
  }

  /// Move thread to archive
  Future<void> archiveThread(EmailThread thread) async {
    if (thread.status == EmailStatus.archived) return;

    await _deleteThreadFiles(thread);
    thread.status = EmailStatus.archived;
    await saveThread(thread);

    _eventController.add(
      EmailChangeEvent(
        thread.station,
        thread.threadId,
        EmailChangeType.statusChanged,
      ),
    );
  }

  /// Move thread to a specific status/folder
  Future<void> moveThread(EmailThread thread, EmailStatus targetStatus) async {
    if (thread.status == targetStatus) return;

    await _deleteThreadFiles(thread);
    thread.status = targetStatus;
    await saveThread(thread);

    _eventController.add(
      EmailChangeEvent(
        thread.station,
        thread.threadId,
        EmailChangeType.statusChanged,
      ),
    );
  }

  /// Restore thread from trash/spam back to inbox
  Future<void> restoreThread(EmailThread thread) async {
    await moveThread(thread, EmailStatus.received);
  }

  /// Delete thread files from current location
  Future<void> _deleteThreadFiles(EmailThread thread) async {
    if (thread.folderPath == null) return;

    try {
      if (await _storage.directoryExists(thread.folderPath!)) {
        await _storage.deleteDirectory(thread.folderPath!, recursive: true);
      }
    } catch (e) {
      print('Error deleting thread files: $e');
    }
  }

  // ============================================================
  // Labels
  // ============================================================

  /// Add label to thread
  Future<void> addLabel(EmailThread thread, String label) async {
    if (thread.labels.contains(label)) return;

    thread.labels = [...thread.labels, label];
    await saveThread(thread);
    await _updateLabelRefs(label, thread, add: true);
  }

  /// Remove label from thread
  Future<void> removeLabel(EmailThread thread, String label) async {
    if (!thread.labels.contains(label)) return;

    thread.labels = thread.labels.where((l) => l != label).toList();
    await saveThread(thread);
    await _updateLabelRefs(label, thread, add: false);
  }

  /// Update label refs.json
  Future<void> _updateLabelRefs(
    String label,
    EmailThread thread, {
    required bool add,
  }) async {
    final labelPath = 'labels/$label';
    final refsPath = '$labelPath/refs.json';

    await _storage.createDirectory(labelPath);

    Map<String, dynamic> refs;

    try {
      final content = await _storage.readString(refsPath);
      if (content != null) {
        refs = jsonDecode(content) as Map<String, dynamic>;
      } else {
        refs = {'label': label, 'threads': []};
      }
    } catch (e) {
      refs = {'label': label, 'threads': []};
    }

    final threads = (refs['threads'] as List).cast<String>();

    if (add) {
      if (!threads.contains(thread.folderPath)) {
        threads.add(thread.folderPath!);
      }
    } else {
      threads.remove(thread.folderPath);
    }

    refs['threads'] = threads;

    final content = const JsonEncoder.withIndent('  ').convert(refs);
    await _storage.writeString(refsPath, content);
  }

  /// Get all labels
  Future<List<String>> getLabels() async {
    await initialize();

    final labels = <String>[];

    try {
      if (!await _storage.directoryExists('labels')) return labels;

      final entries = await _storage.listDirectory('labels');
      for (final entry in entries) {
        if (entry.isDirectory) {
          labels.add(entry.name);
        }
      }

      labels.sort();
    } catch (e) {
      print('Error getting labels: $e');
    }

    return labels;
  }

  /// Create a new label
  Future<void> createLabel(String label) async {
    await initialize();

    final labelPath = 'labels/$label';
    await _storage.createDirectory(labelPath);

    // Create empty refs.json
    final refsPath = '$labelPath/refs.json';
    final content = '{"label": "$label", "threads": []}';
    await _storage.writeString(refsPath, content);
  }

  /// Delete a label
  Future<void> deleteLabel(String label) async {
    await initialize();

    final labelPath = 'labels/$label';

    try {
      if (await _storage.directoryExists(labelPath)) {
        await _storage.deleteDirectory(labelPath, recursive: true);
      }
    } catch (e) {
      print('Error deleting label: $e');
    }
  }

  /// Get threads with a specific label
  Future<List<EmailThread>> getThreadsByLabel(String label) async {
    final threads = <EmailThread>[];
    final refsPath = 'labels/$label/refs.json';

    try {
      final content = await _storage.readString(refsPath);
      if (content == null) return threads;

      final refs = jsonDecode(content) as Map<String, dynamic>;
      final threadPaths = (refs['threads'] as List).cast<String>();

      for (final path in threadPaths) {
        final thread = await loadThread(path);
        if (thread != null) {
          threads.add(thread);
        }
      }

      threads.sort();
    } catch (e) {
      print('Error getting threads by label: $e');
    }

    return threads;
  }

  // ============================================================
  // Config
  // ============================================================

  /// Save email config
  Future<void> saveConfig(Map<String, dynamic> config) async {
    await initialize();

    final content = const JsonEncoder.withIndent('  ').convert(config);
    await _storage.writeString('config.json', content);
  }

  /// Load email config
  Future<Map<String, dynamic>> loadConfig() async {
    await initialize();

    try {
      final content = await _storage.readString('config.json');
      if (content == null) return {};

      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      return {};
    }
  }

  // ============================================================
  // WebSocket Send Operations
  // ============================================================

  /// Send a thread via WebSocket to the station relay
  Future<bool> sendViaWebSocket(EmailThread thread) async {
    final ws = WebSocketService();

    if (!ws.isConnected) {
      LogService().log('WebSocket not connected, cannot send email');
      EventBus().fire(
        EmailNotificationEvent(
          message: 'Cannot send: Not connected to station',
          action: 'failed',
          threadId: thread.threadId,
          recipient: thread.to.isNotEmpty ? thread.to.first : null,
        ),
      );
      return false;
    }

    try {
      final profile = ProfileService().getProfile();
      final content = EmailFormat.export(thread);
      final contentBytes = utf8.encode(content);
      final outgoingAttachments = await _buildOutgoingAttachmentPayload(thread);
      final attachmentsSizeBytes = outgoingAttachments.fold<int>(
        0,
        (sum, attachment) => sum + attachment.sizeBytes,
      );
      final totalPayloadSizeBytes = contentBytes.length + attachmentsSizeBytes;

      if (totalPayloadSizeBytes > _maxOutgoingMessageSizeBytes) {
        final totalMb = (totalPayloadSizeBytes / (1024 * 1024)).toStringAsFixed(
          2,
        );
        final limitMb = (_maxOutgoingMessageSizeBytes / (1024 * 1024))
            .toStringAsFixed(0);
        final reason =
            'Message size $totalMb MB exceeds $limitMb MB limit (content + attachments)';
        LogService().log('EmailService: $reason');
        EventBus().fire(
          EmailNotificationEvent(
            message: 'Cannot send: $reason',
            action: 'failed',
            threadId: thread.threadId,
            recipient: thread.to.isNotEmpty ? thread.to.first : null,
          ),
        );
        return false;
      }

      // Create NOSTR event for the email
      final event = NostrEvent(
        pubkey: profile.npub != null
            ? NostrCrypto.decodeNpub(profile.npub!)
            : '',
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 30078, // Private direct message / email
        tags: [
          ['t', 'email'],
          ['thread_id', thread.threadId],
          ['subject', thread.subject],
        ],
        content: content,
      );

      // Sign the event
      final signedEvent = await SigningService().signEvent(event, profile);

      // Build the message
      final message = <String, dynamic>{
        'type': 'email_send',
        'thread_id': thread.threadId,
        'to': thread.to,
        'cc': thread.cc,
        'subject': thread.subject,
        'content': base64Encode(contentBytes),
        'event': signedEvent?.toJson(),
        'total_size_bytes': totalPayloadSizeBytes,
      };
      if (outgoingAttachments.isNotEmpty) {
        message['attachments'] = outgoingAttachments
            .map(
              (attachment) => {
                'name': attachment.name,
                'content': attachment.contentB64,
              },
            )
            .toList();
      }

      // Send via WebSocket
      ws.send(message);

      // Fire pending notification - actual delivery confirmed via DSN
      EventBus().fire(
        EmailNotificationEvent(
          message: 'Email queued, awaiting delivery...',
          action: 'pending',
          threadId: thread.threadId,
          recipient: thread.to.isNotEmpty ? thread.to.first : null,
        ),
      );

      return true;
    } catch (e) {
      LogService().log('Error sending email via WebSocket: $e');
      EventBus().fire(
        EmailNotificationEvent(
          message: 'Failed to send: $e',
          action: 'failed',
          threadId: thread.threadId,
          recipient: thread.to.isNotEmpty ? thread.to.first : null,
        ),
      );
      return false;
    }
  }

  Future<List<_OutgoingAttachment>> _buildOutgoingAttachmentPayload(
    EmailThread thread,
  ) async {
    final latestMessage = thread.messages.isNotEmpty
        ? thread.messages.last
        : null;
    final attachmentNames = _extractAttachmentNames(latestMessage);
    if (attachmentNames.isEmpty) return [];

    final payload = <_OutgoingAttachment>[];
    for (final filename in attachmentNames) {
      final bytes = await readAttachmentBytes(thread, filename);
      if (bytes == null || bytes.isEmpty) {
        LogService().log(
          'EmailService: Attachment missing or empty in thread ${thread.threadId}: $filename',
        );
        continue;
      }
      payload.add(
        _OutgoingAttachment(
          name: filename,
          contentB64: base64Encode(bytes),
          sizeBytes: bytes.length,
        ),
      );
    }
    return payload;
  }

  Set<String> _extractAttachmentNames(EmailMessage? message) {
    if (message == null) return <String>{};

    final names = <String>{};
    final file = message.getMeta('file');
    final image = message.getMeta('image');
    final voice = message.getMeta('voice');
    final files = message.getMeta('files');

    if (file != null && file.isNotEmpty) names.add(file);
    if (image != null && image.isNotEmpty) names.add(image);
    if (voice != null && voice.isNotEmpty) names.add(voice);
    if (files != null && files.isNotEmpty) {
      for (final item in files.split(',')) {
        final trimmed = item.trim();
        if (trimmed.isNotEmpty) names.add(trimmed);
      }
    }

    return names;
  }

  /// Process outbox - attempt to send all pending emails
  /// Note: Emails stay in outbox until DSN confirmation from station
  Future<void> processOutbox() async {
    final pending = await getOutbox();
    for (final thread in pending) {
      if (thread.status == EmailStatus.pending) {
        // Check if the station for this thread is connected
        final account = _accounts[thread.station];
        if (account == null || !account.isConnected) continue;

        // Send via WebSocket - email stays in outbox until DSN confirms delivery
        await sendViaWebSocket(thread);
        // Don't mark as sent here - wait for DSN confirmation
      }
    }
  }

  /// Handle delivery status notification from station
  Future<void> handleDSN(Map<String, dynamic> dsn) async {
    final threadId = dsn['thread_id'] as String?;
    final action = dsn['action'] as String?;
    final recipient = dsn['recipient'] as String?;
    final reason = dsn['reason'] as String?;

    if (threadId == null || action == null) return;

    LogService().log(
      'DSN received: action=$action, threadId=$threadId, recipient=$recipient',
    );

    // Find the thread in unified outbox
    final outbox = await getOutbox();
    final thread = outbox.firstWhere(
      (t) => t.threadId == threadId,
      orElse: () => EmailThread(
        station: '',
        from: '',
        to: [],
        subject: '',
        created: '',
        threadId: '',
      ),
    );

    String? notificationMessage;

    if (thread.threadId.isNotEmpty) {
      switch (action) {
        case 'delivered':
          await markAsSent(thread);
          notificationMessage =
              'Email delivered to ${recipient ?? thread.to.join(", ")}';
          break;
        case 'failed':
          thread.status = EmailStatus.failed;
          await saveThread(thread);
          notificationMessage =
              'Email delivery failed${reason != null ? ": $reason" : ""}';
          break;
        case 'pending_approval':
          // Email is waiting for station operator approval
          notificationMessage = 'Email to $recipient awaiting station approval';
          break;
        case 'sending':
          // Email is being sent to external recipient
          notificationMessage = 'Sending email to $recipient...';
          break;
        case 'delayed':
          // Keep in outbox, maybe add retry info to metadata
          notificationMessage =
              'Email to $recipient delayed - recipient offline';
          break;
      }
    }

    // Fire notification event for UI to display
    if (notificationMessage != null) {
      EventBus().fire(
        EmailNotificationEvent(
          message: notificationMessage,
          action: action!,
          threadId: threadId,
          recipient: recipient,
        ),
      );
    }

    _eventController.add(
      EmailChangeEvent('', threadId, EmailChangeType.statusChanged),
    );
  }

  /// Receive an email from the station (via WebSocket)
  ///
  /// This is called when the station forwards an email to this client.
  /// The email can be from:
  /// - Another Geogram user (internal)
  /// - An external sender via SMTP
  Future<bool> receiveEmail(Map<String, dynamic> message) async {
    try {
      await initialize();

      final from = message['from'] as String?;
      final threadId = message['thread_id'] as String?;
      final subject = message['subject'] as String?;
      final contentB64 = message['content'] as String?;
      final event = message['event'] as Map<String, dynamic>?;
      final incomingAttachments = _parseIncomingAttachments(
        message['attachments'],
      );

      if (from == null || threadId == null || contentB64 == null) {
        LogService().log(
          'EmailService: Invalid email_receive message - missing fields',
        );
        return false;
      }

      // Decode content (base64-encoded thread.md)
      String content;
      try {
        content = utf8.decode(base64Decode(contentB64));
      } catch (_) {
        content = contentB64; // Already plain text
      }

      // Extract sender callsign for message author
      final senderCallsign = from.contains('@')
          ? from.split('@').first.toUpperCase()
          : from.toUpperCase();

      // Try to find existing thread by threadId (for reply appending)
      EmailThread? existingThread = await _findThreadById(threadId);

      if (existingThread != null) {
        // Append new message to existing thread
        final timestamp = DateTime.now();
        final created =
            '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')} '
            '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}_'
            '${timestamp.second.toString().padLeft(2, '0')}';

        final emailMessage = EmailMessage(
          author: senderCallsign,
          timestamp: created,
          content: content,
          metadata: {},
        );

        if (event != null) {
          emailMessage.metadata['event_id'] = event['id'] as String? ?? '';
          emailMessage.metadata['npub'] = event['pubkey'] as String? ?? '';
          emailMessage.metadata['signature'] = event['sig'] as String? ?? '';
        }

        existingThread.addMessage(emailMessage);
        await saveThread(existingThread);
        if (incomingAttachments.isNotEmpty) {
          await _storeIncomingAttachments(existingThread, incomingAttachments);
        }

        LogService().log(
          'EmailService: Appended reply from $from to existing thread $threadId',
        );

        _eventController.add(
          EmailChangeEvent(
            existingThread.station,
            threadId,
            EmailChangeType.received,
          ),
        );

        await _showIncomingEmailNotification(
          from: from,
          subject: subject ?? existingThread.subject,
          content: content,
        );

        return true;
      }

      // No existing thread found - create new one
      // Parse the thread content
      EmailThread? thread = EmailFormat.parse(content);

      if (thread == null) {
        // Content might just be the message body, not full thread.md
        // Create a new thread for this received email
        final timestamp = DateTime.now();
        final created =
            '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')} '
            '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}_'
            '${timestamp.second.toString().padLeft(2, '0')}';

        // Extract station from recipient address
        final profile = ProfileService().getProfile();
        final stationService = StationService();
        final preferredStation = stationService.getPreferredStation();
        final station = preferredStation?.name ?? 'p2p.radio';

        thread = EmailThread(
          station: station,
          from: from,
          to: ['${profile.callsign.toLowerCase()}@$station'],
          subject: subject ?? '(No Subject)',
          created: created,
          status: EmailStatus.received,
          threadId: threadId,
          messages: [],
        );

        // Create the message
        final emailMessage = EmailMessage(
          author: senderCallsign,
          timestamp: created,
          content: content,
          metadata: {},
        );

        // Add NOSTR metadata if event provided
        if (event != null) {
          emailMessage.metadata['event_id'] = event['id'] as String? ?? '';
          emailMessage.metadata['npub'] = event['pubkey'] as String? ?? '';
          emailMessage.metadata['signature'] = event['sig'] as String? ?? '';
        }

        thread.messages.add(emailMessage);
      } else {
        // Thread was parsed from content, mark as received
        thread.status = EmailStatus.received;
      }

      // Save to inbox
      await saveThread(thread);
      if (incomingAttachments.isNotEmpty) {
        await _storeIncomingAttachments(thread, incomingAttachments);
      }

      LogService().log(
        'EmailService: Received email from $from (thread: $threadId)',
      );

      // Notify listeners
      _eventController.add(
        EmailChangeEvent(thread.station, threadId, EmailChangeType.received),
      );

      await _showIncomingEmailNotification(
        from: from,
        subject: thread.subject,
        content: content,
      );

      return true;
    } catch (e, stack) {
      LogService().log('EmailService: Error receiving email: $e\n$stack');
      return false;
    }
  }

  List<_IncomingAttachment> _parseIncomingAttachments(dynamic rawAttachments) {
    if (rawAttachments is! List) return const [];

    final attachments = <_IncomingAttachment>[];
    for (final entry in rawAttachments) {
      if (entry is! Map) continue;
      final map = entry.cast<dynamic, dynamic>();
      final filename = (map['name'] ?? '').toString().trim();
      final contentB64 = (map['content'] ?? '').toString().trim();

      if (!_isSafeAttachmentFilename(filename) || contentB64.isEmpty) {
        continue;
      }

      try {
        final bytes = base64Decode(contentB64);
        if (bytes.isEmpty) continue;
        attachments.add(_IncomingAttachment(name: filename, bytes: bytes));
      } catch (_) {
        LogService().log(
          'EmailService: Skipping invalid attachment payload for $filename',
        );
      }
    }
    return attachments;
  }

  bool _isSafeAttachmentFilename(String filename) {
    if (filename.isEmpty) return false;
    if (filename.contains('..')) return false;
    if (filename.contains('/')) return false;
    if (filename.contains('\\')) return false;
    return true;
  }

  Future<void> _storeIncomingAttachments(
    EmailThread thread,
    List<_IncomingAttachment> attachments,
  ) async {
    for (final attachment in attachments) {
      await writeAttachment(thread, attachment.name, attachment.bytes);
    }
    LogService().log(
      'EmailService: Stored ${attachments.length} attachment(s) for thread ${thread.threadId}',
    );
  }

  /// Receive an encrypted cached email (was offline when originally sent)
  ///
  /// Decrypts with the user's nsec and delegates to receiveEmail().
  Future<bool> receiveEncryptedEmail(Map<String, dynamic> message) async {
    try {
      final encryptedB64 = message['encrypted_content'] as String?;
      if (encryptedB64 == null) {
        LogService().log(
          'EmailService: Missing encrypted_content in email_receive_encrypted',
        );
        return false;
      }

      final profile = ProfileService().getProfile();
      if (profile.nsec.isEmpty) {
        LogService().log(
          'EmailService: Cannot decrypt cached email - no nsec available',
        );
        return false;
      }

      // Decode and decrypt
      final encryptedBytes = base64Decode(encryptedB64);
      final decryptedBytes = BackupEncryption.decryptFile(
        Uint8List.fromList(encryptedBytes),
        profile.nsec,
      );

      // Parse decrypted JSON as email message
      final decryptedJson =
          jsonDecode(utf8.decode(decryptedBytes)) as Map<String, dynamic>;

      LogService().log(
        'EmailService: Decrypted cached email from ${decryptedJson['from']}',
      );

      // Delegate to standard receiveEmail logic
      return await receiveEmail(decryptedJson);
    } catch (e, stack) {
      LogService().log(
        'EmailService: Error decrypting cached email: $e\n$stack',
      );
      return false;
    }
  }

  Future<void> _showIncomingEmailNotification({
    required String from,
    required String subject,
    required String content,
  }) async {
    try {
      await DMNotificationService().showEmailMessage(
        fromAddress: from,
        subject: subject,
        preview: _buildEmailPreview(content),
      );
    } catch (e) {
      LogService().log('EmailService: Failed to show email notification: $e');
    }
  }

  String _buildEmailPreview(String content) {
    final normalized = content.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return '';
    if (normalized.length <= 120) return normalized;
    return '${normalized.substring(0, 120)}...';
  }

  // ============================================
  // Frequent Contacts Management
  // ============================================

  /// Cached frequent contacts
  List<FrequentContact>? _frequentContacts;

  /// Load frequent contacts from disk
  Future<List<FrequentContact>> loadFrequentContacts() async {
    await initialize();

    if (_frequentContacts != null) return _frequentContacts!;

    try {
      final content = await _storage.readString('frequent.json');
      if (content == null) {
        _frequentContacts = [];
        return _frequentContacts!;
      }

      final List<dynamic> jsonList = jsonDecode(content);
      _frequentContacts = jsonList
          .map((json) => FrequentContact.fromJson(json as Map<String, dynamic>))
          .toList();

      // Sort by count descending
      _frequentContacts!.sort((a, b) => b.count.compareTo(a.count));
      return _frequentContacts!;
    } catch (e) {
      print('Error loading frequent contacts: $e');
      _frequentContacts = [];
      return _frequentContacts!;
    }
  }

  /// Save frequent contacts to disk
  Future<void> _saveFrequentContacts() async {
    await initialize();
    if (_frequentContacts == null) return;

    try {
      final content = jsonEncode(
        _frequentContacts!.map((c) => c.toJson()).toList(),
      );
      await _storage.writeString('frequent.json', content);
    } catch (e) {
      print('Error saving frequent contacts: $e');
    }
  }

  /// Update frequent contacts when sending to recipients
  /// Call this when sending an email to track usage
  Future<void> trackRecipients(
    List<String> recipients, {
    String? senderName,
  }) async {
    if (recipients.isEmpty) return;

    await loadFrequentContacts();

    for (final recipient in recipients) {
      // Parse email to extract name and address
      final parsed = _parseEmailAddress(recipient);
      final email = parsed['email']!.toLowerCase();
      final name = parsed['name'] ?? senderName ?? '';

      // Find existing or create new
      final existingIndex = _frequentContacts!.indexWhere(
        (c) => c.email.toLowerCase() == email,
      );

      if (existingIndex >= 0) {
        // Update existing
        final existing = _frequentContacts![existingIndex];
        _frequentContacts![existingIndex] = FrequentContact(
          name: name.isNotEmpty ? name : existing.name,
          email: existing.email,
          count: existing.count + 1,
        );
      } else {
        // Add new
        _frequentContacts!.add(
          FrequentContact(name: name, email: email, count: 1),
        );
      }
    }

    // Re-sort by count
    _frequentContacts!.sort((a, b) => b.count.compareTo(a.count));

    await _saveFrequentContacts();
  }

  /// Parse an email address string to extract name and email
  /// Handles formats like: "John Doe <john@example.com>" or "john@example.com"
  Map<String, String> _parseEmailAddress(String input) {
    final trimmed = input.trim();

    // Check for "Name <email>" format
    final match = RegExp(r'^(.+?)\s*<(.+?)>$').firstMatch(trimmed);
    if (match != null) {
      return {'name': match.group(1)!.trim(), 'email': match.group(2)!.trim()};
    }

    // Just email address
    return {'name': '', 'email': trimmed};
  }

  /// Get top frequent contacts (for dropdown suggestions)
  Future<List<FrequentContact>> getTopFrequentContacts({int limit = 10}) async {
    final contacts = await loadFrequentContacts();
    return contacts.take(limit).toList();
  }

  /// Search frequent contacts by name or email
  Future<List<FrequentContact>> searchFrequentContacts(String query) async {
    if (query.isEmpty) return [];

    final contacts = await loadFrequentContacts();
    final lowerQuery = query.toLowerCase();

    return contacts.where((c) {
      return c.name.toLowerCase().contains(lowerQuery) ||
          c.email.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Clear the frequent contacts cache (call after external modification)
  void clearFrequentContactsCache() {
    _frequentContacts = null;
  }

  /// Dispose resources
  void dispose() {
    _eventController.close();
  }
}

/// Model for a frequently used contact
class FrequentContact {
  final String name;
  final String email;
  final int count;

  FrequentContact({
    required this.name,
    required this.email,
    required this.count,
  });

  factory FrequentContact.fromJson(Map<String, dynamic> json) {
    return FrequentContact(
      name: json['name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      count: json['count'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'email': email,
    'count': count,
  };

  /// Display string for autocomplete
  String get displayString {
    if (name.isNotEmpty) {
      return '$name <$email>';
    }
    return email;
  }
}
