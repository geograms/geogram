/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP server connection configuration.
 * Persisted as JSON via ProfileStorage at teleport/xmpp/config.json.
 */

class XmppServerConfig {
  final String id;
  final String name;
  final String host;
  final int port;
  final bool directTls;
  final String? jid;
  final String? password;
  final String? conferenceService;
  final List<String> autoJoinRooms;
  final bool autoConnect;

  const XmppServerConfig({
    required this.id,
    required this.name,
    required this.host,
    this.port = 5222,
    this.directTls = false,
    this.jid,
    this.password,
    this.conferenceService,
    this.autoJoinRooms = const [],
    this.autoConnect = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'directTls': directTls,
        'jid': jid,
        'password': password,
        'conferenceService': conferenceService,
        'autoJoinRooms': autoJoinRooms,
        'autoConnect': autoConnect,
      };

  factory XmppServerConfig.fromJson(Map<String, dynamic> json) {
    return XmppServerConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int? ?? 5222,
      directTls: json['directTls'] as bool? ?? false,
      jid: json['jid'] as String?,
      password: json['password'] as String?,
      conferenceService: json['conferenceService'] as String?,
      autoJoinRooms: (json['autoJoinRooms'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      autoConnect: json['autoConnect'] as bool? ?? false,
    );
  }

  XmppServerConfig copyWith({
    String? name,
    String? host,
    int? port,
    bool? directTls,
    String? jid,
    String? password,
    String? conferenceService,
    List<String>? autoJoinRooms,
    bool? autoConnect,
  }) {
    return XmppServerConfig(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      directTls: directTls ?? this.directTls,
      jid: jid ?? this.jid,
      password: password ?? this.password,
      conferenceService: conferenceService ?? this.conferenceService,
      autoJoinRooms: autoJoinRooms ?? this.autoJoinRooms,
      autoConnect: autoConnect ?? this.autoConnect,
    );
  }

  /// Derive default conference service from JID domain.
  String get derivedConferenceService {
    if (conferenceService != null && conferenceService!.isNotEmpty) {
      return conferenceService!;
    }
    // Try to derive from JID
    if (jid != null && jid!.contains('@')) {
      final domain = jid!.split('@').last;
      return 'conference.$domain';
    }
    return 'conference.$host';
  }

  /// Well-known XMPP server presets, sorted by reachability and latency.
  /// Source: https://list.jabber.at/ — probed Feb 2026.
  /// Uses DirectTLS (port 5223) — whixp 3.0.0 has a STARTTLS race condition
  /// that causes WRONG_VERSION_NUMBER errors on port 5222.
  static const List<XmppServerConfig> presets = [
    // --- Tier 1: Low latency, verified reachable (<100ms) ---
    XmppServerConfig(
      id: 'yax',
      name: 'yax.im',
      host: 'yax.im',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.yax.im',
    ),
    XmppServerConfig(
      id: 'conversations',
      name: 'conversations.im',
      host: 'conversations.im',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.conversations.im',
    ),
    XmppServerConfig(
      id: 'magicbroccoli',
      name: 'magicbroccoli.de',
      host: 'magicbroccoli.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.magicbroccoli.de',
    ),
    XmppServerConfig(
      id: 'disroot',
      name: 'disroot.org',
      host: 'disroot.org',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.disroot.org',
    ),
    XmppServerConfig(
      id: 'planetjabber',
      name: 'planetjabber.de',
      host: 'planetjabber.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.planetjabber.de',
    ),
    XmppServerConfig(
      id: 'twattle',
      name: 'twattle.net',
      host: 'twattle.net',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.twattle.net',
    ),
    XmppServerConfig(
      id: 'shad0w',
      name: 'shad0w.io',
      host: 'shad0w.io',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.shad0w.io',
    ),
    XmppServerConfig(
      id: 'jabber_de',
      name: 'jabber.de',
      host: 'jabber.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabber.de',
    ),
    XmppServerConfig(
      id: 'linuxlovers',
      name: 'linuxlovers.at',
      host: 'linuxlovers.at',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.linuxlovers.at',
    ),
    XmppServerConfig(
      id: 'a3pm',
      name: 'a3.pm',
      host: 'a3.pm',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.a3.pm',
    ),
    XmppServerConfig(
      id: 'monocles',
      name: 'monocles.de',
      host: 'monocles.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.monocles.de',
    ),
    XmppServerConfig(
      id: 'pimux',
      name: 'pimux.de',
      host: 'pimux.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.pimux.de',
    ),
    XmppServerConfig(
      id: 'jabber_cz',
      name: 'jabber.cz',
      host: 'jabber.cz',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabber.cz',
    ),
    XmppServerConfig(
      id: 'xmpp_zone',
      name: 'xmpp.zone',
      host: 'xmpp.zone',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.xmpp.zone',
    ),
    XmppServerConfig(
      id: 'dismail',
      name: 'dismail.de',
      host: 'dismail.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.dismail.de',
    ),
    XmppServerConfig(
      id: 'jabber_at',
      name: 'jabber.at',
      host: 'jabber.at',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabber.at',
    ),
    XmppServerConfig(
      id: '5222',
      name: '5222.de',
      host: '5222.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.5222.de',
    ),
    XmppServerConfig(
      id: 'movim',
      name: 'movim.eu',
      host: 'movim.eu',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.movim.eu',
    ),
    XmppServerConfig(
      id: 'jabjab',
      name: 'jabjab.de',
      host: 'jabjab.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabjab.de',
    ),
    XmppServerConfig(
      id: '01337',
      name: '01337.io',
      host: '01337.io',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.01337.io',
    ),
    XmppServerConfig(
      id: 'jabbersone',
      name: 'jabbers.one',
      host: 'jabbers.one',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabbers.one',
    ),
    XmppServerConfig(
      id: 'draugr',
      name: 'draugr.de',
      host: 'draugr.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.draugr.de',
    ),
    XmppServerConfig(
      id: 'jabim',
      name: 'jab.im',
      host: 'jab.im',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jab.im',
    ),
    XmppServerConfig(
      id: 'jabbim',
      name: 'jabbim.com',
      host: 'jabbim.com',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabbim.com',
    ),
    XmppServerConfig(
      id: 'jabb3r',
      name: 'jabb3r.org',
      host: 'jabb3r.org',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabb3r.org',
    ),
    XmppServerConfig(
      id: 'hotchilli',
      name: 'jabber.hot-chilli.eu',
      host: 'jabber.hot-chilli.eu',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabber.hot-chilli.eu',
    ),
    // --- Tier 2: Medium latency (100–200ms) ---
    XmppServerConfig(
      id: 'anoxinon',
      name: 'anoxinon.me',
      host: 'anoxinon.me',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.anoxinon.me',
    ),
    XmppServerConfig(
      id: 'creep',
      name: 'creep.im',
      host: 'creep.im',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.creep.im',
    ),
    XmppServerConfig(
      id: 'xmpp_is',
      name: 'xmpp.is',
      host: 'xmpp.is',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.xmpp.is',
    ),
    XmppServerConfig(
      id: 'rows',
      name: 'rows.im',
      host: 'rows.im',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.rows.im',
    ),
    XmppServerConfig(
      id: 'eigenlab',
      name: 'eigenlab.org',
      host: 'eigenlab.org',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.eigenlab.org',
    ),
    // --- Tier 3: Higher latency (200ms+) ---
    XmppServerConfig(
      id: 'tigase',
      name: 'tigase.im',
      host: 'tigase.im',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.tigase.im',
    ),
    XmppServerConfig(
      id: 'sure',
      name: 'sure.im',
      host: 'sure.im',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.sure.im',
    ),
    XmppServerConfig(
      id: 'jabber_today',
      name: 'jabber.today',
      host: 'jabber.today',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabber.today',
    ),
    XmppServerConfig(
      id: 'chatterboxtown',
      name: 'chatterboxtown.us',
      host: 'chatterboxtown.us',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.chatterboxtown.us',
    ),
    XmppServerConfig(
      id: 'chinwag',
      name: 'chinwag.im',
      host: 'chinwag.im',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.chinwag.im',
    ),
    XmppServerConfig(
      id: 'xmpp_jp',
      name: 'xmpp.jp',
      host: 'xmpp.jp',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.xmpp.jp',
    ),
    XmppServerConfig(
      id: 'linux_monster',
      name: 'linux.monster',
      host: 'linux.monster',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.linux.monster',
    ),
  ];
}
