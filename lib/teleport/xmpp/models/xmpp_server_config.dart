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

  /// Free XMPP server presets from the xmpp-providers directory.
  /// Source: https://data.xmpp.net/providers/v2/providers-C.json
  /// Excludes paid servers. Sorted by category (A > B > C).
  /// Uses DirectTLS (port 5223) — whixp 3.0.0 has a STARTTLS race condition
  /// that causes WRONG_VERSION_NUMBER errors on port 5222.
  static const List<XmppServerConfig> presets = [
    // --- Category A: Best reliability, all support in-band registration ---
    XmppServerConfig(
      id: 'yax',
      name: 'yax.im',
      host: 'yax.im',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.yax.im',
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
      id: '07f',
      name: '07f.de',
      host: '07f.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.07f.de',
    ),
    XmppServerConfig(
      id: 'trashserver',
      name: 'trashserver.net',
      host: 'trashserver.net',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.trashserver.net',
    ),
    XmppServerConfig(
      id: 'jabbers_one',
      name: 'jabbers.one',
      host: 'jabbers.one',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabbers.one',
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
      id: 'draugr',
      name: 'draugr.de',
      host: 'draugr.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.draugr.de',
    ),
    XmppServerConfig(
      id: 'xmpp_earth',
      name: 'xmpp.earth',
      host: 'xmpp.earth',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.xmpp.earth',
    ),
    XmppServerConfig(
      id: 'xmpp_party',
      name: 'xmpp.party',
      host: 'xmpp.party',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.xmpp.party',
    ),
    XmppServerConfig(
      id: 'chatrix',
      name: 'chatrix.one',
      host: 'chatrix.one',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.chatrix.one',
    ),
    XmppServerConfig(
      id: 'hookipa',
      name: 'hookipa.net',
      host: 'hookipa.net',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.hookipa.net',
    ),
    XmppServerConfig(
      id: 'chalec',
      name: 'chalec.org',
      host: 'chalec.org',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.chalec.org',
    ),
    XmppServerConfig(
      id: 'chapril',
      name: 'chapril.org',
      host: 'chapril.org',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.chapril.org',
    ),
    XmppServerConfig(
      id: 'chat_between_us',
      name: 'chat.between-us.online',
      host: 'chat.between-us.online',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.chat.between-us.online',
    ),
    XmppServerConfig(
      id: 'jabber_germany',
      name: 'jabber-germany.de',
      host: 'jabber-germany.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabber-germany.de',
    ),
    XmppServerConfig(
      id: 'jabber_fr',
      name: 'jabber.fr',
      host: 'jabber.fr',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabber.fr',
    ),
    XmppServerConfig(
      id: 'jabber_vg',
      name: 'jabber.vg',
      host: 'jabber.vg',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabber.vg',
    ),
    XmppServerConfig(
      id: 'projectsegfault',
      name: 'projectsegfau.lt',
      host: 'projectsegfau.lt',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.projectsegfau.lt',
    ),
    // --- Category B: Good reliability, web registration only ---
    XmppServerConfig(
      id: '5222',
      name: '5222.de',
      host: '5222.de',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.5222.de',
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
      id: 'movim',
      name: 'movim.eu',
      host: 'movim.eu',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.movim.eu',
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
      id: 'anoxinon',
      name: 'anoxinon.me',
      host: 'anoxinon.me',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.anoxinon.me',
    ),
    XmppServerConfig(
      id: 'durare',
      name: 'durare.org',
      host: 'durare.org',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.durare.org',
    ),
    XmppServerConfig(
      id: 'jabber_hot_chilli',
      name: 'jabber.hot-chilli.net',
      host: 'jabber.hot-chilli.net',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jabber.hot-chilli.net',
    ),
    XmppServerConfig(
      id: 'jix',
      name: 'jix.im',
      host: 'jix.im',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.jix.im',
    ),
    XmppServerConfig(
      id: 'redlibre',
      name: 'redlibre.es',
      host: 'redlibre.es',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.redlibre.es',
    ),
    XmppServerConfig(
      id: 'suchat',
      name: 'suchat.org',
      host: 'suchat.org',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.suchat.org',
    ),
    XmppServerConfig(
      id: 'worlio',
      name: 'worlio.com',
      host: 'worlio.com',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.worlio.com',
    ),
    // --- Category C: Lower reliability ---
    XmppServerConfig(
      id: 'chinwag',
      name: 'chinwag.im',
      host: 'chinwag.im',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.chinwag.im',
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
      id: 'lain',
      name: 'lain.rocks',
      host: 'lain.rocks',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.lain.rocks',
    ),
    XmppServerConfig(
      id: 'nixnet',
      name: 'nixnet.services',
      host: 'nixnet.services',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.nixnet.services',
    ),
    XmppServerConfig(
      id: 'rimkus',
      name: 'rimkus.it',
      host: 'rimkus.it',
      port: 5223,
      directTls: true,
      conferenceService: 'conference.rimkus.it',
    ),
  ];
}
