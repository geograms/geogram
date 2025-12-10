/// Update settings and release information model

/// Asset types available in releases
enum UpdateAssetType {
  androidApk,
  androidAab,
  linuxDesktop,
  linuxCli,
  windowsDesktop,
  macosDesktop,
  iosUnsigned,
  web,
  unknown;

  String get name {
    switch (this) {
      case UpdateAssetType.androidApk:
        return 'android-apk';
      case UpdateAssetType.androidAab:
        return 'android-aab';
      case UpdateAssetType.linuxDesktop:
        return 'linux-desktop';
      case UpdateAssetType.linuxCli:
        return 'linux-cli';
      case UpdateAssetType.windowsDesktop:
        return 'windows-desktop';
      case UpdateAssetType.macosDesktop:
        return 'macos-desktop';
      case UpdateAssetType.iosUnsigned:
        return 'ios-unsigned';
      case UpdateAssetType.web:
        return 'web';
      case UpdateAssetType.unknown:
        return 'unknown';
    }
  }

  String get displayName {
    switch (this) {
      case UpdateAssetType.androidApk:
        return 'Android APK';
      case UpdateAssetType.androidAab:
        return 'Android App Bundle';
      case UpdateAssetType.linuxDesktop:
        return 'Linux Desktop';
      case UpdateAssetType.linuxCli:
        return 'Linux CLI';
      case UpdateAssetType.windowsDesktop:
        return 'Windows Desktop';
      case UpdateAssetType.macosDesktop:
        return 'macOS Desktop';
      case UpdateAssetType.iosUnsigned:
        return 'iOS (unsigned)';
      case UpdateAssetType.web:
        return 'Web';
      case UpdateAssetType.unknown:
        return 'Unknown';
    }
  }

  /// Pattern to match asset filename from GitHub releases
  static UpdateAssetType fromFilename(String filename) {
    final lower = filename.toLowerCase();
    if (lower == 'geogram.apk') return UpdateAssetType.androidApk;
    if (lower == 'app-release.aab') return UpdateAssetType.androidAab;
    if (lower.contains('linux') && lower.contains('cli')) return UpdateAssetType.linuxCli;
    if (lower.contains('linux')) return UpdateAssetType.linuxDesktop;
    if (lower.contains('windows')) return UpdateAssetType.windowsDesktop;
    if (lower.contains('macos')) return UpdateAssetType.macosDesktop;
    if (lower.contains('ios') && lower.endsWith('.ipa')) return UpdateAssetType.iosUnsigned;
    if (lower.contains('web')) return UpdateAssetType.web;
    return UpdateAssetType.unknown;
  }

  static UpdateAssetType fromString(String value) {
    for (final type in UpdateAssetType.values) {
      if (type.name == value) return type;
    }
    return UpdateAssetType.unknown;
  }
}

/// Legacy platform enum for backward compatibility
enum UpdatePlatform {
  linux,
  windows,
  android,
  macos,
  unknown;

  String get name {
    switch (this) {
      case UpdatePlatform.linux:
        return 'linux';
      case UpdatePlatform.windows:
        return 'windows';
      case UpdatePlatform.android:
        return 'android';
      case UpdatePlatform.macos:
        return 'macos';
      case UpdatePlatform.unknown:
        return 'unknown';
    }
  }

  String get binaryPattern {
    switch (this) {
      case UpdatePlatform.linux:
        return 'geogram-linux-x64.tar.gz';
      case UpdatePlatform.windows:
        return 'geogram-windows-x64.zip';
      case UpdatePlatform.android:
        return 'geogram.apk';
      case UpdatePlatform.macos:
        return 'geogram-macos-x64.zip';
      case UpdatePlatform.unknown:
        return '';
    }
  }

  /// Get the corresponding asset type for this platform
  UpdateAssetType get assetType {
    switch (this) {
      case UpdatePlatform.linux:
        return UpdateAssetType.linuxDesktop;
      case UpdatePlatform.windows:
        return UpdateAssetType.windowsDesktop;
      case UpdatePlatform.android:
        return UpdateAssetType.androidApk;
      case UpdatePlatform.macos:
        return UpdateAssetType.macosDesktop;
      case UpdatePlatform.unknown:
        return UpdateAssetType.unknown;
    }
  }

  static UpdatePlatform fromString(String value) {
    switch (value.toLowerCase()) {
      case 'linux':
        return UpdatePlatform.linux;
      case 'windows':
        return UpdatePlatform.windows;
      case 'android':
        return UpdatePlatform.android;
      case 'macos':
        return UpdatePlatform.macos;
      default:
        return UpdatePlatform.unknown;
    }
  }
}

/// Update settings configuration
class UpdateSettings {
  bool autoCheckUpdates;
  bool notifyOnUpdate;
  bool useStationForUpdates; // Default: true (offgrid-first)
  String updateUrl;
  String downloadUrlPattern;
  int maxBackups;
  DateTime? lastCheckTime;
  String? lastCheckedVersion;
  String? lastCheckedReleaseBody; // Cached release notes/changelog
  String? lastCheckedHtmlUrl; // GitHub release URL
  String? lastCheckedStationUrl; // Station URL if from station (null = GitHub)
  String? lastCheckedPublishedAt; // Release date ISO string

  UpdateSettings({
    this.autoCheckUpdates = true,
    this.notifyOnUpdate = true,
    this.useStationForUpdates = true,
    this.updateUrl = 'https://api.github.com/repos/geograms/geogram-desktop/releases/latest',
    this.downloadUrlPattern = '',
    this.maxBackups = 5,
    this.lastCheckTime,
    this.lastCheckedVersion,
    this.lastCheckedReleaseBody,
    this.lastCheckedHtmlUrl,
    this.lastCheckedStationUrl,
    this.lastCheckedPublishedAt,
  });

  factory UpdateSettings.fromJson(Map<String, dynamic> json) {
    return UpdateSettings(
      autoCheckUpdates: json['autoCheckUpdates'] as bool? ?? true,
      notifyOnUpdate: json['notifyOnUpdate'] as bool? ?? true,
      useStationForUpdates: json['useStationForUpdates'] as bool? ?? true,
      updateUrl: json['updateUrl'] as String? ??
          'https://api.github.com/repos/geograms/geogram-desktop/releases/latest',
      downloadUrlPattern: json['downloadUrlPattern'] as String? ?? '',
      maxBackups: json['maxBackups'] as int? ?? 5,
      lastCheckTime: json['lastCheckTime'] != null
          ? DateTime.tryParse(json['lastCheckTime'] as String)
          : null,
      lastCheckedVersion: json['lastCheckedVersion'] as String?,
      lastCheckedReleaseBody: json['lastCheckedReleaseBody'] as String?,
      lastCheckedHtmlUrl: json['lastCheckedHtmlUrl'] as String?,
      lastCheckedStationUrl: json['lastCheckedStationUrl'] as String?,
      lastCheckedPublishedAt: json['lastCheckedPublishedAt'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'autoCheckUpdates': autoCheckUpdates,
      'notifyOnUpdate': notifyOnUpdate,
      'useStationForUpdates': useStationForUpdates,
      'updateUrl': updateUrl,
      'downloadUrlPattern': downloadUrlPattern,
      'maxBackups': maxBackups,
      'lastCheckTime': lastCheckTime?.toIso8601String(),
      'lastCheckedVersion': lastCheckedVersion,
      'lastCheckedReleaseBody': lastCheckedReleaseBody,
      'lastCheckedHtmlUrl': lastCheckedHtmlUrl,
      'lastCheckedStationUrl': lastCheckedStationUrl,
      'lastCheckedPublishedAt': lastCheckedPublishedAt,
    };
  }

  UpdateSettings copyWith({
    bool? autoCheckUpdates,
    bool? notifyOnUpdate,
    bool? useStationForUpdates,
    String? updateUrl,
    String? downloadUrlPattern,
    int? maxBackups,
    DateTime? lastCheckTime,
    String? lastCheckedVersion,
    String? lastCheckedReleaseBody,
    String? lastCheckedHtmlUrl,
    String? lastCheckedStationUrl,
    String? lastCheckedPublishedAt,
  }) {
    return UpdateSettings(
      autoCheckUpdates: autoCheckUpdates ?? this.autoCheckUpdates,
      notifyOnUpdate: notifyOnUpdate ?? this.notifyOnUpdate,
      useStationForUpdates: useStationForUpdates ?? this.useStationForUpdates,
      updateUrl: updateUrl ?? this.updateUrl,
      downloadUrlPattern: downloadUrlPattern ?? this.downloadUrlPattern,
      maxBackups: maxBackups ?? this.maxBackups,
      lastCheckTime: lastCheckTime ?? this.lastCheckTime,
      lastCheckedVersion: lastCheckedVersion ?? this.lastCheckedVersion,
      lastCheckedReleaseBody: lastCheckedReleaseBody ?? this.lastCheckedReleaseBody,
      lastCheckedHtmlUrl: lastCheckedHtmlUrl ?? this.lastCheckedHtmlUrl,
      lastCheckedStationUrl: lastCheckedStationUrl ?? this.lastCheckedStationUrl,
      lastCheckedPublishedAt: lastCheckedPublishedAt ?? this.lastCheckedPublishedAt,
    );
  }
}

/// Release information from GitHub or custom source
class ReleaseInfo {
  final String version;
  final String tagName;
  final String? name;
  final String? body;
  final String? publishedAt;
  final String? htmlUrl;
  final Map<String, String> assets; // assetType.name -> download URL
  final Map<String, String> assetFilenames; // assetType.name -> original filename
  final String? stationBaseUrl; // If fetched from station, the base URL

  ReleaseInfo({
    required this.version,
    required this.tagName,
    this.name,
    this.body,
    this.publishedAt,
    this.htmlUrl,
    Map<String, String>? assets,
    Map<String, String>? assetFilenames,
    this.stationBaseUrl,
  })  : assets = assets ?? {},
        assetFilenames = assetFilenames ?? {};

  factory ReleaseInfo.fromGitHubJson(Map<String, dynamic> json) {
    final tagName = json['tag_name'] as String? ?? '';
    final version = tagName.replaceFirst(RegExp(r'^v'), '');

    final assets = <String, String>{};
    final assetFilenames = <String, String>{};
    final assetsList = json['assets'] as List<dynamic>?;
    if (assetsList != null) {
      for (final asset in assetsList) {
        final assetMap = asset as Map<String, dynamic>;
        final filename = assetMap['name'] as String? ?? '';
        final downloadUrl = assetMap['browser_download_url'] as String?;

        if (downloadUrl != null && filename.isNotEmpty) {
          final assetType = UpdateAssetType.fromFilename(filename);
          if (assetType != UpdateAssetType.unknown) {
            assets[assetType.name] = downloadUrl;
            assetFilenames[assetType.name] = filename;
          }
        }
      }
    }

    return ReleaseInfo(
      version: version,
      tagName: tagName,
      name: json['name'] as String?,
      body: json['body'] as String?,
      publishedAt: json['published_at'] as String?,
      htmlUrl: json['html_url'] as String?,
      assets: assets,
      assetFilenames: assetFilenames,
    );
  }

  /// Create from station API response
  factory ReleaseInfo.fromStationJson(Map<String, dynamic> json, String stationBaseUrl) {
    final assets = <String, String>{};
    final assetFilenames = <String, String>{};

    final assetsJson = json['assets'] as Map<String, dynamic>?;
    if (assetsJson != null) {
      for (final entry in assetsJson.entries) {
        assets[entry.key] = '$stationBaseUrl${entry.value}';
      }
    }

    final filenamesJson = json['assetFilenames'] as Map<String, dynamic>?;
    if (filenamesJson != null) {
      for (final entry in filenamesJson.entries) {
        assetFilenames[entry.key] = entry.value as String;
      }
    }

    return ReleaseInfo(
      version: json['version'] as String? ?? '',
      tagName: json['tagName'] as String? ?? '',
      name: json['name'] as String?,
      body: json['body'] as String?,
      publishedAt: json['publishedAt'] as String?,
      htmlUrl: json['htmlUrl'] as String?,
      assets: assets,
      assetFilenames: assetFilenames,
      stationBaseUrl: stationBaseUrl,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'tagName': tagName,
      'name': name,
      'body': body,
      'publishedAt': publishedAt,
      'htmlUrl': htmlUrl,
      'assets': assets,
      'assetFilenames': assetFilenames,
    };
  }

  /// Get download URL for a specific asset type
  String? getAssetUrl(UpdateAssetType type) => assets[type.name];

  /// Get filename for a specific asset type
  String? getAssetFilename(UpdateAssetType type) => assetFilenames[type.name];

  /// Legacy getter for backward compatibility
  String? getDownloadUrlForPlatform(UpdatePlatform platform) {
    return assets[platform.assetType.name];
  }

  @override
  String toString() {
    return 'Release $version ($tagName) - ${assets.length} assets';
  }
}

/// Backup information for rollback
class BackupInfo {
  final String filename;
  final String? version;
  final DateTime timestamp;
  final int sizeBytes;
  final String path;
  final bool isPinned;

  BackupInfo({
    required this.filename,
    this.version,
    required this.timestamp,
    required this.sizeBytes,
    required this.path,
    this.isPinned = false,
  });

  factory BackupInfo.fromJson(Map<String, dynamic> json) {
    return BackupInfo(
      filename: json['filename'] as String,
      version: json['version'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
      sizeBytes: json['sizeBytes'] as int,
      path: json['path'] as String,
      isPinned: json['isPinned'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'filename': filename,
      'version': version,
      'timestamp': timestamp.toIso8601String(),
      'sizeBytes': sizeBytes,
      'path': path,
      'isPinned': isPinned,
    };
  }

  /// Create a copy with updated isPinned status
  BackupInfo copyWith({bool? isPinned}) {
    return BackupInfo(
      filename: filename,
      version: version,
      timestamp: timestamp,
      sizeBytes: sizeBytes,
      path: path,
      isPinned: isPinned ?? this.isPinned,
    );
  }

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  String toString() {
    return '$filename (v${version ?? "unknown"}) - $formattedSize - ${timestamp.toLocal()}';
  }
}
