/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';
import 'dart:typed_data';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../models/story.dart';
import '../models/story_content.dart';
import '../models/story_scene.dart';
import 'story_ndf_service.dart';

/// Service for managing story files in a collection
class StoriesStorageService {
  final String basePath;
  final ProfileStorage? storage;
  final _log = LogService();
  late final StoryNdfService _ndfService;

  StoriesStorageService({required this.basePath, this.storage}) {
    _ndfService = StoryNdfService(storage: storage);
  }

  /// Convert an absolute path to a relative path for ProfileStorage
  String _toRelative(String absolutePath) {
    if (storage == null) return absolutePath;
    final base = storage!.basePath;
    if (absolutePath.startsWith('$base/')) {
      return absolutePath.substring(base.length + 1);
    }
    return absolutePath;
  }

  /// Get the stories directory path
  String get storiesDir => '$basePath/stories';

  /// Initialize the storage (create directories if needed)
  Future<void> initialize() async {
    if (storage != null) {
      await storage!.createDirectory(_toRelative(storiesDir));
    } else {
      final dir = Directory(storiesDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
  }

  /// List all stories in the collection
  Future<List<Story>> loadStories() async {
    final stories = <Story>[];

    if (storage != null) {
      final relDir = _toRelative(storiesDir);
      final exists = await storage!.directoryExists(relDir);
      if (!exists) return stories;

      final entries = await storage!.listDirectory(relDir);
      for (final entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('.ndf')) {
          // Construct the absolute path for the NDF service
          final absPath = '$storiesDir/${entry.name}';
          final story = await _ndfService.readStory(absPath);
          if (story != null) {
            stories.add(story.copyWith(filePath: absPath));
          }
        }
      }
    } else {
      final dir = Directory(storiesDir);
      if (!await dir.exists()) {
        return stories;
      }

      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.ndf')) {
          final story = await _ndfService.readStory(entity.path);
          if (story != null) {
            stories.add(story.copyWith(filePath: entity.path));
          }
        }
      }
    }

    // Sort by modified date (newest first)
    stories.sort((a, b) => b.modified.compareTo(a.modified));
    return stories;
  }

  /// Get a single story by ID
  Future<Story?> getStory(String storyId) async {
    final stories = await loadStories();
    return stories.cast<Story?>().firstWhere(
          (s) => s?.id == storyId,
          orElse: () => null,
        );
  }

  /// Get a story by filename
  Future<Story?> getStoryByFilename(String filename) async {
    final filePath = '$storiesDir/$filename';
    return _ndfService.readStory(filePath);
  }

  /// Create a new story
  Future<Story> createStory({
    required String title,
    String? description,
    List<String>? categories,
    required String ownerNpub,
    String? ownerName,
  }) async {
    await initialize();

    var story = Story.create(title: title, description: description);
    if (categories != null && categories.isNotEmpty) {
      story = story.copyWith(tags: categories);
    }
    final filePath = '$storiesDir/${story.filename}';

    // Check for filename collision and add number if needed
    final finalPath = await _getUniqueFilePath(filePath);

    await _ndfService.createStory(
      outputPath: finalPath,
      story: story,
      ownerNpub: ownerNpub,
      ownerName: ownerName,
    );

    return story.copyWith(filePath: finalPath);
  }

  /// Get unique file path, adding number suffix if needed
  Future<String> _getUniqueFilePath(String basePath) async {
    var path = basePath;
    var counter = 2;

    if (storage != null) {
      while (await storage!.exists(_toRelative(path))) {
        final nameWithoutExt = basePath.substring(0, basePath.length - 4);
        path = '$nameWithoutExt-$counter.ndf';
        counter++;
      }
    } else {
      while (await File(path).exists()) {
        final nameWithoutExt = basePath.substring(0, basePath.length - 4);
        path = '$nameWithoutExt-$counter.ndf';
        counter++;
      }
    }

    return path;
  }

  /// Update story metadata (title, description, categories)
  Future<Story> updateStoryMetadata(
    Story story, {
    String? title,
    String? description,
    List<String>? categories,
  }) async {
    if (story.filePath == null) {
      throw Exception('Story has no file path');
    }

    var updated = story.copyWith(
      title: title ?? story.title,
      description: description,
      tags: categories ?? story.tags,
      modified: DateTime.now(),
      revision: story.revision + 1,
    );

    // Save updated metadata
    await _ndfService.saveStoryMetadata(story.filePath!, updated);

    // Rename file if title changed
    if (title != null && title != story.title) {
      final newFilename = updated.filename;
      final currentFilename = story.filePath!.split('/').last;

      if (newFilename != currentFilename) {
        final newPath = '$storiesDir/$newFilename';
        final uniquePath = await _getUniqueFilePath(newPath);

        if (storage != null) {
          // ProfileStorage has no rename — read, write new, delete old
          final bytes = await storage!.readBytes(_toRelative(story.filePath!));
          if (bytes != null) {
            await storage!.writeBytes(_toRelative(uniquePath), bytes);
            await storage!.delete(_toRelative(story.filePath!));
          }
        } else {
          await File(story.filePath!).rename(uniquePath);
        }
        _log.log('StoriesStorageService: Renamed ${story.filePath} to $uniquePath');
        return updated.copyWith(filePath: uniquePath);
      }
    }

    return updated.copyWith(filePath: story.filePath);
  }

  /// Rename a story (updates title and filename)
  Future<Story> renameStory(Story story, String newTitle) async {
    if (story.filePath == null) {
      throw Exception('Story has no file path');
    }

    final updated = story.copyWith(
      title: newTitle,
      modified: DateTime.now(),
      revision: story.revision + 1,
    );

    // Save updated metadata
    await _ndfService.saveStoryMetadata(story.filePath!, updated);

    // Rename file if needed
    final newFilename = updated.filename;
    final currentFilename = story.filePath!.split('/').last;

    if (newFilename != currentFilename) {
      final newPath = '$storiesDir/$newFilename';
      final uniquePath = await _getUniqueFilePath(newPath);

      if (storage != null) {
        final bytes = await storage!.readBytes(_toRelative(story.filePath!));
        if (bytes != null) {
          await storage!.writeBytes(_toRelative(uniquePath), bytes);
          await storage!.delete(_toRelative(story.filePath!));
        }
      } else {
        await File(story.filePath!).rename(uniquePath);
      }
      _log.log('StoriesStorageService: Renamed ${story.filePath} to $uniquePath');
      return updated.copyWith(filePath: uniquePath);
    }

    return updated;
  }

  /// Delete a story
  Future<void> deleteStory(Story story) async {
    if (story.filePath == null) return;

    if (storage != null) {
      final rel = _toRelative(story.filePath!);
      if (await storage!.exists(rel)) {
        await storage!.delete(rel);
        _log.log('StoriesStorageService: Deleted ${story.filePath}');
      }
    } else {
      final file = File(story.filePath!);
      if (await file.exists()) {
        await file.delete();
        _log.log('StoriesStorageService: Deleted ${story.filePath}');
      }
    }
  }

  /// Load story content
  Future<StoryContent?> loadStoryContent(Story story) async {
    if (story.filePath == null) return null;
    return _ndfService.readStoryContent(story.filePath!);
  }

  /// Save story content
  Future<void> saveStoryContent(Story story, StoryContent content) async {
    if (story.filePath == null) return;
    await _ndfService.saveStoryContent(story.filePath!, content);

    // Update story metadata first
    final updated = story.touch();
    await _ndfService.saveStoryMetadata(story.filePath!, updated);

    // Then auto-generate thumbnail from first scene's background image
    // (setThumbnail will add thumbnail field to the saved metadata)
    await _updateThumbnailFromFirstScene(story.filePath!, content);
  }

  /// Update thumbnail from the first scene's background image
  Future<void> _updateThumbnailFromFirstScene(
    String filePath,
    StoryContent content,
  ) async {
    // Get the first scene (based on sceneIds order)
    if (content.sceneIds.isEmpty) return;

    final firstSceneId = content.sceneIds.first;
    final firstScene = content.scenes[firstSceneId];
    if (firstScene == null) return;

    // Check if the scene has a background image asset
    final backgroundAsset = firstScene.background.asset;
    if (backgroundAsset == null) return;

    // Read the background image bytes
    final imageBytes = await _ndfService.readMedia(filePath, backgroundAsset);
    if (imageBytes == null) return;

    // Set as thumbnail
    await _ndfService.setThumbnail(filePath, imageBytes);
    _log.log('StoriesStorageService: Auto-set thumbnail from first scene background');
  }

  /// Save a single scene
  Future<void> saveScene(Story story, StoryScene scene) async {
    if (story.filePath == null) return;
    await _ndfService.saveScene(story.filePath!, scene);
  }

  /// Delete a scene
  Future<void> deleteScene(Story story, String sceneId) async {
    if (story.filePath == null) return;
    await _ndfService.deleteScene(story.filePath!, sceneId);
  }

  /// Add media to story
  Future<String> addMedia(Story story, String sourceFilePath) async {
    if (story.filePath == null) {
      throw Exception('Story has no file path');
    }
    return _ndfService.addMediaFromFile(story.filePath!, sourceFilePath);
  }

  /// Read media from story
  Future<String?> extractMedia(Story story, String assetRef) async {
    if (story.filePath == null) return null;
    return _ndfService.extractMediaToTemp(story.filePath!, assetRef);
  }

  /// Set story thumbnail
  Future<void> setThumbnail(Story story, String imagePath) async {
    if (story.filePath == null) return;

    final file = File(imagePath);
    if (!await file.exists()) return;

    final bytes = await file.readAsBytes();
    await _ndfService.setThumbnail(story.filePath!, bytes);
  }

  /// Read story thumbnail
  Future<String?> extractThumbnail(Story story) async {
    if (story.filePath == null) return null;

    // Use thumbnail from metadata, or try default path
    final thumbnailRef = story.thumbnail ?? 'asset://thumbnails/preview.png';
    return _ndfService.extractMediaToTemp(story.filePath!, thumbnailRef);
  }

  /// Extract the blurred quiz thumbnail from the NDF.
  /// Returns a temp file path, or null if no blur asset exists.
  Future<String?> extractBlurredThumbnail(Story story) async {
    if (story.filePath == null) return null;
    return _ndfService.extractQuizBlurToTemp(story.filePath!);
  }

  /// Cleanup unused media in a story
  Future<void> cleanupMedia(Story story) async {
    if (story.filePath == null) return;
    await _ndfService.cleanupUnusedMedia(story.filePath!);
  }

  /// Duplicate a story
  Future<Story> duplicateStory(Story original, String newTitle) async {
    if (original.filePath == null) {
      throw Exception('Original story has no file path');
    }

    // Read original file
    Uint8List bytes;
    if (storage != null) {
      final data = await storage!.readBytes(_toRelative(original.filePath!));
      if (data == null) {
        throw Exception('Original story file not found');
      }
      bytes = data;
    } else {
      final originalFile = File(original.filePath!);
      bytes = await originalFile.readAsBytes();
    }

    // Create new story metadata
    final newStory = Story.create(
      title: newTitle,
      description: original.description,
    );

    // Write to new file
    final newPath = await _getUniqueFilePath('$storiesDir/${newStory.filename}');
    if (storage != null) {
      await storage!.writeBytes(_toRelative(newPath), bytes);
    } else {
      await File(newPath).writeAsBytes(bytes);
    }

    // Update the metadata in the new file
    await _ndfService.saveStoryMetadata(newPath, newStory);

    _log.log('StoriesStorageService: Duplicated story to $newPath');
    return newStory.copyWith(filePath: newPath);
  }
}
