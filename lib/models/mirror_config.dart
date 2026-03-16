/// Mirror sync configuration models.
///
/// Enables P2P synchronization between devices running the same account.
library;

/// Auto-sync mode per peer
enum AutoSyncMode {
  /// Sync only when manually triggered
  manual,

  /// Sync automatically on a timer
  automatic,
}

/// Syncable folder IDs used across the app
const kSyncableFolders = [
  'blog',
  'places',
  'events',
  'alerts',
  'contacts',
  'groups',
  'inventory',
  'market',
  'postcards',
  'news',
  'files',
  'qr',
  'reports',
  'stories',
  'wallet',
  'tracker',
];

/// Human-readable labels and descriptions for each syncable folder
const kFolderLabels = <String, (String, String)>{
  'blog': ('Blog', 'Posts and articles'),
  'places': ('Places', 'Saved locations'),
  'events': ('Events', 'Calendar events'),
  'alerts': ('Alerts', 'Emergency alerts'),
  'contacts': ('Contacts', 'Contact list'),
  'groups': ('Groups', 'Group memberships'),
  'inventory': ('Inventory', 'Item tracking'),
  'market': ('Market', 'Marketplace listings'),
  'postcards': ('Postcards', 'Sent and received postcards'),
  'news': ('News', 'News feeds'),
  'files': ('Files', 'Shared files'),
  'qr': ('QR Codes', 'Saved QR codes'),
  'reports': ('Reports', 'Field reports'),
  'stories': ('Stories', 'Published stories'),
  'wallet': ('Wallet', 'Wallet data'),
  'tracker': ('Tracker', 'GPS tracks'),
};

/// Sync style for an app (like Syncthing)
enum SyncStyle {
  /// Full two-way sync - both sides send and receive
  sendReceive,

  /// Receive only - passive mirror, don't send changes
  receiveOnly,

  /// Send only - source device, don't accept changes
  sendOnly,

  /// Paused - temporarily disabled
  paused,
}

/// Current sync state for an app
enum SyncState {
  /// Up to date, no pending changes
  idle,

  /// Scanning for changes
  scanning,

  /// Actively syncing files
  syncing,

  /// Sync failed
  error,

  /// Changes pending, waiting to sync
  outOfSync,
}

/// Connection state with a peer
enum PeerConnectionState {
  /// Not connected
  disconnected,

  /// Attempting to connect
  connecting,

  /// Active connection established
  connected,

  /// Currently syncing data
  syncing,
}

/// Network type for connection quality
enum NetworkType {
  wifi,
  cellular,
  ethernet,
  bluetooth,
  unknown,
}

/// Sync statistics for an app
class SyncStats {
  final int filesInSync;
  final int filesOutOfSync;
  final int bytesTotal;
  final int bytesNeeded;
  final DateTime? lastScan;

  const SyncStats({
    this.filesInSync = 0,
    this.filesOutOfSync = 0,
    this.bytesTotal = 0,
    this.bytesNeeded = 0,
    this.lastScan,
  });

  factory SyncStats.fromJson(Map<String, dynamic> json) {
    return SyncStats(
      filesInSync: json['files_in_sync'] as int? ?? 0,
      filesOutOfSync: json['files_out_of_sync'] as int? ?? 0,
      bytesTotal: json['bytes_total'] as int? ?? 0,
      bytesNeeded: json['bytes_needed'] as int? ?? 0,
      lastScan: json['last_scan'] != null
          ? DateTime.parse(json['last_scan'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'files_in_sync': filesInSync,
        'files_out_of_sync': filesOutOfSync,
        'bytes_total': bytesTotal,
        'bytes_needed': bytesNeeded,
        if (lastScan != null) 'last_scan': lastScan!.toIso8601String(),
      };
}

/// Per-app sync configuration for a peer
class AppSyncConfig {
  /// App ID (collection type: blog, chat, places, etc.)
  final String appId;

  /// Sync style
  SyncStyle style;

  /// Is sync enabled for this app?
  bool enabled;

  /// Current sync state
  SyncState state;

  /// Sync statistics
  SyncStats stats;

  /// Last sync error message
  String? lastError;

  /// Glob patterns for files to ignore during sync
  List<String> ignorePatterns;

  AppSyncConfig({
    required this.appId,
    this.style = SyncStyle.sendReceive,
    this.enabled = true,
    this.state = SyncState.idle,
    this.stats = const SyncStats(),
    this.lastError,
    this.ignorePatterns = const [],
  });

  factory AppSyncConfig.fromJson(Map<String, dynamic> json) {
    return AppSyncConfig(
      appId: json['app_id'] as String,
      style: SyncStyle.values.firstWhere(
        (e) => e.name == json['style'],
        orElse: () => SyncStyle.sendReceive,
      ),
      enabled: json['enabled'] as bool? ?? true,
      state: SyncState.values.firstWhere(
        (e) => e.name == json['state'],
        orElse: () => SyncState.idle,
      ),
      stats: json['stats'] != null
          ? SyncStats.fromJson(json['stats'] as Map<String, dynamic>)
          : const SyncStats(),
      lastError: json['last_error'] as String?,
      ignorePatterns: (json['ignore_patterns'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }

  Map<String, dynamic> toJson() => {
        'app_id': appId,
        'style': style.name,
        'enabled': enabled,
        'state': state.name,
        'stats': stats.toJson(),
        if (lastError != null) 'last_error': lastError,
        if (ignorePatterns.isNotEmpty) 'ignore_patterns': ignorePatterns,
      };

  AppSyncConfig copyWith({
    SyncStyle? style,
    bool? enabled,
    SyncState? state,
    SyncStats? stats,
    String? lastError,
    List<String>? ignorePatterns,
  }) {
    return AppSyncConfig(
      appId: appId,
      style: style ?? this.style,
      enabled: enabled ?? this.enabled,
      state: state ?? this.state,
      stats: stats ?? this.stats,
      lastError: lastError ?? this.lastError,
      ignorePatterns: ignorePatterns ?? this.ignorePatterns,
    );
  }
}

/// Connection quality information
class ConnectionQuality {
  final NetworkType networkType;
  final bool isMetered;
  final int? latencyMs;
  final int? bandwidthKbps;
  final bool batterySaver;

  const ConnectionQuality({
    this.networkType = NetworkType.unknown,
    this.isMetered = false,
    this.latencyMs,
    this.bandwidthKbps,
    this.batterySaver = false,
  });

  /// Compute quality score 0-100
  int get qualityScore {
    int score = 50;

    // Network type bonus
    switch (networkType) {
      case NetworkType.ethernet:
        score += 30;
        break;
      case NetworkType.wifi:
        score += 25;
        break;
      case NetworkType.cellular:
        score += 10;
        break;
      case NetworkType.bluetooth:
        score += 5;
        break;
      case NetworkType.unknown:
        break;
    }

    // Metered penalty
    if (isMetered) score -= 20;

    // Latency bonus/penalty
    if (latencyMs != null) {
      if (latencyMs! < 50) {
        score += 15;
      } else if (latencyMs! < 100) {
        score += 10;
      } else if (latencyMs! > 500) {
        score -= 15;
      }
    }

    // Battery saver penalty
    if (batterySaver) score -= 10;

    return score.clamp(0, 100);
  }

  factory ConnectionQuality.fromJson(Map<String, dynamic> json) {
    return ConnectionQuality(
      networkType: NetworkType.values.firstWhere(
        (e) => e.name == json['network_type'],
        orElse: () => NetworkType.unknown,
      ),
      isMetered: json['is_metered'] as bool? ?? false,
      latencyMs: json['latency_ms'] as int?,
      bandwidthKbps: json['bandwidth_kbps'] as int?,
      batterySaver: json['battery_saver'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'network_type': networkType.name,
        'is_metered': isMetered,
        if (latencyMs != null) 'latency_ms': latencyMs,
        if (bandwidthKbps != null) 'bandwidth_kbps': bandwidthKbps,
        'battery_saver': batterySaver,
      };
}

/// A paired mirror device (peer)
class MirrorPeer {
  /// Unique peer ID
  final String peerId;

  /// Nostr public key (npub) for crypto identity
  String npub;

  /// Friendly name
  String name;

  /// Callsign (should match ours for same account)
  String callsign;

  /// Known addresses (LAN IPs, URLs, etc.)
  List<String> addresses;

  /// Per-app sync configuration
  Map<String, AppSyncConfig> apps;

  /// Connection state
  PeerConnectionState connectionState;

  /// Last successful sync
  DateTime? lastSyncAt;

  /// Last seen online
  DateTime? lastSeenAt;

  /// Last known connection quality
  ConnectionQuality? lastQuality;

  /// Platform (Android, iOS, Linux, etc.)
  String? platform;

  /// Per-peer auto-sync mode
  AutoSyncMode autoSyncMode;

  /// Sync interval in minutes (null = use global; 15/60/1440/10080)
  int? syncIntervalMinutes;

  MirrorPeer({
    required this.peerId,
    this.npub = '',
    required this.name,
    required this.callsign,
    this.addresses = const [],
    Map<String, AppSyncConfig>? apps,
    this.connectionState = PeerConnectionState.disconnected,
    this.lastSyncAt,
    this.lastSeenAt,
    this.lastQuality,
    this.platform,
    this.autoSyncMode = AutoSyncMode.manual,
    this.syncIntervalMinutes,
  }) : apps = apps ?? {};

  /// First non-relay address (LAN IP / direct URL), or null if none.
  String? get directAddress {
    for (final a in addresses) {
      if (!a.startsWith('station://')) return a;
    }
    return null;
  }

  /// Station relay HTTP URL derived from a `station://host/device/callsign`
  /// address, or null if none.
  String? get stationRelayUrl {
    for (final a in addresses) {
      if (a.startsWith('station://')) {
        // station://host:port/device/CALL → https://host:port/device/CALL
        return a.replaceFirst('station://', 'https://');
      }
    }
    return null;
  }

  /// Check if peer is currently online
  bool get isOnline =>
      connectionState == PeerConnectionState.connected ||
      connectionState == PeerConnectionState.syncing;

  /// Get overall sync state across all apps
  SyncState get overallSyncState {
    if (apps.isEmpty) return SyncState.idle;

    final states = apps.values.where((a) => a.enabled).map((a) => a.state);
    if (states.isEmpty) return SyncState.idle;

    if (states.any((s) => s == SyncState.error)) return SyncState.error;
    if (states.any((s) => s == SyncState.syncing)) return SyncState.syncing;
    if (states.any((s) => s == SyncState.scanning)) return SyncState.scanning;
    if (states.any((s) => s == SyncState.outOfSync)) return SyncState.outOfSync;
    return SyncState.idle;
  }

  factory MirrorPeer.fromJson(Map<String, dynamic> json) {
    final appsJson = json['apps'] as Map<String, dynamic>?;
    final apps = <String, AppSyncConfig>{};
    if (appsJson != null) {
      for (final entry in appsJson.entries) {
        apps[entry.key] =
            AppSyncConfig.fromJson(entry.value as Map<String, dynamic>);
      }
    }

    return MirrorPeer(
      peerId: json['peer_id'] as String,
      npub: json['npub'] as String? ?? '',
      name: json['name'] as String,
      callsign: json['callsign'] as String,
      addresses: (json['addresses'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      apps: apps,
      connectionState: PeerConnectionState.values.firstWhere(
        (e) => e.name == json['connection_state'],
        orElse: () => PeerConnectionState.disconnected,
      ),
      lastSyncAt: json['last_sync_at'] != null
          ? DateTime.parse(json['last_sync_at'] as String)
          : null,
      lastSeenAt: json['last_seen_at'] != null
          ? DateTime.parse(json['last_seen_at'] as String)
          : null,
      lastQuality: json['last_quality'] != null
          ? ConnectionQuality.fromJson(
              json['last_quality'] as Map<String, dynamic>)
          : null,
      platform: json['platform'] as String?,
      autoSyncMode: AutoSyncMode.values.firstWhere(
        (e) => e.name == json['auto_sync_mode'],
        orElse: () => AutoSyncMode.manual,
      ),
      syncIntervalMinutes: json['sync_interval_minutes'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'peer_id': peerId,
        'npub': npub,
        'name': name,
        'callsign': callsign,
        'addresses': addresses,
        'apps': apps.map((k, v) => MapEntry(k, v.toJson())),
        'connection_state': connectionState.name,
        if (lastSyncAt != null) 'last_sync_at': lastSyncAt!.toIso8601String(),
        if (lastSeenAt != null) 'last_seen_at': lastSeenAt!.toIso8601String(),
        if (lastQuality != null) 'last_quality': lastQuality!.toJson(),
        if (platform != null) 'platform': platform,
        'auto_sync_mode': autoSyncMode.name,
        if (syncIntervalMinutes != null) 'sync_interval_minutes': syncIntervalMinutes,
      };

  MirrorPeer copyWith({
    String? npub,
    String? name,
    String? callsign,
    List<String>? addresses,
    Map<String, AppSyncConfig>? apps,
    PeerConnectionState? connectionState,
    DateTime? lastSyncAt,
    DateTime? lastSeenAt,
    ConnectionQuality? lastQuality,
    String? platform,
    AutoSyncMode? autoSyncMode,
    int? syncIntervalMinutes,
  }) {
    return MirrorPeer(
      peerId: peerId,
      npub: npub ?? this.npub,
      name: name ?? this.name,
      callsign: callsign ?? this.callsign,
      addresses: addresses ?? List.from(this.addresses),
      apps: apps ?? Map.from(this.apps),
      connectionState: connectionState ?? this.connectionState,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      lastQuality: lastQuality ?? this.lastQuality,
      platform: platform ?? this.platform,
      autoSyncMode: autoSyncMode ?? this.autoSyncMode,
      syncIntervalMinutes: syncIntervalMinutes ?? this.syncIntervalMinutes,
    );
  }
}

/// Connection preferences
class ConnectionPreferences {
  /// Sync over metered connections (cellular)?
  bool allowMetered;

  /// Maximum bandwidth on metered (KB/s, 0 = unlimited)
  int meteredBandwidthLimit;

  /// Sync when on battery?
  bool allowOnBattery;

  /// Minimum battery level to sync (0-100)
  int minBatteryLevel;

  /// Announce on LAN for discovery?
  bool lanDiscovery;

  /// Announce via BLE?
  bool bleDiscovery;

  /// Auto-sync when peer comes online?
  bool autoSync;

  /// Sync interval in minutes (0 = manual only)
  int syncIntervalMinutes;

  ConnectionPreferences({
    this.allowMetered = false,
    this.meteredBandwidthLimit = 0,
    this.allowOnBattery = true,
    this.minBatteryLevel = 20,
    this.lanDiscovery = true,
    this.bleDiscovery = true,
    this.autoSync = true,
    this.syncIntervalMinutes = 15,
  });

  factory ConnectionPreferences.fromJson(Map<String, dynamic> json) {
    return ConnectionPreferences(
      allowMetered: json['allow_metered'] as bool? ?? false,
      meteredBandwidthLimit: json['metered_bandwidth_limit'] as int? ?? 0,
      allowOnBattery: json['allow_on_battery'] as bool? ?? true,
      minBatteryLevel: json['min_battery_level'] as int? ?? 20,
      lanDiscovery: json['lan_discovery'] as bool? ?? true,
      bleDiscovery: json['ble_discovery'] as bool? ?? true,
      autoSync: json['auto_sync'] as bool? ?? true,
      syncIntervalMinutes: json['sync_interval_minutes'] as int? ?? 15,
    );
  }

  Map<String, dynamic> toJson() => {
        'allow_metered': allowMetered,
        'metered_bandwidth_limit': meteredBandwidthLimit,
        'allow_on_battery': allowOnBattery,
        'min_battery_level': minBatteryLevel,
        'lan_discovery': lanDiscovery,
        'ble_discovery': bleDiscovery,
        'auto_sync': autoSync,
        'sync_interval_minutes': syncIntervalMinutes,
      };
}

/// Device-wide mirror configuration
class MirrorConfig {
  /// Enable mirror feature
  bool enabled;

  /// This device's unique ID
  String deviceId;

  /// This device's friendly name
  String deviceName;

  /// Paired peers
  List<MirrorPeer> peers;

  /// Connection preferences
  ConnectionPreferences preferences;

  /// Default sync style for new apps
  SyncStyle defaultSyncStyle;

  MirrorConfig({
    this.enabled = false,
    required this.deviceId,
    this.deviceName = 'My Device',
    List<MirrorPeer>? peers,
    ConnectionPreferences? preferences,
    this.defaultSyncStyle = SyncStyle.sendReceive,
  })  : peers = peers ?? [],
        preferences = preferences ?? ConnectionPreferences();

  /// Get peer by ID
  MirrorPeer? getPeer(String peerId) {
    try {
      return peers.firstWhere((p) => p.peerId == peerId);
    } catch (_) {
      return null;
    }
  }

  /// Get all online peers
  List<MirrorPeer> get onlinePeers => peers.where((p) => p.isOnline).toList();

  /// Get overall sync state
  SyncState get overallSyncState {
    if (!enabled || peers.isEmpty) return SyncState.idle;

    final states = peers.map((p) => p.overallSyncState);
    if (states.any((s) => s == SyncState.error)) return SyncState.error;
    if (states.any((s) => s == SyncState.syncing)) return SyncState.syncing;
    if (states.any((s) => s == SyncState.scanning)) return SyncState.scanning;
    if (states.any((s) => s == SyncState.outOfSync)) return SyncState.outOfSync;
    return SyncState.idle;
  }

  factory MirrorConfig.fromJson(Map<String, dynamic> json) {
    return MirrorConfig(
      enabled: json['enabled'] as bool? ?? false,
      deviceId: json['device_id'] as String,
      deviceName: json['device_name'] as String? ?? 'My Device',
      peers: (json['peers'] as List<dynamic>?)
              ?.map((e) => MirrorPeer.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      preferences: json['preferences'] != null
          ? ConnectionPreferences.fromJson(
              json['preferences'] as Map<String, dynamic>)
          : ConnectionPreferences(),
      defaultSyncStyle: SyncStyle.values.firstWhere(
        (e) => e.name == json['default_sync_style'],
        orElse: () => SyncStyle.sendReceive,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'device_id': deviceId,
        'device_name': deviceName,
        'peers': peers.map((p) => p.toJson()).toList(),
        'preferences': preferences.toJson(),
        'default_sync_style': defaultSyncStyle.name,
      };

  MirrorConfig copyWith({
    bool? enabled,
    String? deviceName,
    List<MirrorPeer>? peers,
    ConnectionPreferences? preferences,
    SyncStyle? defaultSyncStyle,
  }) {
    return MirrorConfig(
      enabled: enabled ?? this.enabled,
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      peers: peers ?? List.from(this.peers),
      preferences: preferences ?? this.preferences,
      defaultSyncStyle: defaultSyncStyle ?? this.defaultSyncStyle,
    );
  }
}
