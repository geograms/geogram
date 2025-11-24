/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Model representing an update to a report
class ReportUpdate {
  final String fileName;
  final String timestamp;
  final String author;
  final String title;
  final String content;
  final Map<String, String> metadata;

  ReportUpdate({
    required this.fileName,
    required this.timestamp,
    required this.author,
    required this.title,
    required this.content,
    this.metadata = const {},
  });

  /// Parse timestamp to DateTime
  DateTime get dateTime {
    try {
      final normalized = timestamp.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Get NOSTR public key
  String? get npub => metadata['npub'];

  /// Get signature
  String? get signature => metadata['signature'];

  /// Check if update is signed with NOSTR
  bool get isSigned => metadata.containsKey('signature');

  /// Parse update from text
  static ReportUpdate fromText(String text, String fileName) {
    final lines = text.split('\n');
    if (lines.isEmpty) {
      throw Exception('Empty update file');
    }

    String? title;
    String? timestamp;
    String? author;
    Map<String, String> metadata = {};
    final contentLines = <String>[];
    bool inContent = false;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (line.startsWith('# UPDATE: ')) {
        title = line.substring(10).trim();
      } else if (line.startsWith('TIMESTAMP: ')) {
        timestamp = line.substring(11).trim();
      } else if (line.startsWith('AUTHOR: ')) {
        author = line.substring(8).trim();
      } else if (line.startsWith('-->')) {
        final metaLine = line.substring(3).trim();
        final colonIndex = metaLine.indexOf(':');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex).trim();
          final value = metaLine.substring(colonIndex + 1).trim();
          metadata[key] = value;
        }
      } else if (line.trim().isEmpty && !inContent && title != null) {
        inContent = true;
      } else if (inContent && !line.startsWith('-->')) {
        contentLines.add(line);
      }
    }

    if (title == null || timestamp == null || author == null) {
      throw Exception('Missing required update fields');
    }

    return ReportUpdate(
      fileName: fileName,
      timestamp: timestamp,
      author: author,
      title: title,
      content: contentLines.join('\n').trim(),
      metadata: metadata,
    );
  }

  /// Export update as text
  String exportAsText() {
    final buffer = StringBuffer();

    buffer.writeln('# UPDATE: $title');
    buffer.writeln();
    buffer.writeln('TIMESTAMP: $timestamp');
    buffer.writeln('AUTHOR: $author');
    buffer.writeln();
    buffer.writeln(content);
    buffer.writeln();

    final regularMetadata = Map<String, String>.from(metadata);
    final sig = regularMetadata.remove('signature');

    for (var entry in regularMetadata.entries) {
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    if (sig != null) {
      buffer.writeln('--> signature: $sig');
    }

    return buffer.toString();
  }

  @override
  String toString() {
    return 'ReportUpdate(title: $title, timestamp: $timestamp)';
  }
}
