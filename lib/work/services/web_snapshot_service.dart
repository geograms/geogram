/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:http/http.dart' as http;

import '../../util/managed_http_client.dart';
import '../../services/log_service.dart';
import '../models/websnapshot_content.dart';

/// Capture phase for progress reporting
enum CapturePhase {
  fetching,
  parsing,
  downloading,
  rewriting,
  complete,
  failed,
}

/// Progress update during website capture
class CaptureProgress {
  final CapturePhase phase;
  final double progress;  // 0.0 - 1.0
  final String message;
  final int pagesProcessed;
  final int totalPages;
  final int assetsDownloaded;
  final int totalAssets;

  CaptureProgress({
    required this.phase,
    required this.progress,
    required this.message,
    this.pagesProcessed = 0,
    this.totalPages = 0,
    this.assetsDownloaded = 0,
    this.totalAssets = 0,
  });
}

/// Service for capturing websites
class WebSnapshotService {
  final http.BaseClient _httpClient;
  bool _isCancelled = false;

  WebSnapshotService({http.BaseClient? httpClient})
      : _httpClient = httpClient ?? ManagedHttpClient();

  /// Cancel the current capture operation
  void cancel() {
    _isCancelled = true;
  }

  /// Capture a website snapshot
  /// Returns stream of progress updates
  Stream<CaptureProgress> captureWebsite({
    required String url,
    required CrawlDepth depth,
    required WebSnapshotSettings settings,
    required WebSnapshot snapshot,
    required Future<void> Function(String path, Uint8List data) saveAsset,
  }) async* {
    _isCancelled = false;

    try {
      // Normalize URL
      Uri uri;
      try {
        uri = Uri.parse(url);
        if (!uri.hasScheme) {
          uri = Uri.parse('https://$url');
        }
      } catch (e) {
        yield CaptureProgress(
          phase: CapturePhase.failed,
          progress: 0,
          message: 'Invalid URL: $url',
        );
        return;
      }

      final baseUrl = '${uri.scheme}://${uri.host}${uri.port != 80 && uri.port != 443 ? ':${uri.port}' : ''}';

      yield CaptureProgress(
        phase: CapturePhase.fetching,
        progress: 0.1,
        message: 'Fetching $url...',
      );

      // Fetch the main page
      final response = await _fetchPage(uri.toString());
      if (response == null) {
        yield CaptureProgress(
          phase: CapturePhase.failed,
          progress: 0,
          message: 'Failed to fetch page',
        );
        return;
      }

      if (_isCancelled) return;

      yield CaptureProgress(
        phase: CapturePhase.parsing,
        progress: 0.2,
        message: 'Parsing HTML...',
      );

      // Parse HTML
      final document = html_parser.parse(response);

      // Extract page title and description
      snapshot.title = _extractTitle(document);
      snapshot.description = _extractDescription(document);

      // Collect pages to crawl based on depth
      final pagesToCrawl = <String>{uri.toString()};
      final processedPages = <String>{};
      final pageContents = <String, String>{};  // url -> html content
      pageContents[uri.toString()] = response;

      if (depth != CrawlDepth.single) {
        final maxDepth = _depthToInt(depth);
        await _crawlPages(
          document,
          baseUrl,
          uri.toString(),
          pagesToCrawl,
          pageContents,
          processedPages,
          1,
          maxDepth,
        );
      }

      if (_isCancelled) return;

      // Collect all assets from all pages
      final assetUrls = <String>{};
      final pageDocuments = <String, dom.Document>{};

      for (final pageUrl in pagesToCrawl) {
        final pageHtml = pageContents[pageUrl];
        if (pageHtml != null) {
          final pageDoc = html_parser.parse(pageHtml);
          pageDocuments[pageUrl] = pageDoc;
          assetUrls.addAll(extractAssetUrls(pageDoc, pageUrl, settings));
        }
      }

      snapshot.pageCount = pagesToCrawl.length;

      yield CaptureProgress(
        phase: CapturePhase.downloading,
        progress: 0.3,
        message: 'Found ${assetUrls.length} assets...',
        totalAssets: assetUrls.length,
      );

      // Download assets
      final urlToLocalPath = <String, String>{};
      var downloadedCount = 0;
      var totalSize = 0;

      for (final assetUrl in assetUrls) {
        if (_isCancelled) return;

        try {
          final assetData = await _downloadAsset(assetUrl, settings.maxAssetSizeMb);
          if (assetData != null) {
            final localPath = _urlToLocalPath(assetUrl);
            await saveAsset(localPath, assetData);
            urlToLocalPath[assetUrl] = localPath;
            totalSize += assetData.length;

            snapshot.assets.add(CapturedAsset(
              originalUrl: assetUrl,
              localPath: localPath,
              mimeType: _guessMimeType(assetUrl),
              sizeBytes: assetData.length,
            ));
          }
        } catch (e) {
          LogService().log('WebSnapshotService: Failed to download asset $assetUrl: $e');
        }

        downloadedCount++;
        yield CaptureProgress(
          phase: CapturePhase.downloading,
          progress: 0.3 + (0.5 * downloadedCount / assetUrls.length),
          message: 'Downloading assets... ($downloadedCount/${assetUrls.length})',
          assetsDownloaded: downloadedCount,
          totalAssets: assetUrls.length,
        );
      }

      if (_isCancelled) return;

      yield CaptureProgress(
        phase: CapturePhase.rewriting,
        progress: 0.85,
        message: 'Rewriting HTML...',
      );

      // Rewrite and save HTML pages
      var pageIndex = 0;
      for (final pageUrl in pagesToCrawl) {
        final pageDoc = pageDocuments[pageUrl];
        if (pageDoc != null) {
          final rewrittenHtml = rewriteHtml(pageDoc, urlToLocalPath, pageUrl);
          final pageName = pageIndex == 0 ? 'index.html' : 'page_$pageIndex.html';
          await saveAsset(pageName, Uint8List.fromList(utf8.encode(rewrittenHtml)));
          snapshot.pages.add(pageName);
          totalSize += rewrittenHtml.length;
          pageIndex++;
        }
      }

      snapshot.assetCount = urlToLocalPath.length;
      snapshot.totalSizeBytes = totalSize;
      snapshot.status = CrawlStatus.complete;

      yield CaptureProgress(
        phase: CapturePhase.complete,
        progress: 1.0,
        message: 'Capture complete',
        pagesProcessed: snapshot.pageCount,
        totalPages: snapshot.pageCount,
        assetsDownloaded: snapshot.assetCount,
        totalAssets: snapshot.assetCount,
      );

    } catch (e) {
      LogService().log('WebSnapshotService: Capture failed: $e');
      snapshot.status = CrawlStatus.failed;
      snapshot.error = e.toString();
      yield CaptureProgress(
        phase: CapturePhase.failed,
        progress: 0,
        message: 'Capture failed: $e',
      );
    }
  }

  Future<String?> _fetchPage(String url) async {
    try {
      final response = await _httpClient.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (compatible; GeogramBot/1.0)',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return response.body;
      }
      LogService().log('WebSnapshotService: Failed to fetch $url: ${response.statusCode}');
      return null;
    } catch (e) {
      LogService().log('WebSnapshotService: Error fetching $url: $e');
      return null;
    }
  }

  Future<Uint8List?> _downloadAsset(String url, int maxSizeMb) async {
    try {
      final response = await _httpClient.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (compatible; GeogramBot/1.0)',
        },
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        final maxBytes = maxSizeMb * 1024 * 1024;
        if (response.bodyBytes.length <= maxBytes) {
          return response.bodyBytes;
        }
        LogService().log('WebSnapshotService: Asset too large, skipping: $url');
      }
      return null;
    } catch (e) {
      LogService().log('WebSnapshotService: Error downloading asset $url: $e');
      return null;
    }
  }

  Future<void> _crawlPages(
    dom.Document document,
    String baseUrl,
    String currentUrl,
    Set<String> pagesToCrawl,
    Map<String, String> pageContents,
    Set<String> processedPages,
    int currentDepth,
    int maxDepth,
  ) async {
    if (currentDepth > maxDepth || _isCancelled) return;

    processedPages.add(currentUrl);

    final pageUrls = extractPageUrls(document, currentUrl);

    for (final pageUrl in pageUrls) {
      if (_isCancelled) return;
      if (processedPages.contains(pageUrl)) continue;
      if (!pageUrl.startsWith(baseUrl)) continue;  // Same domain only

      // Limit total pages
      if (pagesToCrawl.length >= 50) break;

      pagesToCrawl.add(pageUrl);

      if (currentDepth < maxDepth) {
        final html = await _fetchPage(pageUrl);
        if (html != null) {
          pageContents[pageUrl] = html;
          final pageDoc = html_parser.parse(html);
          await _crawlPages(
            pageDoc,
            baseUrl,
            pageUrl,
            pagesToCrawl,
            pageContents,
            processedPages,
            currentDepth + 1,
            maxDepth,
          );
        }
      }
    }
  }

  int _depthToInt(CrawlDepth depth) {
    switch (depth) {
      case CrawlDepth.single:
        return 0;
      case CrawlDepth.one:
        return 1;
      case CrawlDepth.two:
        return 2;
      case CrawlDepth.three:
        return 3;
    }
  }

  String? _extractTitle(dom.Document document) {
    final titleEl = document.querySelector('title');
    if (titleEl != null && titleEl.text.isNotEmpty) {
      return titleEl.text.trim();
    }
    final ogTitle = document.querySelector('meta[property="og:title"]');
    if (ogTitle != null) {
      return ogTitle.attributes['content']?.trim();
    }
    return null;
  }

  String? _extractDescription(dom.Document document) {
    final metaDesc = document.querySelector('meta[name="description"]');
    if (metaDesc != null) {
      return metaDesc.attributes['content']?.trim();
    }
    final ogDesc = document.querySelector('meta[property="og:description"]');
    if (ogDesc != null) {
      return ogDesc.attributes['content']?.trim();
    }
    return null;
  }

  /// Extract all asset URLs from HTML document
  List<String> extractAssetUrls(
    dom.Document document,
    String baseUrl,
    WebSnapshotSettings settings,
  ) {
    final assets = <String>[];
    final baseUri = Uri.parse(baseUrl);

    // Images
    if (settings.includeImages) {
      for (final img in document.querySelectorAll('img[src]')) {
        final src = img.attributes['src'];
        if (src != null && src.isNotEmpty) {
          assets.add(_resolveUrl(src, baseUri));
        }
        // Also check srcset
        final srcset = img.attributes['srcset'];
        if (srcset != null) {
          for (final part in srcset.split(',')) {
            final url = part.trim().split(' ').first;
            if (url.isNotEmpty) {
              assets.add(_resolveUrl(url, baseUri));
            }
          }
        }
      }
      // Picture sources
      for (final source in document.querySelectorAll('picture source[srcset]')) {
        final srcset = source.attributes['srcset'];
        if (srcset != null) {
          for (final part in srcset.split(',')) {
            final url = part.trim().split(' ').first;
            if (url.isNotEmpty) {
              assets.add(_resolveUrl(url, baseUri));
            }
          }
        }
      }
    }

    // CSS stylesheets
    if (settings.includeStyles) {
      for (final link in document.querySelectorAll('link[rel="stylesheet"]')) {
        final href = link.attributes['href'];
        if (href != null && href.isNotEmpty) {
          assets.add(_resolveUrl(href, baseUri));
        }
      }
    }

    // Scripts
    if (settings.includeScripts) {
      for (final script in document.querySelectorAll('script[src]')) {
        final src = script.attributes['src'];
        if (src != null && src.isNotEmpty) {
          assets.add(_resolveUrl(src, baseUri));
        }
      }
    }

    // Fonts (from link preload)
    if (settings.includeFonts) {
      for (final link in document.querySelectorAll('link[rel="preload"][as="font"]')) {
        final href = link.attributes['href'];
        if (href != null && href.isNotEmpty) {
          assets.add(_resolveUrl(href, baseUri));
        }
      }
    }

    // Favicon
    for (final link in document.querySelectorAll('link[rel*="icon"]')) {
      final href = link.attributes['href'];
      if (href != null && href.isNotEmpty) {
        assets.add(_resolveUrl(href, baseUri));
      }
    }

    // Filter out data URIs and invalid URLs
    return assets
        .where((url) => !url.startsWith('data:') && Uri.tryParse(url) != null)
        .toSet()  // Remove duplicates
        .toList();
  }

  /// Extract linked page URLs from HTML (same domain only)
  List<String> extractPageUrls(dom.Document document, String baseUrl) {
    final pages = <String>[];
    final baseUri = Uri.parse(baseUrl);
    final baseDomain = baseUri.host;

    for (final anchor in document.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href'];
      if (href == null || href.isEmpty) continue;
      if (href.startsWith('#')) continue;  // Fragment only
      if (href.startsWith('javascript:')) continue;
      if (href.startsWith('mailto:')) continue;
      if (href.startsWith('tel:')) continue;

      final resolvedUrl = _resolveUrl(href, baseUri);
      final resolvedUri = Uri.tryParse(resolvedUrl);
      if (resolvedUri == null) continue;

      // Same domain only
      if (resolvedUri.host != baseDomain) continue;

      // Remove fragment
      final cleanUrl = resolvedUri.replace(fragment: '').toString();
      pages.add(cleanUrl);
    }

    return pages.toSet().toList();
  }

  /// Rewrite HTML to use local asset references
  String rewriteHtml(
    dom.Document document,
    Map<String, String> urlToLocalPath,
    String pageUrl,
  ) {
    final baseUri = Uri.parse(pageUrl);

    // Helper to rewrite a URL
    String? rewrite(String? url) {
      if (url == null || url.isEmpty) return null;
      if (url.startsWith('data:')) return url;

      final resolved = _resolveUrl(url, baseUri);
      return urlToLocalPath[resolved];
    }

    // Rewrite images
    for (final img in document.querySelectorAll('img[src]')) {
      final src = img.attributes['src'];
      final newSrc = rewrite(src);
      if (newSrc != null) {
        img.attributes['src'] = newSrc;
      }
      // Rewrite srcset
      final srcset = img.attributes['srcset'];
      if (srcset != null) {
        final newParts = <String>[];
        for (final part in srcset.split(',')) {
          final parts = part.trim().split(' ');
          final url = parts.first;
          final resolved = _resolveUrl(url, baseUri);
          final local = urlToLocalPath[resolved];
          if (local != null) {
            parts[0] = local;
          }
          newParts.add(parts.join(' '));
        }
        img.attributes['srcset'] = newParts.join(', ');
      }
    }

    // Rewrite picture sources
    for (final source in document.querySelectorAll('picture source[srcset]')) {
      final srcset = source.attributes['srcset'];
      if (srcset != null) {
        final newParts = <String>[];
        for (final part in srcset.split(',')) {
          final parts = part.trim().split(' ');
          final url = parts.first;
          final resolved = _resolveUrl(url, baseUri);
          final local = urlToLocalPath[resolved];
          if (local != null) {
            parts[0] = local;
          }
          newParts.add(parts.join(' '));
        }
        source.attributes['srcset'] = newParts.join(', ');
      }
    }

    // Rewrite CSS links
    for (final link in document.querySelectorAll('link[rel="stylesheet"]')) {
      final href = link.attributes['href'];
      final newHref = rewrite(href);
      if (newHref != null) {
        link.attributes['href'] = newHref;
      }
    }

    // Rewrite script sources
    for (final script in document.querySelectorAll('script[src]')) {
      final src = script.attributes['src'];
      final newSrc = rewrite(src);
      if (newSrc != null) {
        script.attributes['src'] = newSrc;
      }
    }

    // Rewrite font preloads
    for (final link in document.querySelectorAll('link[rel="preload"][as="font"]')) {
      final href = link.attributes['href'];
      final newHref = rewrite(href);
      if (newHref != null) {
        link.attributes['href'] = newHref;
      }
    }

    // Rewrite favicon
    for (final link in document.querySelectorAll('link[rel*="icon"]')) {
      final href = link.attributes['href'];
      final newHref = rewrite(href);
      if (newHref != null) {
        link.attributes['href'] = newHref;
      }
    }

    // Add base tag to help with relative links within the archive
    final head = document.querySelector('head');
    if (head != null) {
      final existingBase = head.querySelector('base');
      if (existingBase != null) {
        existingBase.remove();
      }
      // Add a comment indicating this is an archived page
      final comment = dom.Comment(' Archived by Geogram Web Snapshot ');
      if (head.nodes.isNotEmpty) {
        head.nodes.insert(0, comment);
      } else {
        head.append(comment);
      }
    }

    return document.outerHtml;
  }

  /// Rewrite CSS content to use local asset references
  String rewriteCss(
    String css,
    Map<String, String> urlToLocalPath,
    String cssUrl,
  ) {
    final baseUri = Uri.parse(cssUrl);

    // Match url(...) patterns
    final urlPattern = RegExp(r'''url\(['"]?([^'")\s]+)['"]?\)''');

    return css.replaceAllMapped(urlPattern, (match) {
      final url = match.group(1)!;
      if (url.startsWith('data:')) return match.group(0)!;

      final resolved = _resolveUrl(url, baseUri);
      final local = urlToLocalPath[resolved];
      if (local != null) {
        return 'url("$local")';
      }
      return match.group(0)!;
    });
  }

  String _resolveUrl(String url, Uri baseUri) {
    if (url.startsWith('//')) {
      return '${baseUri.scheme}:$url';
    }
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    return baseUri.resolve(url).toString();
  }

  /// Convert URL to local file path (preserving directory structure)
  String _urlToLocalPath(String url) {
    try {
      final uri = Uri.parse(url);
      var path = uri.path;

      // Remove leading slash
      if (path.startsWith('/')) {
        path = path.substring(1);
      }

      // Handle query parameters by encoding them
      if (uri.hasQuery) {
        final ext = _getExtension(path);
        final base = ext.isNotEmpty ? path.substring(0, path.length - ext.length - 1) : path;
        path = '${base}_${uri.query.hashCode.abs()}${ext.isNotEmpty ? '.$ext' : ''}';
      }

      // Ensure valid filename
      if (path.isEmpty) {
        path = 'index';
      }

      // Add extension if missing
      if (!path.contains('.')) {
        final mimeType = _guessMimeType(url);
        final ext = _mimeToExtension(mimeType);
        if (ext.isNotEmpty) {
          path = '$path.$ext';
        }
      }

      // Sanitize path components
      path = path.split('/').map(_sanitizeFilename).join('/');

      return path;
    } catch (e) {
      // Fallback: use hash of URL
      return 'asset_${url.hashCode.abs()}';
    }
  }

  String _sanitizeFilename(String name) {
    // Replace invalid characters with underscore
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  }

  String _getExtension(String path) {
    final lastDot = path.lastIndexOf('.');
    final lastSlash = path.lastIndexOf('/');
    if (lastDot > lastSlash && lastDot < path.length - 1) {
      return path.substring(lastDot + 1).toLowerCase();
    }
    return '';
  }

  String _guessMimeType(String url) {
    final ext = _getExtension(url);
    switch (ext) {
      case 'html':
      case 'htm':
        return 'text/html';
      case 'css':
        return 'text/css';
      case 'js':
        return 'application/javascript';
      case 'json':
        return 'application/json';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'svg':
        return 'image/svg+xml';
      case 'webp':
        return 'image/webp';
      case 'ico':
        return 'image/x-icon';
      case 'woff':
        return 'font/woff';
      case 'woff2':
        return 'font/woff2';
      case 'ttf':
        return 'font/ttf';
      case 'otf':
        return 'font/otf';
      case 'eot':
        return 'application/vnd.ms-fontobject';
      default:
        return 'application/octet-stream';
    }
  }

  String _mimeToExtension(String mimeType) {
    switch (mimeType) {
      case 'text/html':
        return 'html';
      case 'text/css':
        return 'css';
      case 'application/javascript':
        return 'js';
      case 'application/json':
        return 'json';
      case 'image/png':
        return 'png';
      case 'image/jpeg':
        return 'jpg';
      case 'image/gif':
        return 'gif';
      case 'image/svg+xml':
        return 'svg';
      case 'image/webp':
        return 'webp';
      case 'image/x-icon':
        return 'ico';
      case 'font/woff':
        return 'woff';
      case 'font/woff2':
        return 'woff2';
      case 'font/ttf':
        return 'ttf';
      case 'font/otf':
        return 'otf';
      default:
        return '';
    }
  }

  void dispose() {
    _httpClient.close();
  }
}
