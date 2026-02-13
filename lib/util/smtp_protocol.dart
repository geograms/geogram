/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * SMTP Protocol Utilities - Command parsing, response codes, and session handling
 * Used by both SMTPServer and SMTPClient
 */

import 'dart:io';

/// SMTP response codes per RFC 5321
class SMTPCode {
  // 2xx - Success
  static const int ready = 220;
  static const int closing = 221;
  static const int authSuccess = 235;
  static const int ok = 250;
  static const int willForward = 251;

  // 3xx - Intermediate
  static const int startMailInput = 354;
  static const int authContinue = 334;

  // 4xx - Temporary failure
  static const int serviceUnavailable = 421;
  static const int mailboxBusy = 450;
  static const int localError = 451;
  static const int insufficientStorage = 452;

  // 5xx - Permanent failure
  static const int syntaxError = 500;
  static const int paramSyntaxError = 501;
  static const int notImplemented = 502;
  static const int badSequence = 503;
  static const int paramNotImplemented = 504;
  static const int mailboxNotFound = 550;
  static const int userNotLocal = 551;
  static const int exceededStorage = 552;
  static const int mailboxNameInvalid = 553;
  static const int transactionFailed = 554;
  static const int authRequired = 530;
  static const int authFailed = 535;
}

/// SMTP session states
enum SMTPState {
  /// Initial state, waiting for client connection
  connected,

  /// After EHLO/HELO, ready for MAIL command
  greeted,

  /// After MAIL FROM, waiting for RCPT TO
  mailFrom,

  /// After at least one RCPT TO, can receive more or DATA
  rcptTo,

  /// Receiving message data after DATA command
  data,

  /// Session ended
  quit,
}

/// Parsed SMTP command
class SMTPCommand {
  final String verb;
  final String? argument;
  final String raw;

  SMTPCommand({
    required this.verb,
    this.argument,
    required this.raw,
  });

  /// Parse a raw SMTP command line
  factory SMTPCommand.parse(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return SMTPCommand(verb: '', argument: null, raw: line);
    }

    final spaceIndex = trimmed.indexOf(' ');
    if (spaceIndex == -1) {
      return SMTPCommand(
        verb: trimmed.toUpperCase(),
        argument: null,
        raw: line,
      );
    }

    return SMTPCommand(
      verb: trimmed.substring(0, spaceIndex).toUpperCase(),
      argument: trimmed.substring(spaceIndex + 1).trim(),
      raw: line,
    );
  }

  /// Extract email address from angle brackets: <user@domain> -> user@domain
  String? extractAddress() {
    if (argument == null) return null;

    final match = RegExp(r'<([^>]+)>').firstMatch(argument!);
    if (match != null) {
      return match.group(1);
    }

    // Try without angle brackets
    final colonIndex = argument!.indexOf(':');
    if (colonIndex != -1) {
      return argument!.substring(colonIndex + 1).trim();
    }

    return argument!.trim();
  }

  @override
  String toString() => 'SMTPCommand($verb${argument != null ? " $argument" : ""})';
}

/// SMTP response builder
class SMTPResponse {
  final int code;
  final List<String> lines;
  final bool multiline;

  SMTPResponse(this.code, this.lines, {this.multiline = false});

  SMTPResponse.single(this.code, String message)
      : lines = [message],
        multiline = false;

  SMTPResponse.multi(this.code, this.lines) : multiline = true;

  /// Format response for sending over socket
  String format() {
    if (lines.isEmpty) {
      return '$code\r\n';
    }

    if (lines.length == 1 || !multiline) {
      return '$code ${lines.first}\r\n';
    }

    final buffer = StringBuffer();
    for (int i = 0; i < lines.length; i++) {
      final isLast = i == lines.length - 1;
      final separator = isLast ? ' ' : '-';
      buffer.write('$code$separator${lines[i]}\r\n');
    }
    return buffer.toString();
  }

  /// Parse response from server
  static SMTPResponse? parse(String data) {
    final lines = data.split('\r\n').where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return null;

    final codeMatch = RegExp(r'^(\d{3})[ -](.*)$').firstMatch(lines.first);
    if (codeMatch == null) return null;

    final code = int.parse(codeMatch.group(1)!);
    final responseLines = <String>[];

    for (final line in lines) {
      final match = RegExp(r'^\d{3}[ -](.*)$').firstMatch(line);
      if (match != null) {
        responseLines.add(match.group(1)!);
      }
    }

    return SMTPResponse(code, responseLines, multiline: lines.length > 1);
  }

  bool get isSuccess => code >= 200 && code < 300;
  bool get isIntermediate => code >= 300 && code < 400;
  bool get isTransientFailure => code >= 400 && code < 500;
  bool get isPermanentFailure => code >= 500 && code < 600;

  @override
  String toString() => 'SMTPResponse($code: ${lines.join(", ")})';
}

/// SMTP session state manager
class SMTPSession {
  final Socket socket;
  final String remoteAddress;
  final String localDomain;

  SMTPState state = SMTPState.connected;
  String? clientDomain;
  String? mailFrom;
  List<String> rcptTo = [];
  StringBuffer dataBuffer = StringBuffer();

  /// Extensions advertised by server (for client) or supported (for server)
  Set<String> extensions = {};

  /// Whether this session is authenticated
  bool authenticated = false;
  String? authenticatedUser;

  SMTPSession({
    required this.socket,
    required this.remoteAddress,
    required this.localDomain,
  });

  /// Send response to client/server
  Future<void> send(SMTPResponse response) async {
    socket.write(response.format());
    await socket.flush();
  }

  /// Send raw data (for DATA content)
  Future<void> sendRaw(String data) async {
    socket.write(data);
    await socket.flush();
  }

  /// Reset session state (RSET command)
  void reset() {
    mailFrom = null;
    rcptTo = [];
    dataBuffer = StringBuffer();
    if (state != SMTPState.connected) {
      state = SMTPState.greeted;
    }
  }

  /// Close session
  Future<void> close() async {
    state = SMTPState.quit;
    try {
      await socket.close();
    } catch (_) {
      // Socket may already be closing or in a bad state
    }
  }

  @override
  String toString() =>
      'SMTPSession(state: $state, from: $mailFrom, to: ${rcptTo.length} recipients)';
}

/// SMTP protocol utilities
class SMTPProtocol {
  /// CRLF line ending per SMTP spec
  static const String crlf = '\r\n';

  /// End of DATA marker
  static const String dataEnd = '\r\n.\r\n';

  /// Maximum line length per RFC 5321
  static const int maxLineLength = 998;

  /// Validate email address format
  static bool isValidEmail(String email) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
  }

  /// Extract domain from email address
  static String? getDomain(String email) {
    final atIndex = email.indexOf('@');
    if (atIndex <= 0 || atIndex >= email.length - 1) return null;
    return email.substring(atIndex + 1).toLowerCase();
  }

  /// Extract local part from email address
  static String? getLocalPart(String email) {
    final atIndex = email.indexOf('@');
    if (atIndex <= 0) return null;
    return email.substring(0, atIndex);
  }

  /// Escape data for transmission (dot stuffing per RFC 5321)
  static String escapeData(String data) {
    // Lines starting with a dot must be dot-stuffed
    return data.replaceAllMapped(
      RegExp(r'^\.', multiLine: true),
      (m) => '..',
    );
  }

  /// Unescape received data (reverse dot stuffing)
  static String unescapeData(String data) {
    return data.replaceAllMapped(
      RegExp(r'^\.\.', multiLine: true),
      (m) => '.',
    );
  }

  /// Build EHLO extensions list for server greeting
  static List<String> buildExtensions({
    required String domain,
    bool auth = false,
    bool starttls = false,
    int maxSize = 10485760, // 10MB default
  }) {
    final extensions = <String>[
      domain,
      'SIZE $maxSize',
      '8BITMIME',
      'ENHANCEDSTATUSCODES',
      'PIPELINING',
    ];

    if (auth) {
      extensions.add('AUTH PLAIN LOGIN');
    }

    if (starttls) {
      extensions.add('STARTTLS');
    }

    return extensions;
  }

  /// Generate unique Message-ID
  static String generateMessageId(String domain) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = DateTime.now().microsecond;
    return '<$timestamp.$random@$domain>';
  }

  /// Format date for email headers (RFC 5322)
  static String formatDate(DateTime date) {
    final days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];

    final utc = date.toUtc();
    final dayName = days[utc.weekday - 1];
    final monthName = months[utc.month - 1];

    return '$dayName, ${utc.day} $monthName ${utc.year} '
        '${utc.hour.toString().padLeft(2, '0')}:'
        '${utc.minute.toString().padLeft(2, '0')}:'
        '${utc.second.toString().padLeft(2, '0')} +0000';
  }
}
