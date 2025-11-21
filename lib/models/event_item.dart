/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'event_reaction.dart';

/// Type of event item
enum EventItemType {
  file,
  image,
  video,
  document,
  folder,
  dayFolder,
  contributorFolder,
}

/// Model representing an item in an event (file, folder, etc.)
class EventItem {
  final String name;
  final String path;
  final EventItemType type;
  final EventReaction? reaction;
  final List<EventItem>? children; // For folders

  EventItem({
    required this.name,
    required this.path,
    required this.type,
    this.reaction,
    this.children,
  });

  /// Check if item is a folder
  bool get isFolder => type == EventItemType.folder ||
                       type == EventItemType.dayFolder ||
                       type == EventItemType.contributorFolder;

  /// Check if item is a file
  bool get isFile => !isFolder;

  /// Check if item is an image
  bool get isImage => type == EventItemType.image;

  /// Check if item is a video
  bool get isVideo => type == EventItemType.video;

  /// Check if item is a document
  bool get isDocument => type == EventItemType.document;

  /// Get file extension
  String? get extension {
    if (isFolder) return null;
    final parts = name.split('.');
    if (parts.length > 1) {
      return parts.last.toLowerCase();
    }
    return null;
  }

  /// Determine item type from file extension
  static EventItemType getTypeFromExtension(String filename) {
    final ext = filename.split('.').last.toLowerCase();

    // Image extensions
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg'].contains(ext)) {
      return EventItemType.image;
    }

    // Video extensions
    if (['mp4', 'avi', 'mov', 'mkv', 'webm', 'flv'].contains(ext)) {
      return EventItemType.video;
    }

    // Document extensions
    if (['pdf', 'doc', 'docx', 'txt', 'md', 'xls', 'xlsx', 'ppt', 'pptx'].contains(ext)) {
      return EventItemType.document;
    }

    return EventItemType.file;
  }

  /// Get like count from reaction
  int get likeCount => reaction?.likeCount ?? 0;

  /// Get comment count from reaction
  int get commentCount => reaction?.commentCount ?? 0;

  /// Check if user has liked
  bool hasUserLiked(String callsign) {
    return reaction?.hasUserLiked(callsign) ?? false;
  }

  /// Create a copy with updated fields
  EventItem copyWith({
    String? name,
    String? path,
    EventItemType? type,
    EventReaction? reaction,
    List<EventItem>? children,
  }) {
    return EventItem(
      name: name ?? this.name,
      path: path ?? this.path,
      type: type ?? this.type,
      reaction: reaction ?? this.reaction,
      children: children ?? this.children,
    );
  }

  @override
  String toString() {
    return 'EventItem(name: $name, type: $type, likes: $likeCount, comments: $commentCount)';
  }
}
