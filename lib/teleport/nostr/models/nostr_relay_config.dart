/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NOSTR relay connection configuration.
 * Persisted as JSON via ProfileStorage at teleport/nostr/config.json.
 */

class NostrRelayConfig {
  final String id;
  final String url;
  final String name;
  final bool enabled;
  final bool read;
  final bool write;

  const NostrRelayConfig({
    required this.id,
    required this.url,
    required this.name,
    this.enabled = true,
    this.read = true,
    this.write = true,
  });

  /// Derive a display name from the relay URL hostname.
  static String nameFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host;
    } catch (_) {
      return url;
    }
  }

  /// Derive a stable ID from the relay URL.
  static String idFromUrl(String url) {
    return url
        .replaceAll('wss://', '')
        .replaceAll('ws://', '')
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'enabled': enabled,
        'read': read,
        'write': write,
      };

  factory NostrRelayConfig.fromJson(Map<String, dynamic> json) {
    return NostrRelayConfig(
      id: json['id'] as String,
      url: json['url'] as String,
      name: json['name'] as String,
      enabled: json['enabled'] as bool? ?? true,
      read: json['read'] as bool? ?? true,
      write: json['write'] as bool? ?? true,
    );
  }

  NostrRelayConfig copyWith({
    String? url,
    String? name,
    bool? enabled,
    bool? read,
    bool? write,
  }) {
    return NostrRelayConfig(
      id: id,
      url: url ?? this.url,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      read: read ?? this.read,
      write: write ?? this.write,
    );
  }

  /// Default relays pre-populated on first use.
  static final List<NostrRelayConfig> defaults = [
    NostrRelayConfig(
      id: idFromUrl('wss://relay.damus.io'),
      url: 'wss://relay.damus.io',
      name: 'relay.damus.io',
    ),
    NostrRelayConfig(
      id: idFromUrl('wss://nos.lol'),
      url: 'wss://nos.lol',
      name: 'nos.lol',
    ),
    NostrRelayConfig(
      id: idFromUrl('wss://relay.nostr.band'),
      url: 'wss://relay.nostr.band',
      name: 'relay.nostr.band',
    ),
    NostrRelayConfig(
      id: idFromUrl('wss://relay.primal.net'),
      url: 'wss://relay.primal.net',
      name: 'relay.primal.net',
    ),
  ];
}
