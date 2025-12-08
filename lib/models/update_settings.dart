/// Update settings and release information model

/// Platform types for binary selection
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
        return 'geogram-desktop-linux';
      case UpdatePlatform.windows:
        return 'geogram-desktop-windows.exe';
      case UpdatePlatform.android:
        return 'geogram-desktop.apk';
      case UpdatePlatform.macos:
        return 'geogram-desktop-macos';
      case UpdatePlatform.unknown:
        return '';
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
  String updateUrl;
  String downloadUrlPattern;
  int maxBackups;
  DateTime? lastCheckTime;
  String? lastCheckedVersion;

  UpdateSettings({
    this.autoCheckUpdates = true,
    this.notifyOnUpdate = true,
    this.updateUrl = 'https://api.github.com/repos/geograms/geogram-desktop/releases/latest',
    this.downloadUrlPattern = '',
    this.maxBackups = 5,
    this.lastCheckTime,
    this.lastCheckedVersion,
  });

  factory UpdateSettings.fromJson(Map<String, dynamic> json) {
    return UpdateSettings(
      autoCheckUpdates: json['autoCheckUpdates'] as bool? ?? true,
      notifyOnUpdate: json['notifyOnUpdate'] as bool? ?? true,
      updateUrl: json['updateUrl'] as String? ??
          'https://api.github.com/repos/geograms/geogram-desktop/releases/latest',
      downloadUrlPattern: json['downloadUrlPattern'] as String? ?? '',
      maxBackups: json['maxBackups'] as int? ?? 5,
      lastCheckTime: json['lastCheckTime'] != null
          ? DateTime.tryParse(json['lastCheckTime'] as String)
          : null,
      lastCheckedVersion: json['lastCheckedVersion'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'autoCheckUpdates': autoCheckUpdates,
      'notifyOnUpdate': notifyOnUpdate,
      'updateUrl': updateUrl,
      'downloadUrlPattern': downloadUrlPattern,
      'maxBackups': maxBackups,
      'lastCheckTime': lastCheckTime?.toIso8601String(),
      'lastCheckedVersion': lastCheckedVersion,
    };
  }

  UpdateSettings copyWith({
    bool? autoCheckUpdates,
    bool? notifyOnUpdate,
    String? updateUrl,
    String? downloadUrlPattern,
    int? maxBackups,
    DateTime? lastCheckTime,
    String? lastCheckedVersion,
  }) {
    return UpdateSettings(
      autoCheckUpdates: autoCheckUpdates ?? this.autoCheckUpdates,
      notifyOnUpdate: notifyOnUpdate ?? this.notifyOnUpdate,
      updateUrl: updateUrl ?? this.updateUrl,
      downloadUrlPattern: downloadUrlPattern ?? this.downloadUrlPattern,
      maxBackups: maxBackups ?? this.maxBackups,
      lastCheckTime: lastCheckTime ?? this.lastCheckTime,
      lastCheckedVersion: lastCheckedVersion ?? this.lastCheckedVersion,
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
  final Map<String, String> assets; // platform -> download URL

  ReleaseInfo({
    required this.version,
    required this.tagName,
    this.name,
    this.body,
    this.publishedAt,
    this.htmlUrl,
    Map<String, String>? assets,
  }) : assets = assets ?? {};

  factory ReleaseInfo.fromGitHubJson(Map<String, dynamic> json) {
    final tagName = json['tag_name'] as String? ?? '';
    final version = tagName.replaceFirst(RegExp(r'^v'), '');

    final assets = <String, String>{};
    final assetsList = json['assets'] as List<dynamic>?;
    if (assetsList != null) {
      for (final asset in assetsList) {
        final assetMap = asset as Map<String, dynamic>;
        final name = (assetMap['name'] as String? ?? '').toLowerCase();
        final downloadUrl = assetMap['browser_download_url'] as String?;

        if (downloadUrl != null) {
          if (name.contains('linux') || name == 'geogram-desktop-linux') {
            assets['linux'] = downloadUrl;
          } else if (name.contains('windows') || name.endsWith('.exe')) {
            assets['windows'] = downloadUrl;
          } else if (name.contains('android') || name.endsWith('.apk')) {
            assets['android'] = downloadUrl;
          } else if (name.contains('macos') || name.contains('darwin')) {
            assets['macos'] = downloadUrl;
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
    };
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
