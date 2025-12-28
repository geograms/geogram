/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Model representing an individual service/expertise offered by a provider
class ServiceOffering {
  final String type; // From predefined list (e.g., 'plumber', 'electrician')
  final String description; // Primary description
  final Map<String, String> descriptions; // Multilingual descriptions

  ServiceOffering({
    required this.type,
    this.description = '',
    this.descriptions = const {},
  });

  /// Get description in specified language (with fallback)
  String getDescription(String langCode) {
    final upperCode = langCode.toUpperCase();
    if (descriptions.containsKey(upperCode)) {
      return descriptions[upperCode]!;
    }
    if (descriptions.containsKey('EN')) {
      return descriptions['EN']!;
    }
    if (descriptions.isNotEmpty) {
      return descriptions.values.first;
    }
    return description;
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
        'type': type,
        'description': description,
        if (descriptions.isNotEmpty) 'descriptions': descriptions,
      };

  /// Create from JSON
  factory ServiceOffering.fromJson(Map<String, dynamic> json) {
    return ServiceOffering(
      type: json['type'] as String,
      description: json['description'] as String? ?? '',
      descriptions: json['descriptions'] != null
          ? Map<String, String>.from(json['descriptions'] as Map)
          : const {},
    );
  }

  /// Create a copy with updated fields
  ServiceOffering copyWith({
    String? type,
    String? description,
    Map<String, String>? descriptions,
  }) {
    return ServiceOffering(
      type: type ?? this.type,
      description: description ?? this.description,
      descriptions: descriptions ?? this.descriptions,
    );
  }
}

/// Model representing a service provider in the services collection
class Service {
  // Identification
  final String name; // Provider name (single language or primary)
  final Map<String, String> names; // Multilingual names
  final String created; // Format: YYYY-MM-DD HH:MM_ss
  final String author; // Callsign

  // Location
  final double latitude;
  final double longitude;
  final int radius; // In kilometers (1-200, default 30)
  final String? address;

  // About the provider
  final String about; // Single language or primary
  final Map<String, String> abouts; // Multilingual about sections

  // Services offered
  final List<ServiceOffering> offerings;

  // Contact information
  final String? phone;
  final String? email;
  final String? whatsapp;
  final String? instagram;
  final String? facebook;
  final String? website;

  // Operating hours
  final String? hours;

  // Permissions
  final List<String> admins; // List of npubs

  // Metadata
  final String? metadataNpub;
  final String? signature;
  final String? profileImage; // Relative path to profile image

  // File/folder paths
  final String? filePath; // Path to service.txt
  final String? folderPath; // Path to service folder
  final String? regionPath; // Region folder (e.g., "38.7_-9.1")

  // Photo count
  final int photoCount;

  // Feedback counts (loaded separately)
  final int likeCount;
  final int commentCount;

  Service({
    required this.name,
    this.names = const {},
    required this.created,
    required this.author,
    required this.latitude,
    required this.longitude,
    this.radius = 30,
    this.address,
    this.about = '',
    this.abouts = const {},
    this.offerings = const [],
    this.phone,
    this.email,
    this.whatsapp,
    this.instagram,
    this.facebook,
    this.website,
    this.hours,
    this.admins = const [],
    this.metadataNpub,
    this.signature,
    this.profileImage,
    this.filePath,
    this.folderPath,
    this.regionPath,
    this.photoCount = 0,
    this.likeCount = 0,
    this.commentCount = 0,
  });

  /// Parse created timestamp to DateTime
  DateTime get createdDateTime {
    try {
      final normalized = created.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Get display timestamp
  String get displayCreated => created.replaceAll('_', ':');

  /// Get coordinates as string
  String get coordinatesString => '$latitude,$longitude';

  /// Get region folder name from coordinates
  String get regionFolder {
    final latRounded = (latitude * 10).round() / 10;
    final lonRounded = (longitude * 10).round() / 10;
    return '${latRounded}_$lonRounded';
  }

  /// Get service folder name
  String get serviceFolderName {
    final sanitized = _sanitizeName(name);
    return '${latitude}_${longitude}_$sanitized';
  }

  /// Get unique ID for this service (folder name)
  String get id => serviceFolderName;

  /// Sanitize name for folder name
  static String _sanitizeName(String name) {
    String sanitized = name.toLowerCase();
    sanitized = sanitized.replaceAll(RegExp(r'[\s_]+'), '-');
    sanitized = sanitized.replaceAll(RegExp(r'[^a-z0-9-]'), '');
    sanitized = sanitized.replaceAll(RegExp(r'-+'), '-');
    sanitized = sanitized.replaceAll(RegExp(r'^-+|-+$'), '');
    if (sanitized.length > 50) {
      sanitized = sanitized.substring(0, 50);
    }
    return sanitized;
  }

  /// Get name in specified language (with fallback)
  String getName(String langCode) {
    final upperCode = langCode.toUpperCase();
    if (names.containsKey(upperCode)) {
      return names[upperCode]!;
    }
    if (names.containsKey('EN')) {
      return names['EN']!;
    }
    if (names.isNotEmpty) {
      return names.values.first;
    }
    return name;
  }

  /// Get about text in specified language (with fallback)
  String getAbout(String langCode) {
    final upperCode = langCode.toUpperCase();
    if (abouts.containsKey(upperCode)) {
      return abouts[upperCode]!;
    }
    if (abouts.containsKey('EN')) {
      return abouts['EN']!;
    }
    if (abouts.isNotEmpty) {
      return abouts.values.first;
    }
    return about;
  }

  /// Get list of service types offered
  List<String> get serviceTypes => offerings.map((o) => o.type).toList();

  /// Check if provider offers a specific service type
  bool offersService(String type) {
    return offerings.any((o) => o.type == type);
  }

  /// Get offering by type
  ServiceOffering? getOffering(String type) {
    try {
      return offerings.firstWhere((o) => o.type == type);
    } catch (_) {
      return null;
    }
  }

  /// Check if user is admin (or author)
  bool isAdmin(String npub) {
    return admins.contains(npub) || metadataNpub == npub;
  }

  /// Check if this service covers a given location (within radius)
  bool coversLocation(double lat, double lon) {
    final distance = _calculateDistance(latitude, longitude, lat, lon);
    return distance <= radius;
  }

  /// Calculate distance in kilometers using Haversine formula
  static double _calculateDistance(
      double lat1, double lon1, double lat2, double lon2) {
    const double earthRadius = 6371; // km
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);
    final a = _sin(dLat / 2) * _sin(dLat / 2) +
        _cos(_toRadians(lat1)) *
            _cos(_toRadians(lat2)) *
            _sin(dLon / 2) *
            _sin(dLon / 2);
    final c = 2 * _atan2(_sqrt(a), _sqrt(1 - a));
    return earthRadius * c;
  }

  static double _toRadians(double deg) => deg * 3.141592653589793 / 180;
  static double _sin(double x) => _sinTaylor(x);
  static double _cos(double x) => _sinTaylor(x + 1.5707963267948966);
  static double _sqrt(double x) {
    if (x <= 0) return 0;
    double guess = x / 2;
    for (int i = 0; i < 20; i++) {
      guess = (guess + x / guess) / 2;
    }
    return guess;
  }

  static double _atan2(double y, double x) {
    if (x > 0) return _atanTaylor(y / x);
    if (x < 0 && y >= 0) return _atanTaylor(y / x) + 3.141592653589793;
    if (x < 0 && y < 0) return _atanTaylor(y / x) - 3.141592653589793;
    if (x == 0 && y > 0) return 1.5707963267948966;
    if (x == 0 && y < 0) return -1.5707963267948966;
    return 0;
  }

  static double _sinTaylor(double x) {
    // Normalize to -pi to pi
    while (x > 3.141592653589793) x -= 6.283185307179586;
    while (x < -3.141592653589793) x += 6.283185307179586;
    double result = x;
    double term = x;
    for (int n = 1; n <= 10; n++) {
      term *= -x * x / ((2 * n) * (2 * n + 1));
      result += term;
    }
    return result;
  }

  static double _atanTaylor(double x) {
    if (x > 1) return 1.5707963267948966 - _atanTaylor(1 / x);
    if (x < -1) return -1.5707963267948966 - _atanTaylor(1 / x);
    double result = x;
    double term = x;
    for (int n = 1; n <= 15; n++) {
      term *= -x * x;
      result += term / (2 * n + 1);
    }
    return result;
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
        'name': name,
        if (names.isNotEmpty) 'names': names,
        'created': created,
        'author': author,
        'latitude': latitude,
        'longitude': longitude,
        'radius': radius,
        if (address != null) 'address': address,
        'about': about,
        if (abouts.isNotEmpty) 'abouts': abouts,
        'offerings': offerings.map((o) => o.toJson()).toList(),
        if (phone != null) 'phone': phone,
        if (email != null) 'email': email,
        if (whatsapp != null) 'whatsapp': whatsapp,
        if (instagram != null) 'instagram': instagram,
        if (facebook != null) 'facebook': facebook,
        if (website != null) 'website': website,
        if (hours != null) 'hours': hours,
        if (admins.isNotEmpty) 'admins': admins,
        if (metadataNpub != null) 'metadataNpub': metadataNpub,
        if (signature != null) 'signature': signature,
        if (profileImage != null) 'profileImage': profileImage,
        if (filePath != null) 'filePath': filePath,
        if (folderPath != null) 'folderPath': folderPath,
        if (regionPath != null) 'regionPath': regionPath,
        'photoCount': photoCount,
        'likeCount': likeCount,
        'commentCount': commentCount,
      };

  /// Create from JSON
  factory Service.fromJson(Map<String, dynamic> json) {
    return Service(
      name: json['name'] as String,
      names: json['names'] != null
          ? Map<String, String>.from(json['names'] as Map)
          : const {},
      created: json['created'] as String,
      author: json['author'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      radius: json['radius'] as int? ?? 30,
      address: json['address'] as String?,
      about: json['about'] as String? ?? '',
      abouts: json['abouts'] != null
          ? Map<String, String>.from(json['abouts'] as Map)
          : const {},
      offerings: json['offerings'] != null
          ? (json['offerings'] as List)
              .map((o) => ServiceOffering.fromJson(o as Map<String, dynamic>))
              .toList()
          : const [],
      phone: json['phone'] as String?,
      email: json['email'] as String?,
      whatsapp: json['whatsapp'] as String?,
      instagram: json['instagram'] as String?,
      facebook: json['facebook'] as String?,
      website: json['website'] as String?,
      hours: json['hours'] as String?,
      admins: json['admins'] != null
          ? List<String>.from(json['admins'] as List)
          : const [],
      metadataNpub: json['metadataNpub'] as String?,
      signature: json['signature'] as String?,
      profileImage: json['profileImage'] as String?,
      filePath: json['filePath'] as String?,
      folderPath: json['folderPath'] as String?,
      regionPath: json['regionPath'] as String?,
      photoCount: json['photoCount'] as int? ?? 0,
      likeCount: json['likeCount'] as int? ?? 0,
      commentCount: json['commentCount'] as int? ?? 0,
    );
  }

  /// Create a copy with updated fields
  Service copyWith({
    String? name,
    Map<String, String>? names,
    String? created,
    String? author,
    double? latitude,
    double? longitude,
    int? radius,
    String? address,
    String? about,
    Map<String, String>? abouts,
    List<ServiceOffering>? offerings,
    String? phone,
    String? email,
    String? whatsapp,
    String? instagram,
    String? facebook,
    String? website,
    String? hours,
    List<String>? admins,
    String? metadataNpub,
    String? signature,
    String? profileImage,
    String? filePath,
    String? folderPath,
    String? regionPath,
    int? photoCount,
    int? likeCount,
    int? commentCount,
  }) {
    return Service(
      name: name ?? this.name,
      names: names ?? this.names,
      created: created ?? this.created,
      author: author ?? this.author,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      radius: radius ?? this.radius,
      address: address ?? this.address,
      about: about ?? this.about,
      abouts: abouts ?? this.abouts,
      offerings: offerings ?? this.offerings,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      whatsapp: whatsapp ?? this.whatsapp,
      instagram: instagram ?? this.instagram,
      facebook: facebook ?? this.facebook,
      website: website ?? this.website,
      hours: hours ?? this.hours,
      admins: admins ?? this.admins,
      metadataNpub: metadataNpub ?? this.metadataNpub,
      signature: signature ?? this.signature,
      profileImage: profileImage ?? this.profileImage,
      filePath: filePath ?? this.filePath,
      folderPath: folderPath ?? this.folderPath,
      regionPath: regionPath ?? this.regionPath,
      photoCount: photoCount ?? this.photoCount,
      likeCount: likeCount ?? this.likeCount,
      commentCount: commentCount ?? this.commentCount,
    );
  }
}
