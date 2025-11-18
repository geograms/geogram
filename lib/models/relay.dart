/// Internet relay model
class Relay {
  String url;
  String name;
  String status; // 'preferred', 'backup', 'available'
  bool isConnected;
  int? latency; // in milliseconds
  DateTime? lastChecked;
  double? latitude; // Relay disclosed location
  double? longitude; // Relay disclosed location
  String? location; // Human-readable location (e.g., "New York, USA")

  Relay({
    required this.url,
    required this.name,
    this.status = 'available',
    this.isConnected = false,
    this.latency,
    this.lastChecked,
    this.latitude,
    this.longitude,
    this.location,
  });

  /// Create a Relay from JSON map
  factory Relay.fromJson(Map<String, dynamic> json) {
    return Relay(
      url: json['url'] as String,
      name: json['name'] as String,
      status: json['status'] as String? ?? 'available',
      isConnected: json['isConnected'] as bool? ?? false,
      latency: json['latency'] as int?,
      lastChecked: json['lastChecked'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['lastChecked'] as int)
          : null,
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
      location: json['location'] as String?,
    );
  }

  /// Convert Relay to JSON map
  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'name': name,
      'status': status,
      'isConnected': isConnected,
      if (latency != null) 'latency': latency,
      if (lastChecked != null) 'lastChecked': lastChecked!.millisecondsSinceEpoch,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (location != null) 'location': location,
    };
  }

  /// Create a copy of this relay
  Relay copyWith({
    String? url,
    String? name,
    String? status,
    bool? isConnected,
    int? latency,
    DateTime? lastChecked,
    double? latitude,
    double? longitude,
    String? location,
  }) {
    return Relay(
      url: url ?? this.url,
      name: name ?? this.name,
      status: status ?? this.status,
      isConnected: isConnected ?? this.isConnected,
      latency: latency ?? this.latency,
      lastChecked: lastChecked ?? this.lastChecked,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      location: location ?? this.location,
    );
  }

  /// Get status display text
  String get statusDisplay {
    switch (status) {
      case 'preferred':
        return 'Preferred';
      case 'backup':
        return 'Backup';
      default:
        return 'Available';
    }
  }

  /// Get connection status text
  String get connectionStatus {
    if (isConnected) {
      return latency != null ? 'Connected (${latency}ms)' : 'Connected';
    }
    return 'Disconnected';
  }
}
