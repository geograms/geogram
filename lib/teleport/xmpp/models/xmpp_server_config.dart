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

  /// Well-known XMPP server presets.
  static const List<XmppServerConfig> presets = [
    XmppServerConfig(
      id: 'conversations',
      name: 'conversations.im',
      host: 'conversations.im',
      port: 5222,
      conferenceService: 'conference.conversations.im',
    ),
    XmppServerConfig(
      id: 'jabber',
      name: 'jabber.org',
      host: 'jabber.org',
      port: 5222,
      conferenceService: 'conference.jabber.org',
    ),
    XmppServerConfig(
      id: 'disroot',
      name: 'disroot.org',
      host: 'disroot.org',
      port: 5222,
      conferenceService: 'conference.disroot.org',
    ),
    XmppServerConfig(
      id: 'nixnet',
      name: 'nixnet.services',
      host: 'nixnet.services',
      port: 5222,
      conferenceService: 'conference.nixnet.services',
    ),
    XmppServerConfig(
      id: '404city',
      name: '404.city',
      host: '404.city',
      port: 5222,
      conferenceService: 'conference.404.city',
    ),
    XmppServerConfig(
      id: 'snikket',
      name: 'snikket.org',
      host: 'snikket.org',
      port: 5222,
      conferenceService: 'conference.snikket.org',
    ),
    XmppServerConfig(
      id: 'movim',
      name: 'movim.eu',
      host: 'movim.eu',
      port: 5222,
      conferenceService: 'conference.movim.eu',
    ),
    XmppServerConfig(
      id: 'creep',
      name: 'creep.im',
      host: 'creep.im',
      port: 5222,
      conferenceService: 'conference.creep.im',
    ),
    XmppServerConfig(
      id: 'trashserver',
      name: 'trashserver.net',
      host: 'trashserver.net',
      port: 5222,
      conferenceService: 'conference.trashserver.net',
    ),
    XmppServerConfig(
      id: 'blabber',
      name: 'blabber.im',
      host: 'blabber.im',
      port: 5222,
      conferenceService: 'conference.blabber.im',
    ),
  ];
}
