/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * SMTP Server - Receives emails from external SMTP servers
 * Standalone implementation using dart:io sockets
 *
 * ## Security Notes
 * - Only accepts mail for local users (no open relay)
 * - Rate limiting per IP address
 * - Maximum message size enforcement
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../util/smtp_protocol.dart';
import 'log_service.dart';

/// Callback type for delivering received mail
typedef OnMailReceivedCallback = Future<bool> Function(
  String from,
  List<String> to,
  String rawMessage,
);

/// Callback type for validating local recipients
typedef ValidateRecipientCallback = bool Function(String email);

/// SMTP Server for receiving external mail
class SMTPServer {
  final int port;
  final String domain;
  final int maxMessageSize;
  final int maxConnectionsPerIp;
  final Duration connectionTimeout;

  ServerSocket? _server;
  final Map<String, List<SMTPSession>> _sessions = {};
  final Map<String, int> _connectionCounts = {};

  /// Callback when mail is received
  OnMailReceivedCallback? onMailReceived;

  /// Callback to validate if a recipient is local
  ValidateRecipientCallback? validateRecipient;

  SMTPServer({
    required this.port,
    required this.domain,
    this.maxMessageSize = 10 * 1024 * 1024, // 10MB default
    this.maxConnectionsPerIp = 10,
    this.connectionTimeout = const Duration(minutes: 5),
  });

  /// Start the SMTP server
  Future<bool> start() async {
    if (_server != null) {
      LogService().log('SMTP Server: Already running on port $port');
      return true;
    }

    try {
      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        port,
        shared: true,
      );

      _server!.listen(
        _handleConnection,
        onError: (error) {
          LogService().log('SMTP Server error: $error');
        },
        onDone: () {
          LogService().log('SMTP Server: Listener closed');
        },
      );

      LogService().log('SMTP Server: Listening on port $port for domain $domain');
      return true;
    } catch (e) {
      LogService().log('SMTP Server: Failed to start on port $port: $e');
      return false;
    }
  }

  /// Stop the SMTP server
  Future<void> stop() async {
    await _server?.close();
    _server = null;

    // Close all active sessions
    for (final sessions in _sessions.values) {
      for (final session in sessions) {
        await session.close();
      }
    }
    _sessions.clear();
    _connectionCounts.clear();

    LogService().log('SMTP Server: Stopped');
  }

  /// Check if server is running
  bool get isRunning => _server != null;

  /// Get active session count
  int get activeSessionCount =>
      _sessions.values.fold(0, (sum, list) => sum + list.length);

  /// Handle incoming connection
  void _handleConnection(Socket socket) {
    final remoteAddress = socket.remoteAddress.address;

    // Check connection limit per IP
    final count = _connectionCounts[remoteAddress] ?? 0;
    if (count >= maxConnectionsPerIp) {
      LogService().log('SMTP Server: Connection limit exceeded for $remoteAddress');
      socket.write('421 Too many connections from your IP\r\n');
      socket.close();
      return;
    }

    // Create session
    final session = SMTPSession(
      socket: socket,
      remoteAddress: remoteAddress,
      localDomain: domain,
    );

    // Track session
    _sessions.putIfAbsent(remoteAddress, () => []).add(session);
    _connectionCounts[remoteAddress] = count + 1;

    LogService().log('SMTP Server: New connection from $remoteAddress');

    // Send greeting
    session.send(SMTPResponse.single(
      SMTPCode.ready,
      '$domain ESMTP Geogram ready',
    ));

    // Handle incoming data
    final buffer = StringBuffer();

    socket.listen(
      (data) {
        try {
          buffer.write(utf8.decode(data));
          _processBuffer(session, buffer);
        } catch (e) {
          LogService().log('SMTP Server: Error processing data from $remoteAddress: $e');
        }
      },
      onError: (error) {
        LogService().log('SMTP Server: Socket error from $remoteAddress: $error');
        _closeSession(session);
      },
      onDone: () {
        _closeSession(session);
      },
    );

    // Set connection timeout
    Timer(connectionTimeout, () {
      if (session.state != SMTPState.quit) {
        LogService().log('SMTP Server: Connection timeout for $remoteAddress');
        session.send(SMTPResponse.single(
          SMTPCode.serviceUnavailable,
          'Connection timeout',
        ));
        _closeSession(session);
      }
    });
  }

  /// Process buffered data
  void _processBuffer(SMTPSession session, StringBuffer buffer) {
    final content = buffer.toString();

    // In DATA state, look for end of data marker
    if (session.state == SMTPState.data) {
      if (content.contains(SMTPProtocol.dataEnd)) {
        // Extract message content (everything before the terminator)
        final endIndex = content.indexOf(SMTPProtocol.dataEnd);
        final messageData = content.substring(0, endIndex);
        session.dataBuffer.write(messageData);

        // Process the complete message
        _processMessage(session);

        // Clear buffer and reset for next message
        buffer.clear();
        final remaining = content.substring(endIndex + SMTPProtocol.dataEnd.length);
        if (remaining.isNotEmpty) {
          buffer.write(remaining);
        }
      } else {
        // Check message size limit
        if (content.length > maxMessageSize) {
          session.send(SMTPResponse.single(
            SMTPCode.exceededStorage,
            'Message too large',
          ));
          session.reset();
          buffer.clear();
          return;
        }
        // Keep accumulating data
        return;
      }
    }

    // Process command lines
    while (true) {
      final content = buffer.toString();
      final lineEnd = content.indexOf('\r\n');
      if (lineEnd == -1) break;

      final line = content.substring(0, lineEnd);
      final remaining = content.substring(lineEnd + 2);

      buffer.clear();
      if (remaining.isNotEmpty) {
        buffer.write(remaining);
      }

      _handleCommand(session, SMTPCommand.parse(line));
    }
  }

  /// Handle SMTP command
  void _handleCommand(SMTPSession session, SMTPCommand command) {
    LogService().log('SMTP Server: ${session.remoteAddress} -> ${command.verb} ${command.argument ?? ""}');

    switch (command.verb) {
      case 'EHLO':
        _handleEhlo(session, command);
        break;
      case 'HELO':
        _handleHelo(session, command);
        break;
      case 'MAIL':
        _handleMailFrom(session, command);
        break;
      case 'RCPT':
        _handleRcptTo(session, command);
        break;
      case 'DATA':
        _handleData(session);
        break;
      case 'RSET':
        _handleRset(session);
        break;
      case 'NOOP':
        session.send(SMTPResponse.single(SMTPCode.ok, 'OK'));
        break;
      case 'QUIT':
        _handleQuit(session);
        break;
      case 'VRFY':
      case 'EXPN':
        session.send(SMTPResponse.single(SMTPCode.notImplemented, 'Command not implemented'));
        break;
      case '':
        // Empty command, ignore
        break;
      default:
        session.send(SMTPResponse.single(SMTPCode.syntaxError, 'Unknown command'));
    }
  }

  /// Handle EHLO command
  void _handleEhlo(SMTPSession session, SMTPCommand command) {
    if (command.argument == null || command.argument!.isEmpty) {
      session.send(SMTPResponse.single(SMTPCode.paramSyntaxError, 'Hostname required'));
      return;
    }

    session.clientDomain = command.argument;
    session.state = SMTPState.greeted;
    session.extensions = {'SIZE', '8BITMIME', 'ENHANCEDSTATUSCODES', 'PIPELINING'};

    final extensions = SMTPProtocol.buildExtensions(
      domain: domain,
      maxSize: maxMessageSize,
    );

    session.send(SMTPResponse.multi(SMTPCode.ok, extensions));
  }

  /// Handle HELO command
  void _handleHelo(SMTPSession session, SMTPCommand command) {
    if (command.argument == null || command.argument!.isEmpty) {
      session.send(SMTPResponse.single(SMTPCode.paramSyntaxError, 'Hostname required'));
      return;
    }

    session.clientDomain = command.argument;
    session.state = SMTPState.greeted;

    session.send(SMTPResponse.single(SMTPCode.ok, 'Hello ${command.argument}'));
  }

  /// Handle MAIL FROM command
  void _handleMailFrom(SMTPSession session, SMTPCommand command) {
    if (session.state != SMTPState.greeted && session.state != SMTPState.rcptTo) {
      session.send(SMTPResponse.single(SMTPCode.badSequence, 'Send EHLO/HELO first'));
      return;
    }

    final address = command.extractAddress();
    if (address == null || (address.isNotEmpty && !SMTPProtocol.isValidEmail(address))) {
      session.send(SMTPResponse.single(SMTPCode.paramSyntaxError, 'Invalid address'));
      return;
    }

    session.mailFrom = address.isEmpty ? 'null@${session.clientDomain}' : address;
    session.rcptTo = [];
    session.dataBuffer = StringBuffer();
    session.state = SMTPState.mailFrom;

    session.send(SMTPResponse.single(SMTPCode.ok, 'OK'));
  }

  /// Handle RCPT TO command
  void _handleRcptTo(SMTPSession session, SMTPCommand command) {
    if (session.state != SMTPState.mailFrom && session.state != SMTPState.rcptTo) {
      session.send(SMTPResponse.single(SMTPCode.badSequence, 'Send MAIL FROM first'));
      return;
    }

    final address = command.extractAddress();
    if (address == null || !SMTPProtocol.isValidEmail(address)) {
      session.send(SMTPResponse.single(SMTPCode.paramSyntaxError, 'Invalid address'));
      return;
    }

    // Check if recipient is local
    final recipientDomain = SMTPProtocol.getDomain(address);
    if (recipientDomain?.toLowerCase() != domain.toLowerCase()) {
      // Not for our domain - refuse (no relay)
      session.send(SMTPResponse.single(
        SMTPCode.userNotLocal,
        'Relay access denied',
      ));
      return;
    }

    // Validate recipient if callback is set
    if (validateRecipient != null && !validateRecipient!(address)) {
      session.send(SMTPResponse.single(
        SMTPCode.mailboxNotFound,
        'User unknown',
      ));
      return;
    }

    session.rcptTo.add(address);
    session.state = SMTPState.rcptTo;

    session.send(SMTPResponse.single(SMTPCode.ok, 'OK'));
  }

  /// Handle DATA command
  void _handleData(SMTPSession session) {
    if (session.state != SMTPState.rcptTo) {
      session.send(SMTPResponse.single(SMTPCode.badSequence, 'Send RCPT TO first'));
      return;
    }

    if (session.rcptTo.isEmpty) {
      session.send(SMTPResponse.single(SMTPCode.badSequence, 'No valid recipients'));
      return;
    }

    session.state = SMTPState.data;
    session.dataBuffer = StringBuffer();

    session.send(SMTPResponse.single(
      SMTPCode.startMailInput,
      'Start mail input; end with <CRLF>.<CRLF>',
    ));
  }

  /// Handle RSET command
  void _handleRset(SMTPSession session) {
    session.reset();
    session.send(SMTPResponse.single(SMTPCode.ok, 'OK'));
  }

  /// Handle QUIT command
  void _handleQuit(SMTPSession session) {
    session.send(SMTPResponse.single(SMTPCode.closing, 'Bye')).then((_) {
      _closeSession(session);
    });
  }

  /// Process received message
  Future<void> _processMessage(SMTPSession session) async {
    final rawMessage = SMTPProtocol.unescapeData(session.dataBuffer.toString());

    LogService().log(
      'SMTP Server: Received message from ${session.mailFrom} '
      'to ${session.rcptTo.join(", ")} (${rawMessage.length} bytes)',
    );

    // Deliver message via callback
    bool delivered = false;
    if (onMailReceived != null) {
      try {
        delivered = await onMailReceived!(
          session.mailFrom!,
          session.rcptTo,
          rawMessage,
        );
      } catch (e) {
        LogService().log('SMTP Server: Error delivering message: $e');
      }
    }

    if (delivered) {
      session.send(SMTPResponse.single(SMTPCode.ok, 'Message accepted'));
    } else {
      session.send(SMTPResponse.single(SMTPCode.transactionFailed, 'Delivery failed'));
    }

    // Reset for next message
    session.reset();
  }

  /// Close a session
  void _closeSession(SMTPSession session) {
    if (session.state == SMTPState.quit) return;
    session.close();

    // Remove from tracking
    final sessions = _sessions[session.remoteAddress];
    if (sessions != null) {
      sessions.remove(session);
      if (sessions.isEmpty) {
        _sessions.remove(session.remoteAddress);
      }
    }

    final count = _connectionCounts[session.remoteAddress];
    if (count != null && count > 0) {
      _connectionCounts[session.remoteAddress] = count - 1;
      if (count == 1) {
        _connectionCounts.remove(session.remoteAddress);
      }
    }

    LogService().log('SMTP Server: Session closed for ${session.remoteAddress}');
  }
}

/// MIME message parser for extracting headers and body
class MIMEParser {
  final String rawMessage;
  final Map<String, String> headers = {};
  late final String body;

  MIMEParser(this.rawMessage) {
    _parse();
  }

  void _parse() {
    // Find header/body separator (empty line)
    final separatorIndex = rawMessage.indexOf('\r\n\r\n');
    final headerSection = separatorIndex > 0
        ? rawMessage.substring(0, separatorIndex)
        : rawMessage;
    body = separatorIndex > 0
        ? rawMessage.substring(separatorIndex + 4)
        : '';

    // Parse headers (handle folded lines)
    final lines = headerSection.split('\r\n');
    String? currentHeader;
    StringBuffer currentValue = StringBuffer();

    for (final line in lines) {
      if (line.isEmpty) continue;

      // Folded line (starts with whitespace)
      if (line.startsWith(' ') || line.startsWith('\t')) {
        currentValue.write(' ${line.trim()}');
        continue;
      }

      // Save previous header
      if (currentHeader != null) {
        headers[currentHeader.toLowerCase()] = currentValue.toString();
      }

      // Parse new header
      final colonIndex = line.indexOf(':');
      if (colonIndex > 0) {
        currentHeader = line.substring(0, colonIndex).trim();
        currentValue = StringBuffer(line.substring(colonIndex + 1).trim());
      }
    }

    // Save last header
    if (currentHeader != null) {
      headers[currentHeader.toLowerCase()] = currentValue.toString();
    }
  }

  String? get from => headers['from'];
  String? get to => headers['to'];
  String? get subject => headers['subject'];
  String? get date => headers['date'];
  String? get messageId => headers['message-id'];
  String? get contentType => headers['content-type'];
  String? get inReplyTo => headers['in-reply-to'];
  String? get references => headers['references'];

  /// Extract email address from header value
  static String? extractEmail(String? headerValue) {
    if (headerValue == null) return null;

    // Try angle bracket format: "Name <email@domain.com>"
    final match = RegExp(r'<([^>]+)>').firstMatch(headerValue);
    if (match != null) {
      return match.group(1);
    }

    // Plain email format
    if (headerValue.contains('@')) {
      return headerValue.trim();
    }

    return null;
  }

  /// Extract display name from header value
  static String? extractDisplayName(String? headerValue) {
    if (headerValue == null) return null;

    // Format: "Display Name" <email@domain.com>
    final quoteMatch = RegExp(r'"([^"]+)"').firstMatch(headerValue);
    if (quoteMatch != null) {
      return quoteMatch.group(1);
    }

    // Format: Display Name <email@domain.com>
    final angleIndex = headerValue.indexOf('<');
    if (angleIndex > 0) {
      return headerValue.substring(0, angleIndex).trim();
    }

    return null;
  }
}
