/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP Server Protocol - Session state machine, stanza parsing, XML builders
 * Used by XmppServer for station-hosted XMPP service
 *
 * Follows the same raw-socket + regex-parsing pattern as smtp_protocol.dart.
 * No XML parser dependency — stanza boundaries detected via regex.
 */

import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// XMPP Namespaces
// ---------------------------------------------------------------------------

class XmppNs {
  static const String stream = 'http://etherx.jabber.org/streams';
  static const String client = 'jabber:client';
  static const String sasl = 'urn:ietf:params:xml:ns:xmpp-sasl';
  static const String tls = 'urn:ietf:params:xml:ns:xmpp-tls';
  static const String bind = 'urn:ietf:params:xml:ns:xmpp-bind';
  static const String session = 'urn:ietf:params:xml:ns:xmpp-session';
  static const String register = 'jabber:iq:register';
  static const String disco = 'http://jabber.org/protocol/disco';
  static const String discoInfo = 'http://jabber.org/protocol/disco#info';
  static const String discoItems = 'http://jabber.org/protocol/disco#items';
  static const String muc = 'http://jabber.org/protocol/muc';
  static const String mucUser = 'http://jabber.org/protocol/muc#user';
  static const String mucAdmin = 'http://jabber.org/protocol/muc#admin';
  static const String ping = 'urn:xmpp:ping';
  static const String roster = 'jabber:iq:roster';
  static const String vcard = 'vcard-temp';
  static const String server = 'jabber:server';
  static const String dialback = 'jabber:server:dialback';
}

// ---------------------------------------------------------------------------
// Session state enum
// ---------------------------------------------------------------------------

enum XmppServerState {
  /// TCP connected, waiting for initial <stream:stream>
  connected,

  /// Initial stream opened, offered STARTTLS
  streamOpened,

  /// TLS negotiated, waiting for re-opened stream
  tlsEstablished,

  /// Stream re-opened after TLS, offered SASL + register
  awaitingAuth,

  /// SASL auth succeeded, waiting for stream restart
  authenticated,

  /// Post-auth stream opened, offered bind/session
  awaitingBind,

  /// Resource bound, fully operational
  bound,

  /// Session ended
  closed,
}

// ---------------------------------------------------------------------------
// Parsed stanza
// ---------------------------------------------------------------------------

class XmppStanza {
  final String name; // 'iq', 'message', 'presence', 'auth', 'starttls', etc.
  final Map<String, String> attributes;
  final String rawXml;

  XmppStanza({required this.name, required this.attributes, required this.rawXml});

  String? get id => attributes['id'];
  String? get type => attributes['type'];
  String? get to => attributes['to'];
  String? get from => attributes['from'];
  String? get xmlns => attributes['xmlns'];

  /// Extract inner text of a child element by tag name
  String? childText(String tag) {
    final pattern = RegExp('<$tag[^>]*>([^<]*)</$tag>', caseSensitive: false);
    final match = pattern.firstMatch(rawXml);
    return match?.group(1);
  }

  /// Check if a child element exists
  bool hasChild(String tag) {
    return rawXml.contains('<$tag') || rawXml.contains('<$tag>');
  }

  /// Extract xmlns attribute from a child element
  String? childXmlns(String tag) {
    final pattern = RegExp('<$tag[^>]*xmlns=["\']([^"\']*)["\']', caseSensitive: false);
    final match = pattern.firstMatch(rawXml);
    return match?.group(1);
  }

  /// Extract a specific attribute from a child element
  String? childAttr(String tag, String attr) {
    final pattern = RegExp('<$tag[^>]*$attr=["\']([^"\']*)["\']', caseSensitive: false);
    final match = pattern.firstMatch(rawXml);
    return match?.group(1);
  }

  /// Extract the body text from a message stanza
  String? get body => childText('body');

  @override
  String toString() => 'XmppStanza($name, id=$id, type=$type, to=$to, from=$from)';
}

// ---------------------------------------------------------------------------
// Stanza extractor — finds complete stanzas in a buffer
// ---------------------------------------------------------------------------

class XmppStanzaExtractor {
  /// Stanza closing tags we watch for
  static final _closingTags = RegExp(
    r'</(?:iq|message|presence|auth|response|starttls|register|db:result|db:verify|stream:features|features|failure)>',
    caseSensitive: false,
  );

  /// Self-closing stanzas (e.g. <presence/>, <iq .../>)
  static final _selfClosing = RegExp(
    r'<(?:iq|message|presence|auth|response|starttls|register|db:result|db:verify|proceed|failure)\b[^>]*/\s*>',
    caseSensitive: false,
  );

  /// Stream open tag (not a real stanza but we need to detect it)
  static final _streamOpen = RegExp(
    r"<\?xml[^>]*\?>|<stream:stream\b[^>]*>",
    caseSensitive: false,
  );

  /// Stream close
  static final _streamClose = RegExp(r'</stream:stream>', caseSensitive: false);

  /// Extract all complete stanzas from buffer, returning (stanzas, remaining)
  static (List<String>, String) extract(String buffer) {
    final stanzas = <String>[];
    var remaining = buffer;

    while (remaining.isNotEmpty) {
      remaining = remaining.trimLeft();
      if (remaining.isEmpty) break;

      // Check for stream open
      final streamMatch = _streamOpen.firstMatch(remaining);
      if (streamMatch != null && streamMatch.start == 0) {
        stanzas.add(streamMatch.group(0)!);
        remaining = remaining.substring(streamMatch.end);
        continue;
      }

      // Check for stream close
      final closeMatch = _streamClose.firstMatch(remaining);
      if (closeMatch != null && closeMatch.start == 0) {
        stanzas.add(closeMatch.group(0)!);
        remaining = remaining.substring(closeMatch.end);
        continue;
      }

      // Check for self-closing stanza
      final selfMatch = _selfClosing.firstMatch(remaining);
      if (selfMatch != null && selfMatch.start == 0) {
        stanzas.add(selfMatch.group(0)!);
        remaining = remaining.substring(selfMatch.end);
        continue;
      }

      // Check for closing tag
      final endMatch = _closingTags.firstMatch(remaining);
      if (endMatch != null) {
        stanzas.add(remaining.substring(0, endMatch.end));
        remaining = remaining.substring(endMatch.end);
        continue;
      }

      // No complete stanza found
      break;
    }

    return (stanzas, remaining);
  }
}

// ---------------------------------------------------------------------------
// Stanza parser — extracts name + attributes from raw XML
// ---------------------------------------------------------------------------

class XmppStanzaParser {
  static final _tagPattern = RegExp(r'<([a-zA-Z:]+)\s*([^>]*)');
  static final _attrPattern = RegExp(r'''(\w+)=["']([^"']*)["']''');

  static XmppStanza parse(String raw) {
    final tagMatch = _tagPattern.firstMatch(raw);
    if (tagMatch == null) {
      return XmppStanza(name: 'unknown', attributes: {}, rawXml: raw);
    }

    var name = tagMatch.group(1)!;
    // Preserve db: prefix for dialback stanzas, strip other namespace prefixes
    if (name.startsWith('db:')) {
      // keep as-is (db:result, db:verify)
    } else if (name.contains(':')) {
      name = name.split(':').last;
    }

    final attrString = tagMatch.group(2) ?? '';
    final attrs = <String, String>{};
    for (final m in _attrPattern.allMatches(attrString)) {
      attrs[m.group(1)!] = m.group(2)!;
    }

    return XmppStanza(name: name, attributes: attrs, rawXml: raw);
  }
}

// ---------------------------------------------------------------------------
// SASL PLAIN decoder
// ---------------------------------------------------------------------------

class SaslPlain {
  final String? authzid; // authorization identity (usually empty)
  final String username;
  final String password;

  SaslPlain({this.authzid, required this.username, required this.password});

  /// Decode SASL PLAIN base64 payload: base64(\0username\0password)
  static SaslPlain? decode(String base64Payload) {
    try {
      final bytes = base64.decode(base64Payload.trim());
      final decoded = utf8.decode(bytes);

      // Format: [authzid]\0authcid\0passwd
      final parts = decoded.split('\x00');
      if (parts.length < 3) return null;

      return SaslPlain(
        authzid: parts[0].isEmpty ? null : parts[0],
        username: parts[1],
        password: parts[2],
      );
    } catch (_) {
      return null;
    }
  }

  /// Encode SASL PLAIN credentials to base64
  static String encode(String username, String password) {
    return base64.encode(utf8.encode('\x00$username\x00$password'));
  }
}

// ---------------------------------------------------------------------------
// XML builders for server responses
// ---------------------------------------------------------------------------

class XmppXml {
  /// Stream open response
  static String streamOpen({
    required String from,
    required String id,
    String version = '1.0',
  }) {
    return "<?xml version='1.0'?>"
        "<stream:stream "
        "xmlns='${ XmppNs.client}' "
        "xmlns:stream='${XmppNs.stream}' "
        "from='$from' "
        "id='$id' "
        "version='$version' "
        "xml:lang='en'>";
  }

  /// Stream close
  static String streamClose() => '</stream:stream>';

  /// Features: STARTTLS only (pre-TLS)
  static String featuresStartTls() {
    return '<stream:features>'
        '<starttls xmlns="${XmppNs.tls}"><required/></starttls>'
        '</stream:features>';
  }

  /// Features: SASL + in-band registration (post-TLS, pre-auth)
  static String featuresSaslAndRegister() {
    return '<stream:features>'
        '<mechanisms xmlns="${XmppNs.sasl}">'
        '<mechanism>PLAIN</mechanism>'
        '</mechanisms>'
        '<register xmlns="${XmppNs.register}"/>'
        '</stream:features>';
  }

  /// Features: bind + session (post-auth)
  static String featuresBindSession() {
    return '<stream:features>'
        '<bind xmlns="${XmppNs.bind}"/>'
        '<session xmlns="${XmppNs.session}"/>'
        '</stream:features>';
  }

  /// STARTTLS proceed
  static String tlsProceed() => '<proceed xmlns="${XmppNs.tls}"/>';

  /// STARTTLS failure
  static String tlsFailure() => '<failure xmlns="${XmppNs.tls}"/>';

  /// SASL success
  static String saslSuccess() => '<success xmlns="${XmppNs.sasl}"/>';

  /// SASL failure
  static String saslFailure(String reason) {
    return '<failure xmlns="${XmppNs.sasl}">'
        '<$reason/>'
        '</failure>';
  }

  /// IQ result
  static String iqResult({required String id, String? to, String? innerXml}) {
    final toAttr = to != null ? " to='$to'" : '';
    final inner = innerXml ?? '';
    return "<iq type='result' id='$id'$toAttr>$inner</iq>";
  }

  /// IQ error
  static String iqError({
    required String id,
    String? to,
    required String errorType,
    required String condition,
  }) {
    final toAttr = to != null ? " to='$to'" : '';
    return "<iq type='error' id='$id'$toAttr>"
        "<error type='$errorType'>"
        "<$condition xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>"
        "</error></iq>";
  }

  /// Bind result with full JID
  static String bindResult({required String id, required String jid, String? to}) {
    final toAttr = to != null ? " to='$to'" : '';
    return "<iq type='result' id='$id'$toAttr>"
        "<bind xmlns='${XmppNs.bind}'>"
        "<jid>$jid</jid>"
        "</bind></iq>";
  }

  /// Session result
  static String sessionResult({required String id, String? to}) {
    final toAttr = to != null ? " to='$to'" : '';
    return "<iq type='result' id='$id'$toAttr/>";
  }

  /// Registration form (XEP-0077)
  static String registerForm({required String id, String? to}) {
    final toAttr = to != null ? " to='$to'" : '';
    return "<iq type='result' id='$id'$toAttr>"
        "<query xmlns='${XmppNs.register}'>"
        "<instructions>Choose a username and password</instructions>"
        "<username/>"
        "<password/>"
        "</query></iq>";
  }

  /// Registration success
  static String registerSuccess({required String id, String? to}) {
    return iqResult(id: id, to: to);
  }

  /// Registration conflict (username taken)
  static String registerConflict({required String id, String? to}) {
    return iqError(
      id: id,
      to: to,
      errorType: 'cancel',
      condition: 'conflict',
    );
  }

  /// Message stanza
  static String message({
    required String from,
    required String to,
    required String type,
    String? id,
    String? body,
  }) {
    final idAttr = id != null ? " id='$id'" : '';
    final bodyXml = body != null ? '<body>${_escapeXml(body)}</body>' : '';
    return "<message from='$from' to='$to' type='$type'$idAttr>$bodyXml</message>";
  }

  /// Presence stanza
  static String presence({
    String? from,
    String? to,
    String? type,
    String? innerXml,
  }) {
    final fromAttr = from != null ? " from='$from'" : '';
    final toAttr = to != null ? " to='$to'" : '';
    final typeAttr = type != null ? " type='$type'" : '';
    final inner = innerXml ?? '';
    return "<presence$fromAttr$toAttr$typeAttr>$inner</presence>";
  }

  /// MUC presence with status codes (join/leave)
  static String mucPresence({
    required String from,
    required String to,
    String? type,
    required String affiliation,
    required String role,
    List<int> statusCodes = const [],
  }) {
    final typeAttr = type != null ? " type='$type'" : '';
    final statuses = statusCodes.map((c) => "<status code='$c'/>").join();
    return "<presence from='$from' to='$to'$typeAttr>"
        "<x xmlns='${XmppNs.mucUser}'>"
        "<item affiliation='$affiliation' role='$role'/>"
        "$statuses"
        "</x></presence>";
  }

  /// Disco#info result for the server
  static String discoInfoServer({
    required String id,
    required String to,
    required String domain,
  }) {
    return "<iq type='result' id='$id' to='$to' from='$domain'>"
        "<query xmlns='${XmppNs.discoInfo}'>"
        "<identity category='server' type='im' name='Geogram XMPP'/>"
        "<feature var='${XmppNs.discoInfo}'/>"
        "<feature var='${XmppNs.discoItems}'/>"
        "<feature var='${XmppNs.register}'/>"
        "<feature var='${XmppNs.muc}'/>"
        "<feature var='${XmppNs.ping}'/>"
        "</query></iq>";
  }

  /// Disco#info result for a MUC room
  static String discoInfoRoom({
    required String id,
    required String to,
    required String roomJid,
    required String roomName,
  }) {
    return "<iq type='result' id='$id' to='$to' from='$roomJid'>"
        "<query xmlns='${XmppNs.discoInfo}'>"
        "<identity category='conference' type='text' name='$roomName'/>"
        "<feature var='${XmppNs.muc}'/>"
        "<feature var='muc_open'/>"
        "<feature var='muc_unmoderated'/>"
        "</query></iq>";
  }

  /// Disco#items result (room list)
  static String discoItems({
    required String id,
    required String to,
    required String from,
    required List<MapEntry<String, String>> items, // jid -> name
  }) {
    final itemsXml = items.map((e) =>
      "<item jid='${e.key}' name='${_escapeXml(e.value)}'/>").join();
    return "<iq type='result' id='$id' to='$to' from='$from'>"
        "<query xmlns='${XmppNs.discoItems}'>$itemsXml</query></iq>";
  }

  /// Roster result (empty — we don't manage server-side rosters in v1)
  static String rosterResult({required String id, String? to}) {
    final toAttr = to != null ? " to='$to'" : '';
    return "<iq type='result' id='$id'$toAttr>"
        "<query xmlns='${XmppNs.roster}'/></iq>";
  }

  /// Ping pong result
  static String pong({required String id, required String from, required String to}) {
    return "<iq type='result' id='$id' from='$from' to='$to'/>";
  }

  /// Stream error
  static String streamError(String condition) {
    return '<stream:error>'
        '<$condition xmlns="urn:ietf:params:xml:ns:xmpp-streams"/>'
        '</stream:error>';
  }

  /// Escape XML special characters
  static String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll("'", '&apos;')
        .replaceAll('"', '&quot;');
  }
}

// ---------------------------------------------------------------------------
// JID utilities
// ---------------------------------------------------------------------------

class Jid {
  final String local; // user part
  final String domain;
  final String? resource;

  Jid({required this.local, required this.domain, this.resource});

  String get bare => '$local@$domain';
  String get full => resource != null ? '$local@$domain/$resource' : bare;

  static Jid? parse(String jid) {
    if (jid.isEmpty) return null;
    final slashIdx = jid.indexOf('/');
    final atIdx = jid.indexOf('@');

    if (atIdx < 1) return null;

    String? resource;
    String domainPart;

    if (slashIdx > atIdx) {
      resource = jid.substring(slashIdx + 1);
      domainPart = jid.substring(atIdx + 1, slashIdx);
    } else {
      domainPart = jid.substring(atIdx + 1);
    }

    return Jid(
      local: jid.substring(0, atIdx),
      domain: domainPart,
      resource: resource,
    );
  }

  @override
  String toString() => full;
}

// ---------------------------------------------------------------------------
// Server session — tracks state for one connected client
// ---------------------------------------------------------------------------

class XmppServerSession {
  final Socket socket;
  final String remoteAddress;
  final String serverDomain;
  final String streamId;

  XmppServerState state = XmppServerState.connected;
  String? username;
  String? resource;
  Jid? jid;

  /// Write serialization to avoid concurrent IOSink writes
  Future<void> _pendingWrite = Future.value();

  /// Await all pending writes (e.g. before STARTTLS upgrade)
  Future<void> get pendingWrite => _pendingWrite;

  /// Rooms this session has joined: roomJid -> nickname
  final Map<String, String> joinedRooms = {};

  /// Last activity timestamp
  DateTime lastActivity = DateTime.now();

  /// Whether the underlying socket has been upgraded to TLS
  bool isTls = false;

  /// The upgraded secure socket (after STARTTLS)
  SecureSocket? secureSocket;

  XmppServerSession({
    required this.socket,
    required this.remoteAddress,
    required this.serverDomain,
    required this.streamId,
  });

  /// Send raw XML string with write serialization
  void send(String xml) {
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        final sink = secureSocket ?? socket;
        sink.write(xml);
        await sink.flush();
      } catch (_) {
        // Socket may have been closed
      }
    });
  }

  /// Close the connection
  Future<void> close() async {
    try {
      send(XmppXml.streamClose());
      await _pendingWrite;
      if (secureSocket != null) {
        await secureSocket!.close();
      } else {
        await socket.close();
      }
    } catch (_) {
      // Best effort
    }
    state = XmppServerState.closed;
  }

  /// Bare JID or null
  String? get bareJid => jid?.bare;

  /// Full JID or null
  String? get fullJid => jid?.full;
}
