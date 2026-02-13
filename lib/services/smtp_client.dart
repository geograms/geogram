/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * SMTP Client - Sends emails to external SMTP servers
 * Standalone implementation using dart:io sockets
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../util/dkim_signer.dart';
import '../util/smtp_protocol.dart';
import 'log_service.dart';

/// Result of an SMTP send operation
class SMTPSendResult {
  final bool success;
  final int? responseCode;
  final String? message;
  final String? error;
  final Duration? duration;
  final String? messageId;

  SMTPSendResult._({
    required this.success,
    this.responseCode,
    this.message,
    this.error,
    this.duration,
    this.messageId,
  });

  factory SMTPSendResult.success({
    String? message,
    Duration? duration,
    String? messageId,
  }) => SMTPSendResult._(
    success: true,
    message: message,
    duration: duration,
    messageId: messageId,
  );

  factory SMTPSendResult.failure({int? code, String? error}) =>
      SMTPSendResult._(success: false, responseCode: code, error: error);

  @override
  String toString() => success
      ? 'SMTPSendResult(success${message != null ? ": $message" : ""})'
      : 'SMTPSendResult(failed: $error)';
}

/// Email attachment for SMTP sending
class SMTPAttachment {
  final String filename;
  final String mimeType;
  final List<int> data;

  SMTPAttachment({
    required this.filename,
    required this.mimeType,
    required this.data,
  });
}

/// DKIM configuration for signing outgoing emails
class DkimConfig {
  final String privateKeyPem;
  final String selector;

  const DkimConfig({required this.privateKeyPem, this.selector = 'geogram'});
}

/// SMTP Relay configuration for authenticated sending
class SMTPRelayConfig {
  final String host;
  final int port;
  final String? username;
  final String? password;
  final bool useStartTls;

  const SMTPRelayConfig({
    required this.host,
    this.port = 587,
    this.username,
    this.password,
    this.useStartTls = true,
  });

  bool get hasAuth => username != null && password != null;
}

/// SMTP Client for sending emails to external servers
class SMTPClient {
  final String localDomain;
  final Duration timeout;
  final int defaultPort;
  final DkimConfig? dkimConfig;
  final SMTPRelayConfig? relayConfig;
  DkimSigner? _dkimSigner;

  /// Cache of MX records (domain -> host)
  static final Map<String, _MXCacheEntry> _mxCache = {};
  static const Duration _mxCacheTtl = Duration(hours: 1);

  SMTPClient({
    required this.localDomain,
    this.timeout = const Duration(seconds: 30),
    this.defaultPort = 25,
    this.dkimConfig,
    this.relayConfig,
  }) {
    // Initialize DKIM signer if config provided
    if (dkimConfig != null && dkimConfig!.privateKeyPem.isNotEmpty) {
      try {
        _dkimSigner = DkimSigner(
          domain: localDomain,
          selector: dkimConfig!.selector,
          privateKeyPem: dkimConfig!.privateKeyPem,
        );
        LogService().log('SMTP: DKIM signer initialized for $localDomain');
      } catch (e) {
        LogService().log('SMTP: Failed to initialize DKIM signer: $e');
      }
    }
  }

  /// Send email to external recipients
  Future<SMTPSendResult> send({
    required String from,
    required List<String> to,
    required String subject,
    required String body,
    List<String>? cc,
    List<SMTPAttachment>? attachments,
    Map<String, String>? extraHeaders,
  }) async {
    final stopwatch = Stopwatch()..start();

    // Validate inputs
    if (!SMTPProtocol.isValidEmail(from)) {
      return SMTPSendResult.failure(error: 'Invalid sender address: $from');
    }

    final invalidRecipients = to.where((r) => !SMTPProtocol.isValidEmail(r));
    if (invalidRecipients.isNotEmpty) {
      return SMTPSendResult.failure(
        error: 'Invalid recipient addresses: ${invalidRecipients.join(", ")}',
      );
    }

    // Group recipients by domain for efficient delivery
    final recipientsByDomain = <String, List<String>>{};
    for (final recipient in to) {
      final domain = SMTPProtocol.getDomain(recipient)!;
      recipientsByDomain.putIfAbsent(domain, () => []).add(recipient);
    }

    // Send to each domain
    final results = <String, SMTPSendResult>{};
    for (final entry in recipientsByDomain.entries) {
      final domain = entry.key;
      final recipients = entry.value;

      try {
        final result = await _sendToDomain(
          from: from,
          to: recipients,
          subject: subject,
          body: body,
          cc: cc,
          attachments: attachments,
          extraHeaders: extraHeaders,
          domain: domain,
        );
        results[domain] = result;
      } catch (e) {
        results[domain] = SMTPSendResult.failure(error: e.toString());
      }
    }

    stopwatch.stop();

    // Check if all domains succeeded
    final allSuccess = results.values.every((r) => r.success);
    if (allSuccess) {
      String? firstMessageId;
      for (final result in results.values) {
        final candidate = result.messageId;
        if (candidate != null && candidate.isNotEmpty) {
          firstMessageId = candidate;
          break;
        }
      }
      return SMTPSendResult.success(
        message: 'Delivered to ${to.length} recipient(s)',
        duration: stopwatch.elapsed,
        messageId: firstMessageId,
      );
    }

    // Return first failure
    final failure = results.values.firstWhere((r) => !r.success);
    return failure;
  }

  /// Send email to recipients on a specific domain
  Future<SMTPSendResult> _sendToDomain({
    required String from,
    required List<String> to,
    required String subject,
    required String body,
    required String domain,
    List<String>? cc,
    List<SMTPAttachment>? attachments,
    Map<String, String>? extraHeaders,
  }) async {
    String targetHost;
    int targetPort;

    // Use relay server if configured, otherwise lookup MX
    if (relayConfig != null) {
      targetHost = relayConfig!.host;
      targetPort = relayConfig!.port;
      LogService().log('SMTP: Using relay $targetHost:$targetPort for $domain');
    } else {
      // Lookup MX record
      final mxHost = await _getMxHost(domain);
      if (mxHost == null) {
        return SMTPSendResult.failure(
          error: 'No MX record found for domain: $domain',
        );
      }
      targetHost = mxHost;
      targetPort = defaultPort;
      LogService().log('SMTP: Connecting to $targetHost for domain $domain');
    }

    Socket? socket;
    SecureSocket? secureSocket;
    _SMTPSession? session;
    Socket activeSocket;
    try {
      // Connect to mail server with short timeout for fast failure
      final connectTimeout = Duration(seconds: 10);
      try {
        socket = await Socket.connect(
          targetHost,
          targetPort,
          timeout: connectTimeout,
        ).timeout(connectTimeout);
      } on SocketException catch (e) {
        LogService().log(
          'SMTP: Connection failed to $targetHost:$targetPort - $e',
        );
        return SMTPSendResult.failure(
          error:
              'Cannot connect to mail server ($targetHost:$targetPort). Port may be blocked by hosting provider.',
        );
      } on TimeoutException {
        LogService().log('SMTP: Connection timeout to $targetHost:$targetPort');
        return SMTPSendResult.failure(
          error:
              'Connection timeout to mail server. Outbound SMTP port $targetPort may be blocked.',
        );
      }
      activeSocket = socket;

      // Create session for reading responses
      session = _SMTPSession(socket, timeout);

      // Wait for server greeting
      final greeting = await session.readResponse();
      if (greeting == null || !greeting.isSuccess) {
        return SMTPSendResult.failure(
          code: greeting?.code,
          error: 'Server rejected connection: ${greeting?.lines.join(" ")}',
        );
      }

      // Send EHLO
      var ehloResponse = await session.sendAndRead('EHLO $localDomain');
      if (ehloResponse == null || !ehloResponse.isSuccess) {
        // Try HELO as fallback
        final heloResponse = await session.sendAndRead('HELO $localDomain');
        if (heloResponse == null || !heloResponse.isSuccess) {
          return SMTPSendResult.failure(
            code: heloResponse?.code ?? ehloResponse?.code,
            error: 'Server rejected greeting',
          );
        }
      }

      // Check for STARTTLS support and upgrade if using relay
      final supportsStartTls =
          ehloResponse?.lines.any(
            (l) => l.toUpperCase().contains('STARTTLS'),
          ) ??
          false;
      if (relayConfig != null && relayConfig!.useStartTls && supportsStartTls) {
        LogService().log('SMTP: Upgrading to TLS via STARTTLS');
        final startTlsResponse = await session.sendAndRead('STARTTLS');
        if (startTlsResponse != null && startTlsResponse.isSuccess) {
          // Upgrade to secure socket
          session.dispose();
          secureSocket = await SecureSocket.secure(
            socket,
            host: targetHost,
            onBadCertificate: (_) =>
                true, // Allow self-signed certs for testing
          );
          activeSocket = secureSocket;
          session = _SMTPSession(secureSocket, timeout);

          // Re-send EHLO after TLS upgrade
          ehloResponse = await session.sendAndRead('EHLO $localDomain');
          if (ehloResponse == null || !ehloResponse.isSuccess) {
            return SMTPSendResult.failure(
              code: ehloResponse?.code,
              error: 'Server rejected greeting after STARTTLS',
            );
          }
          LogService().log('SMTP: TLS upgrade successful');
        }
      }

      // Authenticate if using relay with credentials
      if (relayConfig != null && relayConfig!.hasAuth) {
        LogService().log('SMTP: Authenticating with relay');
        final authResponse = await session.sendAndRead('AUTH LOGIN');
        if (authResponse == null || !authResponse.isIntermediate) {
          return SMTPSendResult.failure(
            code: authResponse?.code,
            error: 'Server does not support AUTH LOGIN',
          );
        }

        // Send username (base64)
        final userB64 = base64Encode(utf8.encode(relayConfig!.username!));
        final userResponse = await session.sendAndRead(userB64);
        if (userResponse == null || !userResponse.isIntermediate) {
          return SMTPSendResult.failure(
            code: userResponse?.code,
            error: 'Authentication failed (username)',
          );
        }

        // Send password (base64)
        final passB64 = base64Encode(utf8.encode(relayConfig!.password!));
        final passResponse = await session.sendAndRead(passB64);
        if (passResponse == null || !passResponse.isSuccess) {
          return SMTPSendResult.failure(
            code: passResponse?.code,
            error: 'Authentication failed (password)',
          );
        }
        LogService().log('SMTP: Authentication successful');
      }

      // MAIL FROM
      final mailFromResponse = await session.sendAndRead('MAIL FROM:<$from>');
      if (mailFromResponse == null || !mailFromResponse.isSuccess) {
        return SMTPSendResult.failure(
          code: mailFromResponse?.code,
          error: 'Server rejected sender: ${mailFromResponse?.lines.join(" ")}',
        );
      }

      // RCPT TO for each recipient
      for (final recipient in to) {
        final rcptResponse = await session.sendAndRead('RCPT TO:<$recipient>');
        if (rcptResponse == null || !rcptResponse.isSuccess) {
          return SMTPSendResult.failure(
            code: rcptResponse?.code,
            error:
                'Server rejected recipient $recipient: ${rcptResponse?.lines.join(" ")}',
          );
        }
      }

      // DATA
      final dataResponse = await session.sendAndRead('DATA');
      if (dataResponse == null || !dataResponse.isIntermediate) {
        return SMTPSendResult.failure(
          code: dataResponse?.code,
          error: 'Server rejected DATA command',
        );
      }

      // Build and send message content
      final builtMessage = _buildMessage(
        from: from,
        to: to,
        cc: cc,
        subject: subject,
        body: body,
        attachments: attachments,
        extraHeaders: extraHeaders,
      );
      final messageContent = builtMessage.raw;

      // Escape content and add terminator
      final escapedContent = SMTPProtocol.escapeData(messageContent);
      activeSocket.write(escapedContent);
      if (!escapedContent.endsWith('\r\n')) {
        activeSocket.write('\r\n');
      }
      activeSocket.write('.\r\n');
      await activeSocket.flush();

      // Wait for final response
      final finalResponse = await session.readResponse();
      if (finalResponse == null || !finalResponse.isSuccess) {
        return SMTPSendResult.failure(
          code: finalResponse?.code,
          error: 'Server rejected message: ${finalResponse?.lines.join(" ")}',
        );
      }

      // QUIT
      await session.sendAndRead('QUIT');

      LogService().log(
        'SMTP: Successfully delivered to ${to.join(", ")} via $targetHost',
      );

      return SMTPSendResult.success(
        message: 'Delivered via $targetHost',
        messageId: builtMessage.messageId,
      );
    } catch (e) {
      LogService().log('SMTP: Error sending to $domain: $e');
      return SMTPSendResult.failure(error: e.toString());
    } finally {
      session?.dispose();
      await secureSocket?.close();
      await socket?.close();
    }
  }

  /// Lookup MX record for domain
  Future<String?> _getMxHost(String domain) async {
    // Check cache
    final cached = _mxCache[domain];
    if (cached != null && !cached.isExpired) {
      return cached.host;
    }

    try {
      // Try to resolve MX record
      final records = await _lookupMX(domain);
      if (records.isNotEmpty) {
        // Sort by priority and get lowest
        records.sort((a, b) => a.priority.compareTo(b.priority));
        final host = records.first.host;

        // Cache result
        _mxCache[domain] = _MXCacheEntry(host, DateTime.now());
        return host;
      }
    } catch (e) {
      LogService().log('SMTP: MX lookup failed for $domain: $e');
    }

    // Fallback: try direct connection to domain
    try {
      final addresses = await InternetAddress.lookup(domain);
      if (addresses.isNotEmpty) {
        _mxCache[domain] = _MXCacheEntry(domain, DateTime.now());
        return domain;
      }
    } catch (e) {
      LogService().log('SMTP: Direct lookup failed for $domain: $e');
    }

    return null;
  }

  /// Lookup MX records using DNS
  Future<List<_MXRecord>> _lookupMX(String domain) async {
    // Dart doesn't have built-in MX lookup, so we use a workaround
    // Try connecting to common DNS-over-HTTPS services or use system resolver

    // For now, use a simple approach: try well-known mail server patterns
    final results = <_MXRecord>[];

    // Common mail server prefixes to try
    final prefixes = ['mail', 'mx', 'smtp', 'mx1', 'mx2', 'aspmx.l.google.com'];

    // Check if it's a known domain with specific MX
    final knownMX = _getKnownMX(domain);
    if (knownMX != null) {
      return [_MXRecord(knownMX, 10)];
    }

    // Try common patterns
    for (final prefix in prefixes) {
      final host = prefix.contains('.') ? prefix : '$prefix.$domain';
      try {
        await InternetAddress.lookup(host).timeout(const Duration(seconds: 2));
        results.add(_MXRecord(host, prefixes.indexOf(prefix) * 10));
        break; // Found one, use it
      } catch (_) {
        continue;
      }
    }

    // Fallback to domain itself
    if (results.isEmpty) {
      try {
        await InternetAddress.lookup(
          domain,
        ).timeout(const Duration(seconds: 2));
        results.add(_MXRecord(domain, 100));
      } catch (_) {}
    }

    return results;
  }

  /// Get known MX for common domains
  String? _getKnownMX(String domain) {
    final knownMX = {
      'gmail.com': 'gmail-smtp-in.l.google.com',
      'googlemail.com': 'gmail-smtp-in.l.google.com',
      'outlook.com': 'outlook-com.olc.protection.outlook.com',
      'hotmail.com': 'hotmail-com.olc.protection.outlook.com',
      'live.com': 'live-com.olc.protection.outlook.com',
      'yahoo.com': 'mta5.am0.yahoodns.net',
      'yahoo.co.uk': 'mta5.am0.yahoodns.net',
      'icloud.com': 'mx1.mail.icloud.com',
      'me.com': 'mx1.mail.icloud.com',
      'protonmail.com': 'mail.protonmail.ch',
      'proton.me': 'mail.protonmail.ch',
      'pm.me': 'mail.protonmail.ch',
    };
    return knownMX[domain.toLowerCase()];
  }

  /// Build MIME message content with optional DKIM signing
  _BuiltMessage _buildMessage({
    required String from,
    required List<String> to,
    List<String>? cc,
    required String subject,
    required String body,
    List<SMTPAttachment>? attachments,
    Map<String, String>? extraHeaders,
  }) {
    final buffer = StringBuffer();
    final messageId = SMTPProtocol.generateMessageId(localDomain);
    final date = SMTPProtocol.formatDate(DateTime.now());
    final hasAttachments = attachments != null && attachments.isNotEmpty;
    final boundary = hasAttachments
        ? 'geogram_${DateTime.now().millisecondsSinceEpoch}'
        : null;

    // Build message body first (needed for DKIM body hash)
    final bodyBuffer = StringBuffer();
    if (!hasAttachments) {
      bodyBuffer.writeln(body);
    } else {
      bodyBuffer.writeln('--$boundary');
      bodyBuffer.writeln('Content-Type: text/plain; charset=UTF-8');
      bodyBuffer.writeln('Content-Transfer-Encoding: 8bit');
      bodyBuffer.writeln();
      bodyBuffer.writeln(body);

      for (final attachment in attachments) {
        bodyBuffer.writeln('--$boundary');
        bodyBuffer.writeln(
          'Content-Type: ${attachment.mimeType}; name="${attachment.filename}"',
        );
        bodyBuffer.writeln(
          'Content-Disposition: attachment; filename="${attachment.filename}"',
        );
        bodyBuffer.writeln('Content-Transfer-Encoding: base64');
        bodyBuffer.writeln();

        final b64 = base64Encode(attachment.data);
        for (var i = 0; i < b64.length; i += 76) {
          final end = (i + 76 < b64.length) ? i + 76 : b64.length;
          bodyBuffer.writeln(b64.substring(i, end));
        }
      }
      bodyBuffer.writeln('--$boundary--');
    }
    final messageBody = bodyBuffer.toString();

    // Add DKIM-Signature header first if signer available
    if (_dkimSigner != null) {
      try {
        final dkimSignature = _dkimSigner!.sign(
          from: from,
          to: to.join(', '),
          subject: subject,
          date: date,
          messageId: messageId,
          body: messageBody,
        );
        // Fold long DKIM-Signature header for readability
        buffer.writeln('DKIM-Signature: ${_foldHeader(dkimSignature)}');
        LogService().log('SMTP: Added DKIM signature to email');
      } catch (e) {
        LogService().log('SMTP: Failed to sign email with DKIM: $e');
      }
    }

    // Required headers
    buffer.writeln('From: $from');
    buffer.writeln('To: ${to.join(", ")}');
    if (cc != null && cc.isNotEmpty) {
      buffer.writeln('Cc: ${cc.join(", ")}');
    }
    buffer.writeln('Subject: $subject');
    buffer.writeln('Date: $date');
    buffer.writeln('Message-ID: $messageId');
    buffer.writeln('MIME-Version: 1.0');

    // Extra headers
    extraHeaders?.forEach((key, value) {
      buffer.writeln('$key: $value');
    });

    // Content type and body
    if (!hasAttachments) {
      buffer.writeln('Content-Type: text/plain; charset=UTF-8');
      buffer.writeln('Content-Transfer-Encoding: 8bit');
      buffer.writeln();
      buffer.write(messageBody);
    } else {
      buffer.writeln('Content-Type: multipart/mixed; boundary="$boundary"');
      buffer.writeln();
      buffer.write(messageBody);
    }

    return _BuiltMessage(raw: buffer.toString(), messageId: messageId);
  }

  /// Fold a long header value for email formatting (RFC 5322)
  String _foldHeader(String value) {
    if (value.length <= 76) return value;

    final parts = <String>[];
    var remaining = value;

    while (remaining.length > 70) {
      // Find a good break point (at semicolon or space)
      var breakPoint = 70;
      for (var i = 70; i > 20; i--) {
        if (remaining[i] == ';' || remaining[i] == ' ') {
          breakPoint = i + 1;
          break;
        }
      }
      parts.add(remaining.substring(0, breakPoint));
      remaining = remaining.substring(breakPoint);
    }
    if (remaining.isNotEmpty) {
      parts.add(remaining);
    }

    return parts.join('\r\n\t');
  }
}

/// MX record entry
class _MXRecord {
  final String host;
  final int priority;

  _MXRecord(this.host, this.priority);
}

/// MX cache entry
class _MXCacheEntry {
  final String host;
  final DateTime timestamp;

  _MXCacheEntry(this.host, this.timestamp);

  bool get isExpired =>
      DateTime.now().difference(timestamp) > SMTPClient._mxCacheTtl;
}

class _BuiltMessage {
  final String raw;
  final String messageId;

  const _BuiltMessage({required this.raw, required this.messageId});
}

/// SMTP session helper for managing socket stream
class _SMTPSession {
  final Socket _socket;
  final Duration _timeout;
  final StringBuffer _buffer = StringBuffer();
  StreamSubscription<List<int>>? _subscription;
  final List<Completer<String>> _pendingReads = [];

  _SMTPSession(this._socket, this._timeout) {
    _subscription = _socket.listen(_onData, onError: _onError, onDone: _onDone);
  }

  void _onData(List<int> data) {
    _buffer.write(utf8.decode(data));
    _tryComplete();
  }

  void _onError(dynamic error) {
    for (final completer in _pendingReads) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pendingReads.clear();
  }

  void _onDone() {
    _tryComplete();
  }

  void _tryComplete() {
    if (_pendingReads.isEmpty) return;

    final content = _buffer.toString();
    final lines = content.split('\r\n');

    // Check for complete SMTP response (line with code followed by space)
    for (final line in lines) {
      if (line.isNotEmpty && RegExp(r'^\d{3} ').hasMatch(line)) {
        // Found a complete response
        final completer = _pendingReads.removeAt(0);
        if (!completer.isCompleted) {
          completer.complete(content);
        }
        _buffer.clear();
        return;
      }
    }
  }

  /// Read a response from the server
  Future<SMTPResponse?> readResponse() async {
    final completer = Completer<String>();
    _pendingReads.add(completer);
    _tryComplete(); // Check if buffer already has complete response

    try {
      final content = await completer.future.timeout(_timeout);
      return SMTPResponse.parse(content);
    } catch (e) {
      return null;
    }
  }

  /// Send a command and read the response
  Future<SMTPResponse?> sendAndRead(String command) async {
    _socket.write('$command\r\n');
    await _socket.flush();
    return readResponse();
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
