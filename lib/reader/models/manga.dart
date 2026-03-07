/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Status of a manga series
enum MangaStatus {
  ongoing,
  completed,
  hiatus,
  cancelled,
}

/// A manga series
class Manga {
  final String id;
  final String title;
  final String? originalTitle;
  final String? author;
  final String? artist;
  final String description;
  final MangaStatus status;
  final List<String> genres;
  final List<String> tags;
  final int? year;
  final String? language;
  final String thumbnail;
  final String? sourceUrl;
  final String? sourceId;
  final DateTime createdAt;
  final DateTime modifiedAt;

  Manga({
    required this.id,
    required this.title,
    this.originalTitle,
    this.author,
    this.artist,
    required this.description,
    this.status = MangaStatus.ongoing,
    List<String>? genres,
    List<String>? tags,
    this.year,
    this.language,
    required this.thumbnail,
    this.sourceUrl,
    this.sourceId,
    DateTime? createdAt,
    DateTime? modifiedAt,
  })  : genres = genres ?? [],
        tags = tags ?? [],
        createdAt = createdAt ?? DateTime.now(),
        modifiedAt = modifiedAt ?? DateTime.now();

  factory Manga.fromJson(Map<String, dynamic> json) {
    return Manga(
      id: json['id'] as String,
      title: json['title'] as String,
      originalTitle: json['original_title'] as String?,
      author: json['author'] as String?,
      artist: json['artist'] as String?,
      description: json['description'] as String? ?? '',
      status: MangaStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => MangaStatus.ongoing,
      ),
      genres: (json['genres'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ??
              [],
      year: json['year'] as int?,
      language: json['language'] as String?,
      thumbnail: json['thumbnail'] as String,
      sourceUrl: json['source_url'] as String?,
      sourceId: json['source_id'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      modifiedAt: json['modified_at'] != null
          ? DateTime.parse(json['modified_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'original_title': originalTitle,
      'author': author,
      'artist': artist,
      'description': description,
      'status': status.name,
      'genres': genres,
      'tags': tags,
      'year': year,
      'language': language,
      'thumbnail': thumbnail,
      'source_url': sourceUrl,
      'source_id': sourceId,
      'created_at': createdAt.toIso8601String(),
      'modified_at': modifiedAt.toIso8601String(),
    };
  }

  Manga copyWith({
    String? id,
    String? title,
    String? originalTitle,
    String? author,
    String? artist,
    String? description,
    MangaStatus? status,
    List<String>? genres,
    List<String>? tags,
    int? year,
    String? language,
    String? thumbnail,
    String? sourceUrl,
    String? sourceId,
    DateTime? createdAt,
    DateTime? modifiedAt,
  }) {
    return Manga(
      id: id ?? this.id,
      title: title ?? this.title,
      originalTitle: originalTitle ?? this.originalTitle,
      author: author ?? this.author,
      artist: artist ?? this.artist,
      description: description ?? this.description,
      status: status ?? this.status,
      genres: genres ?? this.genres,
      tags: tags ?? this.tags,
      year: year ?? this.year,
      language: language ?? this.language,
      thumbnail: thumbnail ?? this.thumbnail,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      sourceId: sourceId ?? this.sourceId,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
    );
  }
}

/// A manga chapter (CBZ file)
class MangaChapter {
  final String filename;
  final double? number;
  final String? title;
  final int? volume;
  final int? pages;

  MangaChapter({
    required this.filename,
    this.number,
    this.title,
    this.volume,
    this.pages,
  });

  /// Parse chapter number from filename
  /// Supports patterns like:
  /// - chapter-001.cbz -> 1.0
  /// - ch-1.5.cbz -> 1.5
  /// - vol-01-ch-010.cbz -> 10.0
  /// - chapmanganato.to_Vol.1 Chapter 1_ To You, 2,000 Years From Now.cbz
  factory MangaChapter.fromFilename(String filename) {
    double? number;
    String? title;
    int? volume;

    // Strip .cbz extension for parsing
    final baseName = filename.replaceAll(RegExp(r'\.cbz$', caseSensitive: false), '');

    // Try Mangakakalot-style: site_Vol.N Chapter N_ Title
    // Also handles: site_Chapter N_ Title (no volume)
    final mangakakalotMatch = RegExp(
      r'(?:.*?_)?Vol\.?\s*(\d+)\s+Chapter\s+(\d+(?:\.\d+)?)(?:[_:]\s*(.+))?',
      caseSensitive: false,
    ).firstMatch(baseName);
    if (mangakakalotMatch != null) {
      volume = int.tryParse(mangakakalotMatch.group(1)!);
      number = double.tryParse(mangakakalotMatch.group(2)!);
      title = mangakakalotMatch.group(3)?.trim();
      return MangaChapter(
        filename: filename,
        number: number,
        title: title,
        volume: volume,
      );
    }

    // Try: site_Chapter N_ Title (no volume)
    final chapterTitleMatch = RegExp(
      r'(?:.*?_)?Chapter\s+(\d+(?:\.\d+)?)(?:[_:]\s*(.+))?',
      caseSensitive: false,
    ).firstMatch(baseName);
    if (chapterTitleMatch != null) {
      number = double.tryParse(chapterTitleMatch.group(1)!);
      title = chapterTitleMatch.group(2)?.trim();
      return MangaChapter(
        filename: filename,
        number: number,
        title: title,
        volume: volume,
      );
    }

    // Try to extract chapter number (original patterns)
    final chapterMatch = RegExp(r'(?:ch(?:apter)?[-_]?)(\d+(?:\.\d+)?)',
            caseSensitive: false)
        .firstMatch(baseName);
    if (chapterMatch != null) {
      number = double.tryParse(chapterMatch.group(1)!);
    }

    // Try to extract volume
    final volumeMatch =
        RegExp(r'vol(?:ume)?[-_.]?(\d+)', caseSensitive: false).firstMatch(baseName);
    if (volumeMatch != null) {
      volume = int.tryParse(volumeMatch.group(1)!);
    }

    return MangaChapter(
      filename: filename,
      number: number,
      title: title,
      volume: volume,
    );
  }

  /// Compare chapters for sorting
  int compareTo(MangaChapter other) {
    // Sort by volume first if both have volumes
    if (volume != null && other.volume != null) {
      final volumeCompare = volume!.compareTo(other.volume!);
      if (volumeCompare != 0) return volumeCompare;
    }

    // Then by chapter number
    if (number != null && other.number != null) {
      return number!.compareTo(other.number!);
    }

    // Fallback to filename comparison
    return filename.compareTo(other.filename);
  }

  String get displayName {
    if (title != null && title!.isNotEmpty) {
      if (number != null) {
        return 'Chapter ${number!.toStringAsFixed(number! % 1 == 0 ? 0 : 1)}: $title';
      }
      return title!;
    }
    if (number != null) {
      final numStr = number!.toStringAsFixed(number! % 1 == 0 ? 0 : 1);
      if (volume != null) {
        return 'Vol. $volume - Chapter $numStr';
      }
      return 'Chapter $numStr';
    }
    // Strip extension and clean up
    return filename.replaceAll('.cbz', '').replaceAll('-', ' ').trim();
  }
}

/// Per-chapter reading state stored in manga_meta.json
class ChapterReadState {
  bool read;
  int currentPage;
  int totalPages;
  DateTime? lastReadAt;

  ChapterReadState({
    this.read = false,
    this.currentPage = 0,
    this.totalPages = 0,
    this.lastReadAt,
  });

  factory ChapterReadState.fromJson(Map<String, dynamic> json) {
    return ChapterReadState(
      read: json['read'] as bool? ?? false,
      currentPage: json['current_page'] as int? ?? 0,
      totalPages: json['total_pages'] as int? ?? 0,
      lastReadAt: json['last_read_at'] != null
          ? DateTime.tryParse(json['last_read_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'read': read,
      'current_page': currentPage,
      'total_pages': totalPages,
      if (lastReadAt != null) 'last_read_at': lastReadAt!.toIso8601String(),
    };
  }
}

/// Series metadata stored as manga_meta.json alongside CBZ files
class SeriesMeta {
  static const String filename = 'manga_meta.json';

  String title;
  String description;
  List<String> tags;
  String? thumbnail;
  final Map<String, ChapterReadState> chapters;

  SeriesMeta({
    this.title = '',
    this.description = '',
    List<String>? tags,
    this.thumbnail,
    Map<String, ChapterReadState>? chapters,
  })  : tags = tags ?? [],
        chapters = chapters ?? {};

  factory SeriesMeta.fromJson(Map<String, dynamic> json) {
    return SeriesMeta(
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      tags: (json['tags'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      thumbnail: json['thumbnail'] as String?,
      chapters: (json['chapters'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(
                k, ChapterReadState.fromJson(v as Map<String, dynamic>)),
          ) ??
          {},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'description': description,
      'tags': tags,
      if (thumbnail != null) 'thumbnail': thumbnail,
      'chapters': chapters.map((k, v) => MapEntry(k, v.toJson())),
    };
  }

  bool isChapterRead(String chapterFilename) {
    return chapters[chapterFilename]?.read ?? false;
  }

  ChapterReadState getOrCreate(String chapterFilename) {
    return chapters.putIfAbsent(chapterFilename, () => ChapterReadState());
  }

  int get readCount => chapters.values.where((c) => c.read).length;
}

/// Result from manga search
class MangaSearchResult {
  final String id;
  final String title;
  final String? thumbnail;
  final String? description;
  final String? author;
  final MangaStatus? status;
  final int? year;

  MangaSearchResult({
    required this.id,
    required this.title,
    this.thumbnail,
    this.description,
    this.author,
    this.status,
    this.year,
  });

  factory MangaSearchResult.fromJson(Map<String, dynamic> json) {
    return MangaSearchResult(
      id: json['id'] as String,
      title: json['title'] as String,
      thumbnail: json['thumbnail'] as String?,
      description: json['description'] as String?,
      author: json['author'] as String?,
      status: json['status'] != null
          ? MangaStatus.values.firstWhere(
              (s) => s.name == json['status'],
              orElse: () => MangaStatus.ongoing,
            )
          : null,
      year: json['year'] as int?,
    );
  }
}

/// Result from chapter list
class ChapterInfo {
  final String id;
  final double number;
  final String? title;
  final int? volume;
  final int? pages;

  ChapterInfo({
    required this.id,
    required this.number,
    this.title,
    this.volume,
    this.pages,
  });

  factory ChapterInfo.fromJson(Map<String, dynamic> json) {
    return ChapterInfo(
      id: json['id'] as String,
      number: (json['number'] as num).toDouble(),
      title: json['title'] as String?,
      volume: json['volume'] as int?,
      pages: json['pages'] as int?,
    );
  }
}
