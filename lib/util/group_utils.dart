/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Shared helpers for group identifiers and timestamps.
class GroupUtils {
  /// Normalize a group name into a directory-safe identifier.
  /// Keeps lowercase letters, numbers, underscores, and dashes.
  static String sanitizeGroupName(String input) {
    var sanitized = input.trim().toLowerCase();
    sanitized = sanitized.replaceAll(RegExp(r'[^a-z0-9_-]+'), '-');
    sanitized = sanitized.replaceAll(RegExp(r'-{2,}'), '-');
    sanitized = sanitized.replaceAll(RegExp(r'^-+|-+$'), '');

    if (sanitized.isEmpty) {
      sanitized = 'group';
    }

    if (sanitized.length > 64) {
      sanitized = sanitized.substring(0, 64).replaceAll(RegExp(r'-+$'), '');
    }

    return sanitized;
  }

}
