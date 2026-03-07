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

    // Auto-install or update bundled extensions
    await _syncBundledExtensions();

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

  /// Browse a catalog page (popular, latest, etc.) for an extension
  Future<List<MangaSearchResult>> browse(
      String extensionId, int browseIndex) async {
    final ext = _extensions[extensionId];
    if (ext == null) throw Exception('Extension not found: $extensionId');
    if (browseIndex < 0 || browseIndex >= ext.browse.length) {
      throw Exception('Browse index out of range: $browseIndex');
    }

    final browseConfig = ext.browse[browseIndex];
    final vars = {'base_url': ext.baseUrl};

    final results = await _scraper.scrape(
      config: browseConfig.config,
      vars: vars,
      headers: _scraper.resolveHeaders(ext.headers, vars),
      cookies: _cookies[extensionId] ?? {},
      extensionId: extensionId,
      rateLimitMs: ext.rateLimitMs,
    );

    // Deduplicate by ID (some pages have repeated entries)
    final seen = <String>{};
    return results.map((r) {
      return MangaSearchResult(
        id: r['id'] as String? ?? '',
        title: r['title'] as String? ?? '',
        thumbnail: r['thumbnail'] as String?,
        description: r['description'] as String?,
      );
    }).where((r) => r.id.isNotEmpty && r.title.isNotEmpty && seen.add(r.id)).toList();
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

  /// Sync bundled extensions: install missing, update outdated
  Future<void> _syncBundledExtensions() async {
    for (final manifest in _bundledExtensions) {
      try {
        final json = jsonDecode(manifest) as Map<String, dynamic>;
        final id = json['id'] as String;
        final bundledVersion = json['version'] as String;
        final targetDir = Directory('$_extensionsDir/$id');
        final manifestFile = File('${targetDir.path}/extension.json');

        bool shouldInstall = !await targetDir.exists();
        if (!shouldInstall && await manifestFile.exists()) {
          final existing = jsonDecode(await manifestFile.readAsString())
              as Map<String, dynamic>;
          final diskVersion = existing['version'] as String? ?? '0.0.0';
          shouldInstall = _isNewerVersion(bundledVersion, diskVersion);
        }

        if (shouldInstall) {
          await targetDir.create(recursive: true);
          await manifestFile.writeAsString(
            const JsonEncoder.withIndent('  ').convert(json),
          );
          LogService().log(
              'MangaExtensionService: Installed/updated bundled extension $id v$bundledVersion');
        }
      } catch (e) {
        LogService().log(
            'MangaExtensionService: Error syncing bundled extension: $e');
      }
    }

    // Remove bundled extensions that are no longer in the bundled list
    final bundledIds = _bundledExtensions.map((m) {
      final json = jsonDecode(m) as Map<String, dynamic>;
      return json['id'] as String;
    }).toSet();

    final dir = Directory(_extensionsDir!);
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is Directory) {
          final dirName = entity.path.split('/').last;
          // Only remove if it looks like an old bundled extension
          // (has no custom modifications — just extension.json)
          if (!bundledIds.contains(dirName)) {
            final files = await entity.list().toList();
            final isSimple = files.length <= 2 &&
                files.every((f) =>
                    f.path.endsWith('extension.json') ||
                    f.path.endsWith('cookies.json'));
            if (isSimple) {
              await entity.delete(recursive: true);
              LogService().log(
                  'MangaExtensionService: Removed obsolete bundled extension $dirName');
            }
          }
        }
      }
    }
  }

  /// Compare semver: returns true if a > b
  bool _isNewerVersion(String a, String b) {
    final partsA = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final partsB = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final va = i < partsA.length ? partsA[i] : 0;
      final vb = i < partsB.length ? partsB[i] : 0;
      if (va > vb) return true;
      if (va < vb) return false;
    }
    return false;
  }

  /// Install built-in extensions (used by restore)
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
    // MangaPill (verified working)
    '''{
  "id": "mangapill",
  "name": "MangaPill",
  "version": "1.3.0",
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
    "list_selector": "div.grid > div",
    "fields": {
      "id": { "selector": "a[href*='/manga/']", "attr": "href" },
      "title": { "selector": "div.font-black", "text": true },
      "thumbnail": { "selector": "img[data-src]", "attr": "data-src" }
    }
  },
  "browse": [
    {
      "name": "Latest Updates",
      "url": "{base_url}",
      "list_selector": "div.grid > div",
      "fields": {
        "id": { "selector": "a[href*='/manga/']", "attr": "href" },
        "title": { "selector": "a[href*='/manga/'] div.font-bold", "text": true },
        "thumbnail": { "selector": "img[data-src]", "attr": "data-src" }
      }
    },
    {
      "name": "New",
      "url": "{base_url}/mangas/new",
      "list_selector": "div.grid > div",
      "fields": {
        "id": { "selector": "a[href*='/manga/']", "attr": "href" },
        "title": { "selector": "div.font-black", "text": true },
        "thumbnail": { "selector": "img[data-src]", "attr": "data-src" }
      }
    }
  ],
  "series": {
    "url": "{base_url}{id}",
    "fields": {
      "title": { "selector": "h1", "text": true },
      "description": { "selector": "p.text-sm.text--secondary", "text": true },
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

    // MangaBuddy (verified working)
    '''{
  "id": "mangabuddy",
  "name": "MangaBuddy",
  "version": "1.1.0",
  "api_version": 1,
  "language": "en",
  "base_url": "https://mangabuddy.com",
  "rate_limit_ms": 1000,
  "needs_webview": true,
  "headers": {
    "Referer": "{base_url}",
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  },
  "search": {
    "url": "{base_url}/search?q={query}",
    "list_selector": "div.book-item",
    "fields": {
      "id": { "selector": ".thumb a", "attr": "href" },
      "title": { "selector": ".thumb a", "attr": "title" },
      "thumbnail": { "selector": ".thumb img", "attr": "data-src" }
    }
  },
  "browse": [
    {
      "name": "Latest",
      "url": "{base_url}/latest",
      "list_selector": "div.book-item",
      "fields": {
        "id": { "selector": ".thumb a", "attr": "href" },
        "title": { "selector": ".thumb a", "attr": "title" },
        "thumbnail": { "selector": ".thumb img", "attr": "data-src" }
      }
    }
  ],
  "series": {
    "url": "{base_url}{id}",
    "fields": {
      "title": { "selector": "h1", "text": true },
      "description": { "selector": "div.description", "text": true },
      "thumbnail": { "selector": ".thumb img", "attr": "data-src" }
    }
  },
  "chapters": {
    "url": "{base_url}{id}",
    "list_selector": "ul.chapter-list li a",
    "fields": {
      "id": { "attr": "href" },
      "title": { "text": true },
      "number": { "regex": "Chapter (\\\\d+(?:\\\\.\\\\d+)?)", "type": "number" }
    },
    "order": "desc"
  },
  "pages": {
    "url": "{base_url}{chapter_id}",
    "list_selector": "div.chapter-image img",
    "image_attr": "data-src",
    "referer": "{base_url}"
  }
}''',
  ];

  // ============ Helpers ============

  String _encodeQuery(String query) {
    return Uri.encodeComponent(query.trim());
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
