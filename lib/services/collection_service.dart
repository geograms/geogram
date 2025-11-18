import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/collection.dart';
import '../util/nostr_key_generator.dart';
import 'config_service.dart';

/// Service for managing collections on disk
class CollectionService {
  static final CollectionService _instance = CollectionService._internal();
  factory CollectionService() => _instance;
  CollectionService._internal();

  Directory? _collectionsDir;
  final ConfigService _configService = ConfigService();

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
      await for (var entity in folder.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          // Skip metadata files
          if (entity.path.endsWith('collection.js') ||
              entity.path.endsWith('security.json') ||
              entity.path.endsWith('tree-data.js')) {
            continue;
          }

          fileCount++;
          final stat = await entity.stat();
          totalSize += stat.size;
        }
      }
    } catch (e) {
      stderr.writeln('Error counting files: $e');
    }

    collection.filesCount = fileCount;
    collection.totalSize = totalSize;
  }

  /// Create a new collection
  Future<Collection> createCollection({
    required String title,
    String description = '',
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

      // Sanitize folder name
      String folderName = title
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

      // Determine root path
      final rootPath = customRootPath ?? _collectionsDir!.path;
      stderr.writeln('Using root path: $rootPath');

      // Find unique folder name
      var collectionFolder = Directory('$rootPath/$folderName');
      int counter = 1;
      while (await collectionFolder.exists()) {
        collectionFolder = Directory('$rootPath/${folderName}_$counter');
        counter++;
      }

      stderr.writeln('Creating folder: ${collectionFolder.path}');

      // Create folder structure
      await collectionFolder.create(recursive: true);
      final extraDir = Directory('${collectionFolder.path}/extra');
      await extraDir.create();

      stderr.writeln('Folders created successfully');

      // Create collection object
      final collection = Collection(
        id: id,
        title: title,
        description: description,
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

    // Write extra/tree-data.js
    final treeDataJsFile = File('${folder.path}/extra/tree-data.js');
    await treeDataJsFile.writeAsString(collection.generateTreeDataJs());
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
    await _updateTreeData(collection, collectionDir);
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

    // Update metadata
    await _updateTreeData(collection, collectionDir);
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
    await _updateTreeData(collection, collectionDir);
    await updateCollection(collection);
  }

  /// Recursively copy a directory
  Future<void> _copyDirectory(Directory source, Directory dest) async {
    if (!await dest.exists()) {
      await dest.create(recursive: true);
    }

    await for (final entity in source.list(recursive: false)) {
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
      await for (final entity in collectionDir.list(recursive: false)) {
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
      await for (final entity in dir.list(recursive: false)) {
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

  /// Update tree-data.js with current file structure
  Future<void> _updateTreeData(Collection collection, Directory collectionDir) async {
    try {
      final fileTree = await _buildFileTree(collectionDir);
      final treeDataFile = File('${collectionDir.path}/extra/tree-data.js');
      await treeDataFile.writeAsString(collection.generateTreeDataJs(fileTree));
      stderr.writeln('Updated tree-data.js with ${fileTree.length} top-level items');
    } catch (e) {
      stderr.writeln('Error updating tree-data.js: $e');
    }
  }

  /// Load file tree from collection
  Future<List<FileNode>> loadFileTree(Collection collection) async {
    if (collection.storagePath == null) {
      throw Exception('Collection has no storage path');
    }

    final collectionDir = Directory(collection.storagePath!);
    return await _buildFileTree(collectionDir);
  }
}
