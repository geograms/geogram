// Settings adapter for backward compatibility
// Allows gradual migration from old settings classes to unified StationSettings

import '../station_settings.dart';

/// Convert App's StationServerSettings to unified StationSettings
StationSettings fromAppSettings(Map<String, dynamic> appSettings, {
  required String npub,
  required String nsec,
}) {
  return StationSettings(
    httpPort: appSettings['port'] as int? ?? 8080,
    enabled: appSettings['enabled'] as bool? ?? false,
    description: appSettings['description'] as String?,
    latitude: appSettings['latitude'] as double?,
    longitude: appSettings['longitude'] as double?,
    npub: npub,
    nsec: nsec,
    tileServerEnabled: appSettings['tileServerEnabled'] as bool? ?? true,
    osmFallbackEnabled: appSettings['osmFallbackEnabled'] as bool? ?? true,
    maxZoomLevel: appSettings['maxZoomLevel'] as int? ?? 15,
    maxCacheSizeMB: appSettings['maxCacheSize'] as int? ?? 500,
    nostrRequireAuthForWrites: appSettings['nostrRequireAuthForWrites'] as bool? ?? true,
    blossomMaxStorageMb: appSettings['blossomMaxStorageMb'] as int? ?? 1024,
    blossomMaxFileMb: appSettings['blossomMaxFileMb'] as int? ?? 10,
    enableCors: appSettings['enableCors'] as bool? ?? true,
    updateMirrorEnabled: appSettings['updateMirrorEnabled'] as bool? ?? true,
    updateCheckIntervalSeconds: appSettings['updateCheckInterval'] as int? ?? 120,
    stunServerEnabled: appSettings['stunServerEnabled'] as bool? ?? true,
    stunServerPort: appSettings['stunServerPort'] as int? ?? 3478,
  );
}

/// Convert CLI's PureRelaySettings to unified StationSettings
StationSettings fromCliSettings(Map<String, dynamic> cliSettings) {
  return StationSettings(
    httpPort: cliSettings['httpPort'] as int? ?? 8080,
    httpsPort: cliSettings['httpsPort'] as int? ?? 8443,
    enabled: true, // CLI server is always enabled when running
    name: cliSettings['name'] as String?,
    description: cliSettings['description'] as String?,
    location: cliSettings['location'] as String?,
    latitude: cliSettings['latitude'] as double?,
    longitude: cliSettings['longitude'] as double?,
    npub: cliSettings['npub'] as String? ?? '',
    nsec: cliSettings['nsec'] as String? ?? '',
    stationRole: cliSettings['stationRole'] as String? ?? '',
    networkId: cliSettings['networkId'] as String?,
    parentStationUrl: cliSettings['parentStationUrl'] as String?,
    setupComplete: cliSettings['setupComplete'] as bool? ?? false,
    tileServerEnabled: cliSettings['tileServerEnabled'] as bool? ?? true,
    osmFallbackEnabled: cliSettings['osmFallbackEnabled'] as bool? ?? true,
    maxZoomLevel: cliSettings['maxZoomLevel'] as int? ?? 15,
    maxCacheSizeMB: cliSettings['maxCacheSizeMB'] as int? ?? 500,
    nostrRequireAuthForWrites: cliSettings['nostrRequireAuthForWrites'] as bool? ?? true,
    blossomMaxStorageMb: cliSettings['blossomMaxStorageMb'] as int? ?? 1024,
    blossomMaxFileMb: cliSettings['blossomMaxFileMb'] as int? ?? 10,
    enableCors: cliSettings['enableCors'] as bool? ?? true,
    httpRequestTimeout: cliSettings['httpRequestTimeout'] as int? ?? 30000,
    maxConnectedDevices: cliSettings['maxConnectedDevices'] as int? ?? 100,
    enableAprs: cliSettings['enableAprs'] as bool? ?? false,
    enableSsl: cliSettings['enableSsl'] as bool? ?? true,
    sslDomain: cliSettings['sslDomain'] as String?,
    sslEmail: cliSettings['sslEmail'] as String?,
    sslAutoRenew: cliSettings['sslAutoRenew'] as bool? ?? true,
    sslCertPath: cliSettings['sslCertPath'] as String?,
    sslKeyPath: cliSettings['sslKeyPath'] as String?,
    updateMirrorEnabled: cliSettings['updateMirrorEnabled'] as bool? ?? true,
    updateCheckIntervalSeconds: cliSettings['updateCheckIntervalSeconds'] as int? ?? 120,
    lastMirroredVersion: cliSettings['lastMirroredVersion'] as String?,
    smtpEnabled: cliSettings['smtpEnabled'] as bool? ?? false,
    smtpServerEnabled: cliSettings['smtpServerEnabled'] as bool? ?? false,
    smtpPort: cliSettings['smtpPort'] as int? ?? 2525,
    smtpRelayHost: cliSettings['smtpRelayHost'] as String?,
    smtpRelayPort: cliSettings['smtpRelayPort'] as int? ?? 587,
    smtpRelayUsername: cliSettings['smtpRelayUsername'] as String?,
    smtpRelayPassword: cliSettings['smtpRelayPassword'] as String?,
    smtpRelayStartTls: cliSettings['smtpRelayStartTls'] as bool? ?? true,
    dkimPrivateKey: cliSettings['dkimPrivateKey'] as String?,
  );
}

/// Convert unified StationSettings back to App format
Map<String, dynamic> toAppSettings(StationSettings settings) {
  return {
    'port': settings.httpPort,
    'enabled': settings.enabled,
    'description': settings.description,
    'latitude': settings.latitude,
    'longitude': settings.longitude,
    'tileServerEnabled': settings.tileServerEnabled,
    'osmFallbackEnabled': settings.osmFallbackEnabled,
    'maxZoomLevel': settings.maxZoomLevel,
    'maxCacheSize': settings.maxCacheSizeMB,
    'nostrRequireAuthForWrites': settings.nostrRequireAuthForWrites,
    'blossomMaxStorageMb': settings.blossomMaxStorageMb,
    'blossomMaxFileMb': settings.blossomMaxFileMb,
    'enableCors': settings.enableCors,
    'updateMirrorEnabled': settings.updateMirrorEnabled,
    'updateCheckInterval': settings.updateCheckIntervalSeconds,
    'stunServerEnabled': settings.stunServerEnabled,
    'stunServerPort': settings.stunServerPort,
  };
}

/// Convert unified StationSettings back to CLI format
Map<String, dynamic> toCliSettings(StationSettings settings) {
  return settings.toJson();
}
