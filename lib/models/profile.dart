/// Profile type - client or relay
enum ProfileType {
  client, // X1 prefix - regular user
  relay,  // X3 prefix - relay server
}

/// User profile model - represents a single identity/callsign
class Profile {
  /// Unique identifier for this profile (UUID)
  final String id;
  ProfileType type;
  String callsign;
  String nickname;
  String description;
  String? profileImagePath;
  String npub; // NOSTR public key
  String nsec; // NOSTR private key (secret) - empty when using extension
  bool useExtension; // Whether to use NIP-07 browser extension for signing
  String preferredColor;
  double? latitude; // User's current latitude
  double? longitude; // User's current longitude
  String? locationName; // Human-readable location
  DateTime createdAt; // When this profile was created

  // Profile activation state (multiple profiles can be active simultaneously)
  bool isActive;

  // Relay-specific settings (only used when type == relay)
  int? port;
  String? relayRole; // 'root' or 'node'
  String? parentRelayUrl;
  String? networkId;
  bool tileServerEnabled;
  bool osmFallbackEnabled;
  bool enableAprs;

  Profile({
    String? id,
    this.type = ProfileType.client,
    this.callsign = '',
    this.nickname = '',
    this.description = '',
    this.profileImagePath,
    this.npub = '',
    this.nsec = '',
    this.useExtension = false,
    this.preferredColor = 'blue',
    this.latitude,
    this.longitude,
    this.locationName,
    DateTime? createdAt,
    this.isActive = true,
    this.port,
    this.relayRole,
    this.parentRelayUrl,
    this.networkId,
    this.tileServerEnabled = true,
    this.osmFallbackEnabled = true,
    this.enableAprs = false,
  }) : id = id ?? _generateId(),
       createdAt = createdAt ?? DateTime.now();

  bool get isRelay => type == ProfileType.relay;
  bool get isClient => type == ProfileType.client;

  /// Generate a simple unique ID
  static String _generateId() {
    return DateTime.now().millisecondsSinceEpoch.toRadixString(36) +
        (DateTime.now().microsecond).toRadixString(36);
  }

  /// Create a Profile from JSON map
  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      id: json['id'] as String?,
      type: json['type'] == 'relay' ? ProfileType.relay : ProfileType.client,
      callsign: json['callsign'] as String? ?? '',
      nickname: json['nickname'] as String? ?? '',
      description: json['description'] as String? ?? '',
      profileImagePath: json['profileImagePath'] as String?,
      npub: json['npub'] as String? ?? '',
      nsec: json['nsec'] as String? ?? '',
      useExtension: json['useExtension'] as bool? ?? false,
      preferredColor: json['preferredColor'] as String? ?? 'blue',
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
      locationName: json['locationName'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
      isActive: json['isActive'] as bool? ?? false,
      port: json['port'] as int?,
      relayRole: json['relayRole'] as String?,
      parentRelayUrl: json['parentRelayUrl'] as String?,
      networkId: json['networkId'] as String?,
      tileServerEnabled: json['tileServerEnabled'] as bool? ?? true,
      osmFallbackEnabled: json['osmFallbackEnabled'] as bool? ?? true,
      enableAprs: json['enableAprs'] as bool? ?? false,
    );
  }

  /// Convert Profile to JSON map
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type == ProfileType.relay ? 'relay' : 'client',
      'callsign': callsign,
      'nickname': nickname,
      'description': description,
      if (profileImagePath != null) 'profileImagePath': profileImagePath,
      'npub': npub,
      'nsec': nsec,
      'useExtension': useExtension,
      'preferredColor': preferredColor,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (locationName != null) 'locationName': locationName,
      'createdAt': createdAt.toIso8601String(),
      'isActive': isActive,
      if (port != null) 'port': port,
      if (relayRole != null) 'relayRole': relayRole,
      if (parentRelayUrl != null) 'parentRelayUrl': parentRelayUrl,
      if (networkId != null) 'networkId': networkId,
      'tileServerEnabled': tileServerEnabled,
      'osmFallbackEnabled': osmFallbackEnabled,
      'enableAprs': enableAprs,
    };
  }

  /// Create a copy of this profile
  Profile copyWith({
    ProfileType? type,
    String? callsign,
    String? nickname,
    String? description,
    String? profileImagePath,
    String? npub,
    String? nsec,
    bool? useExtension,
    String? preferredColor,
    double? latitude,
    double? longitude,
    String? locationName,
    bool? isActive,
    int? port,
    String? relayRole,
    String? parentRelayUrl,
    String? networkId,
    bool? tileServerEnabled,
    bool? osmFallbackEnabled,
    bool? enableAprs,
  }) {
    return Profile(
      id: id, // Preserve the ID
      type: type ?? this.type,
      callsign: callsign ?? this.callsign,
      nickname: nickname ?? this.nickname,
      description: description ?? this.description,
      profileImagePath: profileImagePath ?? this.profileImagePath,
      npub: npub ?? this.npub,
      nsec: nsec ?? this.nsec,
      useExtension: useExtension ?? this.useExtension,
      preferredColor: preferredColor ?? this.preferredColor,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locationName: locationName ?? this.locationName,
      createdAt: createdAt, // Preserve creation time
      isActive: isActive ?? this.isActive,
      port: port ?? this.port,
      relayRole: relayRole ?? this.relayRole,
      parentRelayUrl: parentRelayUrl ?? this.parentRelayUrl,
      networkId: networkId ?? this.networkId,
      tileServerEnabled: tileServerEnabled ?? this.tileServerEnabled,
      osmFallbackEnabled: osmFallbackEnabled ?? this.osmFallbackEnabled,
      enableAprs: enableAprs ?? this.enableAprs,
    );
  }

  /// Display name for this profile (nickname or callsign)
  String get displayName => nickname.isNotEmpty ? nickname : callsign;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Profile && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Profile(id: $id, callsign: $callsign, nickname: $nickname)';
}
