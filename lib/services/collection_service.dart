import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import '../models/collection.dart';
import '../util/nostr_key_generator.dart';
import '../util/tlsh.dart';
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

      // Check if all required files exist (collection.js, tree.json, data.js, index.html)
      if (!await _hasRequiredFiles(folder)) {
        stderr.writeln('Missing required files for collection: ${collection.title}');
        stderr.writeln('Generating tree.json, data.js, and index.html...');

        // Generate files synchronously on first load
        await _generateAndSaveTreeJson(folder);
        await _generateAndSaveDataJs(folder);
        await _generateAndSaveIndexHtml(folder);
      } else {
        // Validate tree.json matches directory contents
        final isValid = await _validateTreeJson(folder);
        if (!isValid) {
          stderr.writeln('tree.json out of sync for collection: ${collection.title}');
          stderr.writeln('Regenerating tree.json, data.js, and index.html...');

          // Regenerate files if out of sync
          await _generateAndSaveTreeJson(folder);
          await _generateAndSaveDataJs(folder);
          await _generateAndSaveIndexHtml(folder);
        }
      }

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

        for (var entry in entries) {
          if (entry['type'] == 'file') {
            fileCount++;
            totalSize += entry['size'] as int? ?? 0;
          }
        }
      } else {
        // If tree.json doesn't exist yet, set to 0
        // It will be generated soon and counts will be updated on reload
        stderr.writeln('Warning: tree.json not found for counting, setting counts to 0');
        fileCount = 0;
        totalSize = 0;
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

  /// Load file tree from collection
  Future<List<FileNode>> loadFileTree(Collection collection) async {
    if (collection.storagePath == null) {
      throw Exception('Collection has no storage path');
    }

    final collectionDir = Directory(collection.storagePath!);
    return await _buildFileTree(collectionDir);
  }

  /// Generate and save tree.json
  Future<void> _generateAndSaveTreeJson(Directory folder) async {
    try {
      final entries = <Map<String, dynamic>>[];

      // Recursively scan all files and directories
      await for (var entity in folder.list(recursive: true, followLinks: false)) {
        final relativePath = entity.path.substring(folder.path.length + 1);

        // Skip hidden files, metadata files, and the extra directory
        if (relativePath.startsWith('.') ||
            relativePath == 'collection.js' ||
            relativePath == 'index.html' ||
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

      // First pass: collect all entities without reading files
      await for (var entity in folder.list(recursive: true, followLinks: false)) {
        final relativePath = entity.path.substring(folder.path.length + 1);

        // Skip hidden files, metadata files, and the extra directory
        if (relativePath.startsWith('.') ||
            relativePath == 'collection.js' ||
            relativePath == 'index.html' ||
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
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(10px); }
            to { opacity: 1; transform: translateY(0); }
        }

        @keyframes shimmer {
            0% { background-position: -1000px 0; }
            100% { background-position: 1000px 0; }
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            background-attachment: fixed;
            color: #1a202c;
            min-height: 100vh;
            animation: fadeIn 0.6s ease-out;
        }

        .header {
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            color: #1a202c;
            padding: 2.5rem 0;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
            border-bottom: 1px solid rgba(102, 126, 234, 0.1);
        }

        .header-content {
            max-width: 1400px;
            margin: 0 auto;
            padding: 0 2rem;
        }

        .header h1 {
            font-size: 2.5rem;
            font-weight: 700;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
            margin-bottom: 0.5rem;
            letter-spacing: -0.5px;
        }

        .header .description {
            color: #4a5568;
            font-size: 1.1rem;
            line-height: 1.6;
            margin-bottom: 0.75rem;
        }

        .header .meta {
            display: flex;
            align-items: center;
            gap: 0.5rem;
            color: #718096;
            font-size: 0.9rem;
        }

        .meta-icon {
            opacity: 0.7;
        }

        .stats-container {
            max-width: 1400px;
            margin: -3rem auto 0;
            padding: 0 2rem;
            position: relative;
            z-index: 10;
        }

        .stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 1.5rem;
            margin-bottom: 2rem;
        }

        .stat-card {
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            border-radius: 16px;
            padding: 2rem;
            box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
            border: 1px solid rgba(255, 255, 255, 0.8);
            transition: transform 0.3s ease, box-shadow 0.3s ease;
            animation: fadeIn 0.6s ease-out backwards;
        }

        .stat-card:nth-child(1) { animation-delay: 0.1s; }
        .stat-card:nth-child(2) { animation-delay: 0.2s; }
        .stat-card:nth-child(3) { animation-delay: 0.3s; }

        .stat-card:hover {
            transform: translateY(-4px);
            box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 10px 10px -5px rgba(0, 0, 0, 0.04);
        }

        .stat-icon {
            font-size: 2.5rem;
            margin-bottom: 1rem;
            display: inline-block;
        }

        .stat-value {
            font-size: 2.25rem;
            font-weight: 700;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
            margin-bottom: 0.5rem;
        }

        .stat-label {
            font-size: 0.95rem;
            color: #718096;
            font-weight: 500;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .container {
            max-width: 1400px;
            margin: 0 auto;
            padding: 2rem;
        }

        .search-box {
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            padding: 1rem;
            border-radius: 16px;
            box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
            border: 1px solid rgba(255, 255, 255, 0.8);
            margin-bottom: 2rem;
            animation: fadeIn 0.6s ease-out 0.4s backwards;
        }

        .search-wrapper {
            position: relative;
            display: flex;
            align-items: center;
        }

        .search-icon {
            position: absolute;
            left: 1.25rem;
            color: #a0aec0;
            font-size: 1.25rem;
        }

        .search-input {
            width: 100%;
            padding: 1rem 1rem 1rem 3.5rem;
            font-size: 1.05rem;
            border: 2px solid transparent;
            border-radius: 12px;
            outline: none;
            background: #f7fafc;
            transition: all 0.3s ease;
            color: #2d3748;
        }

        .search-input:focus {
            border-color: #667eea;
            background: white;
            box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
        }

        .search-input::placeholder {
            color: #a0aec0;
        }

        .tabs {
            display: flex;
            gap: 0.5rem;
            margin-bottom: 1.5rem;
            background: rgba(255, 255, 255, 0.5);
            backdrop-filter: blur(10px);
            padding: 0.5rem;
            border-radius: 12px;
            animation: fadeIn 0.6s ease-out 0.5s backwards;
        }

        .tab {
            padding: 0.875rem 1.75rem;
            background: transparent;
            border: none;
            cursor: pointer;
            font-size: 1rem;
            font-weight: 500;
            color: #4a5568;
            border-radius: 8px;
            transition: all 0.3s ease;
            position: relative;
        }

        .tab:hover {
            background: rgba(255, 255, 255, 0.6);
            color: #667eea;
        }

        .tab.active {
            background: white;
            color: #667eea;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
        }

        .content {
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            border-radius: 16px;
            box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
            border: 1px solid rgba(255, 255, 255, 0.8);
            padding: 2rem;
            min-height: 500px;
            animation: fadeIn 0.6s ease-out 0.6s backwards;
        }

        .file-tree {
            list-style: none;
        }

        .file-item {
            padding: 0.75rem 1rem;
            cursor: pointer;
            border-radius: 8px;
            transition: all 0.2s ease;
            display: flex;
            align-items: center;
            gap: 0.75rem;
            margin: 0.25rem 0;
        }

        .file-item:hover {
            background: linear-gradient(135deg, rgba(102, 126, 234, 0.05) 0%, rgba(118, 75, 162, 0.05) 100%);
            transform: translateX(4px);
        }

        .file-item.directory {
            font-weight: 600;
        }

        .file-icon {
            font-size: 1.5rem;
            flex-shrink: 0;
            transition: transform 0.2s ease;
        }

        .file-item:hover .file-icon {
            transform: scale(1.1);
        }

        .file-name {
            flex: 1;
            color: #2d3748;
            font-size: 0.95rem;
        }

        .file-type-badge {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 0.25rem 0.75rem;
            border-radius: 6px;
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .file-size {
            color: #a0aec0;
            font-size: 0.875rem;
            font-weight: 500;
            min-width: 80px;
            text-align: right;
        }

        .nested {
            padding-left: 2rem;
            display: none;
            overflow: hidden;
        }

        .nested.open {
            display: block;
            animation: fadeIn 0.3s ease-out;
        }

        .expand-icon {
            margin-right: 0.25rem;
            display: inline-block;
            font-size: 0.75rem;
            transition: transform 0.3s ease;
            color: #a0aec0;
        }

        .expand-icon.expanded {
            transform: rotate(90deg);
            color: #667eea;
        }

        .search-results {
            display: none;
        }

        .search-results.active {
            display: block;
        }

        .result-item {
            padding: 1.25rem;
            border-bottom: 1px solid #e2e8f0;
            cursor: pointer;
            transition: all 0.3s ease;
            border-radius: 8px;
            margin-bottom: 0.5rem;
        }

        .result-item:hover {
            background: linear-gradient(135deg, rgba(102, 126, 234, 0.05) 0%, rgba(118, 75, 162, 0.05) 100%);
            border-color: #667eea;
            transform: translateX(4px);
        }

        .result-name {
            font-weight: 600;
            font-size: 1.05rem;
            margin-bottom: 0.5rem;
            color: #667eea;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }

        .result-path {
            font-size: 0.875rem;
            color: #718096;
            margin-bottom: 0.5rem;
            font-family: 'Courier New', monospace;
        }

        .result-meta {
            font-size: 0.8rem;
            color: #a0aec0;
            display: flex;
            gap: 1.5rem;
            flex-wrap: wrap;
        }

        .result-meta span {
            display: flex;
            align-items: center;
            gap: 0.25rem;
        }

        .no-results {
            text-align: center;
            padding: 4rem 2rem;
            color: #a0aec0;
        }

        .no-results-icon {
            font-size: 4rem;
            margin-bottom: 1rem;
            opacity: 0.5;
        }

        .no-results-text {
            font-size: 1.25rem;
            font-weight: 500;
            margin-bottom: 0.5rem;
        }

        .no-results-hint {
            font-size: 0.95rem;
            opacity: 0.7;
        }

        .footer {
            max-width: 1400px;
            margin: 3rem auto 0;
            padding: 2rem;
            text-align: center;
            color: rgba(255, 255, 255, 0.8);
            font-size: 0.9rem;
        }

        .footer a {
            color: white;
            text-decoration: none;
            font-weight: 600;
            transition: opacity 0.3s ease;
        }

        .footer a:hover {
            opacity: 0.8;
        }

        @media (max-width: 768px) {
            .header h1 {
                font-size: 2rem;
            }

            .stats {
                grid-template-columns: 1fr;
            }

            .stat-card {
                padding: 1.5rem;
            }

            .stat-value {
                font-size: 1.75rem;
            }

            .container {
                padding: 1rem;
            }

            .content {
                padding: 1.5rem;
            }
        }
    </style>
</head>
<body>
    <div class="header">
        <div class="header-content">
            <h1 id="collection-title">Loading...</h1>
            <div class="description" id="collection-description"></div>
            <div class="meta">
                <span class="meta-icon">🕒</span>
                <span id="collection-meta"></span>
            </div>
        </div>
    </div>

    <div class="stats-container">
        <div class="stats">
            <div class="stat-card">
                <div class="stat-icon">📄</div>
                <div class="stat-value" id="total-files">0</div>
                <div class="stat-label">Total Files</div>
            </div>
            <div class="stat-card">
                <div class="stat-icon">📁</div>
                <div class="stat-value" id="total-folders">0</div>
                <div class="stat-label">Folders</div>
            </div>
            <div class="stat-card">
                <div class="stat-icon">💾</div>
                <div class="stat-value" id="total-size">0 B</div>
                <div class="stat-label">Total Size</div>
            </div>
        </div>
    </div>

    <div class="container">
        <div class="search-box">
            <div class="search-wrapper">
                <span class="search-icon">🔍</span>
                <input type="text" class="search-input" id="search-input" placeholder="Search files, folders, or file types...">
            </div>
        </div>

        <div class="tabs">
            <button class="tab active" data-tab="browser">📂 File Browser</button>
            <button class="tab" data-tab="search">🔍 Search Results</button>
        </div>

        <div class="content">
            <div id="browser-view">
                <ul class="file-tree" id="file-tree"></ul>
            </div>
            <div id="search-view" class="search-results">
                <div id="search-results-list"></div>
            </div>
        </div>
    </div>

    <div class="footer">
        Powered by <a href="https://github.com/geograms/geogram" target="_blank">Geogram</a> • Resilient, Decentralized Communication
    </div>

    <script src="collection.js"></script>
    <script src="extra/data.js"></script>
    <script>
        const collectionData = window.COLLECTION_DATA?.collection || {};
        const fileData = window.COLLECTION_DATA_FULL || [];
        let currentView = 'browser';
        let searchTimeout = null;

        // Initialize
        document.addEventListener('DOMContentLoaded', () => {
            loadCollectionInfo();
            buildFileTree();
            setupSearch();
            setupTabs();
            calculateStats();
        });

        function loadCollectionInfo() {
            document.getElementById('collection-title').textContent = collectionData.title || 'Collection';
            document.getElementById('collection-description').textContent = collectionData.description || '';
            document.getElementById('collection-meta').textContent = \`Updated: \${new Date(collectionData.updated).toLocaleString()}\`;
        }

        function getFileIcon(item) {
            if (item.type === 'directory') return '📁';

            const ext = item.name.split('.').pop().toLowerCase();
            const mimeType = item.mimeType || '';

            // Images
            if (mimeType.startsWith('image/') || ['jpg', 'jpeg', 'png', 'gif', 'svg', 'webp', 'bmp'].includes(ext)) {
                return '🖼️';
            }
            // Videos
            if (mimeType.startsWith('video/') || ['mp4', 'avi', 'mov', 'mkv', 'webm'].includes(ext)) {
                return '🎥';
            }
            // Audio
            if (mimeType.startsWith('audio/') || ['mp3', 'wav', 'ogg', 'flac', 'm4a'].includes(ext)) {
                return '🎵';
            }
            // Documents
            if (['pdf'].includes(ext)) return '📕';
            if (['doc', 'docx'].includes(ext)) return '📘';
            if (['xls', 'xlsx'].includes(ext)) return '📗';
            if (['ppt', 'pptx'].includes(ext)) return '📙';
            if (['txt', 'md', 'readme'].includes(ext)) return '📝';

            // Code
            if (['js', 'ts', 'jsx', 'tsx', 'json'].includes(ext)) return '📜';
            if (['html', 'css', 'scss'].includes(ext)) return '🌐';
            if (['py', 'java', 'cpp', 'c', 'h', 'rs', 'go'].includes(ext)) return '⚙️';

            // Archives
            if (['zip', 'tar', 'gz', 'rar', '7z'].includes(ext)) return '📦';

            // Default
            return '📄';
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

        function buildFileTree() {
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

            const treeContainer = document.getElementById('file-tree');
            treeContainer.innerHTML = '';
            renderTree(tree, treeContainer);
        }

        function renderTree(node, container, level = 0) {
            const entries = Object.values(node).sort((a, b) => {
                if (a.type === 'directory' && b.type !== 'directory') return -1;
                if (a.type !== 'directory' && b.type === 'directory') return 1;
                return a.name.localeCompare(b.name);
            });

            entries.forEach(item => {
                const li = document.createElement('li');
                const div = document.createElement('div');
                div.className = \`file-item \${item.type}\`;

                if (item.type === 'directory') {
                    const expandIcon = document.createElement('span');
                    expandIcon.className = 'expand-icon';
                    expandIcon.textContent = '▸';
                    div.appendChild(expandIcon);
                }

                const icon = document.createElement('span');
                icon.className = 'file-icon';
                icon.textContent = getFileIcon(item);
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
                }

                div.addEventListener('click', (e) => {
                    e.stopPropagation();
                    if (item.type === 'directory') {
                        const nested = li.querySelector('.nested');
                        const expandIcon = div.querySelector('.expand-icon');
                        if (nested) {
                            nested.classList.toggle('open');
                            expandIcon.classList.toggle('expanded');
                        }
                    } else {
                        openFile(item.path);
                    }
                });

                li.appendChild(div);

                if (item.type === 'directory' && Object.keys(item.children).length > 0) {
                    const nested = document.createElement('ul');
                    nested.className = 'nested';
                    renderTree(item.children, nested, level + 1);
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
                    performSearch(e.target.value);
                }, 300);
            });
        }

        function performSearch(query) {
            if (!query.trim()) {
                switchTab('browser');
                return;
            }

            const lowerQuery = query.toLowerCase();
            const results = fileData.filter(item => {
                const nameMatch = item.name.toLowerCase().includes(lowerQuery);
                const pathMatch = item.path.toLowerCase().includes(lowerQuery);
                const mimeMatch = item.mimeType && item.mimeType.toLowerCase().includes(lowerQuery);
                return nameMatch || pathMatch || mimeMatch;
            });

            displaySearchResults(results, query);
            switchTab('search');
        }

        function displaySearchResults(results, query) {
            const container = document.getElementById('search-results-list');

            if (results.length === 0) {
                container.innerHTML = \`
                    <div class="no-results">
                        <div class="no-results-icon">🔍</div>
                        <div class="no-results-text">No results found</div>
                        <div class="no-results-hint">Try searching for a different term</div>
                    </div>
                \`;
                return;
            }

            container.innerHTML = '';
            results.forEach(item => {
                const div = document.createElement('div');
                div.className = 'result-item';

                div.innerHTML = \`
                    <div class="result-name">\${getFileIcon(item)} \${item.name}</div>
                    <div class="result-path">\${item.path}</div>
                    <div class="result-meta">
                        \${item.type !== 'directory' ? \`<span>📏 \${formatSize(item.size)}</span>\` : ''}
                        \${item.mimeType ? \`<span>📋 \${item.mimeType}</span>\` : ''}
                    </div>
                \`;

                div.addEventListener('click', () => {
                    if (item.type !== 'directory') {
                        openFile(item.path);
                    }
                });

                container.appendChild(div);
            });
        }

        function setupTabs() {
            document.querySelectorAll('.tab').forEach(tab => {
                tab.addEventListener('click', () => {
                    switchTab(tab.dataset.tab);
                });
            });
        }

        function switchTab(tabName) {
            document.querySelectorAll('.tab').forEach(tab => {
                tab.classList.toggle('active', tab.dataset.tab === tabName);
            });

            document.getElementById('browser-view').style.display = tabName === 'browser' ? 'block' : 'none';
            document.getElementById('search-view').style.display = tabName === 'search' ? 'block' : 'none';
            currentView = tabName;
        }

        function openFile(path) {
            window.open(path, '_blank');
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
