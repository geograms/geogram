/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * IRC server connection configuration.
 * Persisted as JSON via ProfileStorage at teleport/irc/config.json.
 */

class IrcServerConfig {
  final String id;
  final String name;
  final String host;
  final int port;
  final bool useTls;
  final String? password;
  final List<String> autoJoinChannels;
  final bool autoConnect;

  const IrcServerConfig({
    required this.id,
    required this.name,
    required this.host,
    this.port = 6697,
    this.useTls = true,
    this.password,
    this.autoJoinChannels = const [],
    this.autoConnect = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'useTls': useTls,
        'password': password,
        'autoJoinChannels': autoJoinChannels,
        'autoConnect': autoConnect,
      };

  factory IrcServerConfig.fromJson(Map<String, dynamic> json) {
    return IrcServerConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int? ?? 6697,
      useTls: json['useTls'] as bool? ?? true,
      password: json['password'] as String?,
      autoJoinChannels: (json['autoJoinChannels'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      autoConnect: json['autoConnect'] as bool? ?? false,
    );
  }

  IrcServerConfig copyWith({
    String? name,
    String? host,
    int? port,
    bool? useTls,
    String? password,
    List<String>? autoJoinChannels,
    bool? autoConnect,
  }) {
    return IrcServerConfig(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      useTls: useTls ?? this.useTls,
      password: password ?? this.password,
      autoJoinChannels: autoJoinChannels ?? this.autoJoinChannels,
      autoConnect: autoConnect ?? this.autoConnect,
    );
  }

  /// Well-known IRC server presets.
  static const List<IrcServerConfig> presets = [
    IrcServerConfig(
      id: 'libera',
      name: 'Libera.Chat',
      host: 'irc.libera.chat',
      port: 6697,
      useTls: true,
    ),
    IrcServerConfig(
      id: 'oftc',
      name: 'OFTC',
      host: 'irc.oftc.net',
      port: 6697,
      useTls: true,
    ),
    IrcServerConfig(
      id: 'efnet',
      name: 'EFnet',
      host: 'irc.efnet.org',
      port: 6697,
      useTls: true,
    ),
    IrcServerConfig(
      id: 'undernet',
      name: 'Undernet',
      host: 'irc.undernet.org',
      port: 6667,
      useTls: false,
    ),
    IrcServerConfig(
      id: 'ircnet',
      name: 'IRCnet',
      host: 'open.ircnet.net',
      port: 6667,
      useTls: false,
    ),
    IrcServerConfig(
      id: 'dalnet',
      name: 'DALnet',
      host: 'irc.dal.net',
      port: 6697,
      useTls: true,
    ),
    IrcServerConfig(
      id: 'rizon',
      name: 'Rizon',
      host: 'irc.rizon.net',
      port: 6697,
      useTls: true,
    ),
    IrcServerConfig(
      id: 'hackint',
      name: 'hackint',
      host: 'irc.hackint.org',
      port: 6697,
      useTls: true,
    ),
    IrcServerConfig(
      id: 'tildechat',
      name: 'tilde.chat',
      host: 'irc.tilde.chat',
      port: 6697,
      useTls: true,
    ),
  ];
}
