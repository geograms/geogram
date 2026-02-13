/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Email Relay Service - Handles email routing between connected clients
 * Works on both CLI (pure_station) and Android (station_server_service)
 *
 * ## Email Routing Architecture
 *
 * This service handles two types of email routing:
 *
 * ### 1. Internal Emails (Geogram-to-Geogram)
 * - Recipient address ends with station domain (e.g., bob@p2p.radio)
 * - Routed directly via WebSocket if recipient is connected
 * - Queued in `_pendingEmails` if recipient is offline
 * - No approval needed - these are trusted internal communications
 *
 * ### 2. External Emails (to non-Geogram addresses)
 * - Recipient address is external (e.g., someone@gmail.com)
 * - ALWAYS queued in `_externalApprovalQueue` for moderation
 * - Station operator must approve before SMTP delivery
 * - This prevents spam and protects domain reputation
 *
 * ## Why External Email Approval is Critical
 *
 * Sending unmoderated emails to external addresses poses serious risks:
 * - Domain blacklisting by major email providers
 * - IP reputation damage
 * - Legal liability for spam
 * - Abuse of station resources
 *
 * ## Approval Workflow (Future Implementation)
 *
 * 1. Client sends email to external address
 * 2. Email is queued in `_externalApprovalQueue` with status `pending`
 * 3. Station operator reviews via admin interface (TODO: implement UI)
 * 4. Operator can:
 *    - `approve`: Email is sent via SMTP, sender notified
 *    - `reject`: Email is discarded, sender notified with reason
 *    - `ban_sender`: Reject + add sender to blocklist
 * 5. Approved senders can optionally be added to allowlist for auto-approval
 *
 * ## Future Enhancements (TODO)
 *
 * - [ ] Admin UI for reviewing pending external emails
 * - [ ] Allowlist for trusted senders (auto-approve)
 * - [ ] Blocklist for known spammers (auto-reject)
 * - [ ] Rate limiting per sender (e.g., max 10 external emails/day)
 * - [ ] Content filtering (keywords, links, attachments)
 * - [ ] SMTP delivery integration (when approved)
 * - [ ] Webhook notifications for new pending emails
 * - [ ] Email templates for rejection notices
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import '../util/backup_encryption.dart';
import '../util/email_format.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import 'log_service.dart';
import 'nip05_registry_service.dart';
import 'smtp_client.dart' show SMTPClient, DkimConfig, SMTPRelayConfig;
import 'smtp_server.dart' show MIMEParser;

/// Callback type for sending messages to clients
typedef SendToClientCallback = bool Function(String clientId, String message);

/// Callback type for finding a client by callsign
typedef FindClientByCallsignCallback = String? Function(String callsign);

/// Callback type for getting station domain
typedef GetStationDomainCallback = String Function();

/// Callback type for getting a client's npub by callsign
// TODO: Re-enable when ECIES encryption is properly implemented
// typedef GetClientNpubCallback = String? Function(String callsign);

/// Pending email entry
class PendingEmail {
  final Map<String, dynamic> message;
  final String senderCallsign;
  final String senderId;
  final String recipient;
  final DateTime timestamp;
  final DateTime retryUntil;

  PendingEmail({
    required this.message,
    required this.senderCallsign,
    required this.senderId,
    required this.recipient,
    required this.timestamp,
    required this.retryUntil,
  });

  bool get isExpired => DateTime.now().isAfter(retryUntil);
}

/// Encrypted cached email entry persisted on the station for offline recipients.
///
/// The encrypted payload can only be decrypted by the recipient's nsec.
class CachedEncryptedEmailEntry {
  final String id;
  final String recipientCallsign;
  final String recipientNpub;
  final String senderCallsign;
  final String senderId;
  final String recipient;
  final String threadId;
  final DateTime timestamp;
  final DateTime retryUntil;
  final String encryptedContentB64;
  final int payloadSizeBytes;

  CachedEncryptedEmailEntry({
    required this.id,
    required this.recipientCallsign,
    required this.recipientNpub,
    required this.senderCallsign,
    required this.senderId,
    required this.recipient,
    required this.threadId,
    required this.timestamp,
    required this.retryUntil,
    required this.encryptedContentB64,
    required this.payloadSizeBytes,
  });

  bool get isExpired => DateTime.now().isAfter(retryUntil);

  Map<String, dynamic> toJson() => {
    'id': id,
    'recipient_callsign': recipientCallsign,
    'recipient_npub': recipientNpub,
    'sender_callsign': senderCallsign,
    'sender_id': senderId,
    'recipient': recipient,
    'thread_id': threadId,
    'timestamp': timestamp.toIso8601String(),
    'retry_until': retryUntil.toIso8601String(),
    'encrypted_content': encryptedContentB64,
    'payload_size_bytes': payloadSizeBytes,
  };

  factory CachedEncryptedEmailEntry.fromJson(Map<String, dynamic> json) {
    final encryptedContent = json['encrypted_content'] as String? ?? '';
    var payloadSize = json['payload_size_bytes'] as int? ?? 0;
    if (payloadSize <= 0 && encryptedContent.isNotEmpty) {
      try {
        payloadSize = base64Decode(encryptedContent).length;
      } catch (_) {
        payloadSize = encryptedContent.length;
      }
    }

    return CachedEncryptedEmailEntry(
      id: json['id'] as String? ?? '',
      recipientCallsign: json['recipient_callsign'] as String? ?? '',
      recipientNpub: json['recipient_npub'] as String? ?? '',
      senderCallsign: json['sender_callsign'] as String? ?? '',
      senderId: json['sender_id'] as String? ?? '',
      recipient: json['recipient'] as String? ?? '',
      threadId: json['thread_id'] as String? ?? '',
      timestamp:
          DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.now().toUtc(),
      retryUntil:
          DateTime.tryParse(json['retry_until'] as String? ?? '') ??
          DateTime.now().toUtc().add(const Duration(hours: 24)),
      encryptedContentB64: encryptedContent,
      payloadSizeBytes: payloadSize,
    );
  }
}

/// Approval status for external emails
enum ExternalEmailStatus {
  /// Awaiting station operator review
  pending,

  /// Approved by operator, ready for SMTP delivery
  approved,

  /// Rejected by operator, will not be sent
  rejected,

  /// Successfully sent via SMTP
  sent,

  /// SMTP delivery failed
  failed,
}

/// External email awaiting approval before SMTP delivery
///
/// External emails (to non-Geogram addresses) require station operator
/// approval to prevent spam and protect domain reputation.
class ExternalEmailEntry {
  final String id;
  final Map<String, dynamic> message;
  final String senderCallsign;
  final String senderId;
  final String senderNpub;
  final List<String> externalRecipients;
  final DateTime timestamp;
  ExternalEmailStatus status;
  String? rejectionReason;
  String? reviewedBy;
  DateTime? reviewedAt;

  /// Callback to send DSN back to the client after SMTP delivery
  final SendToClientCallback? sendToClientCallback;

  ExternalEmailEntry({
    required this.id,
    required this.message,
    required this.senderCallsign,
    required this.senderId,
    required this.senderNpub,
    required this.externalRecipients,
    required this.timestamp,
    this.status = ExternalEmailStatus.pending,
    this.rejectionReason,
    this.reviewedBy,
    this.reviewedAt,
    this.sendToClientCallback,
  });

  String get threadId => message['thread_id'] as String? ?? id;
  String get subject => message['subject'] as String? ?? '(No Subject)';
  String get content => message['content'] as String? ?? '';

  /// Check if this entry has been waiting too long (default: 7 days)
  bool isExpired([Duration maxAge = const Duration(days: 7)]) {
    return DateTime.now().isAfter(timestamp.add(maxAge));
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'thread_id': threadId,
    'sender_callsign': senderCallsign,
    'sender_npub': senderNpub,
    'external_recipients': externalRecipients,
    'subject': subject,
    'content': content,
    'timestamp': timestamp.toIso8601String(),
    'status': status.name,
    'rejection_reason': rejectionReason,
    'reviewed_by': reviewedBy,
    'reviewed_at': reviewedAt?.toIso8601String(),
  };
}

/// Email relay service for routing emails between connected clients
class EmailRelayService {
  static final EmailRelayService _instance = EmailRelayService._internal();
  factory EmailRelayService() => _instance;
  EmailRelayService._internal();

  /// Pending email deliveries for offline internal recipients (key: threadId_recipient)
  final Map<String, PendingEmail> _pendingEmails = {};

  /// External emails awaiting approval before SMTP delivery (key: entry.id)
  /// These are emails to non-Geogram addresses that require moderation.
  final Map<String, ExternalEmailEntry> _externalApprovalQueue = {};

  /// Allowlist of sender callsigns that can send external emails without approval
  /// TODO: Persist this to disk and provide admin UI to manage
  final Set<String> _externalEmailAllowlist = {};

  /// Blocklist of sender callsigns that are banned from sending external emails
  /// TODO: Persist this to disk and provide admin UI to manage
  final Set<String> _externalEmailBlocklist = {};

  /// Outgoing Message-ID -> threadId mapping for reply matching
  final Map<String, String> _outgoingMessageIds = {};

  /// Normalized subject -> threadId mapping for reply matching
  final Map<String, String> _outgoingSubjects = {};

  /// Maximum cache size per recipient (10 MB)
  static const int _maxCacheSizeBytes = 10 * 1024 * 1024;
  String? _cacheDirectoryPath;

  /// Email relay settings
  EmailRelaySettings settings = EmailRelaySettings();

  /// Configure cache directory for encrypted offline email storage.
  void setCacheDirectory(String cacheDirectoryPath) {
    _cacheDirectoryPath = cacheDirectoryPath;
    _ensureCacheDirectoryExists();
  }

  // ============================================================
  // External Email Approval Queue Methods
  // ============================================================

  /// Get all pending external emails awaiting approval
  List<ExternalEmailEntry> getPendingExternalEmails() {
    return _externalApprovalQueue.values
        .where((e) => e.status == ExternalEmailStatus.pending)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  /// Get external email entry by ID
  ExternalEmailEntry? getExternalEmailById(String id) {
    return _externalApprovalQueue[id];
  }

  /// Approve an external email for SMTP delivery
  ///
  /// Returns true if approved successfully.
  /// After approval, the email should be sent via SMTP (TODO: implement).
  bool approveExternalEmail({
    required String emailId,
    required String reviewerCallsign,
    bool addToAllowlist = false,
  }) {
    final entry = _externalApprovalQueue[emailId];
    if (entry == null || entry.status != ExternalEmailStatus.pending) {
      return false;
    }

    entry.status = ExternalEmailStatus.approved;
    entry.reviewedBy = reviewerCallsign;
    entry.reviewedAt = DateTime.now();

    // Optionally add sender to allowlist for future auto-approval
    if (addToAllowlist) {
      _externalEmailAllowlist.add(entry.senderCallsign.toUpperCase());
    }

    LogService().log(
      'External email approved: ${entry.id} by $reviewerCallsign',
    );

    // Trigger SMTP delivery
    _sendExternalEmailViaSMTP(entry);

    return true;
  }

  /// Send approved external email via SMTP
  ///
  /// This is called automatically when an external email is approved.
  /// Runs asynchronously and updates the entry status based on result.
  Future<void> _sendExternalEmailViaSMTP(ExternalEmailEntry entry) async {
    // Check if station domain is configured
    if (settings.stationDomain == 'localhost') {
      LogService().log(
        'SMTP: Station domain not configured, skipping delivery',
      );
      entry.status = ExternalEmailStatus.failed;

      if (entry.sendToClientCallback != null) {
        final dsn = _createDsn(
          action: 'failed',
          threadId: entry.threadId,
          recipient: entry.externalRecipients.join(', '),
          reason: 'External email not available: station domain not configured',
        );
        entry.sendToClientCallback!(entry.senderId, jsonEncode(dsn));
      }
      return;
    }

    // Check if SMTP relay is configured (required for most cloud providers that block port 25)
    if (!settings.hasRelay && !settings.smtpEnabled) {
      LogService().log('SMTP: No SMTP relay configured and SMTP not enabled');
      entry.status = ExternalEmailStatus.failed;

      if (entry.sendToClientCallback != null) {
        final dsn = _createDsn(
          action: 'failed',
          threadId: entry.threadId,
          recipient: entry.externalRecipients.join(', '),
          reason:
              'External email not available: SMTP relay not configured on station',
        );
        entry.sendToClientCallback!(entry.senderId, jsonEncode(dsn));
      }
      return;
    }

    // Create DKIM config if private key is available
    DkimConfig? dkimConfig;
    if (settings.dkimPrivateKey != null &&
        settings.dkimPrivateKey!.isNotEmpty) {
      dkimConfig = DkimConfig(
        privateKeyPem: settings.dkimPrivateKey!,
        selector: settings.dkimSelector,
      );
    }

    // Create relay config if configured
    SMTPRelayConfig? relayConfig;
    if (settings.hasRelay) {
      relayConfig = SMTPRelayConfig(
        host: settings.smtpRelayHost!,
        port: settings.smtpRelayPort,
        username: settings.smtpRelayUsername,
        password: settings.smtpRelayPassword,
        useStartTls: settings.smtpRelayStartTls,
      );
      LogService().log(
        'SMTP: Using relay ${settings.smtpRelayHost}:${settings.smtpRelayPort}',
      );
    }

    final client = SMTPClient(
      localDomain: settings.stationDomain,
      defaultPort: settings.smtpPort,
      dkimConfig: dkimConfig,
      relayConfig: relayConfig,
    );

    // Build sender email from callsign
    final fromEmail =
        '${entry.senderCallsign.toLowerCase()}@${settings.stationDomain}';

    // Extract email body from content (base64 decoded thread.md content)
    String body;
    try {
      final rawContent = utf8.decode(base64Decode(entry.content));
      body = _extractPlainTextBody(rawContent);
    } catch (_) {
      body = entry.content; // Already plain text
    }

    LogService().log(
      'SMTP: Sending external email from $fromEmail to ${entry.externalRecipients.join(", ")}',
    );

    try {
      // Build extra headers including reply threading
      final extraHeaders = <String, String>{
        'X-Geogram-Thread-ID': entry.threadId,
        'X-Geogram-Sender-Npub': entry.senderNpub,
      };

      // Add In-Reply-To/References if this thread has previous external messages
      final lastExternalMessageId = _outgoingMessageIds.entries
          .where((e) => e.value == entry.threadId)
          .map((e) => e.key)
          .lastOrNull;
      if (lastExternalMessageId != null) {
        extraHeaders['In-Reply-To'] = lastExternalMessageId;
        extraHeaders['References'] = lastExternalMessageId;
      }

      final result = await client.send(
        from: fromEmail,
        to: entry.externalRecipients,
        subject: entry.subject,
        body: body,
        extraHeaders: extraHeaders,
      );

      if (result.success) {
        entry.status = ExternalEmailStatus.sent;

        // Track outgoing email for reply matching
        trackOutgoingEmail(threadId: entry.threadId, subject: entry.subject);
        LogService().log(
          'SMTP: Successfully sent external email: ${entry.id} (${result.message})',
        );

        // Send DSN to notify sender of successful delivery
        if (entry.sendToClientCallback != null) {
          final dsn = _createDsn(
            action: 'delivered',
            threadId: entry.threadId,
            recipient: entry.externalRecipients.join(', '),
          );
          entry.sendToClientCallback!(entry.senderId, jsonEncode(dsn));
          LogService().log(
            'SMTP: Sent delivery confirmation DSN to ${entry.senderCallsign}',
          );
        }
      } else {
        entry.status = ExternalEmailStatus.failed;
        LogService().log(
          'SMTP: Failed to send external email: ${entry.id} - ${result.error}',
        );

        // Send DSN to notify sender of failed delivery
        if (entry.sendToClientCallback != null) {
          final dsn = _createDsn(
            action: 'failed',
            threadId: entry.threadId,
            recipient: entry.externalRecipients.join(', '),
            reason: result.error ?? 'SMTP delivery failed',
          );
          entry.sendToClientCallback!(entry.senderId, jsonEncode(dsn));
        }
      }
    } catch (e) {
      entry.status = ExternalEmailStatus.failed;
      LogService().log(
        'SMTP: Exception sending external email: ${entry.id} - $e',
      );

      // Send DSN to notify sender of exception
      if (entry.sendToClientCallback != null) {
        final dsn = _createDsn(
          action: 'failed',
          threadId: entry.threadId,
          recipient: entry.externalRecipients.join(', '),
          reason: 'SMTP error: $e',
        );
        entry.sendToClientCallback!(entry.senderId, jsonEncode(dsn));
      }
    }
  }

  /// Extract plain text email body from thread.md format for external delivery
  ///
  /// The thread.md format includes headers and metadata that should not be
  /// sent to external recipients. This method extracts only the message content.
  String _extractPlainTextBody(String threadContent) {
    final thread = EmailFormat.parse(threadContent);
    if (thread == null || thread.messages.isEmpty) {
      return threadContent; // Fallback to raw content
    }

    final buffer = StringBuffer();

    // Clean message content
    for (int i = 0; i < thread.messages.length; i++) {
      if (i > 0) buffer.write('\n\n---\n\n');
      buffer.write(thread.messages[i].content);
    }

    // Append signature verification block if any message has signing metadata
    final hasSigningMetadata = thread.messages.any(
      (m) =>
          m.hasMeta('event_id') || m.hasMeta('npub') || m.hasMeta('signature'),
    );

    if (hasSigningMetadata) {
      buffer.write('\n\n\n--------------\n');
      buffer.writeln(
        'Signature verification for NOSTR, you can ignore the text below.',
      );
      buffer.writeln('--------------');
      for (int i = 0; i < thread.messages.length; i++) {
        if (i > 0) buffer.write('\n');
        buffer.write(thread.messages[i].exportAsText());
      }
    }

    return buffer.toString();
  }

  /// Reject an external email
  ///
  /// Returns true if rejected successfully.
  /// Optionally notifies the sender of the rejection.
  bool rejectExternalEmail({
    required String emailId,
    required String reviewerCallsign,
    String? reason,
    bool banSender = false,
    SendToClientCallback? sendToClient,
  }) {
    final entry = _externalApprovalQueue[emailId];
    if (entry == null || entry.status != ExternalEmailStatus.pending) {
      return false;
    }

    entry.status = ExternalEmailStatus.rejected;
    entry.rejectionReason = reason ?? 'Email rejected by station operator';
    entry.reviewedBy = reviewerCallsign;
    entry.reviewedAt = DateTime.now();

    // Optionally ban the sender
    if (banSender) {
      _externalEmailBlocklist.add(entry.senderCallsign.toUpperCase());
      LogService().log(
        'Sender banned from external emails: ${entry.senderCallsign}',
      );
    }

    LogService().log(
      'External email rejected: ${entry.id} by $reviewerCallsign - ${entry.rejectionReason}',
    );

    // Notify sender if callback provided
    if (sendToClient != null) {
      final dsn = _createDsn(
        action: 'failed',
        threadId: entry.threadId,
        recipient: entry.externalRecipients.join(', '),
        reason: 'External email rejected: ${entry.rejectionReason}',
      );
      sendToClient(entry.senderId, jsonEncode(dsn));
    }

    return true;
  }

  /// Check if a sender is allowed to send external emails without approval
  bool isSenderAllowlisted(String callsign) {
    return _externalEmailAllowlist.contains(callsign.toUpperCase());
  }

  /// Check if a sender is blocked from sending external emails
  bool isSenderBlocklisted(String callsign) {
    return _externalEmailBlocklist.contains(callsign.toUpperCase());
  }

  /// Add sender to allowlist
  void addToAllowlist(String callsign) {
    _externalEmailAllowlist.add(callsign.toUpperCase());
    _externalEmailBlocklist.remove(callsign.toUpperCase());
  }

  /// Remove sender from allowlist
  void removeFromAllowlist(String callsign) {
    _externalEmailAllowlist.remove(callsign.toUpperCase());
  }

  /// Add sender to blocklist
  void addToBlocklist(String callsign) {
    _externalEmailBlocklist.add(callsign.toUpperCase());
    _externalEmailAllowlist.remove(callsign.toUpperCase());
  }

  /// Remove sender from blocklist
  void removeFromBlocklist(String callsign) {
    _externalEmailBlocklist.remove(callsign.toUpperCase());
  }

  /// Get allowlist of senders who can send external emails without approval
  List<String> getAllowlist() => _externalEmailAllowlist.toList();

  /// Get blocklist of senders who are blocked from sending external emails
  List<String> getBlocklist() => _externalEmailBlocklist.toList();

  /// Get count of pending external emails
  int get pendingExternalEmailCount => _externalApprovalQueue.values
      .where((e) => e.status == ExternalEmailStatus.pending)
      .length;

  /// Clean up old external email entries (approved, rejected, or expired)
  void cleanupExternalEmailQueue([Duration maxAge = const Duration(days: 30)]) {
    final toRemove = <String>[];
    for (final entry in _externalApprovalQueue.entries) {
      if (entry.value.status != ExternalEmailStatus.pending ||
          entry.value.isExpired(maxAge)) {
        toRemove.add(entry.key);
      }
    }
    for (final key in toRemove) {
      _externalApprovalQueue.remove(key);
    }
    if (toRemove.isNotEmpty) {
      LogService().log(
        'Cleaned up ${toRemove.length} external email queue entries',
      );
    }
  }

  // ============================================================
  // Encrypted Email Cache (for offline recipients)
  // ============================================================

  String _resolveCacheDirectoryPath() {
    if (_cacheDirectoryPath != null && _cacheDirectoryPath!.isNotEmpty) {
      return _cacheDirectoryPath!;
    }
    return path.join('.', 'email-cache');
  }

  void _ensureCacheDirectoryExists() {
    final dir = Directory(_resolveCacheDirectoryPath());
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
  }

  String _getCacheFilePath(String callsign) {
    return path.join(
      _resolveCacheDirectoryPath(),
      '${callsign.toUpperCase()}.json',
    );
  }

  String? _getAuthorizedRecipientNpub(String callsign) {
    return Nip05RegistryService().getRegistration(callsign)?.npub;
  }

  List<CachedEncryptedEmailEntry> _loadCacheEntries(String callsign) {
    final file = File(_getCacheFilePath(callsign));
    if (!file.existsSync()) {
      return [];
    }

    try {
      final raw = file.readAsStringSync();
      if (raw.trim().isEmpty) {
        return [];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return [];
      }
      final entriesRaw = decoded['entries'];
      if (entriesRaw is! List) {
        return [];
      }
      final entries = <CachedEncryptedEmailEntry>[];
      for (final item in entriesRaw) {
        if (item is Map<String, dynamic>) {
          entries.add(CachedEncryptedEmailEntry.fromJson(item));
        } else if (item is Map) {
          entries.add(
            CachedEncryptedEmailEntry.fromJson(item.cast<String, dynamic>()),
          );
        }
      }
      entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      return entries;
    } catch (e) {
      LogService().log('Email cache read error for $callsign: $e');
      return [];
    }
  }

  void _saveCacheEntries(
    String callsign,
    List<CachedEncryptedEmailEntry> entries,
  ) {
    final file = File(_getCacheFilePath(callsign));
    if (entries.isEmpty) {
      if (file.existsSync()) {
        file.deleteSync();
      }
      return;
    }

    _ensureCacheDirectoryExists();
    final payload = <String, dynamic>{
      'version': 1,
      'callsign': callsign.toUpperCase(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'entries': entries.map((e) => e.toJson()).toList(),
    };
    file.writeAsStringSync(jsonEncode(payload));
  }

  int _totalCacheBytes(List<CachedEncryptedEmailEntry> entries) {
    return entries.fold<int>(0, (sum, entry) => sum + entry.payloadSizeBytes);
  }

  int _trimCacheToLimit(List<CachedEncryptedEmailEntry> entries) {
    entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    var dropped = 0;
    var total = _totalCacheBytes(entries);
    while (total > _maxCacheSizeBytes && entries.isNotEmpty) {
      final removed = entries.removeAt(0);
      total -= removed.payloadSizeBytes;
      dropped++;
    }
    return dropped;
  }

  bool _cacheEmailForRecipient({
    required String recipientCallsign,
    required String recipientNpub,
    required Map<String, dynamic> emailMessage,
    required String senderCallsign,
    required String senderId,
    required String recipient,
    required DateTime retryUntil,
  }) {
    try {
      final plaintext = Uint8List.fromList(
        utf8.encode(jsonEncode(emailMessage)),
      );
      final encryptedBytes = BackupEncryption.encryptFile(
        plaintext,
        recipientNpub,
      );

      if (encryptedBytes.length > _maxCacheSizeBytes) {
        LogService().log(
          'Email cache: message too large for $recipientCallsign (${encryptedBytes.length} bytes)',
        );
        return false;
      }

      final entries = _loadCacheEntries(recipientCallsign)
        ..removeWhere((entry) => entry.isExpired);

      final threadId = emailMessage['thread_id'] as String? ?? '';
      final entry = CachedEncryptedEmailEntry(
        id: '${DateTime.now().microsecondsSinceEpoch}_${threadId.hashCode.abs()}',
        recipientCallsign: recipientCallsign.toUpperCase(),
        recipientNpub: recipientNpub,
        senderCallsign: senderCallsign,
        senderId: senderId,
        recipient: recipient,
        threadId: threadId,
        timestamp: DateTime.now().toUtc(),
        retryUntil: retryUntil.toUtc(),
        encryptedContentB64: base64Encode(encryptedBytes),
        payloadSizeBytes: encryptedBytes.length,
      );

      entries.add(entry);
      final dropped = _trimCacheToLimit(entries);
      _saveCacheEntries(recipientCallsign, entries);

      if (dropped > 0) {
        LogService().log(
          'Email cache: dropped $dropped old message(s) for $recipientCallsign to stay under ${_maxCacheSizeBytes ~/ (1024 * 1024)}MB',
        );
      }
      return true;
    } catch (e) {
      LogService().log('Email cache write error for $recipientCallsign: $e');
      return false;
    }
  }

  int _deliverCachedEmails({
    required String clientId,
    required String callsign,
    required SendToClientCallback sendToClient,
  }) {
    final entries = _loadCacheEntries(callsign);
    if (entries.isEmpty) {
      return 0;
    }

    final authorizedNpub = _getAuthorizedRecipientNpub(callsign);
    if (authorizedNpub == null || authorizedNpub.isEmpty) {
      // Recipient is no longer authorized in NIP-05, clear cached messages.
      _saveCacheEntries(callsign, <CachedEncryptedEmailEntry>[]);
      LogService().log(
        'Email cache cleared for unauthorized recipient: ${callsign.toUpperCase()}',
      );
      return 0;
    }

    final remaining = <CachedEncryptedEmailEntry>[];
    var delivered = 0;
    var droppedUnauthorized = 0;
    var droppedExpired = 0;

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];

      if (entry.isExpired) {
        droppedExpired++;
        continue;
      }

      if (entry.recipientNpub != authorizedNpub) {
        droppedUnauthorized++;
        continue;
      }

      final encryptedMessage = <String, dynamic>{
        'type': 'email_receive_encrypted',
        'encrypted_content': entry.encryptedContentB64,
        'thread_id': entry.threadId,
        'cached_at': entry.timestamp.toIso8601String(),
      };

      if (sendToClient(clientId, jsonEncode(encryptedMessage))) {
        delivered++;
        if (entry.senderId.isNotEmpty) {
          final dsn = _createDsn(
            action: 'delivered',
            threadId: entry.threadId,
            recipient: entry.recipient,
          );
          sendToClient(entry.senderId, jsonEncode(dsn));
        }
      } else {
        // Connection likely dropped. Keep this and all remaining entries.
        remaining.add(entry);
        if (i + 1 < entries.length) {
          remaining.addAll(entries.sublist(i + 1));
        }
        break;
      }
    }

    _saveCacheEntries(callsign, remaining);

    if (droppedExpired > 0 || droppedUnauthorized > 0) {
      LogService().log(
        'Email cache cleanup for $callsign: expired=$droppedExpired, unauthorized=$droppedUnauthorized',
      );
    }
    if (delivered > 0) {
      LogService().log('Delivered $delivered cached email(s) to $callsign');
    }
    return delivered;
  }

  void _cleanupExpiredCachedEmails() {
    final dir = Directory(_resolveCacheDirectoryPath());
    if (!dir.existsSync()) {
      return;
    }

    final files = dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.json'))
        .toList();

    var cleanedEntries = 0;
    for (final file in files) {
      final callsign = path.basenameWithoutExtension(file.path).toUpperCase();
      final entries = _loadCacheEntries(callsign);
      final before = entries.length;
      entries.removeWhere((entry) => entry.isExpired);
      if (entries.length != before) {
        cleanedEntries += (before - entries.length);
        _saveCacheEntries(callsign, entries);
      }
    }

    if (cleanedEntries > 0) {
      LogService().log('Cleaned up $cleanedEntries expired cached email(s)');
    }
  }

  int _countCachedEmails() {
    final dir = Directory(_resolveCacheDirectoryPath());
    if (!dir.existsSync()) {
      return 0;
    }

    var count = 0;
    final files = dir.listSync().whereType<File>().where(
      (file) => file.path.toLowerCase().endsWith('.json'),
    );
    for (final file in files) {
      final callsign = path.basenameWithoutExtension(file.path).toUpperCase();
      count += _loadCacheEntries(callsign).length;
    }
    return count;
  }

  // ============================================================
  // Incoming Email Handling (SMTP -> WebSocket)
  // ============================================================

  /// Handle an incoming email from external SMTP
  /// Parses MIME, matches reply threads, and delivers to connected clients
  /// or queues for delivery when offline recipients reconnect.
  Future<bool> handleIncomingEmail({
    required String from,
    required List<String> to,
    required String rawMessage,
    required SendToClientCallback sendToClient,
    required FindClientByCallsignCallback findClientByCallsign,
    required GetStationDomainCallback getStationDomain,
  }) async {
    try {
      final parser = MIMEParser(rawMessage);
      final senderEmail = MIMEParser.extractEmail(parser.from) ?? from;
      final subject = parser.subject ?? '(No Subject)';

      // Reply thread matching (priority order)
      String threadId;

      // 1. Custom header from our outgoing emails
      final customThreadId = parser.headers['x-geogram-thread-id'];
      if (customThreadId != null && customThreadId.isNotEmpty) {
        threadId = customThreadId;
      }
      // 2. In-Reply-To header -> look up in outgoing message IDs
      else if (parser.inReplyTo != null &&
          _outgoingMessageIds.containsKey(parser.inReplyTo)) {
        threadId = _outgoingMessageIds[parser.inReplyTo]!;
      }
      // 3. References header -> check each reference
      else if (parser.references != null) {
        final refs = parser.references!.split(RegExp(r'\s+'));
        threadId =
            refs
                .where((ref) => _outgoingMessageIds.containsKey(ref))
                .map((ref) => _outgoingMessageIds[ref]!)
                .firstOrNull ??
            _matchBySubject(subject) ??
            'ext_${(parser.messageId ?? senderEmail).hashCode.abs()}';
      }
      // 4. Subject matching
      else {
        threadId =
            _matchBySubject(subject) ??
            'ext_${(parser.messageId ?? senderEmail).hashCode.abs()}';
      }

      // Track incoming Message-ID for future reference chain
      if (parser.messageId != null) {
        _outgoingMessageIds[parser.messageId!] = threadId;
      }

      // Build email_receive message
      final emailMessage = <String, dynamic>{
        'type': 'email_receive',
        'from': senderEmail,
        'thread_id': threadId,
        'subject': subject,
        'content': base64Encode(utf8.encode(parser.body)),
        'delivered_at': DateTime.now().toUtc().toIso8601String(),
        'external_message_id': parser.messageId,
      };

      bool anyDelivered = false;

      // Deliver to each local recipient
      for (final recipientAddr in to) {
        final callsign = _extractCallsign(recipientAddr);
        final clientId = findClientByCallsign(callsign);

        if (clientId != null) {
          // Online: deliver immediately via WebSocket
          if (sendToClient(clientId, jsonEncode(emailMessage))) {
            anyDelivered = true;
            LogService().log(
              'External email delivered: $senderEmail -> $callsign (thread: $threadId)',
            );
          }
        } else {
          // Offline: cache encrypted for authorized recipients; fallback to
          // in-memory queue for non-authorized recipients.
          final retryUntil = DateTime.now().add(
            Duration(hours: settings.retryHours),
          );
          final recipientNpub = _getAuthorizedRecipientNpub(callsign);
          if (recipientNpub != null &&
              _cacheEmailForRecipient(
                recipientCallsign: callsign,
                recipientNpub: recipientNpub,
                emailMessage: emailMessage,
                senderCallsign: senderEmail,
                senderId: '',
                recipient: recipientAddr,
                retryUntil: retryUntil,
              )) {
            anyDelivered = true;
            LogService().log(
              'External email cached (encrypted) for offline recipient: $callsign (thread: $threadId)',
            );
          } else {
            final pendingKey = '${threadId}_$callsign';
            _pendingEmails[pendingKey] = PendingEmail(
              message: emailMessage,
              senderCallsign: senderEmail,
              senderId: '',
              recipient: callsign,
              timestamp: DateTime.now(),
              retryUntil: retryUntil,
            );
            anyDelivered = true;
            LogService().log(
              'External email queued in-memory for offline recipient: $callsign (thread: $threadId)',
            );
          }
        }
      }

      return anyDelivered;
    } catch (e) {
      LogService().log('Error handling incoming email: $e');
      return false;
    }
  }

  /// Match a subject line against outgoing subjects (stripping Re:/Fwd: prefixes)
  String? _matchBySubject(String subject) {
    final normalized = _normalizeSubject(subject);
    return _outgoingSubjects[normalized];
  }

  /// Normalize subject by stripping Re:/Fwd: prefixes
  static String _normalizeSubject(String subject) {
    return subject
        .replaceAll(RegExp(r'^(Re|Fwd|Fw):\s*', caseSensitive: false), '')
        .trim()
        .toLowerCase();
  }

  /// Track outgoing Message-ID and subject for reply matching
  void trackOutgoingEmail({
    required String threadId,
    required String subject,
    String? messageId,
  }) {
    if (messageId != null) {
      _outgoingMessageIds[messageId] = threadId;
    }
    final normalized = _normalizeSubject(subject);
    if (normalized.isNotEmpty) {
      _outgoingSubjects[normalized] = threadId;
    }
  }

  /// Clean up old tracking entries (call periodically)
  void cleanupTrackingEntries() {
    // Keep tracking maps reasonable size (max 1000 entries each)
    if (_outgoingMessageIds.length > 1000) {
      final keysToRemove = _outgoingMessageIds.keys
          .take(_outgoingMessageIds.length - 500)
          .toList();
      for (final key in keysToRemove) {
        _outgoingMessageIds.remove(key);
      }
    }
    if (_outgoingSubjects.length > 1000) {
      final keysToRemove = _outgoingSubjects.keys
          .take(_outgoingSubjects.length - 500)
          .toList();
      for (final key in keysToRemove) {
        _outgoingSubjects.remove(key);
      }
    }
  }

  // ============================================================
  // Email Routing
  // ============================================================

  /// Check if an email address is internal (Geogram-to-Geogram)
  bool _isInternalAddress(String email, String stationDomain) {
    final atIndex = email.indexOf('@');
    if (atIndex <= 0) return true; // No @ means local callsign

    final domain = email.substring(atIndex + 1).toLowerCase();
    return domain == stationDomain.toLowerCase() ||
        domain == 'local' ||
        domain.isEmpty;
  }

  /// Handle email send request
  /// Returns a map of recipient -> delivery status
  Map<String, String> handleEmailSend({
    required Map<String, dynamic> message,
    required String senderCallsign,
    required String senderId,
    required SendToClientCallback sendToClient,
    required FindClientByCallsignCallback findClientByCallsign,
    required GetStationDomainCallback getStationDomain,
  }) {
    final threadId = message['thread_id'] as String?;
    final recipients = message['to'] as List<dynamic>?;
    final subject = message['subject'] as String?;
    final content = message['content'] as String?;
    final event = message['event'] as Map<String, dynamic>?;

    final deliveryResults = <String, String>{};

    // Validate required fields
    if (threadId == null ||
        recipients == null ||
        recipients.isEmpty ||
        content == null) {
      // Send failure DSN back to sender
      final dsn = _createDsn(
        action: 'failed',
        threadId: threadId,
        recipient: recipients?.firstOrNull?.toString(),
        reason: 'Missing required fields (thread_id, to, content)',
      );
      sendToClient(senderId, jsonEncode(dsn));
      return {'error': 'missing_fields'};
    }

    // Verify NOSTR signature if present
    if (event != null) {
      try {
        final nostrEvent = NostrEvent.fromJson(event);
        if (!nostrEvent.verify()) {
          final dsn = _createDsn(
            action: 'failed',
            threadId: threadId,
            reason: 'Invalid NOSTR signature',
          );
          sendToClient(senderId, jsonEncode(dsn));
          return {'error': 'invalid_signature'};
        }
      } catch (e) {
        LogService().log('Email relay: failed to verify NOSTR event: $e');
      }

      // Validate sender owns the email identity (NIP-05)
      // Convert hex pubkey to npub format for registry comparison
      final senderPubkeyHex = event['pubkey'] as String?;
      final senderNpub = senderPubkeyHex != null && senderPubkeyHex.isNotEmpty
          ? NostrCrypto.encodeNpub(senderPubkeyHex)
          : null;
      if (senderNpub != null && senderNpub.isNotEmpty) {
        final registry = Nip05RegistryService();
        final collision = registry.checkCollision(senderCallsign, senderNpub);
        if (collision != null) {
          final dsn = _createDsn(
            action: 'failed',
            threadId: threadId,
            reason:
                'Email address "$senderCallsign" belongs to another identity',
          );
          sendToClient(senderId, jsonEncode(dsn));
          LogService().log(
            'Email rejected: NIP-05 validation failed - $senderCallsign belongs to different npub',
          );
          return {'error': 'nip05_mismatch'};
        }
      }
    }

    LogService().log(
      'Email send: $senderCallsign -> ${recipients.join(", ")} (thread: $threadId)',
    );

    final stationDomain = getStationDomain();

    // Separate internal vs external recipients
    final internalRecipients = <String>[];
    final externalRecipients = <String>[];

    for (final recipient in recipients) {
      final recipientStr = recipient.toString();
      if (_isInternalAddress(recipientStr, stationDomain)) {
        internalRecipients.add(recipientStr);
      } else {
        externalRecipients.add(recipientStr);
      }
    }

    // Process internal recipients (Geogram-to-Geogram)
    for (final recipientStr in internalRecipients) {
      final targetCallsign = _extractCallsign(recipientStr);
      final deliveryMessage = {
        'type': 'email_receive',
        'from': '${senderCallsign.toLowerCase()}@$stationDomain',
        'thread_id': threadId,
        'subject': subject,
        'content': content,
        'event': event,
        'delivered_at': DateTime.now().toUtc().toIso8601String(),
      };

      // Find recipient client
      final targetClientId = findClientByCallsign(targetCallsign);

      if (targetClientId != null) {
        // Recipient is connected - deliver immediately
        if (sendToClient(targetClientId, jsonEncode(deliveryMessage))) {
          deliveryResults[recipientStr] = 'delivered';
          LogService().log(
            'Email delivered: $senderCallsign -> $targetCallsign (thread: $threadId)',
          );
        } else {
          deliveryResults[recipientStr] = 'failed';
        }
      } else {
        // Recipient not connected. Cache encrypted for authorized users; fallback
        // to in-memory queue for non-authorized recipients.
        final retryUntil = DateTime.now().add(
          Duration(hours: settings.retryHours),
        );
        final recipientNpub = _getAuthorizedRecipientNpub(targetCallsign);
        if (recipientNpub != null &&
            _cacheEmailForRecipient(
              recipientCallsign: targetCallsign,
              recipientNpub: recipientNpub,
              emailMessage: deliveryMessage,
              senderCallsign: senderCallsign,
              senderId: senderId,
              recipient: recipientStr,
              retryUntil: retryUntil,
            )) {
          LogService().log(
            'Email cached (encrypted): $senderCallsign -> $targetCallsign (thread: $threadId)',
          );
        } else {
          final pendingKey = '${threadId}_$recipientStr';
          _pendingEmails[pendingKey] = PendingEmail(
            message: message,
            senderCallsign: senderCallsign,
            senderId: senderId,
            recipient: recipientStr,
            timestamp: DateTime.now(),
            retryUntil: retryUntil,
          );
          LogService().log(
            'Email queued in-memory: $senderCallsign -> $recipientStr (thread: $threadId)',
          );
        }
        deliveryResults[recipientStr] = 'delayed';
      }
    }

    // Process external recipients (requires approval before SMTP delivery)
    if (externalRecipients.isNotEmpty) {
      // Check if sender is blocked
      if (isSenderBlocklisted(senderCallsign)) {
        for (final recipientStr in externalRecipients) {
          deliveryResults[recipientStr] = 'blocked';
        }
        LogService().log(
          'External email blocked: $senderCallsign is on blocklist',
        );

        final dsn = _createDsn(
          action: 'failed',
          threadId: threadId,
          recipient: externalRecipients.join(', '),
          reason:
              'You are not permitted to send external emails from this station',
        );
        sendToClient(senderId, jsonEncode(dsn));
      }
      // Check if sender is on allowlist (auto-approve)
      else if (isSenderAllowlisted(senderCallsign)) {
        final entryId =
            '${threadId}_external_${DateTime.now().millisecondsSinceEpoch}';
        final senderNpub = event?['pubkey'] as String? ?? '';

        final entry = ExternalEmailEntry(
          id: entryId,
          message: message,
          senderCallsign: senderCallsign,
          senderId: senderId,
          senderNpub: senderNpub,
          externalRecipients: externalRecipients,
          timestamp: DateTime.now(),
          status: ExternalEmailStatus.approved, // Auto-approved
          reviewedBy: 'allowlist',
          reviewedAt: DateTime.now(),
          sendToClientCallback: sendToClient, // Store callback for DSN
        );
        _externalApprovalQueue[entryId] = entry;

        for (final recipientStr in externalRecipients) {
          deliveryResults[recipientStr] = 'queued_approved';
        }
        LogService().log(
          'External email auto-approved (allowlisted sender): $senderCallsign -> ${externalRecipients.join(", ")}',
        );

        // Trigger SMTP delivery
        _sendExternalEmailViaSMTP(entry);
      }
      // Auto-approve and send immediately (no manual approval required for now)
      else {
        final entryId =
            '${threadId}_external_${DateTime.now().millisecondsSinceEpoch}';
        final senderNpub = event?['pubkey'] as String? ?? '';

        final entry = ExternalEmailEntry(
          id: entryId,
          message: message,
          senderCallsign: senderCallsign,
          senderId: senderId,
          senderNpub: senderNpub,
          externalRecipients: externalRecipients,
          timestamp: DateTime.now(),
          status: ExternalEmailStatus.approved, // Auto-approved
          reviewedBy: 'auto',
          reviewedAt: DateTime.now(),
          sendToClientCallback: sendToClient, // Store callback for DSN
        );
        _externalApprovalQueue[entryId] = entry;

        for (final recipientStr in externalRecipients) {
          deliveryResults[recipientStr] = 'sending';
        }
        LogService().log(
          'External email auto-approved: $senderCallsign -> ${externalRecipients.join(", ")} (id: $entryId)',
        );

        // Notify sender that email is being sent
        final dsn = _createDsn(
          action: 'sending',
          threadId: threadId,
          recipient: externalRecipients.join(', '),
          reason: 'Email is being delivered to external recipient(s)',
        );
        sendToClient(senderId, jsonEncode(dsn));

        // Trigger SMTP delivery (will send success/failure DSN when done)
        _sendExternalEmailViaSMTP(entry);
      }
    }

    // Send DSN for each recipient (skip 'sending' - already notified above)
    for (final entry in deliveryResults.entries) {
      // Skip 'sending' status - DSN already sent above for external emails
      if (entry.value == 'sending') continue;

      final dsn = _createDsn(
        action: entry.value,
        threadId: threadId,
        recipient: entry.key,
        reason: entry.value == 'delayed'
            ? 'Recipient device offline'
            : entry.value == 'failed'
            ? 'Failed to deliver message'
            : null,
        retryUntil: entry.value == 'delayed'
            ? DateTime.now().add(Duration(hours: settings.retryHours))
            : null,
      );
      sendToClient(senderId, jsonEncode(dsn));
    }

    return deliveryResults;
  }

  /// Deliver pending emails when a client connects
  void deliverPendingEmails({
    required String clientId,
    required String callsign,
    required SendToClientCallback sendToClient,
    required GetStationDomainCallback getStationDomain,
  }) {
    final cachedDelivered = _deliverCachedEmails(
      clientId: clientId,
      callsign: callsign,
      sendToClient: sendToClient,
    );
    final toDeliver = <String>[];
    final toRemove = <String>[];

    // Find pending emails for this recipient
    for (final entry in _pendingEmails.entries) {
      final pending = entry.value;

      // Check if expired
      if (pending.isExpired) {
        toRemove.add(entry.key);
        continue;
      }

      // Check if this is for our client
      final targetCallsign = _extractCallsign(pending.recipient);
      if (targetCallsign.toUpperCase() == callsign.toUpperCase()) {
        toDeliver.add(entry.key);
      }
    }

    // Deliver pending emails
    for (final key in toDeliver) {
      final pending = _pendingEmails[key];
      if (pending == null) continue;

      final message = pending.message;
      final threadId = message['thread_id'] as String?;
      final subject = message['subject'] as String?;
      final content = message['content'] as String?;
      final event = message['event'] as Map<String, dynamic>?;

      final deliveryMessage = message['type'] == 'email_receive'
          ? {
              ...message,
              'delivered_at': DateTime.now().toUtc().toIso8601String(),
            }
          : {
              'type': 'email_receive',
              'from':
                  '${pending.senderCallsign.toLowerCase()}@${getStationDomain()}',
              'thread_id': threadId,
              'subject': subject,
              'content': content,
              'event': event,
              'delivered_at': DateTime.now().toUtc().toIso8601String(),
            };

      if (sendToClient(clientId, jsonEncode(deliveryMessage))) {
        LogService().log(
          'Email delivered (queued): ${pending.senderCallsign} -> $callsign (thread: $threadId)',
        );

        // Notify original sender
        final dsn = _createDsn(
          action: 'delivered',
          threadId: threadId,
          recipient: pending.recipient,
        );
        sendToClient(pending.senderId, jsonEncode(dsn));

        toRemove.add(key);
      }
    }

    // Remove delivered/expired emails
    for (final key in toRemove) {
      _pendingEmails.remove(key);
    }

    if (toDeliver.isNotEmpty || cachedDelivered > 0) {
      LogService().log(
        'Delivered ${toDeliver.length} in-memory pending and $cachedDelivered cached email(s) to $callsign',
      );
    }
  }

  /// Clean up expired pending emails
  void cleanupExpiredEmails() {
    final toRemove = <String>[];
    for (final entry in _pendingEmails.entries) {
      if (entry.value.isExpired) {
        toRemove.add(entry.key);
      }
    }
    for (final key in toRemove) {
      _pendingEmails.remove(key);
    }
    if (toRemove.isNotEmpty) {
      LogService().log(
        'Cleaned up ${toRemove.length} expired pending email(s)',
      );
    }
    _cleanupExpiredCachedEmails();
  }

  /// Get pending email count
  int get pendingEmailCount => _pendingEmails.length + _countCachedEmails();

  /// Extract callsign from email address
  String _extractCallsign(String email) {
    final atIndex = email.indexOf('@');
    if (atIndex > 0) {
      return email.substring(0, atIndex).toUpperCase();
    }
    return email.toUpperCase();
  }

  /// Create DSN (Delivery Status Notification) message
  Map<String, dynamic> _createDsn({
    required String action,
    String? threadId,
    String? recipient,
    String? reason,
    DateTime? retryUntil,
  }) {
    final dsn = <String, dynamic>{
      'type': 'email_dsn',
      'action': action,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };

    if (threadId != null) dsn['thread_id'] = threadId;
    if (recipient != null) dsn['recipient'] = recipient;
    if (reason != null) dsn['reason'] = reason;
    if (retryUntil != null) {
      dsn['will_retry_until'] = retryUntil.toIso8601String();
      dsn['retry_after'] = settings.retryIntervalSeconds;
    }

    return dsn;
  }
}

/// Email relay settings
class EmailRelaySettings {
  /// Hours to keep pending emails before expiring
  int retryHours;

  /// Seconds between retry attempts (for DSN info)
  int retryIntervalSeconds;

  /// SMTP port for external email (use higher port on non-root devices)
  int smtpPort;

  /// Whether SMTP server is enabled
  bool smtpEnabled;

  /// Station domain for SMTP client (e.g., p2p.radio)
  String stationDomain;

  /// DKIM private key in PEM format for signing outgoing emails
  String? dkimPrivateKey;

  /// DKIM selector (default: geogram)
  String dkimSelector;

  /// SMTP relay host (e.g., smtp.mailgun.org)
  String? smtpRelayHost;

  /// SMTP relay port (default: 587 for submission)
  int smtpRelayPort;

  /// SMTP relay username
  String? smtpRelayUsername;

  /// SMTP relay password
  String? smtpRelayPassword;

  /// Whether to use STARTTLS for relay
  bool smtpRelayStartTls;

  EmailRelaySettings({
    this.retryHours = 24,
    this.retryIntervalSeconds = 300,
    this.smtpPort = 2525, // Default to non-privileged port
    this.smtpEnabled = false,
    this.stationDomain = 'localhost',
    this.dkimPrivateKey,
    this.dkimSelector = 'geogram',
    this.smtpRelayHost,
    this.smtpRelayPort = 587,
    this.smtpRelayUsername,
    this.smtpRelayPassword,
    this.smtpRelayStartTls = true,
  });

  /// Check if relay is configured
  bool get hasRelay => smtpRelayHost != null && smtpRelayHost!.isNotEmpty;

  /// Get appropriate SMTP port based on environment
  /// On non-root devices (Android), returns configured high port
  /// On root/CLI, can use standard port 25 if configured
  static int getDefaultSmtpPort({bool isPrivileged = false}) {
    return isPrivileged ? 25 : 2525;
  }

  factory EmailRelaySettings.fromJson(Map<String, dynamic> json) {
    return EmailRelaySettings(
      retryHours: json['retryHours'] as int? ?? 24,
      retryIntervalSeconds: json['retryIntervalSeconds'] as int? ?? 300,
      smtpPort: json['smtpPort'] as int? ?? 2525,
      smtpEnabled: json['smtpEnabled'] as bool? ?? false,
      stationDomain: json['stationDomain'] as String? ?? 'localhost',
    );
  }

  Map<String, dynamic> toJson() => {
    'retryHours': retryHours,
    'retryIntervalSeconds': retryIntervalSeconds,
    'smtpPort': smtpPort,
    'smtpEnabled': smtpEnabled,
    'stationDomain': stationDomain,
  };
}
