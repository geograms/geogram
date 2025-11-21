/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'blog_comment.dart';

/// News classification levels
enum NewsClassification {
  normal,
  urgent,
  danger;

  static NewsClassification fromString(String value) {
    return NewsClassification.values.firstWhere(
      (e) => e.name == value.toLowerCase(),
      orElse: () => NewsClassification.normal,
    );
  }
}

/// Model representing a news article with location awareness and classification
/// Supports multilanguage headlines and content
class NewsArticle {
  final String id; // Filename without extension
  final String author;
  final String timestamp; // Format: YYYY-MM-DD HH:MM:SS
  final Map<String, String> headlines; // Language code -> headline (e.g., 'en' -> 'Breaking News')
  final Map<String, String> contents; // Language code -> content (max 500 chars each)
  final NewsClassification classification;
  final double? latitude;
  final double? longitude;
  final String? address;
  final double? radiusKm; // 0.1 to 100
  final String? expiry; // Format: YYYY-MM-DD HH:MM:SS
  final String? source;
  final List<String> tags;
  final List<String> likes; // Callsigns who liked
  final List<BlogComment> comments; // Reuse BlogComment
  final Map<String, String> metadata;

  NewsArticle({
    required this.id,
    required this.author,
    required this.timestamp,
    required this.headlines,
    required this.contents,
    this.classification = NewsClassification.normal,
    this.latitude,
    this.longitude,
    this.address,
    this.radiusKm,
    this.expiry,
    this.source,
    this.tags = const [],
    this.likes = const [],
    this.comments = const [],
    this.metadata = const {},
  });

  /// Get headline in specific language with fallback
  /// Priority: requested lang -> 'en' -> first available
  String getHeadline([String? languageCode]) {
    if (headlines.isEmpty) return 'Untitled';

    final lang = languageCode ?? 'en';

    // Try requested language
    if (headlines.containsKey(lang)) {
      return headlines[lang]!;
    }

    // Try English
    if (headlines.containsKey('en')) {
      return headlines['en']!;
    }

    // Return first available
    return headlines.values.first;
  }

  /// Get content in specific language with fallback
  /// Priority: requested lang -> 'en' -> first available
  String getContent([String? languageCode]) {
    if (contents.isEmpty) return '';

    final lang = languageCode ?? 'en';

    // Try requested language
    if (contents.containsKey(lang)) {
      return contents[lang]!;
    }

    // Try English
    if (contents.containsKey('en')) {
      return contents['en']!;
    }

    // Return first available
    return contents.values.first;
  }

  /// Get list of available languages
  List<String> get availableLanguages {
    final langs = <String>{};
    langs.addAll(headlines.keys);
    langs.addAll(contents.keys);
    return langs.toList()..sort();
  }

  /// Check if a language is available
  bool hasLanguage(String languageCode) {
    return headlines.containsKey(languageCode) || contents.containsKey(languageCode);
  }

  /// Parse timestamp to DateTime
  DateTime get dateTime {
    try {
      final normalized = timestamp.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Parse expiry to DateTime
  DateTime? get expiryDateTime {
    if (expiry == null) return null;
    try {
      final normalized = expiry!.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return null;
    }
  }

  /// Check if article is expired
  bool get isExpired {
    final expiryDt = expiryDateTime;
    if (expiryDt == null) return false;
    return DateTime.now().isAfter(expiryDt);
  }

  /// Get display time (HH:MM)
  String get displayTime {
    final dt = dateTime;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  /// Get display date (YYYY-MM-DD)
  String get displayDate {
    final dt = dateTime;
    final year = dt.year.toString();
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// Get year from timestamp
  int get year => dateTime.year;

  /// Check if article has location
  bool get hasLocation => latitude != null && longitude != null;

  /// Check if article has radius (requires location)
  bool get hasRadius => hasLocation && radiusKm != null;

  /// Check if article has expiry
  bool get hasExpiry => expiry != null;

  /// Check if article has source attribution
  bool get hasSource => source != null && source!.isNotEmpty;

  /// Check if article is signed with NOSTR
  bool get isSigned => metadata.containsKey('signature');

  /// Get NOSTR public key
  String? get npub => metadata['npub'];

  /// Get signature
  String? get signature => metadata['signature'];

  /// Check if current user is the author (compare npub)
  bool isOwnArticle(String? currentUserNpub) {
    if (currentUserNpub == null || npub == null) return false;
    return npub == currentUserNpub;
  }

  /// Get comment count
  int get commentCount => comments.length;

  /// Get like count
  int get likeCount => likes.length;

  /// Check if user liked this article
  bool isLikedBy(String callsign) {
    return likes.contains(callsign);
  }

  /// Get classification color
  String get classificationColor {
    switch (classification) {
      case NewsClassification.danger:
        return 'red';
      case NewsClassification.urgent:
        return 'orange';
      case NewsClassification.normal:
      default:
        return 'blue';
    }
  }

  /// Export news article as text format for file storage
  String exportAsText() {
    final buffer = StringBuffer();

    // Headers - multiple headlines for each language
    // Sort languages for consistent output
    final sortedHeadlineLangs = headlines.keys.toList()..sort();
    for (var lang in sortedHeadlineLangs) {
      buffer.writeln('# HEADLINE_${lang.toUpperCase()}: ${headlines[lang]}');
    }

    buffer.writeln();
    buffer.writeln('AUTHOR: $author');
    buffer.writeln('PUBLISHED: $timestamp');
    buffer.writeln('CLASSIFICATION: ${classification.name}');

    // Location fields (optional)
    if (hasLocation) {
      buffer.writeln('LOCATION: $latitude,$longitude');
    }
    if (address != null && address!.isNotEmpty) {
      buffer.writeln('ADDRESS: $address');
    }
    if (hasRadius) {
      buffer.writeln('RADIUS: $radiusKm');
    }

    // Temporal fields
    if (expiry != null && expiry!.isNotEmpty) {
      buffer.writeln('EXPIRY: $expiry');
    }

    // Source attribution
    if (hasSource) {
      buffer.writeln('SOURCE: $source');
    }

    // Tags as metadata (before content)
    if (tags.isNotEmpty) {
      buffer.writeln('--> tags: ${tags.join(',')}');
    }

    // npub if present
    if (npub != null) {
      buffer.writeln('--> npub: $npub');
    }

    buffer.writeln();

    // Content - multiple language versions
    final sortedContentLangs = contents.keys.toList()..sort();
    for (var lang in sortedContentLangs) {
      buffer.writeln('[${lang.toUpperCase()}]');
      buffer.writeln(contents[lang]);
      buffer.writeln();
    }

    // File attachments (excluding signature and likes)
    final regularMetadata = Map<String, String>.from(metadata);
    regularMetadata.remove('tags');
    final sig = regularMetadata.remove('signature');

    for (var entry in regularMetadata.entries) {
      if (entry.key != 'icon_like') {
        buffer.writeln('--> ${entry.key}: ${entry.value}');
      }
    }

    // Signature must be last metadata if present
    if (sig != null) {
      buffer.writeln('--> signature: $sig');
    }

    // Likes
    if (likes.isNotEmpty) {
      buffer.writeln('--> icon_like: ${likes.join(',')}');
    }

    // Comments
    if (comments.isNotEmpty) {
      buffer.writeln();
      for (var comment in comments) {
        buffer.writeln(comment.exportAsText());
      }
    }

    return buffer.toString();
  }

  /// Parse news article from file text
  static NewsArticle fromText(String text, String articleId) {
    final lines = text.split('\n');
    if (lines.isEmpty) {
      throw Exception('Empty news article file');
    }

    // Parse headlines - can be multiple languages
    final Map<String, String> headlines = {};
    int currentLine = 0;

    while (currentLine < lines.length && lines[currentLine].startsWith('# HEADLINE')) {
      final line = lines[currentLine];

      if (line.contains('_')) {
        // New format: # HEADLINE_EN: Text
        final parts = line.substring(2).split(':');
        if (parts.length >= 2) {
          final langPart = parts[0].trim().substring(9); // Remove "HEADLINE_"
          final lang = langPart.toLowerCase();
          final headline = parts.sublist(1).join(':').trim();
          headlines[lang] = headline;
        }
      } else {
        // Old format: # HEADLINE: Text (assume English)
        final headline = line.substring(12).trim();
        headlines['en'] = headline;
      }

      currentLine++;
    }

    if (headlines.isEmpty) {
      throw Exception('Invalid news article - no headline found');
    }

    // Skip blank line
    if (currentLine < lines.length && lines[currentLine].trim().isEmpty) {
      currentLine++;
    }

    // AUTHOR line
    if (currentLine >= lines.length || !lines[currentLine].startsWith('AUTHOR: ')) {
      throw Exception('Invalid author line');
    }
    final author = lines[currentLine].substring(8).trim();
    currentLine++;

    // PUBLISHED line
    if (currentLine >= lines.length || !lines[currentLine].startsWith('PUBLISHED: ')) {
      throw Exception('Invalid published line');
    }
    final timestamp = lines[currentLine].substring(11).trim();
    currentLine++;

    // CLASSIFICATION line
    NewsClassification classification = NewsClassification.normal;
    if (currentLine < lines.length && lines[currentLine].startsWith('CLASSIFICATION: ')) {
      final classStr = lines[currentLine].substring(16).trim();
      classification = NewsClassification.fromString(classStr);
      currentLine++;
    }

    // Optional location fields
    double? latitude;
    double? longitude;
    String? address;
    double? radiusKm;
    String? expiry;
    String? source;

    while (currentLine < lines.length && lines[currentLine].isNotEmpty && !lines[currentLine].startsWith('-->')) {
      final line = lines[currentLine];

      if (line.startsWith('LOCATION: ')) {
        final coords = line.substring(10).trim().split(',');
        if (coords.length == 2) {
          latitude = double.tryParse(coords[0].trim());
          longitude = double.tryParse(coords[1].trim());
        }
      } else if (line.startsWith('ADDRESS: ')) {
        address = line.substring(9).trim();
      } else if (line.startsWith('RADIUS: ')) {
        radiusKm = double.tryParse(line.substring(8).trim());
      } else if (line.startsWith('EXPIRY: ')) {
        expiry = line.substring(8).trim();
      } else if (line.startsWith('SOURCE: ')) {
        source = line.substring(8).trim();
      }

      currentLine++;
    }

    // Parse metadata before blank line (tags, npub)
    final Map<String, String> metadata = {};
    final List<String> tags = [];
    final List<String> likes = [];

    while (currentLine < lines.length &&
        lines[currentLine].trim().isNotEmpty &&
        lines[currentLine].startsWith('-->')) {
      final metaLine = lines[currentLine].substring(3).trim();
      final colonIndex = metaLine.indexOf(':');
      if (colonIndex > 0) {
        final key = metaLine.substring(0, colonIndex).trim();
        final value = metaLine.substring(colonIndex + 1).trim();

        if (key == 'tags') {
          tags.addAll(value.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty));
        } else if (key == 'icon_like') {
          likes.addAll(value.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty));
        } else {
          metadata[key] = value;
        }
      }
      currentLine++;
    }

    // Skip blank line
    if (currentLine < lines.length && lines[currentLine].trim().isEmpty) {
      currentLine++;
    }

    // Parse content and comments
    final Map<String, String> contents = {};
    final comments = <BlogComment>[];
    String? currentLang;
    final currentContentLines = <String>[];

    while (currentLine < lines.length) {
      final line = lines[currentLine];

      // Check for language block marker [EN], [PT], etc.
      if (line.trim().startsWith('[') && line.trim().endsWith(']')) {
        // Save previous language content if any
        if (currentLang != null && currentContentLines.isNotEmpty) {
          final content = currentContentLines.join('\n').trim();
          if (content.isNotEmpty) {
            contents[currentLang] = content;
          }
          currentContentLines.clear();
        }

        // Extract new language code
        final langCode = line.trim().substring(1, line.trim().length - 1).toLowerCase();
        currentLang = langCode;
        currentLine++;
        continue;
      }

      // Check if this is a comment (starts with "> 2" for year 2xxx)
      if (line.startsWith('> 2')) {
        // Save any remaining content
        if (currentLang != null && currentContentLines.isNotEmpty) {
          final content = currentContentLines.join('\n').trim();
          if (content.isNotEmpty) {
            contents[currentLang] = content;
          }
          currentContentLines.clear();
        }

        // Parse comment
        final comment = _parseComment(lines, currentLine);
        comments.add(comment);

        // Skip to next comment or end
        currentLine++;
        while (currentLine < lines.length && !lines[currentLine].startsWith('> 2')) {
          currentLine++;
        }
        continue;
      } else if (line.startsWith('-->')) {
        // Save any remaining content first
        if (currentLang != null && currentContentLines.isNotEmpty) {
          final content = currentContentLines.join('\n').trim();
          if (content.isNotEmpty) {
            contents[currentLang] = content;
          }
          currentContentLines.clear();
        }

        // Metadata for article content
        final metaLine = line.substring(3).trim();
        final colonIndex = metaLine.indexOf(':');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex).trim();
          final value = metaLine.substring(colonIndex + 1).trim();

          if (key == 'icon_like') {
            likes.clear();
            likes.addAll(value.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty));
          } else {
            metadata[key] = value;
          }
        }
        currentLine++;
      } else {
        // Content line - add to current language block
        if (currentLang != null) {
          currentContentLines.add(line);
        } else {
          // Old format without language tags - assume English
          if (currentLang == null) {
            currentLang = 'en';
          }
          currentContentLines.add(line);
        }
        currentLine++;
      }
    }

    // Save final language content if any
    if (currentLang != null && currentContentLines.isNotEmpty) {
      final content = currentContentLines.join('\n').trim();
      if (content.isNotEmpty) {
        contents[currentLang] = content;
      }
    }

    // If no content blocks found, create empty map
    if (contents.isEmpty) {
      contents['en'] = '';
    }

    return NewsArticle(
      id: articleId,
      author: author,
      timestamp: timestamp,
      headlines: headlines,
      contents: contents,
      classification: classification,
      latitude: latitude,
      longitude: longitude,
      address: address,
      radiusKm: radiusKm,
      expiry: expiry,
      source: source,
      tags: tags,
      likes: likes,
      comments: comments,
      metadata: metadata,
    );
  }

  /// Parse a single comment from lines starting at index
  static BlogComment _parseComment(List<String> lines, int startIndex) {
    // Line format: > YYYY-MM-DD HH:MM:SS -- AUTHOR
    final headerLine = lines[startIndex];
    final parts = headerLine.substring(2).split(' -- ');
    if (parts.length < 2) {
      throw Exception('Invalid comment header');
    }

    final timestamp = parts[0].trim();
    final author = parts[1].trim();

    // Parse comment content and metadata
    final contentLines = <String>[];
    final Map<String, String> metadata = {};
    int i = startIndex + 1;

    while (i < lines.length && !lines[i].startsWith('> 2')) {
      final line = lines[i];

      if (line.startsWith('-->')) {
        // Metadata
        final metaLine = line.substring(3).trim();
        final colonIndex = metaLine.indexOf(':');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex).trim();
          final value = metaLine.substring(colonIndex + 1).trim();
          metadata[key] = value;
        }
      } else if (line.trim().isEmpty && contentLines.isEmpty) {
        // Skip leading blank lines
      } else {
        contentLines.add(line);
      }
      i++;
    }

    // Remove trailing empty lines and metadata lines from content
    while (contentLines.isNotEmpty &&
           (contentLines.last.trim().isEmpty || contentLines.last.startsWith('-->'))) {
      contentLines.removeLast();
    }

    final content = contentLines.join('\n').trim();

    return BlogComment(
      author: author,
      timestamp: timestamp,
      content: content,
      metadata: metadata,
    );
  }

  /// Create a copy with updated fields
  NewsArticle copyWith({
    String? id,
    String? author,
    String? timestamp,
    Map<String, String>? headlines,
    Map<String, String>? contents,
    NewsClassification? classification,
    double? latitude,
    double? longitude,
    String? address,
    double? radiusKm,
    String? expiry,
    String? source,
    List<String>? tags,
    List<String>? likes,
    List<BlogComment>? comments,
    Map<String, String>? metadata,
  }) {
    return NewsArticle(
      id: id ?? this.id,
      author: author ?? this.author,
      timestamp: timestamp ?? this.timestamp,
      headlines: headlines ?? this.headlines,
      contents: contents ?? this.contents,
      classification: classification ?? this.classification,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      address: address ?? this.address,
      radiusKm: radiusKm ?? this.radiusKm,
      expiry: expiry ?? this.expiry,
      source: source ?? this.source,
      tags: tags ?? this.tags,
      likes: likes ?? this.likes,
      comments: comments ?? this.comments,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  String toString() {
    return 'NewsArticle(id: $id, headline: ${getHeadline()}, author: $author, classification: ${classification.name}, expired: $isExpired, languages: ${availableLanguages.join(', ')})';
  }
}
