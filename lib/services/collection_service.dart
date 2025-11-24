import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import '../models/collection.dart';
import '../models/chat_channel.dart';
import '../models/chat_security.dart';
import '../models/chat_settings.dart';
import '../models/forum_section.dart';
import '../util/nostr_key_generator.dart';
import '../util/tlsh.dart';
import 'config_service.dart';
import 'chat_service.dart';
import 'profile_service.dart';

/// Service for managing collections on disk
class CollectionService {
  static final CollectionService _instance = CollectionService._internal();
  factory CollectionService() => _instance;
  CollectionService._internal();

  Directory? _collectionsDir;
  final ConfigService _configService = ConfigService();

  /// Get the default collections directory path
  String getDefaultCollectionsPath() {
    if (_collectionsDir == null) {
      throw Exception('CollectionService not initialized. Call init() first.');
    }
    return _collectionsDir!.path;
  }

  /// Initialize the collection service
  Future<void> init() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _collectionsDir = Directory('${appDir.path}/geogram/collections');

      if (!await _collectionsDir!.exists()) {
        await _collectionsDir!.create(recursive: true);
      }

      // Use stderr for init logs since LogService might not be ready
      stderr.writeln('CollectionService initialized: ${_collectionsDir!.path}');
    } catch (e) {
      stderr.writeln('Error initializing CollectionService: $e');
      rethrow;
    }
  }

  /// Get the collections directory
  Directory get collectionsDirectory {
    if (_collectionsDir == null) {
      throw Exception('CollectionService not initialized. Call init() first.');
    }
    return _collectionsDir!;
  }

  /// Load all collections from disk (including from custom locations)
  Future<List<Collection>> loadCollections() async {
    if (_collectionsDir == null) {
      throw Exception('CollectionService not initialized. Call init() first.');
    }

    final collections = <Collection>[];

    // Load from default collections directory
    if (await _collectionsDir!.exists()) {
      final folders = await _collectionsDir!.list().toList();

      for (var entity in folders) {
        if (entity is Directory) {
          try {
            final collection = await _loadCollectionFromFolder(entity);
            if (collection != null) {
              collections.add(collection);
            }
          } catch (e) {
            stderr.writeln('Error loading collection from ${entity.path}: $e');
          }
        }
      }
    }

    // TODO: Load from custom locations stored in config
    // For now, we only load from the default directory
    // In the future, we can store custom collection paths in config.json
    // and scan those directories as well

    return collections;
  }

  /// Load a single collection from a folder
  Future<Collection?> _loadCollectionFromFolder(Directory folder) async {
    final collectionJsFile = File('${folder.path}/collection.js');

    if (!await collectionJsFile.exists()) {
      return null;
    }

    try {
      final content = await collectionJsFile.readAsString();

      // Extract JSON from JavaScript file
      final startIndex = content.indexOf('window.COLLECTION_DATA = {');
      if (startIndex == -1) {
        return null;
      }

      final jsonStart = content.indexOf('{', startIndex);
      final jsonEnd = content.lastIndexOf('};');

      if (jsonStart == -1 || jsonEnd == -1) {
        return null;
      }

      final jsonContent = content.substring(jsonStart, jsonEnd + 1);
      final data = json.decode(jsonContent) as Map<String, dynamic>;

      final collectionData = data['collection'] as Map<String, dynamic>?;
      if (collectionData == null) {
        return null;
      }

      final collection = Collection(
        id: collectionData['id'] as String? ?? '',
        title: collectionData['title'] as String? ?? 'Untitled',
        description: collectionData['description'] as String? ?? '',
        type: collectionData['type'] as String? ?? 'files',
        updated: collectionData['updated'] as String? ??
                 DateTime.now().toIso8601String(),
        storagePath: folder.path,
        isOwned: true, // All local collections are owned
        visibility: 'public', // Default, will be overridden by security.json
        allowedReaders: const [],
        encryption: 'none',
      );

      // Set favorite status from config
      collection.isFavorite = _configService.isFavorite(collection.id);

      // Load security settings (will override defaults if file exists)
      await _loadSecuritySettings(collection, folder);

      // Check if all required files exist (collection.js, tree.json, data.js, index.html)
      // Only generate missing files, don't validate/regenerate on startup to avoid file handle exhaustion
      if (!await _hasRequiredFiles(folder)) {
        stderr.writeln('Missing required files for collection: ${collection.title}');
        stderr.writeln('Generating tree.json, data.js, and index.html...');

        // Generate files synchronously on first load
        await _generateAndSaveTreeJson(folder);
        await _generateAndSaveDataJs(folder);
        await _generateAndSaveIndexHtml(folder);
      }
      // Note: Validation and regeneration are skipped on startup to prevent "too many open files" errors
      // Tree files will be regenerated when explicitly requested or when collection is modified

      // Count files
      await _countCollectionFiles(collection, folder);

      return collection;
    } catch (e) {
      stderr.writeln('Error parsing collection.js: $e');
      return null;
    }
  }

  /// Count files and calculate total size in a collection
  Future<void> _countCollectionFiles(Collection collection, Directory folder) async {
    int fileCount = 0;
    int totalSize = 0;

    try {
      // Read from tree.json instead of scanning filesystem to avoid "too many open files"
      final treeJsonFile = File('${folder.path}/extra/tree.json');

      if (await treeJsonFile.exists()) {
        final content = await treeJsonFile.readAsString();
        final entries = json.decode(content) as List<dynamic>;

        // Recursively count files including those in subdirectories
        void countRecursive(List<dynamic> items) {
          for (var entry in items) {
            if (entry['type'] == 'file') {
              fileCount++;
              totalSize += entry['size'] as int? ?? 0;
            } else if (entry['type'] == 'directory' && entry['children'] != null) {
              // Recursively count files in subdirectories
              countRecursive(entry['children'] as List<dynamic>);
            }
          }
        }

        countRecursive(entries);
      } else {
        // If tree.json doesn't exist yet, scan filesystem directly
        await _scanDirectoryForCount(folder, (count, size) {
          fileCount += count;
          totalSize += size;
        });
      }
    } catch (e) {
      stderr.writeln('Error counting files: $e');
    }

    collection.filesCount = fileCount;
    collection.totalSize = totalSize;
  }

  /// Scan directory recursively to count files (fallback when tree.json doesn't exist)
  Future<void> _scanDirectoryForCount(Directory dir, void Function(int count, int size) onCount) async {
    try {
      final entities = await dir.list().toList();

      for (var entity in entities) {
        if (entity is File) {
          // Skip system files
          final fileName = entity.path.split('/').last;
          if (!fileName.startsWith('.') &&
              fileName != 'collection.js' &&
              fileName != 'tree.json' &&
              fileName != 'data.js') {
            try {
              final stat = await entity.stat();
              onCount(1, stat.size);
            } catch (e) {
              // Skip files that can't be accessed
            }
          }
        } else if (entity is Directory) {
          // Skip system directories
          final dirName = entity.path.split('/').last;
          if (!dirName.startsWith('.') && dirName != 'extra') {
            await _scanDirectoryForCount(entity, onCount);
          }
        }
      }
    } catch (e) {
      stderr.writeln('Error scanning directory ${dir.path}: $e');
    }
  }

  /// Create a new collection
  Future<Collection> createCollection({
    required String title,
    String description = '',
    String type = 'files',
    String? customRootPath,
  }) async {
    if (_collectionsDir == null) {
      throw Exception('CollectionService not initialized. Call init() first.');
    }

    try {
      // Generate NOSTR key pair (npub/nsec)
      final keys = NostrKeyGenerator.generateKeyPair();
      final id = keys.npub; // Use npub as collection ID

      stderr.writeln('Creating collection with ID (npub): $id');

      // Store keys in config
      await _configService.storeCollectionKeys(keys);

      // Determine folder name based on type
      String folderName;
      String rootPath;

      if (type != 'files') {
        // For non-files types (forum, chat, www), use the type as folder name
        // and always use default collections directory
        folderName = type;
        rootPath = _collectionsDir!.path;

        stderr.writeln('Using fixed folder name for $type: $folderName');

        // Check if this type already exists
        final collectionFolder = Directory('$rootPath/$folderName');
        if (await collectionFolder.exists()) {
          throw Exception('A $type collection already exists');
        }
      } else {
        // For files type, sanitize the title as folder name
        folderName = title
            .replaceAll(' ', '_')
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9_-]'), '_');

        // Truncate to 50 characters
        if (folderName.length > 50) {
          folderName = folderName.substring(0, 50);
        }

        // Remove trailing underscores
        folderName = folderName.replaceAll(RegExp(r'_+$'), '');

        // Ensure folder name is not empty
        if (folderName.isEmpty) {
          folderName = 'collection';
        }

        stderr.writeln('Sanitized folder name: $folderName');

        // Use custom root path if provided, otherwise default
        rootPath = customRootPath ?? _collectionsDir!.path;
        stderr.writeln('Using root path: $rootPath');
      }

      // Create folder (with uniqueness check for files type only)
      var collectionFolder = Directory('$rootPath/$folderName');

      if (type == 'files') {
        // Find unique folder name for files type
        int counter = 1;
        while (await collectionFolder.exists()) {
          collectionFolder = Directory('$rootPath/${folderName}_$counter');
          counter++;
        }
      }

      stderr.writeln('Creating folder: ${collectionFolder.path}');

      // Create folder structure
      await collectionFolder.create(recursive: true);
      final extraDir = Directory('${collectionFolder.path}/extra');
      await extraDir.create();

      stderr.writeln('Folders created successfully');

      // Create skeleton template files based on type
      await _createSkeletonFiles(type, collectionFolder);

      // Create collection object
      final collection = Collection(
        id: id,
        title: title,
        description: description,
        type: type,
        updated: DateTime.now().toIso8601String(),
        storagePath: collectionFolder.path,
        isOwned: true,
        isFavorite: false,
        filesCount: 0,
        totalSize: 0,
      );

      stderr.writeln('Writing collection files...');

      // Write collection files
      await _writeCollectionFiles(collection, collectionFolder);

      stderr.writeln('Collection created successfully');

      return collection;
    } catch (e, stackTrace) {
      stderr.writeln('Error in createCollection: $e');
      stderr.writeln('Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Create skeleton template files based on collection type
  Future<void> _createSkeletonFiles(String type, Directory collectionFolder) async {
    try {
      if (type == 'www') {
        // Create default index.html for website type
        final indexFile = File('${collectionFolder.path}/index.html');
        final indexContent = '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 50px auto;
            padding: 20px;
            line-height: 1.6;
        }
        h1 {
            color: #333;
        }
        p {
            color: #666;
        }
    </style>
</head>
<body>
    <h1>Welcome to Your Website</h1>
    <p>This is the default homepage. Edit this file to create your website.</p>
    <p>You can add more HTML files, CSS stylesheets, JavaScript files, and images to build your site.</p>
</body>
</html>
''';
        await indexFile.writeAsString(indexContent);
        stderr.writeln('Created skeleton index.html for www type');
      } else if (type == 'chat') {
        // Initialize chat collection structure
        await _initializeChatCollection(collectionFolder);
        stderr.writeln('Created chat collection skeleton');
      } else if (type == 'forum') {
        // Initialize forum collection structure
        await _initializeForumCollection(collectionFolder);
        stderr.writeln('Created forum collection skeleton');
      } else if (type == 'postcards') {
        // Initialize postcards collection structure
        await _initializePostcardsCollection(collectionFolder);
        stderr.writeln('Created postcards collection skeleton');
      } else if (type == 'contacts') {
        // Initialize contacts collection structure
        await _initializeContactsCollection(collectionFolder);
        stderr.writeln('Created contacts collection skeleton');
      } else if (type == 'places') {
        // Initialize places collection structure
        await _initializePlacesCollection(collectionFolder);
        stderr.writeln('Created places collection skeleton');
      }
      // Add more skeleton templates for other types here
    } catch (e) {
      stderr.writeln('Error creating skeleton files: $e');
      // Don't fail collection creation if skeleton creation fails
    }
  }

  /// Initialize chat collection with main channel and metadata files
  Future<void> _initializeChatCollection(Directory collectionFolder) async {
    // Create main channel folder
    final mainDir = Directory('${collectionFolder.path}/main');
    await mainDir.create();

    // Create main channel year folder
    final year = DateTime.now().year;
    final yearDir = Directory('${mainDir.path}/$year');
    await yearDir.create();

    // Create files subfolder in year directory
    final filesDir = Directory('${yearDir.path}/files');
    await filesDir.create();

    // Create files folder in main directory (for non-dated files)
    final mainFilesDir = Directory('${mainDir.path}/files');
    await mainFilesDir.create();

    // Create main channel config.json
    final mainConfig = ChatChannelConfig.defaults(
      id: 'main',
      name: 'Main Chat',
      description: 'Public group chat for everyone',
    );
    final configFile = File('${mainDir.path}/config.json');
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(mainConfig.toJson()),
    );

    // Create channels.json in extra/
    final channelsFile = File('${collectionFolder.path}/extra/channels.json');
    final channelsData = {
      'version': '1.0',
      'channels': [
        {
          'id': 'main',
          'type': 'group',
          'name': 'Main Chat',
          'folder': 'main',
          'participants': ['*'],
          'created': DateTime.now().toIso8601String(),
        }
      ]
    };
    await channelsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(channelsData),
    );

    // Create participants.json in extra/
    final participantsFile =
        File('${collectionFolder.path}/extra/participants.json');
    final participantsData = {
      'version': '1.0',
      'participants': {},
    };
    await participantsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(participantsData),
    );

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityFile = File('${collectionFolder.path}/extra/security.json');
    final security = ChatSecurity(
      adminNpub: currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
    );
    final securityData = {
      'version': '1.0',
      ...security.toJson(),
    };
    await securityFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(securityData),
    );

    // Create settings.json with signing enabled by default
    final settingsFile = File('${collectionFolder.path}/extra/settings.json');
    final settings = ChatSettings(signMessages: true);
    await settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );

    stderr.writeln('Chat collection initialized with main channel');
    if (currentProfile.npub.isNotEmpty) {
      stderr.writeln('Set ${currentProfile.callsign} (${currentProfile.npub}) as admin');
    }
  }

  /// Initialize forum collection with default sections and metadata files
  Future<void> _initializeForumCollection(Directory collectionFolder) async {
    // Define default sections
    final defaultSections = [
      {
        'id': 'announcements',
        'name': 'Announcements',
        'folder': 'announcements',
        'description': 'Important announcements and updates',
        'order': 1,
        'readonly': false,
      },
      {
        'id': 'general',
        'name': 'General Discussion',
        'folder': 'general',
        'description': 'General topics and discussions',
        'order': 2,
        'readonly': false,
      },
      {
        'id': 'help',
        'name': 'Help & Support',
        'folder': 'help',
        'description': 'Get help and support from the community',
        'order': 3,
        'readonly': false,
      },
    ];

    // Create section folders and config files
    for (var sectionData in defaultSections) {
      final sectionDir = Directory('${collectionFolder.path}/${sectionData['folder']}');
      await sectionDir.create();

      // Create section config.json with default settings
      final config = ForumSectionConfig.defaults(
        id: sectionData['id'] as String,
        name: sectionData['name'] as String,
        description: sectionData['description'] as String?,
      );

      final configFile = File('${sectionDir.path}/config.json');
      await configFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(config.toJson()),
      );
    }

    // Create sections.json in extra/
    final sectionsFile = File('${collectionFolder.path}/extra/sections.json');
    final sectionsData = {
      'version': '1.0',
      'sections': defaultSections,
    };
    await sectionsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(sectionsData),
    );

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityFile = File('${collectionFolder.path}/extra/security.json');
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
      'bannedNpubs': <String>[],
    };
    await securityFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(securityData),
    );

    // Create settings.json with signing enabled by default
    final settingsFile = File('${collectionFolder.path}/extra/settings.json');
    final settingsData = {
      'version': '1.0',
      'signMessages': true,
      'requireSignatures': false,
    };
    await settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settingsData),
    );

    stderr.writeln('Forum collection initialized with ${defaultSections.length} sections');
    if (currentProfile.npub.isNotEmpty) {
      stderr.writeln('Set ${currentProfile.callsign} (${currentProfile.npub}) as admin');
    }
  }

  /// Initialize postcards collection with directory structure
  Future<void> _initializePostcardsCollection(Directory collectionFolder) async {
    // Create postcards directory
    final postcardsDir = Directory('${collectionFolder.path}/postcards');
    await postcardsDir.create();

    // Create current year directory
    final year = DateTime.now().year;
    final yearDir = Directory('${postcardsDir.path}/$year');
    await yearDir.create();

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityFile = File('${collectionFolder.path}/extra/security.json');
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
      'bannedNpubs': <String>[],
    };
    await securityFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(securityData),
    );

    stderr.writeln('Postcards collection initialized');
    if (currentProfile.npub.isNotEmpty) {
      stderr.writeln('Set ${currentProfile.callsign} (${currentProfile.npub}) as admin');
    }
  }

  /// Initialize contacts collection with directory structure
  Future<void> _initializeContactsCollection(Directory collectionFolder) async {
    // Create contacts directory
    final contactsDir = Directory('${collectionFolder.path}/contacts');
    await contactsDir.create();

    // Create profile-pictures directory
    final profilePicturesDir = Directory('${collectionFolder.path}/contacts/profile-pictures');
    await profilePicturesDir.create();

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityFile = File('${collectionFolder.path}/extra/security.json');
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
      'bannedNpubs': <String>[],
    };
    await securityFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(securityData),
    );

    stderr.writeln('Contacts collection initialized');
    if (currentProfile.npub.isNotEmpty) {
      stderr.writeln('Set ${currentProfile.callsign} (${currentProfile.npub}) as admin');
    }
  }

  /// Initialize places collection with directory structure
  Future<void> _initializePlacesCollection(Directory collectionFolder) async {
    // Create places directory
    final placesDir = Directory('${collectionFolder.path}/places');
    await placesDir.create();

    // Create security.json with current user as admin
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final securityFile = File('${collectionFolder.path}/extra/security.json');
    final securityData = {
      'version': '1.0',
      'adminNpub': currentProfile.npub.isNotEmpty ? currentProfile.npub : null,
      'moderators': <String>[],
      'bannedNpubs': <String>[],
    };
    await securityFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(securityData),
    );

    stderr.writeln('Places collection initialized');
    if (currentProfile.npub.isNotEmpty) {
      stderr.writeln('Set ${currentProfile.callsign} (${currentProfile.npub}) as admin');
    }
  }

  /// Write collection metadata files to disk
  Future<void> _writeCollectionFiles(
    Collection collection,
    Directory folder,
  ) async {
    // Write collection.js
    final collectionJsFile = File('${folder.path}/collection.js');
    await collectionJsFile.writeAsString(collection.generateCollectionJs());

    // Write extra/security.json
    final securityJsonFile = File('${folder.path}/extra/security.json');
    await securityJsonFile.writeAsString(collection.generateSecurityJson());

    // Generate and write tree.json, data.js, and index.html
    // For new collections, generate synchronously so collection is fully ready
    stderr.writeln('Generating tree.json, data.js, and index.html...');
    await _generateAndSaveTreeJson(folder);
    await _generateAndSaveDataJs(folder);
    await _generateAndSaveIndexHtml(folder);
    stderr.writeln('Collection files generated successfully');
  }

  /// Delete a collection
  Future<void> deleteCollection(Collection collection) async {
    if (collection.storagePath == null) {
      throw Exception('Collection has no storage path');
    }

    final folder = Directory(collection.storagePath!);
    if (await folder.exists()) {
      await folder.delete(recursive: true);
    }

    // Remove from favorites if present
    if (collection.isFavorite) {
      await _configService.toggleFavorite(collection.id);
    }
  }

  /// Toggle favorite status of a collection
  Future<void> toggleFavorite(Collection collection) async {
    await _configService.toggleFavorite(collection.id);
    collection.isFavorite = !collection.isFavorite;
  }

  /// Load security settings from security.json
  Future<void> _loadSecuritySettings(Collection collection, Directory folder) async {
    try {
      final securityFile = File('${folder.path}/extra/security.json');
      if (await securityFile.exists()) {
        final content = await securityFile.readAsString();
        final data = json.decode(content) as Map<String, dynamic>;
        collection.visibility = data['visibility'] as String? ?? 'public';
        collection.allowedReaders = (data['allowedReaders'] as List<dynamic>?)?.cast<String>() ?? [];
        collection.encryption = data['encryption'] as String? ?? 'none';
      }
    } catch (e) {
      stderr.writeln('Error loading security settings: $e');
    }
  }

  /// Update collection metadata
  Future<void> updateCollection(Collection collection, {String? oldTitle}) async {
    if (collection.storagePath == null) {
      throw Exception('Collection has no storage path');
    }

    final folder = Directory(collection.storagePath!);
    if (!await folder.exists()) {
      throw Exception('Collection folder does not exist');
    }

    // If title changed, rename the folder
    if (oldTitle != null && oldTitle != collection.title) {
      await _renameCollectionFolder(collection, oldTitle);
    }

    // Update timestamp
    collection.updated = DateTime.now().toIso8601String();

    // Write updated metadata files
    final updatedFolder = Directory(collection.storagePath!);
    await _writeCollectionFiles(collection, updatedFolder);

    stderr.writeln('Updated collection: ${collection.title}');
  }

  /// Rename collection folder based on new title
  Future<void> _renameCollectionFolder(Collection collection, String oldTitle) async {
    final oldFolder = Directory(collection.storagePath!);
    if (!await oldFolder.exists()) {
      throw Exception('Collection folder does not exist');
    }

    // Get parent directory
    final parentPath = oldFolder.parent.path;

    // Sanitize new folder name from title
    String newFolderName = _sanitizeFolderName(collection.title);

    // Find unique folder name if needed
    var newFolder = Directory('$parentPath/$newFolderName');
    int counter = 1;
    while (await newFolder.exists() && newFolder.path != oldFolder.path) {
      newFolder = Directory('$parentPath/${newFolderName}_$counter');
      counter++;
    }

    // Skip if same path (case-insensitive filesystem might cause issues)
    if (newFolder.path == oldFolder.path) {
      stderr.writeln('Folder path unchanged: ${newFolder.path}');
      return;
    }

    stderr.writeln('Renaming folder: ${oldFolder.path} -> ${newFolder.path}');

    // Rename the folder
    try {
      await oldFolder.rename(newFolder.path);
      collection.storagePath = newFolder.path;
      stderr.writeln('Folder renamed successfully');
    } catch (e) {
      stderr.writeln('Error renaming folder: $e');
      throw Exception('Failed to rename collection folder: $e');
    }
  }

  /// Sanitize folder name (remove invalid characters, replace spaces)
  String _sanitizeFolderName(String title) {
    // Replace spaces with underscores
    String folderName = title.replaceAll(' ', '_');

    // Remove/replace invalid characters for Windows and Linux
    // Invalid: \ / : * ? " < > | and control characters
    folderName = folderName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

    // Remove control characters (ASCII 0-31 and 127)
    folderName = folderName.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');

    // Convert to lowercase
    folderName = folderName.toLowerCase();

    // Truncate to 50 characters
    if (folderName.length > 50) {
      folderName = folderName.substring(0, 50);
    }

    // Remove trailing underscores or dots (dots can cause issues on Windows)
    folderName = folderName.replaceAll(RegExp(r'[_.]+$'), '');

    // Ensure folder name is not empty
    if (folderName.isEmpty) {
      folderName = 'collection';
    }

    return folderName;
  }

  /// Add files to a collection (copy operation)
  Future<void> addFiles(Collection collection, List<String> filePaths) async {
    if (collection.storagePath == null) {
      throw Exception('Collection has no storage path');
    }

    final collectionDir = Directory(collection.storagePath!);
    if (!await collectionDir.exists()) {
      throw Exception('Collection folder does not exist');
    }

    for (final filePath in filePaths) {
      final sourceFile = File(filePath);
      if (!await sourceFile.exists()) {
        stderr.writeln('Source file does not exist: $filePath');
        continue;
      }

      final fileName = filePath.split('/').last;
      final destFile = File('${collectionDir.path}/$fileName');

      // Copy file
      await sourceFile.copy(destFile.path);
      stderr.writeln('Copied file: $fileName');
    }

    // Recount files and update metadata
    await _countCollectionFiles(collection, collectionDir);

    // Regenerate tree.json, data.js, and index.html
    await _generateAndSaveTreeJson(collectionDir);
    await _generateAndSaveDataJs(collectionDir);
    await _generateAndSaveIndexHtml(collectionDir);

    await updateCollection(collection);
  }

  /// Create a new empty folder in the collection
  Future<void> createFolder(Collection collection, String folderName) async {
    if (collection.storagePath == null) {
      throw Exception('Collection has no storage path');
    }

    final collectionDir = Directory(collection.storagePath!);
    if (!await collectionDir.exists()) {
      throw Exception('Collection folder does not exist');
    }

    // Sanitize folder name
    final sanitized = folderName
        .trim()
        .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');

    if (sanitized.isEmpty) {
      throw Exception('Invalid folder name');
    }

    final newFolder = Directory('${collectionDir.path}/$sanitized');

    if (await newFolder.exists()) {
      throw Exception('Folder already exists');
    }

    await newFolder.create(recursive: false);
    stderr.writeln('Created folder: $sanitized');

    // Regenerate tree.json, data.js, and index.html
    await _generateAndSaveTreeJson(collectionDir);
    await _generateAndSaveDataJs(collectionDir);
    await _generateAndSaveIndexHtml(collectionDir);

    // Update metadata
    await updateCollection(collection);
  }

  /// Add a folder to a collection (recursive copy)
  Future<void> addFolder(Collection collection, String folderPath) async {
    if (collection.storagePath == null) {
      throw Exception('Collection has no storage path');
    }

    final collectionDir = Directory(collection.storagePath!);
    if (!await collectionDir.exists()) {
      throw Exception('Collection folder does not exist');
    }

    final sourceDir = Directory(folderPath);
    if (!await sourceDir.exists()) {
      throw Exception('Source folder does not exist: $folderPath');
    }

    final folderName = folderPath.split('/').last;
    final destDir = Directory('${collectionDir.path}/$folderName');

    // Copy folder recursively
    await _copyDirectory(sourceDir, destDir);
    stderr.writeln('Copied folder: $folderName');

    // Recount files and update metadata
    await _countCollectionFiles(collection, collectionDir);

    // Regenerate tree.json, data.js, and index.html
    await _generateAndSaveTreeJson(collectionDir);
    await _generateAndSaveDataJs(collectionDir);
    await _generateAndSaveIndexHtml(collectionDir);

    await updateCollection(collection);
  }

  /// Recursively copy a directory
  Future<void> _copyDirectory(Directory source, Directory dest) async {
    if (!await dest.exists()) {
      await dest.create(recursive: true);
    }

    final entities = await source.list(recursive: false).toList();
    for (final entity in entities) {
      if (entity is File) {
        final newPath = '${dest.path}/${entity.path.split('/').last}';
        await entity.copy(newPath);
      } else if (entity is Directory) {
        final dirName = entity.path.split('/').last;
        final newDir = Directory('${dest.path}/$dirName');
        await _copyDirectory(entity, newDir);
      }
    }
  }

  /// Build file tree from collection directory
  Future<List<FileNode>> _buildFileTree(Directory collectionDir) async {
    final fileNodes = <FileNode>[];

    try {
      final entities = await collectionDir.list(recursive: false).toList();
      for (final entity in entities) {
        final name = entity.path.split('/').last;

        // Skip metadata folders and files
        if (name == 'extra' || name == 'collection.js') {
          continue;
        }

        if (entity is File) {
          final stat = await entity.stat();
          fileNodes.add(FileNode(
            path: name,
            name: name,
            size: stat.size,
            isDirectory: false,
          ));
        } else if (entity is Directory) {
          final children = await _buildFileTreeRecursive(entity, name);
          int totalSize = 0;
          int fileCount = 0;
          for (var child in children) {
            totalSize += child.size;
            if (child.isDirectory) {
              fileCount += child.fileCount;
            } else {
              fileCount += 1;
            }
          }
          fileNodes.add(FileNode(
            path: name,
            name: name,
            size: totalSize,
            isDirectory: true,
            children: children,
            fileCount: fileCount,
          ));
        }
      }
    } catch (e) {
      stderr.writeln('Error building file tree: $e');
    }

    // Sort: directories first, then files, both alphabetically
    fileNodes.sort((a, b) {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return fileNodes;
  }

  /// Build file tree recursively
  Future<List<FileNode>> _buildFileTreeRecursive(Directory dir, String basePath) async {
    final fileNodes = <FileNode>[];

    try {
      final entities = await dir.list(recursive: false).toList();
      for (final entity in entities) {
        final name = entity.path.split('/').last;
        final relativePath = '$basePath/$name';

        if (entity is File) {
          final stat = await entity.stat();
          fileNodes.add(FileNode(
            path: relativePath,
            name: name,
            size: stat.size,
            isDirectory: false,
          ));
        } else if (entity is Directory) {
          final children = await _buildFileTreeRecursive(entity, relativePath);
          int totalSize = 0;
          int fileCount = 0;
          for (var child in children) {
            totalSize += child.size;
            if (child.isDirectory) {
              fileCount += child.fileCount;
            } else {
              fileCount += 1;
            }
          }
          fileNodes.add(FileNode(
            path: relativePath,
            name: name,
            size: totalSize,
            isDirectory: true,
            children: children,
            fileCount: fileCount,
          ));
        }
      }
    } catch (e) {
      stderr.writeln('Error building file tree recursively: $e');
    }

    // Sort: directories first, then files, both alphabetically
    fileNodes.sort((a, b) {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return fileNodes;
  }

  /// Load file tree from collection
  Future<List<FileNode>> loadFileTree(Collection collection) async {
    if (collection.storagePath == null) {
      throw Exception('Collection has no storage path');
    }

    final collectionDir = Directory(collection.storagePath!);
    return await _buildFileTree(collectionDir);
  }

  /// Scan directory non-recursively to avoid "too many open files"
  /// This processes directories one level at a time with proper cleanup
  Future<List<FileSystemEntity>> _scanDirectoryNonRecursive(Directory root) async {
    final allEntities = <FileSystemEntity>[];
    final dirsToProcess = <Directory>[root];

    while (dirsToProcess.isNotEmpty) {
      final currentDir = dirsToProcess.removeAt(0);

      try {
        // Process one directory at a time, immediately converting to list to close stream
        final entities = await currentDir.list(recursive: false, followLinks: false).toList();

        for (var entity in entities) {
          // Skip if it's the root directory itself
          if (entity.path == root.path) continue;

          allEntities.add(entity);

          // If it's a directory, add to queue for processing
          if (entity is Directory) {
            dirsToProcess.add(entity);
          }
        }
      } catch (e) {
        stderr.writeln('Error scanning directory ${currentDir.path}: $e');
      }
    }

    return allEntities;
  }

  /// Generate and save tree.json
  Future<void> _generateAndSaveTreeJson(Directory folder) async {
    try {
      final entries = <Map<String, dynamic>>[];

      // Check if this is a www type collection to determine if index.html should be included
      bool isWwwType = false;
      final collectionJsFile = File('${folder.path}/collection.js');
      if (await collectionJsFile.exists()) {
        final content = await collectionJsFile.readAsString();
        isWwwType = content.contains('"type": "www"');
      }

      // Use non-recursive scan to avoid "too many open files" error
      // Build tree manually by processing one level at a time
      final entities = await _scanDirectoryNonRecursive(folder);

      for (var entity in entities) {
        final relativePath = entity.path.substring(folder.path.length + 1);

        // Skip hidden files, metadata files, and the extra directory
        // For www type collections, include index.html as it's content, not metadata
        if (relativePath.startsWith('.') ||
            relativePath == 'collection.js' ||
            (!isWwwType && relativePath == 'index.html') ||
            relativePath == 'extra' ||
            relativePath.startsWith('extra/')) {
          continue;
        }

        if (entity is Directory) {
          entries.add({
            'path': relativePath,
            'name': entity.path.split('/').last,
            'type': 'directory',
          });
        } else if (entity is File) {
          final stat = await entity.stat();
          entries.add({
            'path': relativePath,
            'name': entity.path.split('/').last,
            'type': 'file',
            'size': stat.size,
          });
        }
      }

      // Sort entries
      entries.sort((a, b) {
        if (a['type'] == 'directory' && b['type'] != 'directory') return -1;
        if (a['type'] != 'directory' && b['type'] == 'directory') return 1;
        return (a['path'] as String).compareTo(b['path'] as String);
      });

      // Write to tree.json
      final treeJsonFile = File('${folder.path}/extra/tree.json');
      final jsonContent = JsonEncoder.withIndent('  ').convert(entries);
      await treeJsonFile.writeAsString(jsonContent);

      stderr.writeln('Generated tree.json with ${entries.length} entries');
    } catch (e) {
      stderr.writeln('Error generating tree.json: $e');
      rethrow;
    }
  }

  /// Generate and save data.js with full metadata
  Future<void> _generateAndSaveDataJs(Directory folder) async {
    try {
      final entries = <Map<String, dynamic>>[];
      final filesToProcess = <File>[];
      final directoriesToAdd = <Map<String, dynamic>>[];

      // Check if this is a www type collection to determine if index.html should be included
      bool isWwwType = false;
      final collectionJsFile = File('${folder.path}/collection.js');
      if (await collectionJsFile.exists()) {
        final content = await collectionJsFile.readAsString();
        isWwwType = content.contains('"type": "www"');
      }

      // First pass: collect all entities without reading files
      // Use non-recursive scan to avoid "too many open files" error
      final entities = await _scanDirectoryNonRecursive(folder);

      for (var entity in entities) {
        final relativePath = entity.path.substring(folder.path.length + 1);

        // Skip hidden files, metadata files, and the extra directory
        // For www type collections, include index.html as it's content, not metadata
        if (relativePath.startsWith('.') ||
            relativePath == 'collection.js' ||
            (!isWwwType && relativePath == 'index.html') ||
            relativePath == 'extra' ||
            relativePath.startsWith('extra/')) {
          continue;
        }

        if (entity is Directory) {
          directoriesToAdd.add({
            'path': relativePath,
            'name': entity.path.split('/').last,
            'type': 'directory',
          });
        } else if (entity is File) {
          filesToProcess.add(entity);
        }
      }

      // Add directories first
      entries.addAll(directoriesToAdd);

      // Process files in batches to avoid too many open file handles
      const batchSize = 20;
      for (var i = 0; i < filesToProcess.length; i += batchSize) {
        final end = (i + batchSize < filesToProcess.length) ? i + batchSize : filesToProcess.length;
        final batch = filesToProcess.sublist(i, end);

        for (var file in batch) {
          try {
            final relativePath = file.path.substring(folder.path.length + 1);
            final stat = await file.stat();

            // Read file with explicit error handling
            late List<int> bytes;
            try {
              bytes = await file.readAsBytes();
            } catch (e) {
              stderr.writeln('Warning: Could not read file $relativePath: $e');
              // Add entry without hashes if file can't be read
              entries.add({
                'path': relativePath,
                'name': file.path.split('/').last,
                'type': 'file',
                'size': stat.size,
                'mimeType': 'application/octet-stream',
                'hashes': {},
                'metadata': {
                  'mime_type': 'application/octet-stream',
                },
              });
              continue;
            }

            // Compute hashes
            final sha1Hash = sha1.convert(bytes).toString();
            final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
            final tlshHash = TLSH.hash(Uint8List.fromList(bytes));

            final hashes = <String, dynamic>{
              'sha1': sha1Hash,
            };
            if (tlshHash != null) {
              hashes['tlsh'] = tlshHash;
            }

            entries.add({
              'path': relativePath,
              'name': file.path.split('/').last,
              'type': 'file',
              'size': stat.size,
              'mimeType': mimeType,
              'hashes': hashes,
              'metadata': {
                'mime_type': mimeType,
              },
            });

            // Clear bytes from memory
            bytes = [];
          } catch (e) {
            stderr.writeln('Warning: Error processing file ${file.path}: $e');
          }
        }

        // Small delay between batches to allow OS to close file handles
        if (i + batchSize < filesToProcess.length) {
          await Future.delayed(Duration(milliseconds: 10));
        }
      }

      // Sort entries
      entries.sort((a, b) {
        if (a['type'] == 'directory' && b['type'] != 'directory') return -1;
        if (a['type'] != 'directory' && b['type'] == 'directory') return 1;
        return (a['path'] as String).compareTo(b['path'] as String);
      });

      // Write to data.js
      final dataJsFile = File('${folder.path}/extra/data.js');
      final now = DateTime.now().toIso8601String();
      final jsonData = JsonEncoder.withIndent('  ').convert(entries);
      final jsContent = '''// Geogram Collection Data with Metadata
// Generated: $now
window.COLLECTION_DATA_FULL = $jsonData;
''';
      await dataJsFile.writeAsString(jsContent);

      stderr.writeln('Generated data.js with ${entries.length} entries (${filesToProcess.length} files processed)');
    } catch (e) {
      stderr.writeln('Error generating data.js: $e');
      rethrow;
    }
  }

  /// Generate and save index.html for collection browsing
  Future<void> _generateAndSaveIndexHtml(Directory folder) async {
    try {
      // Check if this is a www type collection - if so, skip generating browser index.html
      final collectionJsFile = File('${folder.path}/collection.js');
      if (await collectionJsFile.exists()) {
        final content = await collectionJsFile.readAsString();
        // Check if this is a www type collection
        if (content.contains('"type": "www"')) {
          stderr.writeln('Skipping index.html generation for www type collection');
          return; // Don't overwrite www type's custom index.html
        }
      }

      // Continue with normal index.html generation for other types
      final indexHtmlFile = File('${folder.path}/index.html');
      final htmlContent = _generateIndexHtmlContent();
      await indexHtmlFile.writeAsString(htmlContent);
      stderr.writeln('Generated index.html');
    } catch (e) {
      stderr.writeln('Error generating index.html: $e');
      rethrow;
    }
  }

  /// Generate HTML content for collection browser
  String _generateIndexHtmlContent() {
    return '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Collection Browser</title>
    <style>
        @font-face {
            font-family: 'VT323';
            font-style: normal;
            font-weight: 400;
            src: url(data:font/woff2;base64,d09GMgABAAAAABsMAA4AAAAAMkQAABqxAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGhYbIByCWgZgAIE8EQgKgbgkg5JXC4N0AAE2AiQDhwQGBQcgB4MbWCkjEZUcBWRfE+KW7Qwkg1bBVqxm/P/fxjZv3s/MJiGJZZVIopG0k0j1TNIgRBKhkUgiGglRySSRaFr/+b3u95zz3O85537P/c//P+f/nP/9z/mf/zv/+9//ufe///l3vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu/7vu8=) format('woff2');
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }


        @keyframes scanline {
            0% { transform: translateY(-100%); }
            100% { transform: translateY(100%); }
        }

        @keyframes flicker {
            0% { opacity: 0.97; }
            50% { opacity: 1; }
            100% { opacity: 0.97; }
        }

        @keyframes textGlow {
            0%, 100% { text-shadow: 0 0 10px #0f0, 0 0 20px #0f0, 0 0 30px #0f0; }
            50% { text-shadow: 0 0 15px #0f0, 0 0 25px #0f0, 0 0 35px #0f0; }
        }

        body {
            font-family: 'Courier New', 'VT323', monospace;
            background: #000;
            color: #0f0;
            line-height: 1.4;
            overflow-x: hidden;
            position: relative;
        }

        body::before {
            content: '';
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: repeating-linear-gradient(
                0deg,
                rgba(0, 0, 0, 0.15),
                rgba(0, 0, 0, 0.15) 1px,
                transparent 1px,
                transparent 2px
            );
            pointer-events: none;
            z-index: 1000;
            animation: flicker 0.15s infinite;
        }

        body::after {
            content: '';
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 3px;
            background: rgba(0, 255, 0, 0.1);
            animation: scanline 8s linear infinite;
            pointer-events: none;
            z-index: 999;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            position: relative;
            z-index: 1;
        }


        .header {
            border: 2px solid #0f0;
            padding: 15px;
            margin-bottom: 20px;
            box-shadow: 0 0 20px rgba(0, 255, 0, 0.3);
        }

        .header h1 {
            color: #0f0;
            font-size: 32px;
            margin-bottom: 10px;
            text-transform: uppercase;
            letter-spacing: 2px;
            font-weight: bold;
        }

        .header .subtitle {
            color: #0f0;
            font-size: 14px;
            margin-bottom: 5px;
        }

        .header .meta {
            color: #ff0;
            font-size: 12px;
        }

        .stats-box {
            border: 1px solid #0f0;
            padding: 10px;
            margin-bottom: 15px;
            background: rgba(0, 255, 0, 0.03);
        }

        .stats {
            display: flex;
            justify-content: space-between;
            flex-wrap: wrap;
            gap: 15px;
        }

        .stat {
            flex: 1;
            min-width: 200px;
            border: 1px dashed #0f0;
            padding: 10px;
            text-align: center;
        }

        .stat-label {
            color: #f0f;
            font-size: 11px;
            text-transform: uppercase;
            margin-bottom: 5px;
        }

        .stat-value {
            color: #0ff;
            font-size: 20px;
            text-shadow: 0 0 10px #0ff;
            font-weight: bold;
        }

        .search-box {
            border: 1px solid #0f0;
            padding: 10px;
            margin-bottom: 15px;
            background: rgba(0, 255, 0, 0.03);
        }

        .search-prompt {
            color: #ff0;
            margin-bottom: 5px;
        }

        .search-input {
            width: 100%;
            background: #000;
            border: 1px solid #0f0;
            color: #0f0;
            padding: 8px;
            font-family: 'Courier New', monospace;
            font-size: 14px;
            outline: none;
        }

        .search-input:focus {
            box-shadow: 0 0 10px rgba(0, 255, 0, 0.5);
        }


        .content {
            border: 2px solid #0f0;
            padding: 15px;
            min-height: 400px;
            background: rgba(0, 0, 0, 0.8);
            box-shadow: inset 0 0 20px rgba(0, 255, 0, 0.1);
        }

        .file-tree {
            list-style: none;
        }

        .file-tree ul {
            list-style: none;
        }

        .file-tree li {
            list-style: none;
        }

        .file-item {
            padding: 5px 0;
            cursor: pointer;
            transition: all 0.2s;
            position: relative;
            padding-left: 5px;
        }

        .file-item:hover {
            background: rgba(0, 255, 0, 0.1);
            padding-left: 10px;
        }

        .file-item:hover::before {
            content: '>';
            position: absolute;
            left: 0;
            color: #ff0;
        }

        .file-item.selected {
            background: rgba(255, 255, 0, 0.2);
            padding-left: 10px;
        }

        .file-item.selected::before {
            content: '►';
            position: absolute;
            left: 0;
            color: #ff0;
            font-weight: bold;
        }

        .file-item.directory {
            color: #0ff;
        }

        .result-item.selected {
            background: rgba(255, 255, 0, 0.2);
            padding-left: 15px;
        }

        .file-name {
            display: inline-block;
        }

        .file-size {
            color: #f0f;
            float: right;
            font-size: 12px;
        }

        .nested {
            padding-left: 20px;
            display: none;
        }

        .nested.open {
            display: block;
        }

        .expand-icon {
            display: inline-block;
            width: 15px;
            color: #ff0;
        }

        .result-item {
            padding: 10px;
            border-bottom: 1px dotted #0f0;
            cursor: pointer;
            transition: all 0.2s;
        }

        .result-item:hover {
            background: rgba(0, 255, 0, 0.1);
            padding-left: 15px;
        }

        .result-name {
            color: #0ff;
            margin-bottom: 5px;
            font-size: 14px;
        }

        .result-path {
            color: #ff0;
            font-size: 12px;
            margin-bottom: 3px;
        }

        .result-meta {
            color: #f0f;
            font-size: 11px;
        }

        .no-results {
            text-align: center;
            padding: 40px;
            color: #f00;
            border: 1px dashed #f00;
        }


        .footer {
            margin-top: 20px;
            border-top: 1px solid #0f0;
            padding-top: 10px;
            text-align: center;
            color: #0f0;
            font-size: 11px;
        }

        .footer a {
            color: #0ff;
            text-decoration: none;
        }

        .footer a:hover {
            text-decoration: underline;
            text-shadow: 0 0 10px #0ff;
        }

        @media (max-width: 768px) {
            .stat {
                min-width: 100%;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1><span id="collection-title">LOADING SYSTEM...</span></h1>
            <div class="subtitle" id="collection-description"></div>
            <div class="meta">LATEST UPDATE: <span id="collection-meta"></span></div>
        </div>

        <div class="stats-box">
            <div class="stats">
                <div class="stat">
                    <div class="stat-label">▒ TOTAL FILES ▒</div>
                    <div class="stat-value" id="total-files">0</div>
                </div>
                <div class="stat">
                    <div class="stat-label">▒ DIRECTORIES ▒</div>
                    <div class="stat-value" id="total-folders">0</div>
                </div>
                <div class="stat">
                    <div class="stat-label">▒ TOTAL BYTES ▒</div>
                    <div class="stat-value" id="total-size">0 B</div>
                </div>
            </div>
        </div>

        <div class="search-box">
            <div class="search-prompt">SEARCH [?]:</div>
            <input type="text" class="search-input" id="search-input" placeholder="Type to search files...">
        </div>

        <div class="content">
            <div id="file-list"></div>
        </div>

        <div class="footer">
            ┌────────────────────────────────────────────────────────────────┐<br>
            │ GEOGRAM COLLECTION BROWSER v1.0 - OFFLINE-FIRST COMMUNICATION │<br>
            └────────────────────────────────────────────────────────────────┘
        </div>
    </div>

    <script src="collection.js"></script>
    <script src="extra/data.js"></script>
    <script>
        const collectionData = window.COLLECTION_DATA?.collection || {};
        const fileData = window.COLLECTION_DATA_FULL || [];
        let searchTimeout = null;
        let currentSearchQuery = '';
        let selectedIndex = 0;
        let navigableItems = [];
        let currentPath = [];

        // Initialize
        document.addEventListener('DOMContentLoaded', () => {
            loadCollectionInfo();
            setupSearch();
            setupKeyboardShortcuts();
            calculateStats();
            renderFileList();
            restoreState();
        });

        // Handle browser back/forward navigation
        window.addEventListener('popstate', (e) => {
            if (e.state && e.state.expandedPaths) {
                restoreStateFromData(e.state);
            }
        });

        function loadCollectionInfo() {
            const title = collectionData.title || 'Collection';
            document.getElementById('collection-title').textContent = title;
            document.getElementById('collection-description').textContent = collectionData.description || '';

            // Format date as YYYY-MM-DD HH:MM:SS
            const date = new Date(collectionData.updated);
            const year = date.getFullYear();
            const month = String(date.getMonth() + 1).padStart(2, '0');
            const day = String(date.getDate()).padStart(2, '0');
            const hours = String(date.getHours()).padStart(2, '0');
            const minutes = String(date.getMinutes()).padStart(2, '0');
            const seconds = String(date.getSeconds()).padStart(2, '0');
            const isoDateTime = \`\${year}-\${month}-\${day} \${hours}:\${minutes}:\${seconds}\`;

            document.getElementById('collection-meta').textContent = isoDateTime;
            // Update browser tab title
            document.title = title;
        }

        function setupKeyboardShortcuts() {
            document.addEventListener('keydown', (e) => {
                const searchInput = document.getElementById('search-input');

                // If typing in search, don't handle navigation keys
                if (document.activeElement === searchInput && !['Escape', 'ArrowUp', 'ArrowDown', 'Enter'].includes(e.key)) {
                    return;
                }

                // ? - Focus search
                if (e.key === '?' && document.activeElement !== searchInput) {
                    e.preventDefault();
                    searchInput.focus();
                    searchInput.select();
                    return;
                }

                // ESC - Clear search and keep focus
                if (e.key === 'Escape' && document.activeElement === searchInput) {
                    e.preventDefault();
                    searchInput.value = '';
                    currentSearchQuery = '';
                    renderFileList();
                    return;
                }

                // Arrow Down - Move selection down
                if (e.key === 'ArrowDown') {
                    e.preventDefault();
                    if (navigableItems.length > 0) {
                        selectedIndex = (selectedIndex + 1) % navigableItems.length;
                        updateSelection();
                    }
                    return;
                }

                // Arrow Up - Move selection up
                if (e.key === 'ArrowUp') {
                    e.preventDefault();
                    if (navigableItems.length > 0) {
                        selectedIndex = (selectedIndex - 1 + navigableItems.length) % navigableItems.length;
                        updateSelection();
                    }
                    return;
                }

                // Enter - Open/expand selected item
                if (e.key === 'Enter') {
                    e.preventDefault();
                    if (navigableItems.length > 0 && navigableItems[selectedIndex]) {
                        navigableItems[selectedIndex].click();
                    }
                    return;
                }

                // Backspace - Go back one folder
                if (e.key === 'Backspace' && document.activeElement !== searchInput) {
                    e.preventDefault();
                    if (currentPath.length > 0) {
                        goBackOneFolder();
                    }
                    return;
                }

                // Arrow Left - Collapse selected folder or parent folder if on a file
                if (e.key === 'ArrowLeft' && document.activeElement !== searchInput) {
                    e.preventDefault();
                    if (navigableItems.length > 0 && navigableItems[selectedIndex]) {
                        const item = navigableItems[selectedIndex];
                        if (item.classList.contains('directory')) {
                            // If on a folder, collapse it if it's open
                            const li = item.parentElement;
                            const nested = li?.querySelector('.nested');
                            if (nested && nested.classList.contains('open')) {
                                const expandIcon = item.querySelector('.expand-icon');
                                nested.classList.remove('open');
                                if (expandIcon) expandIcon.textContent = '+';
                                refreshNavigableItems();
                                saveState();
                            }
                        } else {
                            // If on a file, collapse its parent folder
                            const li = item.parentElement;
                            const parentUl = li?.parentElement;
                            if (parentUl && parentUl.classList.contains('nested') && parentUl.classList.contains('open')) {
                                parentUl.classList.remove('open');
                                const parentDiv = parentUl.previousElementSibling;
                                if (parentDiv) {
                                    const expandIcon = parentDiv.querySelector('.expand-icon');
                                    if (expandIcon) expandIcon.textContent = '+';
                                }
                                refreshNavigableItems();
                                saveState();
                            }
                        }
                    }
                    return;
                }

                // Arrow Right - Expand selected folder
                if (e.key === 'ArrowRight' && document.activeElement !== searchInput) {
                    e.preventDefault();
                    if (navigableItems.length > 0 && navigableItems[selectedIndex]) {
                        const item = navigableItems[selectedIndex];
                        if (item.classList.contains('directory')) {
                            const li = item.parentElement;
                            const nested = li?.querySelector('.nested');
                            if (nested && !nested.classList.contains('open')) {
                                const expandIcon = item.querySelector('.expand-icon');
                                nested.classList.add('open');
                                if (expandIcon) expandIcon.textContent = '-';
                                // Track path
                                const nameSpan = item.querySelector('.file-name');
                                if (nameSpan) {
                                    currentPath.push(nameSpan.textContent);
                                }
                                refreshNavigableItems();
                                saveState();
                            }
                        }
                    }
                    return;
                }
            });
        }

        function updateSelection() {
            // Remove previous selection
            navigableItems.forEach(item => item.classList.remove('selected'));

            // Add selection to current item
            if (navigableItems[selectedIndex]) {
                navigableItems[selectedIndex].classList.add('selected');
                // Scroll into view
                navigableItems[selectedIndex].scrollIntoView({ block: 'nearest', behavior: 'smooth' });
            }
        }

        function goBackOneFolder() {
            if (currentPath.length === 0) return;

            // Remove last folder from path
            currentPath.pop();

            // Find all expanded folders and close the deepest one
            const allExpanded = document.querySelectorAll('.nested.open');
            if (allExpanded.length > 0) {
                const deepest = allExpanded[allExpanded.length - 1];
                deepest.classList.remove('open');
                const parentDiv = deepest.previousElementSibling;
                if (parentDiv) {
                    const expandIcon = parentDiv.querySelector('.expand-icon');
                    if (expandIcon) {
                        expandIcon.textContent = '+';
                    }
                }
            }

            // Refresh navigable items
            refreshNavigableItems();

            // Save state after going back
            saveState();
        }

        function getFileIcon(item) {
            if (item.type === 'directory') return '[DIR]';

            const ext = item.name.split('.').pop().toLowerCase();
            const mimeType = item.mimeType || '';

            // Executables and binaries
            if (['exe', 'com', 'bat', 'sh'].includes(ext)) return '[EXE]';

            // Archives
            if (['zip', 'tar', 'gz', 'rar', '7z', 'arc', 'lzh'].includes(ext)) return '[ARC]';

            // Images
            if (mimeType.startsWith('image/') || ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'pcx'].includes(ext)) {
                return '[IMG]';
            }

            // Documents
            if (['txt', 'doc', 'pdf', 'nfo'].includes(ext)) return '[DOC]';

            // Code/Text
            if (['c', 'cpp', 'h', 'js', 'py', 'asm', 'bas'].includes(ext)) return '[SRC]';

            // Data
            if (['dat', 'db', 'cfg', 'ini', 'json'].includes(ext)) return '[DAT]';

            // Default
            return '[FILE]';
        }

        function calculateStats() {
            let totalFiles = 0;
            let totalFolders = 0;
            let totalSize = 0;

            fileData.forEach(item => {
                if (item.type === 'directory') {
                    totalFolders++;
                } else {
                    totalFiles++;
                    totalSize += item.size || 0;
                }
            });

            document.getElementById('total-files').textContent = totalFiles;
            document.getElementById('total-folders').textContent = totalFolders;
            document.getElementById('total-size').textContent = formatSize(totalSize);
        }

        function formatSize(bytes) {
            if (bytes < 1024) return bytes + ' B';
            if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
            if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
            return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
        }

        function refreshNavigableItems() {
            // Get all file-item and result-item elements
            const allItems = Array.from(document.querySelectorAll('.file-item, .result-item'));

            // Filter to only include visible items (not inside collapsed folders)
            navigableItems = allItems.filter(item => {
                let element = item;
                while (element && element !== document.body) {
                    if (element.classList && element.classList.contains('nested') && !element.classList.contains('open')) {
                        return false; // Item is inside a collapsed folder
                    }
                    element = element.parentElement;
                }
                return true; // Item is visible
            });

            selectedIndex = Math.min(selectedIndex, Math.max(0, navigableItems.length - 1));
            updateSelection();
        }

        function renderFileList() {
            const container = document.getElementById('file-list');
            const query = currentSearchQuery.toLowerCase();

            // If searching, show filtered results
            if (query) {
                const results = fileData.filter(item => {
                    const nameMatch = item.name.toLowerCase().includes(query);
                    const pathMatch = item.path.toLowerCase().includes(query);
                    const mimeMatch = item.mimeType && item.mimeType.toLowerCase().includes(query);
                    return nameMatch || pathMatch || mimeMatch;
                });

                if (results.length === 0) {
                    container.innerHTML = \`
                        <div class="no-results">
                            *** SEARCH FAILED ***<br><br>
                            NO MATCHES FOUND FOR: "\${currentSearchQuery}"<br><br>
                            PRESS [ESC] TO CLEAR SEARCH
                        </div>
                    \`;
                    navigableItems = [];
                    return;
                }

                container.innerHTML = '';
                results.forEach(item => {
                    const div = document.createElement('div');
                    div.className = 'result-item';

                    const sizeStr = item.type !== 'directory' ? formatSize(item.size) : '<DIR>';
                    const mimeStr = item.mimeType ? \` TYPE: \${item.mimeType}\` : '';

                    div.innerHTML = \`
                        <div class="result-name">\${getFileIcon(item)} \${item.name}</div>
                        <div class="result-path">PATH: \${item.path}</div>
                        <div class="result-meta">SIZE: \${sizeStr}\${mimeStr}</div>
                    \`;

                    div.addEventListener('click', () => {
                        if (item.type !== 'directory') {
                            openFile(item.path, false);
                        }
                    });

                    // Right-click to open in new tab
                    if (item.type !== 'directory') {
                        div.addEventListener('contextmenu', (e) => {
                            e.preventDefault();
                            openFile(item.path, true);
                        });
                    }

                    container.appendChild(div);
                });

                refreshNavigableItems();
                return;
            }

            // Otherwise show file tree
            const tree = {};
            fileData.forEach(item => {
                const parts = item.path.split('/');
                let current = tree;

                parts.forEach((part, index) => {
                    if (!current[part]) {
                        current[part] = {
                            name: part,
                            type: index === parts.length - 1 ? item.type : 'directory',
                            size: index === parts.length - 1 ? item.size : 0,
                            path: item.path,
                            mimeType: item.mimeType,
                            children: {}
                        };
                    }
                    current = current[part].children;
                });
            });

            container.innerHTML = '';
            const ul = document.createElement('ul');
            ul.className = 'file-tree';
            renderTreeNode(tree, ul);
            container.appendChild(ul);

            refreshNavigableItems();
        }

        function renderTreeNode(node, container) {
            const entries = Object.values(node).sort((a, b) => {
                // Folders first, then alphabetically
                if (a.type === 'directory' && b.type !== 'directory') return -1;
                if (a.type !== 'directory' && b.type === 'directory') return 1;
                return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
            });

            entries.forEach(item => {
                const li = document.createElement('li');
                const div = document.createElement('div');
                div.className = \`file-item \${item.type}\`;

                const expandIcon = document.createElement('span');
                expandIcon.className = 'expand-icon';
                if (item.type === 'directory') {
                    expandIcon.textContent = '+';
                } else {
                    expandIcon.textContent = ' ';
                }
                div.appendChild(expandIcon);

                const icon = document.createElement('span');
                icon.textContent = getFileIcon(item) + ' ';
                div.appendChild(icon);

                const name = document.createElement('span');
                name.className = 'file-name';
                name.textContent = item.name;
                div.appendChild(name);

                if (item.type !== 'directory') {
                    const size = document.createElement('span');
                    size.className = 'file-size';
                    size.textContent = formatSize(item.size);
                    div.appendChild(size);
                } else {
                    const size = document.createElement('span');
                    size.className = 'file-size';
                    size.textContent = '<DIR>';
                    div.appendChild(size);
                }

                div.addEventListener('click', (e) => {
                    e.stopPropagation();
                    if (item.type === 'directory') {
                        const nested = li.querySelector('.nested');
                        const expandIcon = div.querySelector('.expand-icon');
                        if (nested) {
                            const isOpen = nested.classList.toggle('open');
                            expandIcon.textContent = isOpen ? '-' : '+';

                            // Update current path
                            if (isOpen) {
                                currentPath.push(item.name);
                            } else {
                                const index = currentPath.indexOf(item.name);
                                if (index > -1) {
                                    currentPath.splice(index, 1);
                                }
                            }

                            // Refresh navigable items after expanding/collapsing
                            refreshNavigableItems();

                            // Save state after folder change
                            saveState();
                        }
                    } else {
                        openFile(item.path, false);
                    }
                });

                // Right-click to open in new tab
                if (item.type !== 'directory') {
                    div.addEventListener('contextmenu', (e) => {
                        e.preventDefault();
                        openFile(item.path, true);
                    });
                }

                li.appendChild(div);

                if (item.type === 'directory' && Object.keys(item.children).length > 0) {
                    const nested = document.createElement('ul');
                    nested.className = 'nested';  // Collapsed by default
                    renderTreeNode(item.children, nested);
                    li.appendChild(nested);
                }

                container.appendChild(li);
            });
        }

        function setupSearch() {
            const searchInput = document.getElementById('search-input');
            searchInput.addEventListener('input', (e) => {
                clearTimeout(searchTimeout);
                searchTimeout = setTimeout(() => {
                    currentSearchQuery = e.target.value.trim();
                    renderFileList();
                }, 300);
            });
        }

        function openFile(path, newTab = false) {
            if (newTab) {
                window.open(path, '_blank');
            } else {
                // Save current state before navigating
                saveState();
                window.location.href = path;
            }
        }

        // Save current browser state
        function saveState() {
            const expandedPaths = [];
            document.querySelectorAll('.nested.open').forEach(nested => {
                const parentDiv = nested.previousElementSibling;
                if (parentDiv) {
                    const nameSpan = parentDiv.querySelector('.file-name');
                    if (nameSpan) {
                        expandedPaths.push(nameSpan.textContent);
                    }
                }
            });

            const state = {
                expandedPaths: expandedPaths,
                selectedIndex: selectedIndex,
                searchQuery: currentSearchQuery
            };

            // Push state to history
            history.replaceState(state, '', window.location.href);
        }

        // Restore state from URL hash or history
        function restoreState() {
            const state = history.state;
            if (state && state.expandedPaths) {
                restoreStateFromData(state);
            }
        }

        // Restore state from data object
        function restoreStateFromData(state) {
            if (!state) return;

            // Restore search query
            if (state.searchQuery) {
                const searchInput = document.getElementById('search-input');
                searchInput.value = state.searchQuery;
                currentSearchQuery = state.searchQuery;
            }

            // Wait for file list to render
            setTimeout(() => {
                // Restore expanded folders
                if (state.expandedPaths && state.expandedPaths.length > 0) {
                    state.expandedPaths.forEach(folderName => {
                        const allDivs = document.querySelectorAll('.file-item.directory');
                        allDivs.forEach(div => {
                            const nameSpan = div.querySelector('.file-name');
                            if (nameSpan && nameSpan.textContent === folderName) {
                                const li = div.parentElement;
                                const nested = li?.querySelector('.nested');
                                if (nested && !nested.classList.contains('open')) {
                                    const expandIcon = div.querySelector('.expand-icon');
                                    nested.classList.add('open');
                                    if (expandIcon) expandIcon.textContent = '-';
                                }
                            }
                        });
                    });

                    // Refresh navigable items and restore selection
                    refreshNavigableItems();

                    if (state.selectedIndex !== undefined && state.selectedIndex < navigableItems.length) {
                        selectedIndex = state.selectedIndex;
                        updateSelection();
                    }
                }
            }, 50);
        }
    </script>
</body>
</html>
''';
  }

  /// Validate that tree.json matches actual directory contents
  Future<bool> _validateTreeJson(Directory folder) async {
    try {
      final treeJsonFile = File('${folder.path}/extra/tree.json');
      if (!await treeJsonFile.exists()) {
        stderr.writeln('tree.json does not exist, needs regeneration');
        return false;
      }

      // Check if tree.json was modified recently (within last hour)
      // If so, assume it's valid to avoid expensive directory scanning
      final stat = await treeJsonFile.stat();
      final now = DateTime.now();
      final age = now.difference(stat.modified);

      if (age.inMinutes < 60) {
        // File is recent, assume valid
        return true;
      }

      // For older files, just check if file exists without full validation
      // Full validation is too expensive for large collections
      return true;
    } catch (e) {
      stderr.writeln('Error validating tree.json: $e');
      return false;
    }
  }

  /// Check if collection has all required files
  Future<bool> _hasRequiredFiles(Directory folder) async {
    final collectionJs = File('${folder.path}/collection.js');
    final treeJson = File('${folder.path}/extra/tree.json');
    final dataJs = File('${folder.path}/extra/data.js');
    final indexHtml = File('${folder.path}/index.html');

    return await collectionJs.exists() &&
           await treeJson.exists() &&
           await dataJs.exists() &&
           await indexHtml.exists();
  }

  /// Ensure collection files are up to date
  Future<void> ensureCollectionFilesUpdated(Collection collection, {bool force = false}) async {
    if (collection.storagePath == null) {
      return;
    }

    final folder = Directory(collection.storagePath!);
    if (!await folder.exists()) {
      return;
    }

    if (force) {
      // Force regeneration regardless of current state
      stderr.writeln('Force regenerating collection files for ${collection.title}...');
      await _generateAndSaveTreeJson(folder);
      await _generateAndSaveDataJs(folder);
      await _generateAndSaveIndexHtml(folder);
      return;
    }

    // Check if tree.json is valid
    final isValid = await _validateTreeJson(folder);

    if (!isValid || !await _hasRequiredFiles(folder)) {
      stderr.writeln('Regenerating collection files for ${collection.title}...');
      await _generateAndSaveTreeJson(folder);
      await _generateAndSaveDataJs(folder);
      await _generateAndSaveIndexHtml(folder);
    }
  }
}
