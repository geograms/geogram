/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Video visibility levels
enum VideoVisibility {
  public,
  private,
  unlisted,
  restricted;

  static VideoVisibility fromString(String value) {
    return VideoVisibility.values.firstWhere(
      (e) => e.name == value.toLowerCase(),
      orElse: () => VideoVisibility.public,
    );
  }
}

/// Video categories as defined in the specification
enum VideoCategory {
  // Entertainment
  entertainment,
  comedy,
  music,
  gaming,
  movies,
  shows,
  animation,

  // Education
  education,
  tutorial,
  course,
  lecture,
  documentary,
  science,
  history,
  language,

  // Lifestyle
  travel,
  food,
  fitness,
  fashion,
  beauty,
  home,
  garden,
  pets,

  // Technology
  tech,
  programming,
  hardware,
  gadgets,
  apps,
  ai,

  // News & Information
  news,
  politics,
  business,
  sports,
  weather,

  // Creative
  art,
  photography,
  film,
  design,
  craft,

  // Personal
  vlog,
  family,
  events,
  memories,

  // Other
  other;

  static VideoCategory fromString(String value) {
    return VideoCategory.values.firstWhere(
      (e) => e.name == value.toLowerCase(),
      orElse: () => VideoCategory.other,
    );
  }

  /// Get display name for the category
  String get displayName {
    switch (this) {
      case VideoCategory.ai:
        return 'AI';
      case VideoCategory.tech:
        return 'Technology';
      case VideoCategory.vlog:
        return 'Vlog';
      default:
        // Capitalize first letter
        return name[0].toUpperCase() + name.substring(1);
    }
  }
}

/// Model representing a video with multilingual support
class Video {
  final String id; // Folder name (sanitized title)
  final String author; // Callsign
  final String created; // Format: YYYY-MM-DD HH:MM_ss
  final String? edited; // Format: YYYY-MM-DD HH:MM_ss

  // Multilingual support
  final Map<String, String> titles; // {langCode: title}
  final Map<String, String> descriptions; // {langCode: description}

  // Video metadata
  final int duration; // Seconds
  final String resolution; // e.g., "1920x1080"
  final int fileSize; // Bytes
  final String mimeType; // e.g., "video/mp4"

  // Classification
  final VideoCategory category;
  final VideoVisibility visibility;
  final List<String> tags;

  // Optional location
  final double? latitude;
  final double? longitude;

  // Optional author info
  final List<String> websites;
  final List<String> social;
  final String? contact;

  // Restricted visibility
  final List<String> allowedGroups;
  final List<String> allowedUsers; // npub format

  // NOSTR
  final String? npub;
  final String? signature;

  // File paths
  final String? folderPath; // Full path to video folder
  final String? thumbnailPath; // Relative or absolute path to thumbnail
  final String? videoFilePath; // Full path to video file (local only)
  final bool isLocal; // Whether video file exists locally

  // Feedback counts
  final int likesCount;
  final int pointsCount;
  final int dislikesCount;
  final int subscribeCount;
  final int verificationsCount;
  final int viewsCount;

  // Emoji reaction counts
  final int heartCount;
  final int thumbsUpCount;
  final int thumbsDownCount;
  final int fireCount;
  final int hundredCount;
  final int curiousCount;
  final int celebrateCount;
  final int laughCount;
  final int sadCount;
  final int beerCheersCount;
  final int surpriseCount;

  // Comment count
  final int commentCount;

  // User-specific feedback state
  final bool hasLiked;
  final bool hasPointed;
  final bool hasDisliked;
  final bool hasSubscribed;
  final bool hasVerified;
  final bool hasHearted;
  final bool hasThumbsUp;
  final bool hasThumbsDown;
  final bool hasFired;
  final bool hasHundred;
  final bool hasCurious;
  final bool hasCelebrated;
  final bool hasLaughed;
  final bool hasSad;
  final bool hasBeerCheers;
  final bool hasSurprised;

  Video({
    required this.id,
    required this.author,
    required this.created,
    this.edited,
    this.titles = const {},
    this.descriptions = const {},
    required this.duration,
    required this.resolution,
    required this.fileSize,
    this.mimeType = 'video/mp4',
    this.category = VideoCategory.other,
    this.visibility = VideoVisibility.public,
    this.tags = const [],
    this.latitude,
    this.longitude,
    this.websites = const [],
    this.social = const [],
    this.contact,
    this.allowedGroups = const [],
    this.allowedUsers = const [],
    this.npub,
    this.signature,
    this.folderPath,
    this.thumbnailPath,
    this.videoFilePath,
    this.isLocal = false,
    // Feedback counts
    this.likesCount = 0,
    this.pointsCount = 0,
    this.dislikesCount = 0,
    this.subscribeCount = 0,
    this.verificationsCount = 0,
    this.viewsCount = 0,
    this.heartCount = 0,
    this.thumbsUpCount = 0,
    this.thumbsDownCount = 0,
    this.fireCount = 0,
    this.hundredCount = 0,
    this.curiousCount = 0,
    this.celebrateCount = 0,
    this.laughCount = 0,
    this.sadCount = 0,
    this.beerCheersCount = 0,
    this.surpriseCount = 0,
    this.commentCount = 0,
    // User feedback state
    this.hasLiked = false,
    this.hasPointed = false,
    this.hasDisliked = false,
    this.hasSubscribed = false,
    this.hasVerified = false,
    this.hasHearted = false,
    this.hasThumbsUp = false,
    this.hasThumbsDown = false,
    this.hasFired = false,
    this.hasHundred = false,
    this.hasCurious = false,
    this.hasCelebrated = false,
    this.hasLaughed = false,
    this.hasSad = false,
    this.hasBeerCheers = false,
    this.hasSurprised = false,
  });

  /// Get title in requested language with fallback
  /// Fallback: requested language -> EN -> first available
  String getTitle([String langCode = 'EN']) {
    if (titles.containsKey(langCode)) return titles[langCode]!;
    if (titles.containsKey('EN')) return titles['EN']!;
    if (titles.isNotEmpty) return titles.values.first;
    return id; // Fallback to ID
  }

  /// Get description in requested language with fallback
  String getDescription([String langCode = 'EN']) {
    if (descriptions.containsKey(langCode)) return descriptions[langCode]!;
    if (descriptions.containsKey('EN')) return descriptions['EN']!;
    if (descriptions.isNotEmpty) return descriptions.values.first;
    return '';
  }

  /// Parse created timestamp to DateTime
  DateTime get dateTime {
    try {
      final normalized = created.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Get display time (HH:MM)
  String get displayTime {
    final dt = dateTime;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  /// Get display date (YYYY-MM-DD)
  String get displayDate {
    final dt = dateTime;
    final year = dt.year.toString();
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// Get year from timestamp
  int get year => dateTime.year;

  /// Get formatted duration (MM:SS or HH:MM:SS)
  String get formattedDuration {
    final hours = duration ~/ 3600;
    final minutes = (duration % 3600) ~/ 60;
    final seconds = duration % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Get human-readable file size
  String get formattedFileSize {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Check visibility
  bool get isPublic => visibility == VideoVisibility.public;
  bool get isPrivate => visibility == VideoVisibility.private;
  bool get isUnlisted => visibility == VideoVisibility.unlisted;
  bool get isRestricted => visibility == VideoVisibility.restricted;

  /// Check if has coordinates
  bool get hasLocation => latitude != null && longitude != null;

  /// Check if signed with NOSTR
  bool get isSigned => signature != null && signature!.isNotEmpty;

  /// Check if user has access (for restricted videos)
  bool hasAccess(String? userNpub, List<String>? userGroups) {
    if (!isRestricted) return true;
    if (userNpub == null) return false;

    // Check if user is in allowed users
    if (allowedUsers.contains(userNpub)) return true;

    // Check if user is in any allowed group
    if (userGroups != null) {
      for (final group in userGroups) {
        if (allowedGroups.contains(group)) return true;
      }
    }

    return false;
  }

  /// Export video as text format (video.txt content)
  String exportAsText() {
    final buffer = StringBuffer();

    // Title line(s)
    if (titles.length == 1 && titles.containsKey('EN')) {
      // Single language format
      buffer.writeln('# VIDEO: ${titles['EN']}');
    } else {
      // Multilingual format
      for (final entry in titles.entries) {
        buffer.writeln('# VIDEO_${entry.key}: ${entry.value}');
      }
    }

    buffer.writeln();

    // Metadata
    buffer.writeln('CREATED: $created');
    if (edited != null && edited!.isNotEmpty) {
      buffer.writeln('EDITED: $edited');
    }
    buffer.writeln('AUTHOR: $author');
    buffer.writeln();

    // Video metadata
    buffer.writeln('DURATION: $duration');
    buffer.writeln('RESOLUTION: $resolution');
    buffer.writeln('FILE_SIZE: $fileSize');
    buffer.writeln('MIME_TYPE: $mimeType');
    buffer.writeln();

    // Optional location
    if (hasLocation) {
      buffer.writeln('COORDINATES: $latitude,$longitude');
    }

    // Tags
    if (tags.isNotEmpty) {
      buffer.writeln('TAGS: ${tags.join(', ')}');
    }

    // Category and visibility
    buffer.writeln('CATEGORY: ${category.name}');
    buffer.writeln('VISIBILITY: ${visibility.name}');

    // Restricted access
    if (isRestricted) {
      if (allowedGroups.isNotEmpty) {
        buffer.writeln('ALLOWED_GROUPS: ${allowedGroups.join(', ')}');
      }
      if (allowedUsers.isNotEmpty) {
        buffer.writeln('ALLOWED_USERS: ${allowedUsers.join(', ')}');
      }
    }

    // Optional author info
    if (websites.isNotEmpty) {
      buffer.writeln('WEBSITES: ${websites.join(', ')}');
    }
    if (social.isNotEmpty) {
      buffer.writeln('SOCIAL: ${social.join(', ')}');
    }
    if (contact != null && contact!.isNotEmpty) {
      buffer.writeln('CONTACT: $contact');
    }

    buffer.writeln();

    // Description content
    if (descriptions.length == 1 && descriptions.containsKey('EN')) {
      // Single language
      buffer.writeln(descriptions['EN']);
    } else if (descriptions.isNotEmpty) {
      // Multilingual
      for (final entry in descriptions.entries) {
        buffer.writeln('[${entry.key}]');
        buffer.writeln(entry.value);
        buffer.writeln();
      }
    }

    // NOSTR signature
    if (npub != null && npub!.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('--> npub: $npub');
    }
    if (signature != null && signature!.isNotEmpty) {
      buffer.writeln('--> signature: $signature');
    }

    return buffer.toString();
  }

  /// Create a copy with updated fields
  Video copyWith({
    String? id,
    String? author,
    String? created,
    String? edited,
    Map<String, String>? titles,
    Map<String, String>? descriptions,
    int? duration,
    String? resolution,
    int? fileSize,
    String? mimeType,
    VideoCategory? category,
    VideoVisibility? visibility,
    List<String>? tags,
    double? latitude,
    double? longitude,
    List<String>? websites,
    List<String>? social,
    String? contact,
    List<String>? allowedGroups,
    List<String>? allowedUsers,
    String? npub,
    String? signature,
    String? folderPath,
    String? thumbnailPath,
    String? videoFilePath,
    bool? isLocal,
    int? likesCount,
    int? pointsCount,
    int? dislikesCount,
    int? subscribeCount,
    int? verificationsCount,
    int? viewsCount,
    int? heartCount,
    int? thumbsUpCount,
    int? thumbsDownCount,
    int? fireCount,
    int? hundredCount,
    int? curiousCount,
    int? celebrateCount,
    int? laughCount,
    int? sadCount,
    int? beerCheersCount,
    int? surpriseCount,
    int? commentCount,
    bool? hasLiked,
    bool? hasPointed,
    bool? hasDisliked,
    bool? hasSubscribed,
    bool? hasVerified,
    bool? hasHearted,
    bool? hasThumbsUp,
    bool? hasThumbsDown,
    bool? hasFired,
    bool? hasHundred,
    bool? hasCurious,
    bool? hasCelebrated,
    bool? hasLaughed,
    bool? hasSad,
    bool? hasBeerCheers,
    bool? hasSurprised,
  }) {
    return Video(
      id: id ?? this.id,
      author: author ?? this.author,
      created: created ?? this.created,
      edited: edited ?? this.edited,
      titles: titles ?? this.titles,
      descriptions: descriptions ?? this.descriptions,
      duration: duration ?? this.duration,
      resolution: resolution ?? this.resolution,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      category: category ?? this.category,
      visibility: visibility ?? this.visibility,
      tags: tags ?? this.tags,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      websites: websites ?? this.websites,
      social: social ?? this.social,
      contact: contact ?? this.contact,
      allowedGroups: allowedGroups ?? this.allowedGroups,
      allowedUsers: allowedUsers ?? this.allowedUsers,
      npub: npub ?? this.npub,
      signature: signature ?? this.signature,
      folderPath: folderPath ?? this.folderPath,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      videoFilePath: videoFilePath ?? this.videoFilePath,
      isLocal: isLocal ?? this.isLocal,
      likesCount: likesCount ?? this.likesCount,
      pointsCount: pointsCount ?? this.pointsCount,
      dislikesCount: dislikesCount ?? this.dislikesCount,
      subscribeCount: subscribeCount ?? this.subscribeCount,
      verificationsCount: verificationsCount ?? this.verificationsCount,
      viewsCount: viewsCount ?? this.viewsCount,
      heartCount: heartCount ?? this.heartCount,
      thumbsUpCount: thumbsUpCount ?? this.thumbsUpCount,
      thumbsDownCount: thumbsDownCount ?? this.thumbsDownCount,
      fireCount: fireCount ?? this.fireCount,
      hundredCount: hundredCount ?? this.hundredCount,
      curiousCount: curiousCount ?? this.curiousCount,
      celebrateCount: celebrateCount ?? this.celebrateCount,
      laughCount: laughCount ?? this.laughCount,
      sadCount: sadCount ?? this.sadCount,
      beerCheersCount: beerCheersCount ?? this.beerCheersCount,
      surpriseCount: surpriseCount ?? this.surpriseCount,
      commentCount: commentCount ?? this.commentCount,
      hasLiked: hasLiked ?? this.hasLiked,
      hasPointed: hasPointed ?? this.hasPointed,
      hasDisliked: hasDisliked ?? this.hasDisliked,
      hasSubscribed: hasSubscribed ?? this.hasSubscribed,
      hasVerified: hasVerified ?? this.hasVerified,
      hasHearted: hasHearted ?? this.hasHearted,
      hasThumbsUp: hasThumbsUp ?? this.hasThumbsUp,
      hasThumbsDown: hasThumbsDown ?? this.hasThumbsDown,
      hasFired: hasFired ?? this.hasFired,
      hasHundred: hasHundred ?? this.hasHundred,
      hasCurious: hasCurious ?? this.hasCurious,
      hasCelebrated: hasCelebrated ?? this.hasCelebrated,
      hasLaughed: hasLaughed ?? this.hasLaughed,
      hasSad: hasSad ?? this.hasSad,
      hasBeerCheers: hasBeerCheers ?? this.hasBeerCheers,
      hasSurprised: hasSurprised ?? this.hasSurprised,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'author': author,
      'created': created,
      if (edited != null) 'edited': edited,
      'titles': titles,
      'descriptions': descriptions,
      'duration': duration,
      'resolution': resolution,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'category': category.name,
      'visibility': visibility.name,
      'tags': tags,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      'websites': websites,
      'social': social,
      if (contact != null) 'contact': contact,
      'allowedGroups': allowedGroups,
      'allowedUsers': allowedUsers,
      if (npub != null) 'npub': npub,
      if (signature != null) 'signature': signature,
      if (folderPath != null) 'folderPath': folderPath,
      if (thumbnailPath != null) 'thumbnailPath': thumbnailPath,
      if (videoFilePath != null) 'videoFilePath': videoFilePath,
      'isLocal': isLocal,
      // Feedback counts
      'likesCount': likesCount,
      'pointsCount': pointsCount,
      'dislikesCount': dislikesCount,
      'subscribeCount': subscribeCount,
      'verificationsCount': verificationsCount,
      'viewsCount': viewsCount,
      'heartCount': heartCount,
      'thumbsUpCount': thumbsUpCount,
      'thumbsDownCount': thumbsDownCount,
      'fireCount': fireCount,
      'hundredCount': hundredCount,
      'curiousCount': curiousCount,
      'celebrateCount': celebrateCount,
      'laughCount': laughCount,
      'sadCount': sadCount,
      'beerCheersCount': beerCheersCount,
      'surpriseCount': surpriseCount,
      'commentCount': commentCount,
    };
  }

  /// Create from JSON
  factory Video.fromJson(Map<String, dynamic> json) {
    return Video(
      id: json['id'] as String,
      author: json['author'] as String,
      created: json['created'] as String,
      edited: json['edited'] as String?,
      titles: Map<String, String>.from(json['titles'] ?? {}),
      descriptions: Map<String, String>.from(json['descriptions'] ?? {}),
      duration: json['duration'] as int,
      resolution: json['resolution'] as String,
      fileSize: json['fileSize'] as int,
      mimeType: json['mimeType'] as String? ?? 'video/mp4',
      category: VideoCategory.fromString(json['category'] as String? ?? 'other'),
      visibility: VideoVisibility.fromString(json['visibility'] as String? ?? 'public'),
      tags: List<String>.from(json['tags'] ?? []),
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
      websites: List<String>.from(json['websites'] ?? []),
      social: List<String>.from(json['social'] ?? []),
      contact: json['contact'] as String?,
      allowedGroups: List<String>.from(json['allowedGroups'] ?? []),
      allowedUsers: List<String>.from(json['allowedUsers'] ?? []),
      npub: json['npub'] as String?,
      signature: json['signature'] as String?,
      folderPath: json['folderPath'] as String?,
      thumbnailPath: json['thumbnailPath'] as String?,
      videoFilePath: json['videoFilePath'] as String?,
      isLocal: json['isLocal'] as bool? ?? false,
      likesCount: json['likesCount'] as int? ?? 0,
      pointsCount: json['pointsCount'] as int? ?? 0,
      dislikesCount: json['dislikesCount'] as int? ?? 0,
      subscribeCount: json['subscribeCount'] as int? ?? 0,
      verificationsCount: json['verificationsCount'] as int? ?? 0,
      viewsCount: json['viewsCount'] as int? ?? 0,
      heartCount: json['heartCount'] as int? ?? 0,
      thumbsUpCount: json['thumbsUpCount'] as int? ?? 0,
      thumbsDownCount: json['thumbsDownCount'] as int? ?? 0,
      fireCount: json['fireCount'] as int? ?? 0,
      hundredCount: json['hundredCount'] as int? ?? 0,
      curiousCount: json['curiousCount'] as int? ?? 0,
      celebrateCount: json['celebrateCount'] as int? ?? 0,
      laughCount: json['laughCount'] as int? ?? 0,
      sadCount: json['sadCount'] as int? ?? 0,
      beerCheersCount: json['beerCheersCount'] as int? ?? 0,
      surpriseCount: json['surpriseCount'] as int? ?? 0,
      commentCount: json['commentCount'] as int? ?? 0,
    );
  }

  @override
  String toString() {
    return 'Video(id: $id, title: ${getTitle()}, author: $author, duration: ${formattedDuration}, visibility: ${visibility.name})';
  }
}
