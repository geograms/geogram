import 'dart:convert';

/// File node in the app tree
class FileNode {
  String path; // Relative path within app
  String name;
  int size;
  bool isDirectory;
  String? hash; // SHA256 hash for files
  List<FileNode>? children; // For directories
  int fileCount; // Number of files inside (for directories)

  FileNode({
    required this.path,
    required this.name,
    required this.size,
    required this.isDirectory,
    this.hash,
    this.children,
    this.fileCount = 0,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'path': path,
      'name': name,
      'size': size,
      'type': isDirectory ? 'directory' : 'file',
    };
    if (hash != null) json['hash'] = hash;
    if (children != null && children!.isNotEmpty) {
      json['children'] = children!.map((c) => c.toJson()).toList();
    }
    return json;
  }

  factory FileNode.fromJson(Map<String, dynamic> json) {
    return FileNode(
      path: json['path'] as String,
      name: json['name'] as String,
      size: json['size'] as int,
      isDirectory: json['type'] == 'directory',
      hash: json['hash'] as String?,
      children: (json['children'] as List<dynamic>?)
          ?.map((c) => FileNode.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Model representing a Geogram app
class App {
  String id;
  String title;
  String description;
  String? thumbnailPath;
  int totalSize;
  int filesCount;
  String updated;
  String? storagePath;
  bool isOwned;
  bool isFavorite;
  String type; // 'shared', 'forum', 'chat', 'www'

  // Security settings
  String visibility; // 'public', 'private', 'restricted'
  List<String> allowedReaders; // List of npub keys
  String encryption; // 'none', 'aes256'

  App({
    required this.id,
    required this.title,
    this.description = '',
    this.thumbnailPath,
    this.totalSize = 0,
    this.filesCount = 0,
    required this.updated,
    this.storagePath,
    this.isOwned = false,
    this.isFavorite = false,
    this.type = 'shared',
    this.visibility = 'public',
    this.allowedReaders = const [],
    this.encryption = 'none',
  });

  /// Create an App from JSON map
  factory App.fromJson(Map<String, dynamic> json) {
    return App(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      description: json['description'] as String? ?? '',
      thumbnailPath: json['thumbnailPath'] as String?,
      totalSize: json['totalSize'] as int? ?? 0,
      filesCount: json['filesCount'] as int? ?? 0,
      updated: json['updated'] as String? ?? DateTime.now().toIso8601String(),
      storagePath: json['storagePath'] as String?,
      isOwned: json['isOwned'] as bool? ?? false,
      isFavorite: json['isFavorite'] as bool? ?? false,
      type: json['type'] as String? ?? 'shared',
      visibility: json['visibility'] as String? ?? 'public',
      allowedReaders: (json['allowedReaders'] as List<dynamic>?)?.cast<String>() ?? [],
      encryption: json['encryption'] as String? ?? 'none',
    );
  }

  /// Convert App to JSON map
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      if (thumbnailPath != null) 'thumbnailPath': thumbnailPath,
      'totalSize': totalSize,
      'filesCount': filesCount,
      'updated': updated,
      if (storagePath != null) 'storagePath': storagePath,
      'isOwned': isOwned,
      'isFavorite': isFavorite,
      'type': type,
      'visibility': visibility,
      'allowedReaders': allowedReaders,
      'encryption': encryption,
    };
  }

  /// Generate app.js content for storage
  String generateAppJs() {
    final data = {
      'app': {
        'id': id,
        'title': title,
        'description': description,
        'type': type,
        'updated': updated,
      },
    };

    // Use dart:convert for proper JSON encoding
    final jsonStr = JsonEncoder.withIndent('  ').convert(data);

    return '''
// Geogram App Metadata
// Generated: ${DateTime.now().toIso8601String()}
window.APP_DATA = $jsonStr;
''';
  }

  /// Generate security.json content
  String generateSecurityJson() {
    final data = {
      'visibility': visibility,
      'allowedReaders': allowedReaders,
      'encryption': encryption,
    };
    return JsonEncoder.withIndent('  ').convert(data);
  }

  /// Format file size for display
  String get formattedSize {
    if (totalSize < 1024) return '$totalSize B';
    if (totalSize < 1024 * 1024) {
      return '${(totalSize / 1024).toStringAsFixed(1)} KB';
    }
    if (totalSize < 1024 * 1024 * 1024) {
      return '${(totalSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(totalSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Format updated date for display
  String get formattedDate {
    try {
      final date = DateTime.parse(updated);
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    } catch (e) {
      return updated;
    }
  }
}
