/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Station node types
enum StationType {
  root,
  node,
}

/// Station node status
enum StationNodeStatus {
  stopped,
  starting,
  running,
  stopping,
  error,
}

/// Power source types for station
enum PowerSource {
  grid,
  solar,
  battery,
  solarBattery,
  fuel,
  wind,
  gridUps,
  vehicle,
}

/// Binary caching policy
enum BinaryPolicy {
  textOnly,
  thumbnailsOnly,
  onDemand,
  fullCache,
}

/// Storage configuration for station node
class StationStorageConfig {
  final int allocatedMb;
  final BinaryPolicy binaryPolicy;
  final int thumbnailMaxKb;
  final int retentionDays;
  final int chatRetentionDays;
  final int resolvedReportRetentionDays;
  final bool nostrRequireAuthForWrites;
  final int blossomMaxStorageMb;
  final int blossomMaxFileMb;

  const StationStorageConfig({
    this.allocatedMb = 16384,
    this.binaryPolicy = BinaryPolicy.textOnly,
    this.thumbnailMaxKb = 10,
    this.retentionDays = 365,
    this.chatRetentionDays = 90,
    this.resolvedReportRetentionDays = 180,
    this.nostrRequireAuthForWrites = true,
    this.blossomMaxStorageMb = 1024,
    this.blossomMaxFileMb = 10,
  });

  factory StationStorageConfig.fromJson(Map<String, dynamic> json) {
    return StationStorageConfig(
      allocatedMb: json['allocatedMb'] as int? ?? 16384,
      binaryPolicy: BinaryPolicy.values.firstWhere(
        (e) => e.name == json['binaryPolicy'],
        orElse: () => BinaryPolicy.textOnly,
      ),
      thumbnailMaxKb: json['thumbnailMaxKb'] as int? ?? 10,
      retentionDays: json['retentionDays'] as int? ?? 365,
      chatRetentionDays: json['chatRetentionDays'] as int? ?? 90,
      resolvedReportRetentionDays: json['resolvedReportRetentionDays'] as int? ?? 180,
      nostrRequireAuthForWrites: json['nostrRequireAuthForWrites'] as bool? ?? true,
      blossomMaxStorageMb: json['blossomMaxStorageMb'] as int? ?? 1024,
      blossomMaxFileMb: json['blossomMaxFileMb'] as int? ?? 10,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'allocatedMb': allocatedMb,
      'binaryPolicy': binaryPolicy.name,
      'thumbnailMaxKb': thumbnailMaxKb,
      'retentionDays': retentionDays,
      'chatRetentionDays': chatRetentionDays,
      'resolvedReportRetentionDays': resolvedReportRetentionDays,
      'nostrRequireAuthForWrites': nostrRequireAuthForWrites,
      'blossomMaxStorageMb': blossomMaxStorageMb,
      'blossomMaxFileMb': blossomMaxFileMb,
    };
  }

  StationStorageConfig copyWith({
    int? allocatedMb,
    BinaryPolicy? binaryPolicy,
    int? thumbnailMaxKb,
    int? retentionDays,
    int? chatRetentionDays,
    int? resolvedReportRetentionDays,
    bool? nostrRequireAuthForWrites,
    int? blossomMaxStorageMb,
    int? blossomMaxFileMb,
  }) {
    return StationStorageConfig(
      allocatedMb: allocatedMb ?? this.allocatedMb,
      binaryPolicy: binaryPolicy ?? this.binaryPolicy,
      thumbnailMaxKb: thumbnailMaxKb ?? this.thumbnailMaxKb,
      retentionDays: retentionDays ?? this.retentionDays,
      chatRetentionDays: chatRetentionDays ?? this.chatRetentionDays,
      resolvedReportRetentionDays: resolvedReportRetentionDays ?? this.resolvedReportRetentionDays,
      nostrRequireAuthForWrites: nostrRequireAuthForWrites ?? this.nostrRequireAuthForWrites,
      blossomMaxStorageMb: blossomMaxStorageMb ?? this.blossomMaxStorageMb,
      blossomMaxFileMb: blossomMaxFileMb ?? this.blossomMaxFileMb,
    );
  }
}

/// Geographic coverage configuration
class GeographicCoverage {
  final double latitude;
  final double longitude;
  final double radiusKm;
  final String? locationName;

  const GeographicCoverage({
    required this.latitude,
    required this.longitude,
    this.radiusKm = 50.0,
    this.locationName,
  });

  factory GeographicCoverage.fromJson(Map<String, dynamic> json) {
    return GeographicCoverage(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      radiusKm: (json['radiusKm'] as num?)?.toDouble() ?? 50.0,
      locationName: json['locationName'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'radiusKm': radiusKm,
      if (locationName != null) 'locationName': locationName,
    };
  }

  GeographicCoverage copyWith({
    double? latitude,
    double? longitude,
    double? radiusKm,
    String? locationName,
  }) {
    return GeographicCoverage(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      radiusKm: radiusKm ?? this.radiusKm,
      locationName: locationName ?? this.locationName,
    );
  }
}

/// Power configuration for station
class PowerConfig {
  final PowerSource primarySource;
  final bool gridConnected;
  final int? batteryPercent;
  final int? solarWatts;
  final int? estimatedRuntimeHours;

  const PowerConfig({
    this.primarySource = PowerSource.grid,
    this.gridConnected = true,
    this.batteryPercent,
    this.solarWatts,
    this.estimatedRuntimeHours,
  });

  factory PowerConfig.fromJson(Map<String, dynamic> json) {
    return PowerConfig(
      primarySource: PowerSource.values.firstWhere(
        (e) => e.name == json['primarySource'],
        orElse: () => PowerSource.grid,
      ),
      gridConnected: json['gridConnected'] as bool? ?? true,
      batteryPercent: json['batteryPercent'] as int?,
      solarWatts: json['solarWatts'] as int?,
      estimatedRuntimeHours: json['estimatedRuntimeHours'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'primarySource': primarySource.name,
      'gridConnected': gridConnected,
      if (batteryPercent != null) 'batteryPercent': batteryPercent,
      if (solarWatts != null) 'solarWatts': solarWatts,
      if (estimatedRuntimeHours != null) 'estimatedRuntimeHours': estimatedRuntimeHours,
    };
  }
}

/// Channel configuration
class ChannelConfig {
  final String type;
  final bool enabled;
  final String? interfaceName;
  final Map<String, dynamic> settings;

  const ChannelConfig({
    required this.type,
    this.enabled = false,
    this.interfaceName,
    this.settings = const {},
  });

  factory ChannelConfig.fromJson(Map<String, dynamic> json) {
    return ChannelConfig(
      type: json['type'] as String,
      enabled: json['enabled'] as bool? ?? false,
      interfaceName: json['interfaceName'] as String?,
      settings: (json['settings'] as Map<String, dynamic>?) ?? {},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'enabled': enabled,
      if (interfaceName != null) 'interfaceName': interfaceName,
      if (settings.isNotEmpty) 'settings': settings,
    };
  }
}

/// Station node configuration
class StationNodeConfig {
  final StationStorageConfig storage;
  final GeographicCoverage? coverage;
  final PowerConfig power;
  final List<ChannelConfig> channels;
  final List<String> supportedApps;
  final bool acceptConnections;
  final int maxConnections;

  const StationNodeConfig({
    this.storage = const StationStorageConfig(),
    this.coverage,
    this.power = const PowerConfig(),
    this.channels = const [],
    this.supportedApps = const ['reports', 'places', 'events'],
    this.acceptConnections = true,
    this.maxConnections = 50,
  });

  factory StationNodeConfig.fromJson(Map<String, dynamic> json) {
    return StationNodeConfig(
      storage: json['storage'] != null
          ? StationStorageConfig.fromJson(json['storage'] as Map<String, dynamic>)
          : const StationStorageConfig(),
      coverage: json['coverage'] != null
          ? GeographicCoverage.fromJson(json['coverage'] as Map<String, dynamic>)
          : null,
      power: json['power'] != null
          ? PowerConfig.fromJson(json['power'] as Map<String, dynamic>)
          : const PowerConfig(),
      channels: (json['channels'] as List<dynamic>?)
              ?.map((e) => ChannelConfig.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      supportedApps: ((json['supportedApps'] ?? json['supportedCollections']) as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          ['reports', 'places', 'events'],
      acceptConnections: json['acceptConnections'] as bool? ?? true,
      maxConnections: json['maxConnections'] as int? ?? 50,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'storage': storage.toJson(),
      if (coverage != null) 'coverage': coverage!.toJson(),
      'power': power.toJson(),
      'channels': channels.map((e) => e.toJson()).toList(),
      'supportedApps': supportedApps,
      'acceptConnections': acceptConnections,
      'maxConnections': maxConnections,
    };
  }

  StationNodeConfig copyWith({
    StationStorageConfig? storage,
    GeographicCoverage? coverage,
    PowerConfig? power,
    List<ChannelConfig>? channels,
    List<String>? supportedApps,
    bool? acceptConnections,
    int? maxConnections,
  }) {
    return StationNodeConfig(
      storage: storage ?? this.storage,
      coverage: coverage ?? this.coverage,
      power: power ?? this.power,
      channels: channels ?? this.channels,
      supportedApps: supportedApps ?? this.supportedApps,
      acceptConnections: acceptConnections ?? this.acceptConnections,
      maxConnections: maxConnections ?? this.maxConnections,
    );
  }
}

/// Statistics for station node
class StationNodeStats {
  final int connectedDevices;
  final int messagesRelayed;
  final int appsServed;
  final int storageUsedMb;
  final DateTime? lastActivity;
  final Duration uptime;

  const StationNodeStats({
    this.connectedDevices = 0,
    this.messagesRelayed = 0,
    this.appsServed = 0,
    this.storageUsedMb = 0,
    this.lastActivity,
    this.uptime = Duration.zero,
  });

  factory StationNodeStats.fromJson(Map<String, dynamic> json) {
    return StationNodeStats(
      connectedDevices: json['connectedDevices'] as int? ?? 0,
      messagesRelayed: json['messagesRelayed'] as int? ?? 0,
      appsServed: (json['appsServed'] ?? json['collectionsServed']) as int? ?? 0,
      storageUsedMb: json['storageUsedMb'] as int? ?? 0,
      lastActivity: json['lastActivity'] != null
          ? DateTime.parse(json['lastActivity'] as String)
          : null,
      uptime: Duration(seconds: json['uptimeSeconds'] as int? ?? 0),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'connectedDevices': connectedDevices,
      'messagesRelayed': messagesRelayed,
      'appsServed': appsServed,
      'storageUsedMb': storageUsedMb,
      if (lastActivity != null) 'lastActivity': lastActivity!.toIso8601String(),
      'uptimeSeconds': uptime.inSeconds,
    };
  }
}

/// Represents this device operating as a station
class StationNode {
  final String id;
  final String name;

  // Station identity (X3 prefix) - the station device's own keypair
  final String stationCallsign;  // X3 callsign derived from station npub
  final String stationNpub;      // Station's public key
  final String stationNsec;      // Station's private key (secret)

  // Operator identity (X1 prefix) - the human managing this station
  final String operatorCallsign;  // X1 callsign of the operator
  final String operatorNpub;      // Operator's public key

  final StationType type;
  final String? networkId;
  final String? networkName;
  final String? rootNpub;
  final String? rootCallsign;
  final StationNodeConfig config;
  final StationNodeStatus status;
  final StationNodeStats stats;
  final String? errorMessage;
  final DateTime created;
  final DateTime updated;

  // Remote station management fields
  final bool isRemote;           // True if this is a remote station we're managing
  final String? remoteUrl;       // URL of the remote station (wss:// or https://)

  const StationNode({
    required this.id,
    required this.name,
    required this.stationCallsign,
    required this.stationNpub,
    required this.stationNsec,
    required this.operatorCallsign,
    required this.operatorNpub,
    required this.type,
    this.networkId,
    this.networkName,
    this.rootNpub,
    this.rootCallsign,
    this.config = const StationNodeConfig(),
    this.status = StationNodeStatus.stopped,
    this.stats = const StationNodeStats(),
    this.errorMessage,
    required this.created,
    required this.updated,
    this.isRemote = false,
    this.remoteUrl,
  });

  /// Backwards compatibility: returns station callsign
  String get callsign => stationCallsign;

  /// Backwards compatibility: returns station npub
  String get npub => stationNpub;

  /// Check if this is a root station
  bool get isRoot => type == StationType.root;

  /// Check if this is a node station
  bool get isNode => type == StationType.node;

  /// Check if station is running
  bool get isRunning => status == StationNodeStatus.running;

  /// Get status display text
  String get statusDisplay {
    switch (status) {
      case StationNodeStatus.stopped:
        return 'Stopped';
      case StationNodeStatus.starting:
        return 'Starting...';
      case StationNodeStatus.running:
        return 'Running';
      case StationNodeStatus.stopping:
        return 'Stopping...';
      case StationNodeStatus.error:
        return 'Error';
    }
  }

  /// Get type display text
  String get typeDisplay {
    switch (type) {
      case StationType.root:
        return 'Root Station';
      case StationType.node:
        return 'Node Station';
    }
  }

  factory StationNode.fromJson(Map<String, dynamic> json) {
    // Handle backwards compatibility for old format
    final stationCallsign = json['stationCallsign'] as String? ?? json['callsign'] as String;
    final stationNpub = json['stationNpub'] as String? ?? json['npub'] as String;
    final stationNsec = json['stationNsec'] as String? ?? '';
    final operatorCallsign = json['operatorCallsign'] as String? ?? json['callsign'] as String;
    final operatorNpub = json['operatorNpub'] as String? ?? json['npub'] as String;

    return StationNode(
      id: json['id'] as String,
      name: json['name'] as String,
      stationCallsign: stationCallsign,
      stationNpub: stationNpub,
      stationNsec: stationNsec,
      operatorCallsign: operatorCallsign,
      operatorNpub: operatorNpub,
      type: StationType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => StationType.node,
      ),
      networkId: json['networkId'] as String?,
      networkName: json['networkName'] as String?,
      rootNpub: json['rootNpub'] as String?,
      rootCallsign: json['rootCallsign'] as String?,
      config: json['config'] != null
          ? StationNodeConfig.fromJson(json['config'] as Map<String, dynamic>)
          : const StationNodeConfig(),
      status: StationNodeStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => StationNodeStatus.stopped,
      ),
      stats: json['stats'] != null
          ? StationNodeStats.fromJson(json['stats'] as Map<String, dynamic>)
          : const StationNodeStats(),
      errorMessage: json['errorMessage'] as String?,
      created: DateTime.parse(json['created'] as String),
      updated: DateTime.parse(json['updated'] as String),
      isRemote: json['isRemote'] as bool? ?? false,
      remoteUrl: json['remoteUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'stationCallsign': stationCallsign,
      'stationNpub': stationNpub,
      'stationNsec': stationNsec,
      'operatorCallsign': operatorCallsign,
      'operatorNpub': operatorNpub,
      'type': type.name,
      if (networkId != null) 'networkId': networkId,
      if (networkName != null) 'networkName': networkName,
      if (rootNpub != null) 'rootNpub': rootNpub,
      if (rootCallsign != null) 'rootCallsign': rootCallsign,
      'config': config.toJson(),
      'status': status.name,
      'stats': stats.toJson(),
      if (errorMessage != null) 'errorMessage': errorMessage,
      'created': created.toIso8601String(),
      'updated': updated.toIso8601String(),
      'isRemote': isRemote,
      if (remoteUrl != null) 'remoteUrl': remoteUrl,
    };
  }

  StationNode copyWith({
    String? id,
    String? name,
    String? stationCallsign,
    String? stationNpub,
    String? stationNsec,
    String? operatorCallsign,
    String? operatorNpub,
    StationType? type,
    String? networkId,
    String? networkName,
    String? rootNpub,
    String? rootCallsign,
    StationNodeConfig? config,
    StationNodeStatus? status,
    StationNodeStats? stats,
    String? errorMessage,
    DateTime? created,
    DateTime? updated,
    bool? isRemote,
    String? remoteUrl,
  }) {
    return StationNode(
      id: id ?? this.id,
      name: name ?? this.name,
      stationCallsign: stationCallsign ?? this.stationCallsign,
      stationNpub: stationNpub ?? this.stationNpub,
      stationNsec: stationNsec ?? this.stationNsec,
      operatorCallsign: operatorCallsign ?? this.operatorCallsign,
      operatorNpub: operatorNpub ?? this.operatorNpub,
      type: type ?? this.type,
      networkId: networkId ?? this.networkId,
      networkName: networkName ?? this.networkName,
      rootNpub: rootNpub ?? this.rootNpub,
      rootCallsign: rootCallsign ?? this.rootCallsign,
      config: config ?? this.config,
      status: status ?? this.status,
      stats: stats ?? this.stats,
      errorMessage: errorMessage ?? this.errorMessage,
      created: created ?? this.created,
      updated: updated ?? this.updated,
      isRemote: isRemote ?? this.isRemote,
      remoteUrl: remoteUrl ?? this.remoteUrl,
    );
  }
}
