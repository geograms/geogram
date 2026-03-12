/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

import '../../util/managed_http_client.dart';
import '../../pages/photo_viewer_page.dart';
import '../../services/i18n_service.dart';
import '../../services/log_service.dart';
import '../models/websnapshot_content.dart';
import '../services/ndf_service.dart';
import '../services/web_snapshot_service.dart';

/// Page for viewing a captured web snapshot using native HTML rendering
/// Uses flutter_widget_from_html_core for cross-platform compatibility (including Linux)
class WebSnapshotViewerPage extends StatefulWidget {
  final String filePath;
  final WebSnapshot snapshot;

  const WebSnapshotViewerPage({
    super.key,
    required this.filePath,
    required this.snapshot,
  });

  @override
  State<WebSnapshotViewerPage> createState() => _WebSnapshotViewerPageState();
}

class _WebSnapshotViewerPageState extends State<WebSnapshotViewerPage> {
  final I18nService _i18n = I18nService();
  final NdfService _ndfService = NdfService();
  final ScrollController _scrollController = ScrollController();

  /// Use native WebView on platforms that support it (Android/iOS/macOS)
  /// Linux doesn't have WebView support, so fall back to HtmlWidget
  bool get _useWebView => !Platform.isLinux;

  bool _isLoading = true;
  bool _isDownloading = false;
  String? _error;
  String? _extractedPath;
  String? _htmlContent; // For Linux HtmlWidget fallback
  WebViewController? _webViewController; // For WebView platforms
  String _currentTitle = '';
  final Set<String> _indexedAssets = {};

  @override
  void initState() {
    super.initState();
    _extractAndLoad();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    // Clean up extracted files
    _cleanupTempFiles();
    super.dispose();
  }

  Future<void> _cleanupTempFiles() async {
    if (_extractedPath != null) {
      try {
        final dir = Directory(_extractedPath!);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
          LogService().log('WebSnapshotViewerPage: Cleaned up temp files');
        }
      } catch (e) {
        LogService().log('WebSnapshotViewerPage: Error cleaning temp files: $e');
      }
    }
  }

  Future<void> _extractAndLoad() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Extract snapshot to temp directory
      final tempDir = await _ndfService.extractSnapshotToTemp(
        widget.filePath,
        widget.snapshot.id,
      );

      if (tempDir == null) {
        throw Exception('Failed to extract snapshot');
      }

      _extractedPath = tempDir;
      final indexPath = '$tempDir/index.html';
      final indexFile = File(indexPath);

      if (!await indexFile.exists()) {
        throw Exception('index.html not found in snapshot');
      }

      // Read HTML content to extract title
      final htmlContent = await indexFile.readAsString();

      // Extract title from HTML if not already set
      String title = widget.snapshot.title ?? '';
      if (title.isEmpty) {
        final titleMatch = RegExp(r'<title[^>]*>([^<]*)</title>', caseSensitive: false)
            .firstMatch(htmlContent);
        if (titleMatch != null) {
          title = titleMatch.group(1) ?? '';
        }
      }

      if (_useWebView) {
        // Android/iOS/macOS: Use WebView with full JavaScript support
        _webViewController = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(Colors.white)
          ..setNavigationDelegate(NavigationDelegate(
            onNavigationRequest: (request) {
              // Allow local file navigation within the snapshot
              if (request.url.startsWith('file://')) {
                return NavigationDecision.navigate;
              }
              // Block external URLs for security
              LogService().log('WebSnapshotViewerPage: Blocked external URL: ${request.url}');
              return NavigationDecision.prevent;
            },
          ))
          ..loadFile(indexPath);

        setState(() {
          _currentTitle = title;
          _isLoading = false;
        });
      } else {
        // Linux: Use HtmlWidget (no JS support, but works on Linux)
        await _buildAssetIndex();

        setState(() {
          _htmlContent = htmlContent;
          _currentTitle = title;
          _isLoading = false;
        });
      }
    } catch (e) {
      LogService().log('WebSnapshotViewerPage: Error loading snapshot: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Build an index of all assets in the snapshot for quick lookup
  Future<void> _buildAssetIndex() async {
    _indexedAssets.clear();

    // Get list of all files in the extracted directory
    if (_extractedPath != null) {
      final dir = Directory(_extractedPath!);
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final relativePath = entity.path.substring(_extractedPath!.length + 1);
          _indexedAssets.add(relativePath);
        }
      }
    }

    // Also add assets from snapshot metadata
    for (final asset in widget.snapshot.assets) {
      _indexedAssets.add(asset.localPath);
    }

    // Add pages
    for (final page in widget.snapshot.pages) {
      _indexedAssets.add(page);
    }

    LogService().log('WebSnapshotViewerPage: Indexed ${_indexedAssets.length} assets');
  }

  Future<void> _reload() async {
    await _extractAndLoad();
  }

  /// Resolve image path from src attribute to absolute file path
  String? _resolveImagePath(String? src) {
    if (src == null || _extractedPath == null) return null;
    if (src.startsWith('http')) return null; // Network images not supported offline
    return src.startsWith('/')
        ? '$_extractedPath$src'
        : '$_extractedPath/$src';
  }

  /// Open image in full-screen viewer
  void _openImageViewer(String imagePath) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoViewerPage(
          imagePaths: [imagePath],
          initialIndex: 0,
        ),
      ),
    );
  }

  /// Check if a URL points to content that exists in the snapshot
  bool _isContentIndexed(String url) {
    // Handle relative URLs
    if (!url.startsWith('http')) {
      final cleanPath = url.startsWith('/') ? url.substring(1) : url;
      // Remove query string and fragment
      final pathOnly = cleanPath.split('?').first.split('#').first;
      return _indexedAssets.contains(pathOnly) ||
          _indexedAssets.contains('$pathOnly.html') ||
          _indexedAssets.contains('${pathOnly}index.html');
    }

    // Handle absolute URLs - check if it's the same domain
    try {
      final snapshotUri = Uri.parse(widget.snapshot.url);
      final linkUri = Uri.parse(url);

      if (linkUri.host == snapshotUri.host) {
        // Same domain - check if we have this path
        var path = linkUri.path;
        if (path.startsWith('/')) path = path.substring(1);
        if (path.isEmpty) path = 'index.html';

        return _indexedAssets.contains(path) ||
            _indexedAssets.contains('$path.html') ||
            _indexedAssets.contains('${path}index.html');
      }
    } catch (e) {
      // Invalid URL
    }

    return false;
  }

  /// Resolve a relative URL to absolute using the snapshot's base URL
  String _resolveToAbsoluteUrl(String url) {
    if (url.startsWith('http')) return url;

    try {
      final baseUri = Uri.parse(widget.snapshot.url);
      return baseUri.resolve(url).toString();
    } catch (e) {
      return url;
    }
  }

  /// Handle tap on a URL - check if indexed, offer to download if not
  Future<bool> _handleUrlTap(String url) async {
    // Handle anchors
    if (url.startsWith('#')) {
      LogService().log('WebSnapshotViewerPage: Anchor tap: $url');
      return true;
    }

    // Check if content is indexed
    if (_isContentIndexed(url)) {
      // Content exists - navigate to it (for internal pages)
      // For now we just show a message since we render single pages
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('work_websnapshot_page_available')),
          duration: const Duration(seconds: 2),
        ),
      );
      return true;
    }

    // Content not indexed - ask user if they want to download
    final absoluteUrl = _resolveToAbsoluteUrl(url);
    final shouldDownload = await _showDownloadDialog(absoluteUrl);

    if (shouldDownload) {
      await _downloadAndIndexContent(absoluteUrl);
    }

    return true; // Consume the tap
  }

  /// Show dialog asking if user wants to download missing content
  Future<bool> _showDownloadDialog(String url) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('work_websnapshot_download_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_i18n.t('work_websnapshot_download_message')),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                url,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.download),
            label: Text(_i18n.t('work_websnapshot_download_action')),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  /// Download and index new content into the snapshot
  Future<void> _downloadAndIndexContent(String url) async {
    setState(() {
      _isDownloading = true;
    });

    try {
      // Fetch the content
      await withHttpClient((client) async {
        final response = await client.get(
          Uri.parse(url),
          headers: {
            'User-Agent': 'Mozilla/5.0 (compatible; GeogramBot/1.0)',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          },
        ).timeout(const Duration(seconds: 30));

        if (response.statusCode != 200) {
          throw Exception('Failed to fetch: HTTP ${response.statusCode}');
        }

        final contentType = response.headers['content-type'] ?? '';
        final isHtml = contentType.contains('text/html');
        final bytes = response.bodyBytes;

        // Generate local path for the new content
        final uri = Uri.parse(url);
        var localPath = uri.path;
        if (localPath.startsWith('/')) localPath = localPath.substring(1);
        if (localPath.isEmpty) localPath = 'index';

        // Add extension if missing
        if (!localPath.contains('.')) {
          localPath = isHtml ? '$localPath.html' : localPath;
        }

        // Sanitize filename
        localPath = localPath.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

        // If HTML, also download assets referenced in the page
        if (isHtml) {
          await _downloadHtmlWithAssets(url, response.body, localPath, client);
        } else {
          // Save single asset
          await _ndfService.saveSnapshotAssets(
            widget.filePath,
            widget.snapshot.id,
            {localPath: Uint8List.fromList(bytes)},
          );

          // Update snapshot metadata
          widget.snapshot.assets.add(CapturedAsset(
            originalUrl: url,
            localPath: localPath,
            mimeType: contentType.split(';').first,
            sizeBytes: bytes.length,
          ));
        }

        // Update snapshot in NDF
        widget.snapshot.assetCount = widget.snapshot.assets.length;
        await _ndfService.saveWebSnapshot(widget.filePath, widget.snapshot);

        // Reload to show new content
        await _extractAndLoad();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_i18n.t('work_websnapshot_download_complete')),
              backgroundColor: Colors.green,
            ),
          );
        }
      });
    } catch (e) {
      LogService().log('WebSnapshotViewerPage: Download failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('work_websnapshot_download_failed', params: [e.toString()])),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
        });
      }
    }
  }

  /// Download HTML page and its referenced assets
  Future<void> _downloadHtmlWithAssets(
    String pageUrl,
    String htmlContent,
    String localPath,
    http.Client client,
  ) async {
    final snapshotService = WebSnapshotService(httpClient: client as http.BaseClient);

    // Read current settings from the NDF
    final content = await _ndfService.readWebSnapshotContent(widget.filePath);
    final settings = content?.settings ?? WebSnapshotSettings();

    // Parse HTML and extract assets
    final document = html_parser.parse(htmlContent);
    final assetUrls = snapshotService.extractAssetUrls(document, pageUrl, settings);

    // Download assets
    final urlToLocalPath = <String, String>{};
    final newAssets = <String, Uint8List>{};

    for (final assetUrl in assetUrls) {
      try {
        final response = await client.get(
          Uri.parse(assetUrl),
          headers: {'User-Agent': 'Mozilla/5.0 (compatible; GeogramBot/1.0)'},
        ).timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          final assetPath = _urlToLocalPath(assetUrl);
          newAssets[assetPath] = response.bodyBytes;
          urlToLocalPath[assetUrl] = assetPath;

          // Track in snapshot
          final contentType = response.headers['content-type'] ?? 'application/octet-stream';
          widget.snapshot.assets.add(CapturedAsset(
            originalUrl: assetUrl,
            localPath: assetPath,
            mimeType: contentType.split(';').first,
            sizeBytes: response.bodyBytes.length,
          ));
        }
      } catch (e) {
        LogService().log('WebSnapshotViewerPage: Failed to download asset $assetUrl: $e');
      }
    }

    // Rewrite HTML to use local asset paths
    final rewrittenHtml = snapshotService.rewriteHtml(document, urlToLocalPath, pageUrl);

    // Add HTML to assets
    newAssets[localPath] = Uint8List.fromList(utf8.encode(rewrittenHtml));
    widget.snapshot.pages.add(localPath);
    widget.snapshot.pageCount = widget.snapshot.pages.length;

    // Save all assets to the NDF
    await _ndfService.saveSnapshotAssets(widget.filePath, widget.snapshot.id, newAssets);
  }

  /// Convert URL to local file path
  String _urlToLocalPath(String url) {
    try {
      final uri = Uri.parse(url);
      var path = uri.path;

      if (path.startsWith('/')) path = path.substring(1);
      if (path.isEmpty) path = 'asset_${url.hashCode.abs()}';

      // Handle query parameters
      if (uri.hasQuery) {
        final ext = _getExtension(path);
        final base = ext.isNotEmpty ? path.substring(0, path.length - ext.length - 1) : path;
        path = '${base}_${uri.query.hashCode.abs()}${ext.isNotEmpty ? '.$ext' : ''}';
      }

      // Sanitize
      return path.split('/').map((s) => s.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')).join('/');
    } catch (e) {
      return 'asset_${url.hashCode.abs()}';
    }
  }

  String _getExtension(String path) {
    final lastDot = path.lastIndexOf('.');
    final lastSlash = path.lastIndexOf('/');
    if (lastDot > lastSlash && lastDot < path.length - 1) {
      return path.substring(lastDot + 1).toLowerCase();
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _currentTitle.isNotEmpty
                  ? _currentTitle
                  : widget.snapshot.title ?? _i18n.t('work_websnapshot_view'),
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              widget.snapshot.url,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: (_htmlContent != null || _webViewController != null) && !_isDownloading
                ? _reload
                : null,
            tooltip: _i18n.t('work_websnapshot_reload'),
          ),
        ],
        bottom: _isLoading || _isDownloading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                _i18n.t('work_websnapshot_view_error'),
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _extractAndLoad,
                icon: const Icon(Icons.refresh),
                label: Text(_i18n.t('retry')),
              ),
            ],
          ),
        ),
      );
    }

    // WebView for Android/iOS/macOS - full JavaScript support
    if (_useWebView && _webViewController != null) {
      return WebViewWidget(controller: _webViewController!);
    }

    // Linux fallback with HtmlWidget
    if (_htmlContent == null) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    return Stack(
      children: [
        SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          child: HtmlWidget(
            _htmlContent!,
            baseUrl: _extractedPath != null ? Uri.file(_extractedPath!) : null,
            customWidgetBuilder: (element) {
              // Handle local images - make them clickable for full-screen view
              if (element.localName == 'img') {
                final src = element.attributes['src'];
                final imagePath = _resolveImagePath(src);

                if (imagePath != null) {
                  final imageFile = File(imagePath);

                  return MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => _openImageViewer(imagePath),
                      child: Image.file(
                        imageFile,
                        errorBuilder: (context, error, stackTrace) {
                          return _buildBrokenImagePlaceholder(src ?? 'unknown');
                        },
                      ),
                    ),
                  );
                }
              }

              return null;
            },
            factoryBuilder: () => _WebSnapshotWidgetFactory(
              extractedPath: _extractedPath,
              onImageTap: _openImageViewer,
            ),
            onTapUrl: _handleUrlTap,
            textStyle: theme.textTheme.bodyMedium,
          ),
        ),
        if (_isDownloading)
          Container(
            color: Colors.black26,
            child: Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(_i18n.t('work_websnapshot_downloading')),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBrokenImagePlaceholder(String src) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image, color: Colors.grey.shade400),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              src,
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 12,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom widget factory to add tooltips to links
class _WebSnapshotWidgetFactory extends WidgetFactory {
  final String? extractedPath;
  final void Function(String imagePath) onImageTap;

  _WebSnapshotWidgetFactory({
    required this.extractedPath,
    required this.onImageTap,
  });

  @override
  Widget? buildImageWidget(BuildMetadata meta, ImageSource src) {
    // Handle local images with click-to-view functionality
    final url = src.url;
    if (url.startsWith('file://') || (!url.startsWith('http') && extractedPath != null)) {
      String imagePath;
      if (url.startsWith('file://')) {
        imagePath = url.substring(7); // Remove file:// prefix
      } else {
        imagePath = url.startsWith('/')
            ? '$extractedPath$url'
            : '$extractedPath/$url';
      }

      final imageFile = File(imagePath);
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => onImageTap(imagePath),
          child: Image.file(
            imageFile,
            errorBuilder: (context, error, stackTrace) {
              return Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image, color: Colors.grey.shade400),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        url,
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    }

    return super.buildImageWidget(meta, src);
  }

  @override
  void parse(BuildMetadata meta) {
    // Check for anchor tags and add tooltip
    final element = meta.element;
    if (element.localName == 'a') {
      final href = element.attributes['href'];
      if (href != null && href.isNotEmpty) {
        // Register a callback to wrap the built widget with a tooltip
        meta.register(BuildOp(
          onWidgets: (meta, widgets) {
            return widgets.map((widget) {
              return Builder(
                builder: (context) {
                  return Tooltip(
                    message: href,
                    waitDuration: const Duration(milliseconds: 500),
                    child: widget,
                  );
                },
              );
            });
          },
        ));
      }
    }

    super.parse(meta);
  }
}
