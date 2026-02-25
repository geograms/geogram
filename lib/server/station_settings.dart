// Unified station server settings for both CLI and App modes
import '../util/nostr_key_generator.dart';

/// Unified station server settings
/// Combines fields from PureRelaySettings (CLI) and StationServerSettings (App)
class StationSettings {
  // ============ Core Server Settings ============
  int httpPort;
  bool enabled;
  String? name;
  String? description;
  String? location;
  double? latitude;
  double? longitude;

  // ============ Station Identity (NOSTR keys) ============
  String npub;
  String nsec;
  /// Callsign is derived from npub (X3 prefix for stations)
  String get callsign => NostrKeyGenerator.deriveStationCallsign(npub);

  // ============ Station Role ============
  String stationRole; // 'root' or 'node'
  String? networkId;
  String? parentStationUrl; // For node stations
  bool setupComplete;

  // ============ Tile Server ============
  bool tileServerEnabled;
  bool osmFallbackEnabled;
  int maxZoomLevel;
  int maxCacheSizeMB;

  // ============ NOSTR/Blossom ============
  bool nostrRequireAuthForWrites;
  int blossomMaxStorageMb;
  int blossomMaxFileMb;

  // ============ Connection Limits ============
  bool enableCors;
  int httpRequestTimeout;
  int maxConnectedDevices;
  bool enableAprs;

  // ============ SSL/TLS ============
  bool enableSsl;
  String? sslDomain;
  String? sslEmail;
  bool sslAutoRenew;
  String? sslCertPath;
  String? sslKeyPath;
  int httpsPort;

  // ============ Update Mirror ============
  bool updateMirrorEnabled;
  int updateCheckIntervalSeconds;
  String? lastMirroredVersion;
  String updateMirrorUrl;

  // ============ SMTP (CLI-only, App can inherit) ============
  bool smtpEnabled;
  bool smtpServerEnabled;
  int smtpPort;
  String? smtpRelayHost;
  int smtpRelayPort;
  String? smtpRelayUsername;
  String? smtpRelayPassword;
  bool smtpRelayStartTls;
  String? dkimPrivateKey;

  // ============ AT Protocol PDS ============
  bool atprotoEnabled;
  String? atprotoHandle;

  // ============ XMPP Server ============
  bool xmppServerEnabled;
  int xmppServerPort;

  // ============ STUN Server (App-only, CLI can inherit) ============
  bool stunServerEnabled;
  int stunServerPort;

  StationSettings({
    this.httpPort = 8080,
    this.enabled = false,
    this.name,
    this.description,
    this.location,
    this.latitude,
    this.longitude,
    String? npub,
    String? nsec,
    this.stationRole = '',
    this.networkId,
    this.parentStationUrl,
    this.setupComplete = false,
    this.tileServerEnabled = true,
    this.osmFallbackEnabled = true,
    this.maxZoomLevel = 15,
    this.maxCacheSizeMB = 500,
    this.nostrRequireAuthForWrites = true,
    this.blossomMaxStorageMb = 1024,
    this.blossomMaxFileMb = 10,
    this.enableCors = true,
    this.httpRequestTimeout = 30000,
    this.maxConnectedDevices = 100,
    this.enableAprs = false,
    this.enableSsl = false,
    this.sslDomain,
    this.sslEmail,
    this.sslAutoRenew = true,
    this.sslCertPath,
    this.sslKeyPath,
    this.httpsPort = 8443,
    this.updateMirrorEnabled = true,
    this.updateCheckIntervalSeconds = 120,
    this.lastMirroredVersion,
    this.updateMirrorUrl = 'https://api.github.com/repos/geograms/geogram/releases/latest',
    this.smtpEnabled = false,
    this.smtpServerEnabled = false,
    this.smtpPort = 2525,
    this.smtpRelayHost,
    this.smtpRelayPort = 587,
    this.smtpRelayUsername,
    this.smtpRelayPassword,
    this.smtpRelayStartTls = true,
    this.dkimPrivateKey,
    this.atprotoEnabled = false,
    this.atprotoHandle,
    this.xmppServerEnabled = false,
    this.xmppServerPort = 5222,
    this.stunServerEnabled = true,
    this.stunServerPort = 3478,
  })  : npub = npub ?? _defaultKeys.npub,
        nsec = nsec ?? _defaultKeys.nsec;

  // Generate default keys for station (only created once per app run if no keys provided)
  static final NostrKeys _defaultKeys = NostrKeys.forRelay();

  factory StationSettings.fromJson(Map<String, dynamic> json) {
    return StationSettings(
      // Support both old 'port' and new 'httpPort' keys for backward compatibility
      httpPort: json['httpPort'] as int? ?? json['port'] as int? ?? 8080,
      enabled: json['enabled'] as bool? ?? false,
      name: json['name'] as String?,
      description: json['description'] as String?,
      location: json['location'] as String?,
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
      // Station identity keys (callsign is derived from npub with X3 prefix)
      // Treat empty strings as null to trigger default key generation
      npub: (json['npub'] as String?)?.isNotEmpty == true ? json['npub'] as String : null,
      nsec: (json['nsec'] as String?)?.isNotEmpty == true ? json['nsec'] as String : null,
      stationRole: json['stationRole'] as String? ?? '',
      networkId: json['networkId'] as String?,
      parentStationUrl: json['parentStationUrl'] as String?,
      setupComplete: json['setupComplete'] as bool? ?? false,
      tileServerEnabled: json['tileServerEnabled'] as bool? ?? true,
      osmFallbackEnabled: json['osmFallbackEnabled'] as bool? ?? true,
      maxZoomLevel: json['maxZoomLevel'] as int? ?? 15,
      // Support both old 'maxCacheSize' and new 'maxCacheSizeMB' keys
      maxCacheSizeMB: json['maxCacheSizeMB'] as int? ?? json['maxCacheSize'] as int? ?? 500,
      nostrRequireAuthForWrites: json['nostrRequireAuthForWrites'] as bool? ?? true,
      blossomMaxStorageMb: json['blossomMaxStorageMb'] as int? ?? 1024,
      blossomMaxFileMb: json['blossomMaxFileMb'] as int? ?? 10,
      enableCors: json['enableCors'] as bool? ?? true,
      httpRequestTimeout: json['httpRequestTimeout'] as int? ?? 30000,
      maxConnectedDevices: json['maxConnectedDevices'] as int? ?? 100,
      enableAprs: json['enableAprs'] as bool? ?? false,
      enableSsl: json['enableSsl'] as bool? ?? false,
      sslDomain: json['sslDomain'] as String?,
      sslEmail: json['sslEmail'] as String?,
      sslAutoRenew: json['sslAutoRenew'] as bool? ?? true,
      sslCertPath: json['sslCertPath'] as String?,
      sslKeyPath: json['sslKeyPath'] as String?,
      // Support both old 'sslPort' and new 'httpsPort' keys
      httpsPort: json['httpsPort'] as int? ?? json['sslPort'] as int? ?? 8443,
      updateMirrorEnabled: json['updateMirrorEnabled'] as bool? ?? true,
      updateCheckIntervalSeconds: json['updateCheckIntervalSeconds'] as int? ?? json['updateCheckInterval'] as int? ?? 120,
      lastMirroredVersion: json['lastMirroredVersion'] as String?,
      updateMirrorUrl: json['updateMirrorUrl'] as String? ?? 'https://api.github.com/repos/geograms/geogram/releases/latest',
      smtpEnabled: json['smtpEnabled'] as bool? ?? false,
      smtpServerEnabled: json['smtpServerEnabled'] as bool? ?? false,
      smtpPort: json['smtpPort'] as int? ?? 2525,
      smtpRelayHost: json['smtpRelayHost'] as String?,
      smtpRelayPort: json['smtpRelayPort'] as int? ?? 587,
      smtpRelayUsername: json['smtpRelayUsername'] as String?,
      smtpRelayPassword: json['smtpRelayPassword'] as String?,
      smtpRelayStartTls: json['smtpRelayStartTls'] as bool? ?? true,
      dkimPrivateKey: json['dkimPrivateKey'] as String?,
      atprotoEnabled: json['atprotoEnabled'] as bool? ?? false,
      atprotoHandle: json['atprotoHandle'] as String?,
      xmppServerEnabled: json['xmppServerEnabled'] as bool? ?? false,
      xmppServerPort: json['xmppServerPort'] as int? ?? 5222,
      stunServerEnabled: json['stunServerEnabled'] as bool? ?? true,
      stunServerPort: json['stunServerPort'] as int? ?? 3478,
    );
  }

  Map<String, dynamic> toJson() => {
    'httpPort': httpPort,
    'enabled': enabled,
    'name': name,
    'description': description,
    'location': location,
    'latitude': latitude,
    'longitude': longitude,
    // Station identity keys
    'npub': npub,
    'nsec': nsec,
    'callsign': callsign, // Derived from npub (read-only)
    'stationRole': stationRole,
    'networkId': networkId,
    'parentStationUrl': parentStationUrl,
    'setupComplete': setupComplete,
    'tileServerEnabled': tileServerEnabled,
    'osmFallbackEnabled': osmFallbackEnabled,
    'maxZoomLevel': maxZoomLevel,
    'maxCacheSizeMB': maxCacheSizeMB,
    'nostrRequireAuthForWrites': nostrRequireAuthForWrites,
    'blossomMaxStorageMb': blossomMaxStorageMb,
    'blossomMaxFileMb': blossomMaxFileMb,
    'enableCors': enableCors,
    'httpRequestTimeout': httpRequestTimeout,
    'maxConnectedDevices': maxConnectedDevices,
    'enableAprs': enableAprs,
    'enableSsl': enableSsl,
    'sslDomain': sslDomain,
    'sslEmail': sslEmail,
    'sslAutoRenew': sslAutoRenew,
    'sslCertPath': sslCertPath,
    'sslKeyPath': sslKeyPath,
    'httpsPort': httpsPort,
    'updateMirrorEnabled': updateMirrorEnabled,
    'updateCheckIntervalSeconds': updateCheckIntervalSeconds,
    'lastMirroredVersion': lastMirroredVersion,
    'updateMirrorUrl': updateMirrorUrl,
    'smtpEnabled': smtpEnabled,
    'smtpServerEnabled': smtpServerEnabled,
    'smtpPort': smtpPort,
    'smtpRelayHost': smtpRelayHost,
    'smtpRelayPort': smtpRelayPort,
    'smtpRelayUsername': smtpRelayUsername,
    'smtpRelayPassword': smtpRelayPassword,
    'smtpRelayStartTls': smtpRelayStartTls,
    'dkimPrivateKey': dkimPrivateKey,
    'atprotoEnabled': atprotoEnabled,
    'atprotoHandle': atprotoHandle,
    'xmppServerEnabled': xmppServerEnabled,
    'xmppServerPort': xmppServerPort,
    'stunServerEnabled': stunServerEnabled,
    'stunServerPort': stunServerPort,
  };

  StationSettings copyWith({
    int? httpPort,
    bool? enabled,
    String? name,
    String? description,
    String? location,
    double? latitude,
    double? longitude,
    String? npub,
    String? nsec,
    String? stationRole,
    String? networkId,
    String? parentStationUrl,
    bool? setupComplete,
    bool? tileServerEnabled,
    bool? osmFallbackEnabled,
    int? maxZoomLevel,
    int? maxCacheSizeMB,
    bool? nostrRequireAuthForWrites,
    int? blossomMaxStorageMb,
    int? blossomMaxFileMb,
    bool? enableCors,
    int? httpRequestTimeout,
    int? maxConnectedDevices,
    bool? enableAprs,
    bool? enableSsl,
    String? sslDomain,
    String? sslEmail,
    bool? sslAutoRenew,
    String? sslCertPath,
    String? sslKeyPath,
    int? httpsPort,
    bool? updateMirrorEnabled,
    int? updateCheckIntervalSeconds,
    String? lastMirroredVersion,
    String? updateMirrorUrl,
    bool? smtpEnabled,
    bool? smtpServerEnabled,
    int? smtpPort,
    String? smtpRelayHost,
    int? smtpRelayPort,
    String? smtpRelayUsername,
    String? smtpRelayPassword,
    bool? smtpRelayStartTls,
    String? dkimPrivateKey,
    bool? atprotoEnabled,
    String? atprotoHandle,
    bool? xmppServerEnabled,
    int? xmppServerPort,
    bool? stunServerEnabled,
    int? stunServerPort,
  }) {
    return StationSettings(
      httpPort: httpPort ?? this.httpPort,
      enabled: enabled ?? this.enabled,
      name: name ?? this.name,
      description: description ?? this.description,
      location: location ?? this.location,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      npub: npub ?? this.npub,
      nsec: nsec ?? this.nsec,
      stationRole: stationRole ?? this.stationRole,
      networkId: networkId ?? this.networkId,
      parentStationUrl: parentStationUrl ?? this.parentStationUrl,
      setupComplete: setupComplete ?? this.setupComplete,
      tileServerEnabled: tileServerEnabled ?? this.tileServerEnabled,
      osmFallbackEnabled: osmFallbackEnabled ?? this.osmFallbackEnabled,
      maxZoomLevel: maxZoomLevel ?? this.maxZoomLevel,
      maxCacheSizeMB: maxCacheSizeMB ?? this.maxCacheSizeMB,
      nostrRequireAuthForWrites: nostrRequireAuthForWrites ?? this.nostrRequireAuthForWrites,
      blossomMaxStorageMb: blossomMaxStorageMb ?? this.blossomMaxStorageMb,
      blossomMaxFileMb: blossomMaxFileMb ?? this.blossomMaxFileMb,
      enableCors: enableCors ?? this.enableCors,
      httpRequestTimeout: httpRequestTimeout ?? this.httpRequestTimeout,
      maxConnectedDevices: maxConnectedDevices ?? this.maxConnectedDevices,
      enableAprs: enableAprs ?? this.enableAprs,
      enableSsl: enableSsl ?? this.enableSsl,
      sslDomain: sslDomain ?? this.sslDomain,
      sslEmail: sslEmail ?? this.sslEmail,
      sslAutoRenew: sslAutoRenew ?? this.sslAutoRenew,
      sslCertPath: sslCertPath ?? this.sslCertPath,
      sslKeyPath: sslKeyPath ?? this.sslKeyPath,
      httpsPort: httpsPort ?? this.httpsPort,
      updateMirrorEnabled: updateMirrorEnabled ?? this.updateMirrorEnabled,
      updateCheckIntervalSeconds: updateCheckIntervalSeconds ?? this.updateCheckIntervalSeconds,
      lastMirroredVersion: lastMirroredVersion ?? this.lastMirroredVersion,
      updateMirrorUrl: updateMirrorUrl ?? this.updateMirrorUrl,
      smtpEnabled: smtpEnabled ?? this.smtpEnabled,
      smtpServerEnabled: smtpServerEnabled ?? this.smtpServerEnabled,
      smtpPort: smtpPort ?? this.smtpPort,
      smtpRelayHost: smtpRelayHost ?? this.smtpRelayHost,
      smtpRelayPort: smtpRelayPort ?? this.smtpRelayPort,
      smtpRelayUsername: smtpRelayUsername ?? this.smtpRelayUsername,
      smtpRelayPassword: smtpRelayPassword ?? this.smtpRelayPassword,
      smtpRelayStartTls: smtpRelayStartTls ?? this.smtpRelayStartTls,
      dkimPrivateKey: dkimPrivateKey ?? this.dkimPrivateKey,
      atprotoEnabled: atprotoEnabled ?? this.atprotoEnabled,
      atprotoHandle: atprotoHandle ?? this.atprotoHandle,
      xmppServerEnabled: xmppServerEnabled ?? this.xmppServerEnabled,
      xmppServerPort: xmppServerPort ?? this.xmppServerPort,
      stunServerEnabled: stunServerEnabled ?? this.stunServerEnabled,
      stunServerPort: stunServerPort ?? this.stunServerPort,
    );
  }

  /// Check if setup needs to be run
  bool needsSetup() {
    return !setupComplete || callsign.isEmpty || stationRole.isEmpty;
  }
}
