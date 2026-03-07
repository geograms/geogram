/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';

import '../models/manga_extension.dart';
import '../models/manga.dart';
import 'manga_scraper.dart';
import '../../services/log_service.dart';

/// Service for managing manga extensions and orchestrating scraping
class MangaExtensionService {
  static final MangaExtensionService _instance =
      MangaExtensionService._internal();
  factory MangaExtensionService() => _instance;
  MangaExtensionService._internal();

  final _scraper = MangaScraper();
  final Map<String, MangaExtension> _extensions = {};
  final Map<String, Map<String, String>> _cookies = {};
  String? _extensionsDir;

  /// Whether extensions have been loaded
  bool get isInitialized => _extensionsDir != null;

  /// Get all loaded extensions
  List<MangaExtension> get extensions => _extensions.values.toList();

  /// Initialize with the extensions directory path
  Future<void> initialize(String extensionsDir) async {
    _extensionsDir = extensionsDir;
    await loadExtensions();
  }

  /// Load all extensions from the extensions directory
  Future<void> loadExtensions() async {
    if (_extensionsDir == null) return;
    _extensions.clear();

    final dir = Directory(_extensionsDir!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // Auto-install bundled extensions if none exist on disk
    bool hasAny = false;
    await for (final entity in dir.list()) {
      if (entity is Directory) {
        hasAny = true;
        break;
      }
    }
    if (!hasAny) {
      await _installBundledExtensions();
    }

    // Load all extensions from disk
    await for (final entity in dir.list()) {
      if (entity is Directory) {
        try {
          final manifestFile = File('${entity.path}/extension.json');
          if (await manifestFile.exists()) {
            final content = await manifestFile.readAsString();
            final json = jsonDecode(content) as Map<String, dynamic>;
            final ext = MangaExtension.fromJson(json);
            _extensions[ext.id] = ext;

            // Load cached cookies
            await _loadCookies(ext.id, entity.path);
          }
        } catch (e) {
          LogService().log(
              'MangaExtensionService: Error loading extension from ${entity.path}: $e');
        }
      }
    }

    LogService()
        .log('MangaExtensionService: Loaded ${_extensions.length} extensions');
  }

  /// Get a specific extension by ID
  MangaExtension? getExtension(String id) => _extensions[id];

  /// Search for manga using a specific extension
  Future<List<MangaSearchResult>> search(
      String extensionId, String query) async {
    final ext = _extensions[extensionId];
    if (ext == null) throw Exception('Extension not found: $extensionId');

    final vars = {
      'base_url': ext.baseUrl,
      'query': _encodeQuery(query),
    };

    final results = await _scraper.scrape(
      config: ext.search,
      vars: vars,
      headers: _scraper.resolveHeaders(ext.headers, vars),
      cookies: _cookies[extensionId] ?? {},
      extensionId: extensionId,
      rateLimitMs: ext.rateLimitMs,
    );

    return results.map((r) {
      return MangaSearchResult(
        id: r['id'] as String? ?? '',
        title: r['title'] as String? ?? '',
        thumbnail: r['thumbnail'] as String?,
        description: r['description'] as String?,
      );
    }).where((r) => r.id.isNotEmpty && r.title.isNotEmpty).toList();
  }

  /// Search across all extensions for a manga by name
  Future<List<ExtensionSearchResult>> searchAllExtensions(String query) async {
    final results = <ExtensionSearchResult>[];

    for (final ext in _extensions.values) {
      try {
        final searchResults = await search(ext.id, query);
        for (final result in searchResults) {
          results.add(ExtensionSearchResult(
            extensionId: ext.id,
            result: result,
          ));
        }
      } catch (e) {
        LogService().log(
            'MangaExtensionService: Search failed for extension ${ext.id}: $e');
      }
    }

    return results;
  }

  /// Get chapter list for a manga from a specific extension
  Future<List<ChapterInfo>> listChapters(
      String extensionId, String mangaId) async {
    final ext = _extensions[extensionId];
    if (ext == null) throw Exception('Extension not found: $extensionId');

    final vars = {
      'base_url': ext.baseUrl,
      'id': mangaId,
    };

    final results = await _scraper.scrape(
      config: ext.chapters,
      vars: vars,
      headers: _scraper.resolveHeaders(ext.headers, vars),
      cookies: _cookies[extensionId] ?? {},
      extensionId: extensionId,
      rateLimitMs: ext.rateLimitMs,
    );

    return results.map((r) {
      final number = r['number'];
      return ChapterInfo(
        id: r['id'] as String? ?? '',
        number: number is double
            ? number
            : double.tryParse(number?.toString() ?? '') ?? 0,
        title: r['title'] as String?,
      );
    }).where((c) => c.id.isNotEmpty).toList();
  }

  /// Get page image URLs for a chapter
  Future<List<String>> getPageUrls(
      String extensionId, String chapterId) async {
    final ext = _extensions[extensionId];
    if (ext == null) throw Exception('Extension not found: $extensionId');

    final vars = {
      'base_url': ext.baseUrl,
      'chapter_id': chapterId,
    };

    return _scraper.scrapePageUrls(
      config: ext.pages,
      vars: vars,
      headers: _scraper.resolveHeaders(ext.headers, vars),
      cookies: _cookies[extensionId] ?? {},
      extensionId: extensionId,
      rateLimitMs: ext.rateLimitMs,
    );
  }

  /// Get resolved headers for image download (includes Referer)
  Map<String, String> getImageHeaders(String extensionId) {
    final ext = _extensions[extensionId];
    if (ext == null) return {};

    final vars = {'base_url': ext.baseUrl};
    final headers = _scraper.resolveHeaders(ext.headers, vars);

    // Add/override referer from page config
    if (ext.pages.referer != null) {
      final referer = ext.pages.referer!
          .replaceAll('{base_url}', ext.baseUrl);
      headers['Referer'] = referer;
    }

    return headers;
  }

  /// Get cookies for an extension
  Map<String, String> getCookies(String extensionId) {
    return _cookies[extensionId] ?? {};
  }

  /// Get rate limit for an extension
  int getRateLimitMs(String extensionId) {
    return _extensions[extensionId]?.rateLimitMs ?? 1000;
  }

  // ============ Extension Management ============

  /// Install an extension from a directory path
  Future<void> installExtension(String sourcePath) async {
    if (_extensionsDir == null) throw Exception('Service not initialized');

    final manifestFile = File('$sourcePath/extension.json');
    if (!await manifestFile.exists()) {
      throw Exception('No extension.json found in $sourcePath');
    }

    final content = await manifestFile.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;
    final ext = MangaExtension.fromJson(json);

    final targetDir = Directory('$_extensionsDir/${ext.id}');
    if (await targetDir.exists()) {
      await targetDir.delete(recursive: true);
    }
    await targetDir.create(recursive: true);

    // Copy all files from source to target
    final sourceDir = Directory(sourcePath);
    await for (final entity in sourceDir.list()) {
      if (entity is File) {
        final name = entity.path.split('/').last;
        await entity.copy('${targetDir.path}/$name');
      }
    }

    _extensions[ext.id] = ext;
    LogService().log('MangaExtensionService: Installed extension ${ext.id}');
  }

  /// Remove an extension
  Future<void> removeExtension(String extensionId) async {
    if (_extensionsDir == null) return;

    final dir = Directory('$_extensionsDir/$extensionId');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }

    _extensions.remove(extensionId);
    _cookies.remove(extensionId);
    LogService().log('MangaExtensionService: Removed extension $extensionId');
  }

  // ============ Cookie Management ============

  Future<void> _loadCookies(String extensionId, String extPath) async {
    try {
      final file = File('$extPath/cookies.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        _cookies[extensionId] =
            json.map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {}
  }

  Future<void> saveCookies(
      String extensionId, Map<String, String> cookies) async {
    _cookies[extensionId] = cookies;
    if (_extensionsDir == null) return;

    try {
      final file = File('$_extensionsDir/$extensionId/cookies.json');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(cookies),
      );
    } catch (e) {
      LogService()
          .log('MangaExtensionService: Error saving cookies for $extensionId: $e');
    }
  }

  // ============ Bundled Extensions ============

  /// Install built-in extensions on first run
  Future<void> _installBundledExtensions() async {
    for (final manifest in _bundledExtensions) {
      try {
        final json = jsonDecode(manifest) as Map<String, dynamic>;
        final id = json['id'] as String;
        final targetDir = Directory('$_extensionsDir/$id');
        await targetDir.create(recursive: true);
        final file = File('${targetDir.path}/extension.json');
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert(json),
        );
        LogService()
            .log('MangaExtensionService: Installed bundled extension $id');
      } catch (e) {
        LogService().log(
            'MangaExtensionService: Error installing bundled extension: $e');
      }
    }
  }

  /// Restore bundled extensions (re-install all)
  Future<void> restoreBundledExtensions() async {
    await _installBundledExtensions();
    await loadExtensions();
  }

  static final List<String> _bundledExtensions = [
    // Mangakakalot
    '''{
  "id": "mangakakalot",
  "name": "Mangakakalot",
  "version": "1.0.0",
  "api_version": 1,
  "language": "en",
  "base_url": "https://mangakakalot.com",
  "rate_limit_ms": 1000,
  "needs_webview": false,
  "headers": {
    "Referer": "{base_url}",
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  },
  "search": {
    "url": "{base_url}/search/story/{query}",
    "list_selector": "div.story_item",
    "fields": {
      "id": { "selector": "h3 a", "attr": "href" },
      "title": { "selector": "h3 a", "text": true },
      "thumbnail": { "selector": "a img", "attr": "src" },
      "description": { "selector": ".story_item_right span:last-child", "text": true }
    }
  },
  "series": {
    "url": "{id}",
    "fields": {
      "title": { "selector": "h1", "text": true },
      "description": { "selector": "#noidungm", "text": true },
      "thumbnail": { "selector": ".manga-info-pic img", "attr": "src" }
    }
  },
  "chapters": {
    "url": "{id}",
    "list_selector": "div.chapter-list div.row a",
    "fields": {
      "id": { "attr": "href" },
      "title": { "text": true },
      "number": { "regex": "Chapter (\\\\d+(?:\\\\.\\\\d+)?)", "type": "number" }
    },
    "order": "desc"
  },
  "pages": {
    "url": "{chapter_id}",
    "list_selector": "div#vungdoc img, div.container-chapter-reader img",
    "image_attr": "src",
    "referer": "{base_url}"
  }
}''',

    // Chapmanganato (manganato.com)
    '''{
  "id": "chapmanganato",
  "name": "Chapmanganato",
  "version": "1.0.0",
  "api_version": 1,
  "language": "en",
  "base_url": "https://chapmanganato.to",
  "rate_limit_ms": 1000,
  "needs_webview": false,
  "headers": {
    "Referer": "{base_url}",
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  },
  "search": {
    "url": "{base_url}/search/story/{query}",
    "list_selector": "div.search-story-item",
    "fields": {
      "id": { "selector": "a.item-img", "attr": "href" },
      "title": { "selector": "a.item-img", "attr": "title" },
      "thumbnail": { "selector": "a.item-img img", "attr": "src" },
      "description": { "selector": ".item-right span:last-child", "text": true }
    }
  },
  "series": {
    "url": "{id}",
    "fields": {
      "title": { "selector": "h1", "text": true },
      "description": { "selector": "#panel-story-info-description", "text": true },
      "thumbnail": { "selector": ".info-image img", "attr": "src" }
    }
  },
  "chapters": {
    "url": "{id}",
    "list_selector": ".row-content-chapter li a",
    "fields": {
      "id": { "attr": "href" },
      "title": { "text": true },
      "number": { "regex": "Chapter (\\\\d+(?:\\\\.\\\\d+)?)", "type": "number" }
    },
    "order": "desc"
  },
  "pages": {
    "url": "{chapter_id}",
    "list_selector": ".container-chapter-reader img",
    "image_attr": "src",
    "referer": "{base_url}"
  }
}''',

    // MangaPill
    '''{
  "id": "mangapill",
  "name": "MangaPill",
  "version": "1.0.0",
  "api_version": 1,
  "language": "en",
  "base_url": "https://mangapill.com",
  "rate_limit_ms": 1000,
  "needs_webview": false,
  "headers": {
    "Referer": "{base_url}",
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  },
  "search": {
    "url": "{base_url}/search?q={query}&type=&status=",
    "list_selector": ".my-3.justify-end",
    "fields": {
      "id": { "selector": "a", "attr": "href" },
      "title": { "selector": "a div", "text": true },
      "thumbnail": { "selector": "a figure img", "attr": "data-src" }
    }
  },
  "series": {
    "url": "{base_url}{id}",
    "fields": {
      "title": { "selector": "h1", "text": true },
      "description": { "selector": ".limit-html p", "text": true },
      "thumbnail": { "selector": "figure img", "attr": "data-src" }
    }
  },
  "chapters": {
    "url": "{base_url}{id}",
    "list_selector": "#chapters a",
    "fields": {
      "id": { "attr": "href" },
      "title": { "text": true },
      "number": { "regex": "Chapter (\\\\d+(?:\\\\.\\\\d+)?)", "type": "number" }
    },
    "order": "desc"
  },
  "pages": {
    "url": "{base_url}{chapter_id}",
    "list_selector": "chapter-page img",
    "image_attr": "data-src",
    "referer": "{base_url}"
  }
}''',
  ];

  // ============ Helpers ============

  String _encodeQuery(String query) {
    return query.replaceAll(' ', '_').toLowerCase();
  }
}

/// A search result paired with the extension that found it
class ExtensionSearchResult {
  final String extensionId;
  final MangaSearchResult result;

  ExtensionSearchResult({
    required this.extensionId,
    required this.result,
  });
}
