/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as wv_windows;
import 'package:webf/webf.dart';

import '../services/app_service.dart';
import '../services/i18n_service.dart';
import '../services/log_api_service.dart';
import '../services/profile_service.dart';
import '../services/profile_storage.dart';
import '../services/station_service.dart';
import '../services/websocket_service.dart';
import '../widgets/file_folder_picker.dart';
import '../widgets/video_player_widget.dart';
import 'document_viewer_editor_page.dart';
import 'photo_viewer_page.dart';

/// Website (www) browser page with Files + Preview tabs.
///
/// - **Files tab**: [FileFolderPicker] in explorer mode with inline editing
/// - **Preview tab**: renders the published page via the local HTTP server
/// - **URL bar**: shows `https://p2p.radio/{CALLSIGN}` when connected
class WebsiteBrowserPage extends StatefulWidget {
  final String appPath;
  final String appTitle;
  final I18nService i18n;

  const WebsiteBrowserPage({
    super.key,
    required this.appPath,
    required this.appTitle,
    required this.i18n,
  });

  @override
  State<WebsiteBrowserPage> createState() => _WebsiteBrowserPageState();
}

class _WebsiteBrowserPageState extends State<WebsiteBrowserPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // --- File browser state (same as FilesBrowserPage) ---
  final _pickerKey = GlobalKey<FileFolderPickerState>();
  final _viewerKey = GlobalKey<DocumentViewerWidgetState>();
  final _imageFocusNode = FocusNode();
  final _transformController = TransformationController();

  String? _previewPath;
  String _previewExt = '';
  List<String> _folderFiles = [];
  int _currentFileIndex = 0;
  double _dividerRatio = 0.4;

  // --- Preview tab state ---
  /// URL the embedded webview loads. Null means "no index.html yet".
  String? _previewUrl;
  bool _previewLoading = false;

  // --- Custom homepage toggle ---
  /// Default true so the UI mirrors the new install default (static
  /// "It works!" page) until the real value is loaded from disk.
  bool _useCustomHomepage = true;
  bool _customHomepageBusy = false;

  // --- WebView state (platform-adaptive) ---
  WebViewController? _webViewController; // Android/iOS/macOS
  wv_windows.WebviewController? _winWebViewController; // Windows
  bool _winWebViewReady = false;
  int _webfKey = 0; // Force-rebuild key for WebF widget on Linux
  bool _webfManagerInitialized = false;

  static const _imageExtensions = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg', 'ico', 'heic',
  };

  static const _textExtensions = {
    'txt', 'log', 'json', 'xml', 'csv', 'yaml', 'yml', 'ini', 'conf',
    'dart', 'py', 'js', 'ts', 'css', 'html', 'sh', 'c', 'cpp', 'java',
    'kt', 'go', 'rs', 'rb', 'php', 'toml', 'cfg',
  };

  static const _audioExtensions = {
    'mp3', 'wav', 'flac', 'ogg', 'aac', 'm4a', 'opus', 'wma',
  };

  static const _videoExtensions = {
    'mp4', 'avi', 'mkv', 'webm', 'mov', 'wmv', 'm4v', '3gp',
  };

  bool _isPreviewable(String ext) {
    return _imageExtensions.contains(ext) ||
        _textExtensions.contains(ext) ||
        _videoExtensions.contains(ext) ||
        ext == 'pdf' ||
        ext == 'md' ||
        ext == 'markdown';
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    _loadCustomHomepageSetting();
    // Rebuild after first frame so _pickerKey.currentState is available.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadCustomHomepageSetting() async {
    final value = await AppService().isWwwUsingCustomHomepage();
    if (!mounted) return;
    setState(() => _useCustomHomepage = value);
  }

  Future<void> _toggleCustomHomepage(bool value) async {
    if (_customHomepageBusy) return;
    if (value) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Use custom homepage?'),
          content: const Text(
            'Your index.html will be replaced with a starter "It works!" page '
            'that you can edit freely. The auto-generated homepage will no '
            'longer overwrite your changes. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace and enable'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() => _customHomepageBusy = true);
    try {
      await AppService().setWwwUseCustomHomepage(value);
      if (!mounted) return;
      setState(() => _useCustomHomepage = value);
      _pickerKey.currentState?.refresh();
      if (_tabController.index == 1) _loadPreview();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(value
              ? 'Custom homepage enabled — edit index.html to customise'
              : 'Auto-generated homepage restored'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update setting: $e')),
      );
    } finally {
      if (mounted) setState(() => _customHomepageBusy = false);
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _imageFocusNode.dispose();
    _transformController.dispose();
    _winWebViewController?.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging && _tabController.index == 1) {
      _loadPreview();
    }
    setState(() {});
  }

  Future<void> _loadPreview() async {
    setState(() => _previewLoading = true);
    try {
      // The preview must look like the real visitor view, including the
      // global /styles.css that the dark Terminimal theme depends on. The
      // local HTTP server already serves the page exactly as a relay would
      // expose it, so we point the embedded webviews at it instead of
      // rendering a stripped-down file:// copy.
      final url = await _resolvePreviewUrl();
      if (url == null) {
        if (mounted) setState(() => _previewLoading = false);
        return;
      }

      if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        _webViewController ??= WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(Colors.white);
        await _webViewController!.loadRequest(Uri.parse(url));
      } else if (Platform.isWindows) {
        if (_winWebViewController == null) {
          _winWebViewController = wv_windows.WebviewController();
          await _winWebViewController!.initialize();
          await _winWebViewController!.setPopupWindowPolicy(
            wv_windows.WebviewPopupWindowPolicy.deny,
          );
          _winWebViewReady = true;
        }
        await _winWebViewController!.loadUrl(url);
      } else if (Platform.isLinux) {
        if (!_webfManagerInitialized) {
          WebFControllerManager.instance.initialize(
            const WebFControllerManagerConfig(
              maxAliveInstances: 1,
              maxAttachedInstances: 1,
              enableDevTools: false,
            ),
          );
          _webfManagerInitialized = true;
        }
        _previewUrl = url;
        _webfKey++; // Force widget rebuild
      }

      if (mounted) setState(() => _previewLoading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _previewUrl = null;
          _previewLoading = false;
        });
      }
    }
  }

  /// Build the URL the embedded webview should load for the preview.
  /// Returns null when no index.html is published yet.
  Future<String?> _resolvePreviewUrl() async {
    // First confirm an index.html actually exists; otherwise the empty-state
    // panel ("No index.html found") is shown instead of a 404 in the webview.
    final hasIndex = await _hasIndexHtml();
    if (!hasIndex) {
      _previewUrl = null;
      return null;
    }

    final port = LogApiService().port;
    // Folder name is the last segment of the app's storage path.
    final folder = p.basename(widget.appPath);
    final url = 'http://127.0.0.1:$port/$folder/index.html';
    _previewUrl = url;
    return url;
  }

  Future<bool> _hasIndexHtml() async {
    final storage = AppService().profileStorage;
    if (storage != null) {
      final scoped = ScopedProfileStorage.fromAbsolutePath(
        storage,
        widget.appPath,
      );
      return scoped.exists('index.html');
    }
    return File(p.join(widget.appPath, 'index.html')).exists();
  }

  // ---------------------------------------------------------------------------
  // Public URL helpers
  // ---------------------------------------------------------------------------

  String? _getPublicUrl() {
    if (!WebSocketService().isConnected) return null;
    final station = StationService().getPreferredStation();
    final connected = StationService().getConnectedStation();
    final url = station?.url.isNotEmpty == true
        ? station!.url
        : connected?.url;
    if (url == null || url.isEmpty) return null;

    // wss://p2p.radio -> p2p.radio
    var domain = url.replaceFirst('wss://', '').replaceFirst('ws://', '');
    if (domain.endsWith('/')) domain = domain.substring(0, domain.length - 1);

    final callsign = ProfileService().getProfile().callsign;
    if (callsign.isEmpty) return null;

    return 'https://$domain/$callsign';
  }

  // ---------------------------------------------------------------------------
  // File browser – open file logic (same as FilesBrowserPage)
  // ---------------------------------------------------------------------------

  void _openFile(String path) {
    final storage = AppService().profileStorage;
    if (storage != null && storage.isEncrypted) {
      final basePath = storage.basePath;
      if (p.isWithin(basePath, path)) {
        _openEncryptedFile(path, storage);
        return;
      }
    }

    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    final isWide = MediaQuery.of(context).size.width >= 800;

    if (isWide && _isPreviewable(ext)) {
      _transformController.value = Matrix4.identity();
      setState(() {
        _previewPath = path;
        _previewExt = ext;
        if (_imageExtensions.contains(ext)) {
          _loadFolderFiles(path, _imageExtensions);
        } else if (ext == 'pdf') {
          _loadFolderFiles(path, {'pdf'});
        } else {
          _folderFiles = [];
          _currentFileIndex = 0;
        }
      });
      _pickerKey.currentState?.selectFile(path);
      return;
    }

    _openFileFull(path);
  }

  Future<void> _openEncryptedFile(String path, ProfileStorage storage) async {
    final basePath = storage.basePath;
    final relativePath = path.substring(basePath.length + 1);
    final fileName = p.basename(path);
    final tempPath =
        p.join(Directory.systemTemp.path, 'geogram_preview_$fileName');

    try {
      await storage.copyToExternal(relativePath, tempPath);

      final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
      final isWide = mounted && MediaQuery.of(context).size.width >= 800;

      if (isWide && _isPreviewable(ext)) {
        _transformController.value = Matrix4.identity();
        setState(() {
          _previewPath = tempPath;
          _previewExt = ext;
          _folderFiles = [];
          _currentFileIndex = 0;
        });
        _pickerKey.currentState?.selectFile(path);
        return;
      }

      _openFileFull(tempPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open file: $e')),
        );
      }
    }
  }

  void _loadFolderFiles(String filePath, Set<String> extensions) {
    final dir = Directory(p.dirname(filePath));
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final ext = p.extension(f.path).toLowerCase().replaceFirst('.', '');
          return extensions.contains(ext);
        })
        .map((f) => f.path)
        .toList()
      ..sort((a, b) =>
          p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
    _folderFiles = files;
    _currentFileIndex = files.indexOf(filePath).clamp(0, files.length - 1);
  }

  void _goToPrevious() {
    if (_currentFileIndex > 0) {
      _currentFileIndex--;
      _previewPath = _folderFiles[_currentFileIndex];
      _previewExt =
          p.extension(_previewPath!).toLowerCase().replaceFirst('.', '');
      _transformController.value = Matrix4.identity();
      setState(() {});
      _pickerKey.currentState?.selectFile(_previewPath!);
    }
  }

  void _goToNext() {
    if (_currentFileIndex < _folderFiles.length - 1) {
      _currentFileIndex++;
      _previewPath = _folderFiles[_currentFileIndex];
      _previewExt =
          p.extension(_previewPath!).toLowerCase().replaceFirst('.', '');
      _transformController.value = Matrix4.identity();
      setState(() {});
      _pickerKey.currentState?.selectFile(_previewPath!);
    }
  }

  void _openFileFull(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');

    if (_imageExtensions.contains(ext)) {
      final dir = Directory(p.dirname(path));
      List<String> siblings;
      int index;
      try {
        siblings = dir
            .listSync()
            .whereType<File>()
            .where((f) {
              final e =
                  p.extension(f.path).toLowerCase().replaceFirst('.', '');
              return _imageExtensions.contains(e);
            })
            .map((f) => f.path)
            .toList()
          ..sort((a, b) => p
              .basename(a)
              .toLowerCase()
              .compareTo(p.basename(b).toLowerCase()));
        index = siblings.indexOf(path).clamp(0, siblings.length - 1);
      } catch (_) {
        siblings = [path];
        index = 0;
      }
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PhotoViewerPage(
            imagePaths: siblings,
            initialIndex: index,
          ),
        ),
      );
    } else if (ext == 'pdf') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DocumentViewerEditorPage(
            filePath: path,
            viewerType: DocumentViewerType.pdf,
          ),
        ),
      );
    } else if (ext == 'md' || ext == 'markdown') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DocumentViewerEditorPage(
            filePath: path,
            viewerType: DocumentViewerType.markdown,
          ),
        ),
      );
    } else if (_textExtensions.contains(ext)) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DocumentViewerEditorPage(
            filePath: path,
            viewerType: DocumentViewerType.text,
          ),
        ),
      );
    } else if (_videoExtensions.contains(ext)) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(p.basename(path)),
            ),
            body: Center(
              child: VideoPlayerWidget(
                videoPath: path,
                autoPlay: true,
              ),
            ),
          ),
        ),
      );
    } else if (_audioExtensions.contains(ext)) {
      _openExternal(path);
    } else {
      _openExternal(path);
    }
  }

  Future<void> _regenerateTemplate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Regenerate template?'),
        content: const Text(
          'This will overwrite index.html and styles.css with the '
          'default generated template. Any manual edits to those '
          'files will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final app = AppService().getAppByType('www');
      if (app == null) throw Exception('www app not found');
      await AppService().generateDefaultWwwIndex(app);
      _pickerKey.currentState?.refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Template regenerated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to regenerate template: $e')),
        );
      }
    }
  }

  Future<void> _openExternal(String path) async {
    final uri = Uri.file(path);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isFilesTab = _tabController.index == 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.appTitle),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.folder), text: 'Files'),
            Tab(icon: Icon(Icons.preview), text: 'Preview'),
          ],
        ),
        actions: isFilesTab
            ? [
                IconButton(
                  icon: const Icon(Icons.restart_alt),
                  tooltip: 'Regenerate template',
                  onPressed: _regenerateTemplate,
                ),
                ...?_pickerKey.currentState?.buildActions(),
              ]
            : null,
      ),
      body: Column(
        children: [
          _buildUrlBar(),
          _buildHomepageToggle(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildFilesTab(),
                _buildPreviewTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // URL bar
  // ---------------------------------------------------------------------------

  Widget _buildUrlBar() {
    final publicUrl = _getPublicUrl();
    if (publicUrl == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: InkWell(
        onTap: () => launchUrl(Uri.parse(publicUrl)),
        child: Row(
          children: [
            Icon(Icons.language, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                publicUrl,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: 'Copy URL',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: publicUrl));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('URL copied to clipboard')),
                );
              },
            ),
            if (Platform.isAndroid || Platform.isIOS) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.share, size: 18),
                tooltip: 'Share URL',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => Share.share(publicUrl),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Custom-homepage toggle
  // ---------------------------------------------------------------------------

  Widget _buildHomepageToggle() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Icon(
            _useCustomHomepage ? Icons.edit_document : Icons.auto_awesome,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Use custom homepage',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  _useCustomHomepage
                      ? 'Visitors see your edited index.html'
                      : 'Visitors see an auto-generated page',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (_customHomepageBusy)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Switch(
              value: _useCustomHomepage,
              onChanged: _toggleCustomHomepage,
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Files tab
  // ---------------------------------------------------------------------------

  Widget _buildFilesTab() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 800;

        if (!isWide && _previewPath != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _previewPath = null);
          });
        }

        if (isWide && _previewPath != null) {
          final totalWidth = constraints.maxWidth;
          final browserWidth =
              (totalWidth * _dividerRatio).clamp(200.0, totalWidth - 200.0);

          return Row(
            children: [
              SizedBox(width: browserWidth, child: _buildFileBrowser()),
              _buildDragHandle(totalWidth),
              Expanded(child: _buildFilePreviewPanel()),
            ],
          );
        }

        return _buildFileBrowser();
      },
    );
  }

  Widget _buildFileBrowser() {
    return FileFolderPicker(
      key: _pickerKey,
      initialDirectory: widget.appPath,
      title: widget.appTitle,
      explorerMode: true,
      onFileOpen: _openFile,
      allowMultiSelect: false,
      onStateChanged: () => setState(() {}),
      profileStorage: AppService().profileStorage,
      showStorageBar: false,
      rootPath: widget.appPath,
    );
  }

  Widget _buildDragHandle(double totalWidth) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) {
          setState(() {
            _dividerRatio =
                ((_dividerRatio * totalWidth + details.delta.dx) / totalWidth)
                    .clamp(200.0 / totalWidth, 1.0 - 200.0 / totalWidth);
          });
        },
        child: SizedBox(
          width: 8,
          child: Center(
            child: VerticalDivider(
              width: 1,
              color: Theme.of(context).dividerColor,
            ),
          ),
        ),
      ),
    );
  }

  bool get _isFilePreviewEditable =>
      DocumentViewerWidget.isEditableExtension(_previewExt);

  Widget _buildFilePreviewPanel() {
    final filename = p.basename(_previewPath!);
    final theme = Theme.of(context);
    final viewerState = _viewerKey.currentState;
    final isEditing = viewerState?.isEditing ?? false;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border(
              bottom: BorderSide(color: theme.dividerColor),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.preview, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isEditing
                      ? '$filename (editing)'
                      : _folderFiles.length > 1
                          ? '$filename (${_currentFileIndex + 1}/${_folderFiles.length})'
                          : filename,
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isEditing) ...[
                IconButton(
                  icon: const Icon(Icons.save, size: 20),
                  tooltip: 'Save',
                  onPressed: (viewerState?.hasUnsavedChanges ?? false)
                      ? () async {
                          await viewerState?.saveFile();
                          setState(() {});
                        }
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: 'Cancel editing',
                  onPressed: () async {
                    await viewerState?.cancelEditing();
                    setState(() {});
                  },
                ),
              ] else ...[
                if (_isFilePreviewEditable)
                  IconButton(
                    icon: const Icon(Icons.edit, size: 20),
                    tooltip: 'Edit',
                    onPressed: () {
                      viewerState?.startEditing();
                      setState(() {});
                    },
                  ),
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 20),
                  tooltip: 'Open full screen',
                  onPressed: () {
                    final path = _previewPath!;
                    setState(() => _previewPath = null);
                    _openFileFull(path);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: 'Close preview',
                  onPressed: () => setState(() => _previewPath = null),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: _buildFilePreviewContent(_previewPath!, _previewExt),
        ),
      ],
    );
  }

  Widget _buildFilePreviewContent(String path, String ext) {
    if (_imageExtensions.contains(ext)) {
      _imageFocusNode.requestFocus();
      return KeyboardListener(
        focusNode: _imageFocusNode,
        onKeyEvent: (event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _goToPrevious();
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _goToNext();
          }
        },
        child: Stack(
          children: [
            Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  final keys = HardwareKeyboard.instance.logicalKeysPressed;
                  final ctrlHeld =
                      keys.contains(LogicalKeyboardKey.controlLeft) ||
                          keys.contains(LogicalKeyboardKey.controlRight);
                  if (ctrlHeld) {
                    const minScale = 0.5;
                    const maxScale = 4.0;
                    final scaleDelta =
                        event.scrollDelta.dy > 0 ? 0.9 : 1.1;
                    final currentScale =
                        _transformController.value.getMaxScaleOnAxis();
                    final newScale =
                        (currentScale * scaleDelta).clamp(minScale, maxScale);
                    final focalPoint = event.localPosition;
                    final s = newScale / currentScale;
                    final dx = focalPoint.dx * (1 - s);
                    final dy = focalPoint.dy * (1 - s);
                    final matrix = Matrix4.identity()
                      ..setEntry(0, 0, s)
                      ..setEntry(1, 1, s)
                      ..setEntry(0, 3, dx)
                      ..setEntry(1, 3, dy);
                    _transformController.value =
                        _transformController.value * matrix;
                  }
                }
              },
              child: InteractiveViewer(
                key: ValueKey(path),
                transformationController: _transformController,
                minScale: 0.5,
                maxScale: 4.0,
                child: Center(
                  child: Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return const Center(
                        child: Icon(Icons.broken_image,
                            size: 64, color: Colors.grey),
                      );
                    },
                  ),
                ),
              ),
            ),
            if (_folderFiles.length > 1)
              Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildNavigationButton(
                    icon: Icons.chevron_left,
                    onPressed:
                        _currentFileIndex > 0 ? _goToPrevious : null,
                  ),
                ),
              ),
            if (_folderFiles.length > 1)
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildNavigationButton(
                    icon: Icons.chevron_right,
                    onPressed:
                        _currentFileIndex < _folderFiles.length - 1
                            ? _goToNext
                            : null,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    if (_videoExtensions.contains(ext)) {
      return VideoPlayerWidget(
        key: ValueKey(path),
        videoPath: path,
        autoPlay: true,
      );
    }

    if (ext == 'pdf') {
      _imageFocusNode.requestFocus();
      return KeyboardListener(
        focusNode: _imageFocusNode,
        onKeyEvent: (event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _goToPrevious();
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _goToNext();
          }
        },
        child: Stack(
          children: [
            DocumentViewerWidget(
              key: ValueKey(path),
              filePath: path,
              viewerType: DocumentViewerType.pdf,
            ),
            if (_folderFiles.length > 1)
              Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildNavigationButton(
                    icon: Icons.chevron_left,
                    onPressed:
                        _currentFileIndex > 0 ? _goToPrevious : null,
                  ),
                ),
              ),
            if (_folderFiles.length > 1)
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildNavigationButton(
                    icon: Icons.chevron_right,
                    onPressed:
                        _currentFileIndex < _folderFiles.length - 1
                            ? _goToNext
                            : null,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    if (ext == 'md' || ext == 'markdown') {
      return DocumentViewerWidget(
        key: _viewerKey,
        filePath: path,
        viewerType: DocumentViewerType.markdown,
        editable: true,
        showEditToolbar: false,
      );
    }

    return DocumentViewerWidget(
      key: _viewerKey,
      filePath: path,
      viewerType: DocumentViewerType.text,
      editable: true,
      showEditToolbar: false,
    );
  }

  Widget _buildNavigationButton({
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(30),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: onPressed != null ? Colors.black54 : Colors.black26,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: onPressed != null ? Colors.white : Colors.white38,
            size: 32,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Preview tab (platform-adaptive WebView)
  // ---------------------------------------------------------------------------

  Widget _buildPreviewTab() {
    if (_previewLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_previewUrl == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.web_asset_off,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              'No index.html found',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Create an index.html file in the Files tab to preview your website.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _loadPreview,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        _buildPreviewContent(),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.small(
            onPressed: _loadPreview,
            tooltip: 'Refresh preview',
            child: const Icon(Icons.refresh),
          ),
        ),
      ],
    );
  }

  Widget _buildPreviewContent() {
    final url = _previewUrl;
    if (url == null) {
      return const Center(child: Text('Preview unavailable'));
    }

    // Android / iOS / macOS — webview_flutter
    if ((Platform.isAndroid || Platform.isIOS || Platform.isMacOS) &&
        _webViewController != null) {
      return WebViewWidget(controller: _webViewController!);
    }

    // Windows — webview_windows (WebView2)
    if (Platform.isWindows && _winWebViewReady && _winWebViewController != null) {
      return wv_windows.Webview(_winWebViewController!);
    }

    // Linux — webf (QuickJS engine). Loads via http://, so the global
    // /styles.css that the dark Terminimal theme depends on is fetched
    // from the local server instead of resolving to file:///styles.css.
    if (Platform.isLinux) {
      return WebF.fromControllerName(
        key: ValueKey('webf-preview-$_webfKey'),
        controllerName: 'website-preview',
        bundle: WebFBundle.fromUrl(url),
        forceLoad: true,
        initialRoute: null,
        loadingWidget: const Center(child: CircularProgressIndicator()),
        errorBuilder: (context, error) => Center(
          child: Text('Preview error: $error'),
        ),
      );
    }

    return const Center(child: Text('Preview unavailable'));
  }
}
