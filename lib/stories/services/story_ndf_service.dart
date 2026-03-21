/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../work/models/ndf_permission.dart';
import '../models/story.dart';
import '../models/story_content.dart';
import '../models/story_scene.dart';

/// Service for reading and writing Story NDF documents
class StoryNdfService {
  final _log = LogService();
  final ProfileStorage? storage;

  StoryNdfService({this.storage});

  /// Convert an absolute file path to a relative path for ProfileStorage
  String _toRelative(String absolutePath) {
    if (storage == null) return absolutePath;
    final base = storage!.basePath;
    if (absolutePath.startsWith('$base/')) {
      return absolutePath.substring(base.length + 1);
    }
    return absolutePath;
  }

  // ============================================================
  // STORY METADATA METHODS
  // ============================================================

  /// Read story metadata from NDF file
  Future<Story?> readStory(String filePath) async {
    try {
      Uint8List? bytes;
      if (storage != null) {
        bytes = await storage!.readBytes(_toRelative(filePath));
      } else {
        final file = File(filePath);
        if (!await file.exists()) return null;
        bytes = await file.readAsBytes();
      }
      if (bytes == null) return null;

      final archive = ZipDecoder().decodeBytes(bytes);

      for (final entry in archive) {
        if (entry.name == 'ndf.json' && entry.isFile) {
          final content = utf8.decode(entry.content as List<int>);
          final json = jsonDecode(content) as Map<String, dynamic>;
          return Story.fromJson(json, filePath: filePath);
        }
      }

      _log.log('StoryNdfService: ndf.json not found in $filePath');
      return null;
    } catch (e) {
      _log.log('StoryNdfService: Error reading story from $filePath: $e');
      return null;
    }
  }

  /// Read story content from NDF file
  Future<StoryContent?> readStoryContent(String filePath) async {
    try {
      Uint8List? bytes;
      if (storage != null) {
        bytes = await storage!.readBytes(_toRelative(filePath));
      } else {
        final file = File(filePath);
        if (!await file.exists()) return null;
        bytes = await file.readAsBytes();
      }
      if (bytes == null) return null;

      final archive = ZipDecoder().decodeBytes(bytes);

      // First read main.json
      Map<String, dynamic>? mainJson;
      for (final entry in archive) {
        if (entry.name == 'content/main.json' && entry.isFile) {
          final content = utf8.decode(entry.content as List<int>);
          mainJson = jsonDecode(content) as Map<String, dynamic>;
          break;
        }
      }

      if (mainJson == null) {
        _log.log('StoryNdfService: content/main.json not found');
        return null;
      }

      // Load all scenes
      final scenes = <String, StoryScene>{};
      for (final entry in archive) {
        if (entry.name.startsWith('content/scenes/') &&
            entry.name.endsWith('.json') &&
            entry.isFile) {
          final content = utf8.decode(entry.content as List<int>);
          final sceneJson = jsonDecode(content) as Map<String, dynamic>;
          final scene = StoryScene.fromJson(sceneJson);
          scenes[scene.id] = scene;
        }
      }

      return StoryContent.fromJson(mainJson, loadedScenes: scenes);
    } catch (e) {
      _log.log('StoryNdfService: Error reading story content from $filePath: $e');
      return null;
    }
  }

  /// Read a specific scene from NDF file
  Future<StoryScene?> readScene(String filePath, String sceneId) async {
    final json = await _readArchiveJson(filePath, 'content/scenes/$sceneId.json');
    if (json == null) return null;

    try {
      return StoryScene.fromJson(json);
    } catch (e) {
      _log.log('StoryNdfService: Error parsing scene $sceneId: $e');
      return null;
    }
  }

  // ============================================================
  // CREATE & SAVE METHODS
  // ============================================================

  /// Create a new story NDF file
  Future<String> createStory({
    required String outputPath,
    required Story story,
    required String ownerNpub,
    String? ownerName,
  }) async {
    final archive = Archive();

    // Add ndf.json
    final ndfJson = utf8.encode(const JsonEncoder.withIndent('  ').convert(story.toJson()));
    archive.addFile(ArchiveFile('ndf.json', ndfJson.length, ndfJson));

    // Add permissions.json
    final permissions = NdfPermission.create(
      documentId: story.id,
      ownerNpub: ownerNpub,
      ownerName: ownerName,
    );
    final permissionsJson = utf8.encode(permissions.toJsonString());
    archive.addFile(ArchiveFile('permissions.json', permissionsJson.length, permissionsJson));

    // Add default content/main.json
    final defaultContent = StoryContent(
      startSceneId: 'scene-001',
      sceneIds: ['scene-001'],
    );
    final contentJson = utf8.encode(const JsonEncoder.withIndent('  ').convert(defaultContent.toJson()));
    archive.addFile(ArchiveFile('content/main.json', contentJson.length, contentJson));

    // Add initial scene (no background image yet - user must add one)
    final initialScene = StoryScene(
      id: 'scene-001',
      index: 0,
      title: 'Scene 1',
      background: const SceneBackground(placeholder: '#1a1a2e'),
      elements: [],
      triggers: [],
    );
    final sceneJson = utf8.encode(const JsonEncoder.withIndent('  ').convert(initialScene.toJson()));
    archive.addFile(ArchiveFile('content/scenes/scene-001.json', sceneJson.length, sceneJson));

    // Write the ZIP file
    final zipData = ZipEncoder().encode(archive);
    if (zipData == null) {
      throw Exception('Failed to encode story NDF archive');
    }

    if (storage != null) {
      await storage!.writeBytes(_toRelative(outputPath), Uint8List.fromList(zipData));
    } else {
      final file = File(outputPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(zipData);
    }

    _log.log('StoryNdfService: Created story at $outputPath');
    return outputPath;
  }

  /// Save story metadata (ndf.json)
  Future<void> saveStoryMetadata(String filePath, Story story) async {
    await _updateArchiveFiles(filePath, {
      'ndf.json': const JsonEncoder.withIndent('  ').convert(story.toJson()),
    });
  }

  /// Save story content (main.json and scenes)
  Future<void> saveStoryContent(
    String filePath,
    StoryContent content,
  ) async {
    final files = <String, String>{
      'content/main.json': const JsonEncoder.withIndent('  ').convert(content.toJson()),
    };

    // Save all scenes
    for (final scene in content.scenes.values) {
      files['content/scenes/${scene.id}.json'] =
          const JsonEncoder.withIndent('  ').convert(scene.toJson());
    }

    await _updateArchiveFiles(filePath, files);
  }

  /// Save a single scene
  Future<void> saveScene(String filePath, StoryScene scene) async {
    await _updateArchiveFiles(filePath, {
      'content/scenes/${scene.id}.json':
          const JsonEncoder.withIndent('  ').convert(scene.toJson()),
    });
  }

  /// Delete a scene
  Future<void> deleteScene(String filePath, String sceneId) async {
    await _deleteArchiveFiles(filePath, ['content/scenes/$sceneId.json']);
  }

  // ============================================================
  // MEDIA ASSET METHODS
  // ============================================================

  /// Add media file to the story, returning the asset reference
  /// Uses SHA1 hash as filename for deduplication
  Future<String> addMedia(String filePath, Uint8List data, String originalExtension) async {
    // Generate SHA1 hash of the content
    final hash = sha1.convert(data).toString();
    final assetPath = 'media/$hash.$originalExtension';
    final assetRef = 'asset://$assetPath';

    // Check if asset already exists
    final existingFiles = await _listArchiveFiles(filePath);
    if (existingFiles.contains('assets/$assetPath')) {
      _log.log('StoryNdfService: Media already exists: $assetRef');
      return assetRef;
    }

    // Add to archive
    await _updateArchiveFilesBytes(filePath, {
      'assets/$assetPath': data,
    });

    _log.log('StoryNdfService: Added media: $assetRef');
    return assetRef;
  }

  /// Add media from a file path
  Future<String> addMediaFromFile(String ndfPath, String sourceFilePath) async {
    final file = File(sourceFilePath);
    if (!await file.exists()) {
      throw Exception('Source file not found: $sourceFilePath');
    }

    final data = await file.readAsBytes();
    final extension = sourceFilePath.split('.').last.toLowerCase();
    return addMedia(ndfPath, data, extension);
  }

  /// Read a media asset
  Future<Uint8List?> readMedia(String filePath, String assetRef) async {
    if (!assetRef.startsWith('asset://')) return null;

    final assetPath = assetRef.substring(8); // Remove 'asset://'
    return _readArchiveFile(filePath, 'assets/$assetPath');
  }

  /// Extract media to a temporary file
  Future<String?> extractMediaToTemp(String filePath, String assetRef) async {
    final data = await readMedia(filePath, assetRef);
    if (data == null) return null;

    final ext = assetRef.split('.').last;
    final tempDir = Directory.systemTemp;
    final tempFile = File(
      '${tempDir.path}/story_media_${DateTime.now().millisecondsSinceEpoch}.$ext',
    );
    await tempFile.writeAsBytes(data);
    return tempFile.path;
  }

  /// List all media assets in the story
  Future<List<String>> listMedia(String filePath) async {
    final files = await _listArchiveFiles(filePath);
    return files
        .where((f) => f.startsWith('assets/media/') && !f.endsWith('/'))
        .map((f) => 'asset://${f.substring(7)}') // Convert to asset:// reference
        .toList();
  }

  /// Remove unused media from the story
  Future<void> cleanupUnusedMedia(String filePath) async {
    // Get all media references used in scenes
    final content = await readStoryContent(filePath);
    if (content == null) return;

    final usedRefs = <String>{};

    for (final scene in content.scenes.values) {
      // Check background
      if (scene.background.asset != null) {
        usedRefs.add(scene.background.asset!);
      }

      // Check elements
      for (final element in scene.elements) {
        final asset = element.properties['asset'] as String?;
        if (asset != null) usedRefs.add(asset);

        final soundAsset = element.properties['soundAsset'] as String?;
        if (soundAsset != null) usedRefs.add(soundAsset);
      }

      // Check triggers
      for (final trigger in scene.triggers) {
        if (trigger.soundAsset != null) {
          usedRefs.add(trigger.soundAsset!);
        }
      }
    }

    // Get all media files and find unused ones
    final allMedia = await listMedia(filePath);
    final unusedMedia = allMedia.where((ref) => !usedRefs.contains(ref)).toList();

    if (unusedMedia.isEmpty) return;

    // Delete unused media
    final pathsToDelete = unusedMedia
        .map((ref) => 'assets/${ref.substring(8)}')
        .toList();
    await _deleteArchiveFiles(filePath, pathsToDelete);

    _log.log('StoryNdfService: Cleaned up ${unusedMedia.length} unused media files');
  }

  // ============================================================
  // THUMBNAIL METHODS
  // ============================================================

  /// Set story thumbnail
  Future<void> setThumbnail(String filePath, Uint8List imageBytes) async {
    await _updateArchiveFilesBytes(filePath, {
      'assets/thumbnails/preview.png': imageBytes,
    });

    // Update metadata
    final story = await readStory(filePath);
    if (story != null) {
      final updated = story.copyWith(
        thumbnail: 'asset://thumbnails/preview.png',
        modified: DateTime.now(),
        revision: story.revision + 1,
      );
      await saveStoryMetadata(filePath, updated);
    }
  }

  /// Extract the first quiz_blur asset to a temp file.
  /// Returns the temp path, or null if no blur asset exists.
  Future<String?> extractQuizBlurToTemp(String filePath) async {
    try {
      Uint8List? bytes;
      if (storage != null) {
        bytes = await storage!.readBytes(_toRelative(filePath));
      } else {
        final file = File(filePath);
        if (!await file.exists()) return null;
        bytes = await file.readAsBytes();
      }
      if (bytes == null) return null;

      final archive = ZipDecoder().decodeBytes(bytes);
      for (final entry in archive) {
        if (entry.isFile &&
            entry.name.startsWith('assets/quiz_blur/') &&
            entry.name.endsWith('_blur.jpg')) {
          final tempDir = Directory.systemTemp;
          final tempFile = File(
            '${tempDir.path}/story_blur_${DateTime.now().millisecondsSinceEpoch}.jpg',
          );
          await tempFile.writeAsBytes(entry.content as List<int>);
          return tempFile.path;
        }
      }
      return null;
    } catch (e) {
      _log.log('StoryNdfService: Error extracting quiz blur: $e');
      return null;
    }
  }

  /// Read thumbnail
  Future<Uint8List?> readThumbnail(String filePath) async {
    final story = await readStory(filePath);
    if (story?.thumbnail == null) return null;
    return readMedia(filePath, story!.thumbnail!);
  }

  // ============================================================
  // PRIVATE HELPER METHODS
  // ============================================================

  Future<Map<String, dynamic>?> _readArchiveJson(String filePath, String archivePath) async {
    final bytes = await _readArchiveFile(filePath, archivePath);
    if (bytes == null) return null;

    try {
      final content = utf8.decode(bytes);
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      _log.log('StoryNdfService: Error parsing JSON from $archivePath: $e');
      return null;
    }
  }

  Future<Uint8List?> _readArchiveFile(String filePath, String archivePath) async {
    try {
      Uint8List? bytes;
      if (storage != null) {
        bytes = await storage!.readBytes(_toRelative(filePath));
      } else {
        final file = File(filePath);
        if (!await file.exists()) return null;
        bytes = await file.readAsBytes();
      }
      if (bytes == null) return null;

      final archive = ZipDecoder().decodeBytes(bytes);

      for (final entry in archive) {
        if (entry.name == archivePath && entry.isFile) {
          return Uint8List.fromList(entry.content as List<int>);
        }
      }
      return null;
    } catch (e) {
      _log.log('StoryNdfService: Error reading $archivePath: $e');
      return null;
    }
  }

  Future<List<String>> _listArchiveFiles(String filePath) async {
    try {
      Uint8List? bytes;
      if (storage != null) {
        bytes = await storage!.readBytes(_toRelative(filePath));
      } else {
        final file = File(filePath);
        if (!await file.exists()) return [];
        bytes = await file.readAsBytes();
      }
      if (bytes == null) return [];

      final archive = ZipDecoder().decodeBytes(bytes);
      return archive.map((e) => e.name).toList();
    } catch (e) {
      _log.log('StoryNdfService: Error listing archive: $e');
      return [];
    }
  }

  Future<void> _updateArchiveFiles(String filePath, Map<String, String> files) async {
    final bytesMap = <String, Uint8List>{};
    for (final entry in files.entries) {
      bytesMap[entry.key] = Uint8List.fromList(utf8.encode(entry.value));
    }
    await _updateArchiveFilesBytes(filePath, bytesMap);
  }

  Future<void> _updateArchiveFilesBytes(String filePath, Map<String, Uint8List> files) async {
    Uint8List? existingBytes;
    if (storage != null) {
      existingBytes = await storage!.readBytes(_toRelative(filePath));
    } else {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('NDF file not found: $filePath');
      }
      existingBytes = await file.readAsBytes();
    }
    if (existingBytes == null) {
      throw Exception('NDF file not found: $filePath');
    }

    final archive = ZipDecoder().decodeBytes(existingBytes);

    final newArchive = Archive();
    final addedPaths = <String>{};

    // Copy existing entries, replacing those in files map
    for (final entry in archive) {
      if (files.containsKey(entry.name)) {
        final newData = files[entry.name]!;
        newArchive.addFile(ArchiveFile(entry.name, newData.length, newData));
        addedPaths.add(entry.name);
      } else {
        newArchive.addFile(entry);
      }
    }

    // Add new files
    for (final entry in files.entries) {
      if (!addedPaths.contains(entry.key)) {
        newArchive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
      }
    }

    final zipData = ZipEncoder().encode(newArchive);
    if (zipData == null) {
      throw Exception('Failed to encode NDF archive');
    }

    if (storage != null) {
      await storage!.writeBytes(_toRelative(filePath), Uint8List.fromList(zipData));
    } else {
      await File(filePath).writeAsBytes(zipData);
    }
  }

  Future<void> _deleteArchiveFiles(String filePath, List<String> paths) async {
    Uint8List? existingBytes;
    if (storage != null) {
      existingBytes = await storage!.readBytes(_toRelative(filePath));
    } else {
      final file = File(filePath);
      if (!await file.exists()) return;
      existingBytes = await file.readAsBytes();
    }
    if (existingBytes == null) return;

    final archive = ZipDecoder().decodeBytes(existingBytes);

    final newArchive = Archive();
    final pathSet = paths.toSet();

    for (final entry in archive) {
      if (!pathSet.contains(entry.name)) {
        newArchive.addFile(entry);
      }
    }

    final zipData = ZipEncoder().encode(newArchive);
    if (zipData == null) {
      throw Exception('Failed to encode NDF archive');
    }

    if (storage != null) {
      await storage!.writeBytes(_toRelative(filePath), Uint8List.fromList(zipData));
    } else {
      await File(filePath).writeAsBytes(zipData);
    }
  }
}
