/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';

import '../models/inventory_folder.dart';
import '../models/inventory_item.dart';
import '../models/inventory_borrow.dart';
import '../models/inventory_usage.dart';
import '../models/inventory_template.dart';
import '../utils/inventory_folder_utils.dart';
import '../../services/log_service.dart';

/// Service for handling inventory file I/O operations
class InventoryStorageService {
  final String basePath;

  InventoryStorageService(this.basePath);

  // ============ Folder Operations ============

  /// Read folder metadata from _folder.json
  Future<InventoryFolder?> readFolderMetadata(List<String> folderPath) async {
    try {
      final metaPath = InventoryFolderUtils.buildFolderMetadataPath(
        basePath,
        folderPath,
      );
      final file = File(metaPath);
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return InventoryFolder.fromJson(json);
    } catch (e) {
      LogService().log('InventoryStorageService: Error reading folder metadata: $e');
      return null;
    }
  }

  /// Write folder metadata to _folder.json
  Future<bool> writeFolderMetadata(
    List<String> folderPath,
    InventoryFolder folder,
  ) async {
    try {
      final metaPath = InventoryFolderUtils.buildFolderMetadataPath(
        basePath,
        folderPath,
      );
      final file = File(metaPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(folder.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('InventoryStorageService: Error writing folder metadata: $e');
      return false;
    }
  }

  /// Create a new folder directory with metadata
  Future<bool> createFolder(
    List<String> parentPath,
    InventoryFolder folder,
  ) async {
    try {
      final folderPath = [...parentPath, folder.id];
      final dirPath = InventoryFolderUtils.buildFolderPath(basePath, folderPath);
      final dir = Directory(dirPath);

      // Create folder directory
      await dir.create(recursive: true);

      // Create media subdirectory
      final mediaDir = Directory(InventoryFolderUtils.buildMediaPath(basePath, folderPath));
      await mediaDir.create(recursive: true);

      // Write folder metadata
      return await writeFolderMetadata(folderPath, folder);
    } catch (e) {
      LogService().log('InventoryStorageService: Error creating folder: $e');
      return false;
    }
  }

  /// Delete a folder and all its contents
  Future<bool> deleteFolder(List<String> folderPath) async {
    try {
      final dirPath = InventoryFolderUtils.buildFolderPath(basePath, folderPath);
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return true;
    } catch (e) {
      LogService().log('InventoryStorageService: Error deleting folder: $e');
      return false;
    }
  }

  /// List subfolders in a folder
  Future<List<InventoryFolder>> listSubfolders(List<String> folderPath) async {
    try {
      final dirPath = InventoryFolderUtils.buildFolderPath(basePath, folderPath);
      final dir = Directory(dirPath);
      if (!await dir.exists()) return [];

      final subfolders = <InventoryFolder>[];
      await for (final entity in dir.list()) {
        if (entity is Directory) {
          final name = entity.path.split('/').last;
          // Skip media and other special directories
          if (name.startsWith('.') || name == 'media' || name == 'templates') {
            continue;
          }
          final subFolderPath = [...folderPath, name];
          final metadata = await readFolderMetadata(subFolderPath);
          if (metadata != null) {
            subfolders.add(metadata);
          }
        }
      }
      return subfolders;
    } catch (e) {
      LogService().log('InventoryStorageService: Error listing subfolders: $e');
      return [];
    }
  }

  // ============ Item Operations ============

  /// Read an item from its JSON file
  Future<InventoryItem?> readItem(
    List<String> folderPath,
    String itemId,
  ) async {
    try {
      final itemPath = InventoryFolderUtils.buildItemPath(
        basePath,
        folderPath,
        itemId,
      );
      final file = File(itemPath);
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return InventoryItem.fromJson(json);
    } catch (e) {
      LogService().log('InventoryStorageService: Error reading item: $e');
      return null;
    }
  }

  /// Write an item to its JSON file
  Future<bool> writeItem(
    List<String> folderPath,
    InventoryItem item,
  ) async {
    try {
      final itemPath = InventoryFolderUtils.buildItemPath(
        basePath,
        folderPath,
        item.id,
      );
      final file = File(itemPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(item.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('InventoryStorageService: Error writing item: $e');
      return false;
    }
  }

  /// Delete an item file
  Future<bool> deleteItem(List<String> folderPath, String itemId) async {
    try {
      final itemPath = InventoryFolderUtils.buildItemPath(
        basePath,
        folderPath,
        itemId,
      );
      final file = File(itemPath);
      if (await file.exists()) {
        await file.delete();
      }
      return true;
    } catch (e) {
      LogService().log('InventoryStorageService: Error deleting item: $e');
      return false;
    }
  }

  /// List all items in a folder
  Future<List<InventoryItem>> listItems(List<String> folderPath) async {
    try {
      final dirPath = InventoryFolderUtils.buildFolderPath(basePath, folderPath);
      final dir = Directory(dirPath);
      if (!await dir.exists()) return [];

      final items = <InventoryItem>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          final name = entity.path.split('/').last;
          // Skip special files
          if (name.startsWith('_') || name == 'usage.json' || name == 'borrows.json') {
            continue;
          }
          final itemId = name.replaceAll('.json', '');
          final item = await readItem(folderPath, itemId);
          if (item != null) {
            items.add(item);
          }
        }
      }
      return items;
    } catch (e) {
      LogService().log('InventoryStorageService: Error listing items: $e');
      return [];
    }
  }

  // ============ Usage Operations ============

  /// Read usage events from usage.json
  Future<List<InventoryUsage>> readUsage(List<String> folderPath) async {
    try {
      final usagePath = InventoryFolderUtils.buildUsagePath(basePath, folderPath);
      final file = File(usagePath);
      if (!await file.exists()) return [];

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final events = json['events'] as List<dynamic>? ?? [];
      return events
          .map((e) => InventoryUsage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      LogService().log('InventoryStorageService: Error reading usage: $e');
      return [];
    }
  }

  /// Write usage events to usage.json
  Future<bool> writeUsage(
    List<String> folderPath,
    List<InventoryUsage> events,
  ) async {
    try {
      final usagePath = InventoryFolderUtils.buildUsagePath(basePath, folderPath);
      final file = File(usagePath);
      await file.parent.create(recursive: true);

      final json = {
        'version': '1.0',
        'events': events.map((e) => e.toJson()).toList(),
      };
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
      );
      return true;
    } catch (e) {
      LogService().log('InventoryStorageService: Error writing usage: $e');
      return false;
    }
  }

  /// Append a usage event
  Future<bool> appendUsage(
    List<String> folderPath,
    InventoryUsage event,
  ) async {
    final events = await readUsage(folderPath);
    events.add(event);
    return writeUsage(folderPath, events);
  }

  // ============ Borrow Operations ============

  /// Read borrows from borrows.json
  Future<List<InventoryBorrow>> readBorrows(List<String> folderPath) async {
    try {
      final borrowsPath = InventoryFolderUtils.buildBorrowsPath(basePath, folderPath);
      final file = File(borrowsPath);
      if (!await file.exists()) return [];

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final borrows = json['borrows'] as List<dynamic>? ?? [];
      return borrows
          .map((e) => InventoryBorrow.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      LogService().log('InventoryStorageService: Error reading borrows: $e');
      return [];
    }
  }

  /// Write borrows to borrows.json
  Future<bool> writeBorrows(
    List<String> folderPath,
    List<InventoryBorrow> borrows,
  ) async {
    try {
      final borrowsPath = InventoryFolderUtils.buildBorrowsPath(basePath, folderPath);
      final file = File(borrowsPath);
      await file.parent.create(recursive: true);

      final json = {
        'version': '1.0',
        'borrows': borrows.map((b) => b.toJson()).toList(),
      };
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
      );
      return true;
    } catch (e) {
      LogService().log('InventoryStorageService: Error writing borrows: $e');
      return false;
    }
  }

  // ============ Template Operations ============

  /// Read a template from its JSON file
  Future<InventoryTemplate?> readTemplate(String templateId) async {
    try {
      final templatePath = InventoryFolderUtils.buildTemplatePath(
        basePath,
        templateId,
      );
      final file = File(templatePath);
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return InventoryTemplate.fromJson(json);
    } catch (e) {
      LogService().log('InventoryStorageService: Error reading template: $e');
      return null;
    }
  }

  /// Write a template to its JSON file
  Future<bool> writeTemplate(InventoryTemplate template) async {
    try {
      final templatePath = InventoryFolderUtils.buildTemplatePath(
        basePath,
        template.id,
      );
      final file = File(templatePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(template.toJson()),
      );
      return true;
    } catch (e) {
      LogService().log('InventoryStorageService: Error writing template: $e');
      return false;
    }
  }

  /// Delete a template file
  Future<bool> deleteTemplate(String templateId) async {
    try {
      final templatePath = InventoryFolderUtils.buildTemplatePath(
        basePath,
        templateId,
      );
      final file = File(templatePath);
      if (await file.exists()) {
        await file.delete();
      }
      return true;
    } catch (e) {
      LogService().log('InventoryStorageService: Error deleting template: $e');
      return false;
    }
  }

  /// List all templates
  Future<List<InventoryTemplate>> listTemplates() async {
    try {
      final templatesPath = InventoryFolderUtils.buildTemplatesPath(basePath);
      final dir = Directory(templatesPath);
      if (!await dir.exists()) return [];

      final templates = <InventoryTemplate>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          final name = entity.path.split('/').last;
          final templateId = name.replaceAll('.json', '');
          final template = await readTemplate(templateId);
          if (template != null) {
            templates.add(template);
          }
        }
      }
      return templates;
    } catch (e) {
      LogService().log('InventoryStorageService: Error listing templates: $e');
      return [];
    }
  }

  // ============ Media Operations ============

  /// Copy a media file to the folder's media directory
  Future<String?> copyMediaFile(
    List<String> folderPath,
    String sourcePath,
    String filename,
  ) async {
    try {
      final mediaDir = InventoryFolderUtils.buildMediaPath(basePath, folderPath);
      await Directory(mediaDir).create(recursive: true);

      final targetPath = '$mediaDir/$filename';
      final sourceFile = File(sourcePath);
      await sourceFile.copy(targetPath);
      return filename;
    } catch (e) {
      LogService().log('InventoryStorageService: Error copying media file: $e');
      return null;
    }
  }

  /// Delete a media file from the folder's media directory
  Future<bool> deleteMediaFile(
    List<String> folderPath,
    String filename,
  ) async {
    try {
      final mediaDir = InventoryFolderUtils.buildMediaPath(basePath, folderPath);
      final file = File('$mediaDir/$filename');
      if (await file.exists()) {
        await file.delete();
      }
      return true;
    } catch (e) {
      LogService().log('InventoryStorageService: Error deleting media file: $e');
      return false;
    }
  }

  /// Get the full path to a media file
  String getMediaFilePath(List<String> folderPath, String filename) {
    final mediaDir = InventoryFolderUtils.buildMediaPath(basePath, folderPath);
    return '$mediaDir/$filename';
  }

  /// List all media files in a folder
  Future<List<String>> listMediaFiles(List<String> folderPath) async {
    try {
      final mediaDir = InventoryFolderUtils.buildMediaPath(basePath, folderPath);
      final dir = Directory(mediaDir);
      if (!await dir.exists()) return [];

      final files = <String>[];
      await for (final entity in dir.list()) {
        if (entity is File) {
          files.add(entity.path.split('/').last);
        }
      }
      return files;
    } catch (e) {
      LogService().log('InventoryStorageService: Error listing media files: $e');
      return [];
    }
  }

  // ============ Initialization ============

  /// Initialize the base inventory directory structure
  Future<bool> initialize() async {
    try {
      // Create base directory
      final baseDir = Directory(basePath);
      await baseDir.create(recursive: true);

      // Create templates directory
      final templatesDir = Directory(InventoryFolderUtils.buildTemplatesPath(basePath));
      await templatesDir.create(recursive: true);

      return true;
    } catch (e) {
      LogService().log('InventoryStorageService: Error initializing: $e');
      return false;
    }
  }

  /// Check if the inventory has been initialized
  Future<bool> isInitialized() async {
    try {
      final baseDir = Directory(basePath);
      return await baseDir.exists();
    } catch (e) {
      return false;
    }
  }
}
