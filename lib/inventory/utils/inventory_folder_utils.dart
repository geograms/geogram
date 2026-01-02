/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:math';

/// Utility functions for inventory folder and file path management
class InventoryFolderUtils {
  InventoryFolderUtils._();

  /// Sanitize a string for use as a folder name
  ///
  /// Removes or replaces characters that are invalid in file paths
  static String sanitizeForFolderName(String name) {
    // Replace invalid characters with underscores
    String sanitized = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    // Replace multiple underscores with single
    sanitized = sanitized.replaceAll(RegExp(r'_+'), '_');
    // Trim underscores from start/end
    sanitized = sanitized.trim();
    if (sanitized.startsWith('_')) {
      sanitized = sanitized.substring(1);
    }
    if (sanitized.endsWith('_')) {
      sanitized = sanitized.substring(0, sanitized.length - 1);
    }
    // Convert to lowercase for consistency
    sanitized = sanitized.toLowerCase();
    // Limit length
    if (sanitized.length > 50) {
      sanitized = sanitized.substring(0, 50);
    }
    // Fallback for empty names
    if (sanitized.isEmpty) {
      sanitized = 'folder';
    }
    return sanitized;
  }

  /// Build the path to a folder within the inventory
  ///
  /// [basePath] - The base inventory collection path
  /// [folderPath] - List of folder IDs from root to target folder
  static String buildFolderPath(String basePath, List<String> folderPath) {
    if (folderPath.isEmpty) {
      return basePath;
    }
    return '$basePath/${folderPath.join('/')}';
  }

  /// Build the path to an item's JSON file
  ///
  /// [basePath] - The base inventory collection path
  /// [folderPath] - List of folder IDs from root to the folder containing the item
  /// [itemId] - The item's unique ID
  static String buildItemPath(
    String basePath,
    List<String> folderPath,
    String itemId,
  ) {
    final folderDir = buildFolderPath(basePath, folderPath);
    return '$folderDir/$itemId.json';
  }

  /// Build the path to the media directory for a folder
  ///
  /// [basePath] - The base inventory collection path
  /// [folderPath] - List of folder IDs from root to target folder
  static String buildMediaPath(String basePath, List<String> folderPath) {
    final folderDir = buildFolderPath(basePath, folderPath);
    return '$folderDir/media';
  }

  /// Build the path to the folder metadata file
  ///
  /// [basePath] - The base inventory collection path
  /// [folderPath] - List of folder IDs from root to target folder
  static String buildFolderMetadataPath(
    String basePath,
    List<String> folderPath,
  ) {
    final folderDir = buildFolderPath(basePath, folderPath);
    return '$folderDir/_folder.json';
  }

  /// Build the path to the usage log file for a folder
  ///
  /// [basePath] - The base inventory collection path
  /// [folderPath] - List of folder IDs from root to target folder
  static String buildUsagePath(String basePath, List<String> folderPath) {
    final folderDir = buildFolderPath(basePath, folderPath);
    return '$folderDir/usage.json';
  }

  /// Build the path to the borrows log file for a folder
  ///
  /// [basePath] - The base inventory collection path
  /// [folderPath] - List of folder IDs from root to target folder
  static String buildBorrowsPath(String basePath, List<String> folderPath) {
    final folderDir = buildFolderPath(basePath, folderPath);
    return '$folderDir/borrows.json';
  }

  /// Build the path to the templates directory
  ///
  /// [basePath] - The base inventory collection path
  static String buildTemplatesPath(String basePath) {
    return '$basePath/templates';
  }

  /// Build the path to a specific template file
  ///
  /// [basePath] - The base inventory collection path
  /// [templateId] - The template's unique ID
  static String buildTemplatePath(String basePath, String templateId) {
    return '$basePath/templates/$templateId.json';
  }

  /// Generate a unique item ID
  ///
  /// Format: item_YYYYMMDD_HHMMSS_XXXX where X is random hex
  static String generateItemId() {
    final now = DateTime.now();
    final datePart =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final timePart =
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final randomPart = _generateRandomHex(4);
    return 'item_${datePart}_${timePart}_$randomPart';
  }

  /// Generate a unique folder ID
  ///
  /// Format: folder_YYYYMMDD_XXXX where X is random hex
  static String generateFolderId() {
    final now = DateTime.now();
    final datePart =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final randomPart = _generateRandomHex(4);
    return 'folder_${datePart}_$randomPart';
  }

  /// Generate a unique batch ID
  ///
  /// Format: batch_YYYYMMDD_XXXX where X is random hex
  static String generateBatchId() {
    final now = DateTime.now();
    final datePart =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final randomPart = _generateRandomHex(4);
    return 'batch_${datePart}_$randomPart';
  }

  /// Generate a unique borrow ID
  ///
  /// Format: borrow_YYYYMMDD_XXXX where X is random hex
  static String generateBorrowId() {
    final now = DateTime.now();
    final datePart =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final randomPart = _generateRandomHex(4);
    return 'borrow_${datePart}_$randomPart';
  }

  /// Generate a unique usage ID
  ///
  /// Format: usage_YYYYMMDD_HHMMSS_XXXX where X is random hex
  static String generateUsageId() {
    final now = DateTime.now();
    final datePart =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final timePart =
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final randomPart = _generateRandomHex(4);
    return 'usage_${datePart}_${timePart}_$randomPart';
  }

  /// Generate a unique template ID
  ///
  /// Format: template_YYYYMMDD_XXXX where X is random hex
  static String generateTemplateId() {
    final now = DateTime.now();
    final datePart =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final randomPart = _generateRandomHex(4);
    return 'template_${datePart}_$randomPart';
  }

  /// Generate a random hex string of the given length
  static String _generateRandomHex(int length) {
    final random = Random.secure();
    final bytes = List.generate(length, (_) => random.nextInt(16));
    return bytes.map((b) => b.toRadixString(16)).join();
  }

  /// Validate that a folder depth is within limits
  static bool isValidFolderDepth(int depth) {
    return depth >= 0 && depth <= 5;
  }

  /// Validate that a folder name is valid
  static bool isValidFolderName(String name) {
    if (name.isEmpty || name.length > 100) return false;
    // Check for invalid characters
    if (name.contains(RegExp(r'[<>:"/\\|?*]'))) return false;
    // Check for reserved names
    if (name == '.' || name == '..' || name == '_folder') return false;
    return true;
  }

  /// Parse a folder path string into a list of folder IDs
  static List<String> parseFolderPath(String pathString) {
    if (pathString.isEmpty) return [];
    return pathString.split('/').where((s) => s.isNotEmpty).toList();
  }

  /// Join a list of folder IDs into a path string
  static String joinFolderPath(List<String> folderPath) {
    return folderPath.join('/');
  }

  /// Get the parent folder path from a folder path
  static List<String> getParentPath(List<String> folderPath) {
    if (folderPath.isEmpty) return [];
    return folderPath.sublist(0, folderPath.length - 1);
  }

  /// Get the folder ID from a folder path
  static String? getFolderId(List<String> folderPath) {
    if (folderPath.isEmpty) return null;
    return folderPath.last;
  }

  /// Check if a path is a child of another path
  static bool isChildOf(List<String> childPath, List<String> parentPath) {
    if (childPath.length <= parentPath.length) return false;
    for (int i = 0; i < parentPath.length; i++) {
      if (childPath[i] != parentPath[i]) return false;
    }
    return true;
  }

  /// Get the relative path from parent to child
  static List<String> getRelativePath(
    List<String> childPath,
    List<String> parentPath,
  ) {
    if (!isChildOf(childPath, parentPath) && childPath != parentPath) {
      return childPath;
    }
    return childPath.sublist(parentPath.length);
  }
}
