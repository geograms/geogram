/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:highlighting/highlighting.dart';
import 'package:flutter_highlighting/themes/vs2015.dart';
import 'package:flutter_highlighting/themes/github.dart';
import 'package:pdfx/pdfx.dart';
import 'package:path/path.dart' as path;

import '../models/mirror_config.dart';
import '../models/sync_file_version.dart';
import '../services/app_service.dart';
import '../services/sync_version_service.dart';
import '../widgets/syntax_highlight_controller.dart';

/// Document viewer type options.
enum DocumentViewerType {
  text,      // .txt, .log, plain text
  markdown,  // .md files
  pdf,       // .pdf files
  cbz,       // .cbz manga (future)
  auto,      // Detect from file extension
}

/// Reusable document viewer widget (no Scaffold).
///
/// Displays documents based on file extension or explicit viewer type.
/// Can be embedded in any layout — split-pane previews, dialogs, etc.
/// Set [editable] to true to enable inline text editing for supported formats.
class DocumentViewerWidget extends StatefulWidget {
  /// Path to the document file.
  final String filePath;

  /// Force a specific viewer type (default: auto-detect from extension).
  final DocumentViewerType viewerType;

  /// Whether to allow editing for text-based files (default: false).
  final bool editable;

  /// Whether to show the built-in edit toolbar (default: true).
  /// Set to false when hosting code provides its own edit button
  /// and calls [DocumentViewerWidgetState.startEditing] via a GlobalKey.
  final bool showEditToolbar;

  /// Called after a successful save when editing.
  final VoidCallback? onSaved;

  const DocumentViewerWidget({
    super.key,
    required this.filePath,
    this.viewerType = DocumentViewerType.auto,
    this.editable = false,
    this.showEditToolbar = true,
    this.onSaved,
  });

  /// Check if a file extension supports text editing.
  static bool isEditableExtension(String ext) {
    const editable = {
      'txt', 'log', 'json', 'xml', 'csv', 'yaml', 'yml', 'ini', 'conf',
      'cfg', 'toml', 'md', 'markdown', 'html', 'htm', 'css',
      'dart', 'py', 'js', 'ts', 'java', 'c', 'cpp', 'h', 'sh', 'bat',
      'kt', 'go', 'rs', 'rb', 'php',
      // New extensions
      'sql', 'lua', 'swift', 'r', 'pl', 'pm', 'scala', 'hs',
      'ex', 'exs', 'clj', 'zig', 'nim', 'makefile', 'dockerfile',
      'gradle', 'tf', 'ps1', 'fish', 'zsh', 'scss', 'sass', 'less',
      'jsx', 'tsx', 'vue', 'svelte', 'graphql', 'gql',
      'bash', 'properties',
    };
    return editable.contains(ext.toLowerCase());
  }

  @override
  DocumentViewerWidgetState createState() => DocumentViewerWidgetState();
}

class DocumentViewerWidgetState extends State<DocumentViewerWidget> {
  DocumentViewerType _resolvedType = DocumentViewerType.text;
  String? _textContent;
  List<Uint8List> _pdfPages = [];
  bool _isLoading = true;
  String? _error;
  PdfDocument? _pdfDocument;

  // Zoom state for PDF viewer
  final _pdfTransformController = TransformationController();

  // Editing state
  bool _isEditing = false;
  bool _hasUnsavedChanges = false;
  late TextEditingController _editController;

  // Syntax highlighting state
  String? _languageId;

  // Active line number (0-indexed) for gutter highlight
  int? _activeLine;

  // Find-in-file state
  bool _showFindBar = false;
  final _findController = TextEditingController();
  final _findFocusNode = FocusNode();
  final _keyFocusNode = FocusNode();
  List<int> _findOffsets = [];   // start offsets of each match
  int _findCurrent = -1;         // index into _findOffsets

  // Scroll controllers for syncing editor line-number gutter
  final _editScrollController = ScrollController();
  final _gutterScrollController = ScrollController();

  // Debounced gutter state for editor (lineCount, activeLine)
  final _gutterState = ValueNotifier<(int, int?)>((1, null));
  Timer? _gutterDebounce;

  void _syncGutterScroll() {
    if (_gutterScrollController.hasClients) {
      final max = _gutterScrollController.position.maxScrollExtent;
      _gutterScrollController.jumpTo(
        _editScrollController.offset.clamp(0.0, max),
      );
    }
  }

  void _scheduleGutterUpdate() {
    _gutterDebounce?.cancel();
    _gutterDebounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      final text = _editController.text;
      final lineCount = '\n'.allMatches(text).length + 1;
      int? activeLine;
      final offset = _editController.selection.baseOffset;
      if (offset >= 0) {
        activeLine = _lineFromOffset(text, offset);
      }
      _gutterState.value = (lineCount, activeLine);
    });
  }

  /// Compute 0-indexed line number from a character offset in [text].
  static int _lineFromOffset(String text, int offset) {
    return '\n'.allMatches(text.substring(0, offset.clamp(0, text.length))).length;
  }

  /// Build gutter text with the active line highlighted.
  Text _buildGutterText({
    required int lineCount,
    required int? activeLine,
    required TextStyle? baseStyle,
  }) {
    final activeStyle = baseStyle?.copyWith(
      color: Theme.of(context).colorScheme.onSurface,
      fontWeight: FontWeight.w600,
    );

    final spans = <InlineSpan>[];
    for (int i = 0; i < lineCount; i++) {
      if (i > 0) spans.add(const TextSpan(text: '\n'));
      spans.add(TextSpan(
        text: '${i + 1}',
        style: i == activeLine ? activeStyle : null,
      ));
    }

    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      textAlign: TextAlign.right,
    );
  }

  /// Create the appropriate controller for the current file.
  TextEditingController _createController() {
    _languageId = languageIdForFile(widget.filePath);
    if (_languageId != null) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      return SyntaxHighlightController(
        languageId: _languageId!,
        brightness: brightness,
      );
    }
    return TextEditingController();
  }

  @override
  void initState() {
    super.initState();
    _editController = _createController();
    _editController.addListener(_scheduleGutterUpdate);
    _editScrollController.addListener(_syncGutterScroll);
    _loadDocument();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Update syntax theme when brightness changes
    final controller = _editController;
    if (controller is SyntaxHighlightController) {
      controller.updateBrightness(Theme.of(context).brightness);
    }
  }

  @override
  void didUpdateWidget(DocumentViewerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath ||
        oldWidget.viewerType != widget.viewerType) {
      _pdfDocument?.close();
      _pdfDocument = null;
      _pdfPages = [];
      _pdfTransformController.value = Matrix4.identity();
      _textContent = null;
      _isEditing = false;
      _hasUnsavedChanges = false;
      _activeLine = null;
      _showFindBar = false;
      _findController.clear();
      _findOffsets = [];
      _findCurrent = -1;
      _editController.removeListener(_scheduleGutterUpdate);
      _editController.dispose();
      _editController = _createController();
      _editController.addListener(_scheduleGutterUpdate);
      _gutterState.value = (1, null);
      _loadDocument();
    }
  }

  @override
  void dispose() {
    _gutterDebounce?.cancel();
    _pdfDocument?.close();
    _pdfTransformController.dispose();
    _editScrollController.removeListener(_syncGutterScroll);
    _editScrollController.dispose();
    _gutterScrollController.dispose();
    _editController.removeListener(_scheduleGutterUpdate);
    _editController.dispose();
    _gutterState.dispose();
    _findController.dispose();
    _findFocusNode.dispose();
    _keyFocusNode.dispose();
    super.dispose();
  }

  /// Detect viewer type from file extension.
  DocumentViewerType _detectType(String filePath) {
    final ext = filePath.toLowerCase().split('.').last;
    switch (ext) {
      case 'pdf':
        return DocumentViewerType.pdf;
      case 'md':
      case 'markdown':
        return DocumentViewerType.markdown;
      case 'cbz':
        return DocumentViewerType.cbz;
      case 'txt':
      case 'log':
      case 'json':
      case 'xml':
      case 'csv':
      case 'yaml':
      case 'yml':
      case 'html':
      case 'htm':
      case 'css':
      case 'js':
      case 'dart':
      case 'py':
      case 'java':
      case 'c':
      case 'cpp':
      case 'h':
      case 'sh':
      case 'bat':
      case 'ini':
      case 'conf':
      case 'cfg':
      case 'toml':
      case 'kt':
      case 'go':
      case 'rs':
      case 'rb':
      case 'php':
      // New extensions
      case 'sql':
      case 'lua':
      case 'swift':
      case 'r':
      case 'pl':
      case 'pm':
      case 'scala':
      case 'hs':
      case 'ex':
      case 'exs':
      case 'clj':
      case 'zig':
      case 'nim':
      case 'makefile':
      case 'dockerfile':
      case 'gradle':
      case 'tf':
      case 'ps1':
      case 'fish':
      case 'zsh':
      case 'bash':
      case 'scss':
      case 'sass':
      case 'less':
      case 'jsx':
      case 'tsx':
      case 'vue':
      case 'svelte':
      case 'graphql':
      case 'gql':
      case 'properties':
      default:
        return DocumentViewerType.text;
    }
  }

  /// Load the document content based on type.
  Future<void> _loadDocument() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Resolve viewer type
      _resolvedType = widget.viewerType == DocumentViewerType.auto
          ? _detectType(widget.filePath)
          : widget.viewerType;

      final file = File(widget.filePath);
      if (!await file.exists()) {
        throw Exception('File not found: ${widget.filePath}');
      }

      switch (_resolvedType) {
        case DocumentViewerType.pdf:
          await _loadPdf(file);
          break;
        case DocumentViewerType.cbz:
          // Future implementation
          throw Exception('CBZ viewer not yet implemented');
        case DocumentViewerType.text:
        case DocumentViewerType.markdown:
        case DocumentViewerType.auto:
          _textContent = await file.readAsString();
          break;
      }

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Load PDF and render all pages as images.
  Future<void> _loadPdf(File file) async {
    if (Platform.isLinux) {
      await _loadPdfLinux(file);
    } else {
      await _loadPdfNative(file);
    }
  }

  /// Linux fallback: render PDF pages via pdftoppm (poppler-utils).
  Future<void> _loadPdfLinux(File file) async {
    final tempDir = await Directory.systemTemp.createTemp('geogram_pdf_');
    final prefix = path.join(tempDir.path, 'page');
    final result = await Process.run(
      'pdftoppm', ['-png', '-r', '200', file.path, prefix],
    );
    if (result.exitCode != 0) {
      await tempDir.delete(recursive: true);
      throw Exception('pdftoppm failed: ${result.stderr}');
    }

    final pngFiles = tempDir.listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final pages = <Uint8List>[];
    for (final png in pngFiles) {
      pages.add(await png.readAsBytes());
    }
    await tempDir.delete(recursive: true);
    _pdfPages = pages;
  }

  /// Native PDF rendering via pdfx (non-Linux platforms).
  Future<void> _loadPdfNative(File file) async {
    _pdfDocument = await PdfDocument.openFile(file.path);
    final pageCount = _pdfDocument!.pagesCount;
    final pages = <Uint8List>[];

    for (int i = 1; i <= pageCount; i++) {
      final page = await _pdfDocument!.getPage(i);
      final pageImage = await page.render(
        width: page.width * 2, // 2x for better quality
        height: page.height * 2,
        format: PdfPageImageFormat.png,
      );
      await page.close();

      if (pageImage != null) {
        pages.add(pageImage.bytes);
      }
    }

    _pdfPages = pages;
  }

  @override
  Widget build(BuildContext context) {
    return _buildBody();
  }

  /// Whether the current resolved type supports editing.
  bool get isEditableType =>
      _resolvedType == DocumentViewerType.text ||
      _resolvedType == DocumentViewerType.markdown;

  /// Whether the widget is currently in edit mode.
  bool get isEditing => _isEditing;

  /// Whether there are unsaved changes.
  bool get hasUnsavedChanges => _hasUnsavedChanges;

  /// Enter edit mode (loads current text content into the editor).
  void startEditing() {
    _editController.text = _textContent ?? '';
    final text = _editController.text;
    final lc = '\n'.allMatches(text).length + 1;
    _gutterState.value = (lc, null);
    setState(() => _isEditing = true);
  }

  /// Save edited content to disk.
  Future<void> saveFile() async {
    try {
      await _archiveBeforeSave();
      await File(widget.filePath).writeAsString(_editController.text);
      await _clearTombstoneAfterSave();
      setState(() {
        _textContent = _editController.text;
        _hasUnsavedChanges = false;
        _isEditing = false;
      });
      widget.onSaved?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }

  /// Save edited content to disk without leaving edit mode (for Ctrl+S).
  Future<void> _saveInPlace() async {
    try {
      await _archiveBeforeSave();
      await File(widget.filePath).writeAsString(_editController.text);
      await _clearTombstoneAfterSave();
      setState(() {
        _textContent = _editController.text;
        _hasUnsavedChanges = false;
      });
      widget.onSaved?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }

  ({String folder, String filePath})? _profileSyncPath() {
    final storage = AppService().profileStorage;
    if (storage == null) return null;
    final basePath = storage.basePath;
    if (widget.filePath != basePath && !path.isWithin(basePath, widget.filePath)) {
      return null;
    }
    final relativePath = widget.filePath == basePath
        ? ''
        : path.relative(widget.filePath, from: basePath).replaceAll('\\', '/');
    final slash = relativePath.indexOf('/');
    if (slash <= 0 || slash == relativePath.length - 1) return null;
    final folder = relativePath.substring(0, slash);
    if (!kSyncableFolders.contains(folder)) return null;
    return (folder: folder, filePath: relativePath.substring(slash + 1));
  }

  Future<void> _archiveBeforeSave() async {
    final syncPath = _profileSyncPath();
    if (syncPath == null) return;
    await SyncVersionService.instance.archiveProfileFile(
      folder: syncPath.folder,
      filePath: syncPath.filePath,
      reason: SyncVersionReason.modified,
    );
  }

  Future<void> _clearTombstoneAfterSave() async {
    final syncPath = _profileSyncPath();
    if (syncPath == null) return;
    await SyncVersionService.instance.removeTombstone(
      syncPath.folder,
      syncPath.filePath,
    );
  }

  /// Cancel editing (prompts if there are unsaved changes).
  Future<void> cancelEditing() async {
    if (_hasUnsavedChanges) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard changes?'),
          content: const Text('You have unsaved changes. Discard them?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep editing'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    setState(() {
      _isEditing = false;
      _hasUnsavedChanges = false;
    });
  }

  // -- Keyboard shortcut handler --

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isCtrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyS && _isEditing) {
      if (_hasUnsavedChanges) _saveInPlace();
      return KeyEventResult.handled;
    }
    if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyF) {
      _toggleFindBar();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && _showFindBar) {
      _closeFindBar();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // -- Find-in-file logic --

  void _toggleFindBar() {
    setState(() => _showFindBar = true);
    // Delay focus request to after the build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _findFocusNode.requestFocus();
    });
  }

  void _closeFindBar() {
    setState(() {
      _showFindBar = false;
      _findController.clear();
      _findOffsets = [];
      _findCurrent = -1;
    });
  }

  void _onFindChanged(String query) {
    if (query.isEmpty) {
      setState(() {
        _findOffsets = [];
        _findCurrent = -1;
      });
      return;
    }

    final text = _isEditing ? _editController.text : (_textContent ?? '');
    final lowerQuery = query.toLowerCase();
    final lowerText = text.toLowerCase();
    final offsets = <int>[];
    var start = 0;
    while (true) {
      final idx = lowerText.indexOf(lowerQuery, start);
      if (idx == -1) break;
      offsets.add(idx);
      start = idx + 1;
    }

    setState(() {
      _findOffsets = offsets;
      _findCurrent = offsets.isEmpty ? -1 : 0;
    });

    if (_isEditing && offsets.isNotEmpty) {
      _selectEditMatch(0);
    }
  }

  void _findNext() {
    if (_findOffsets.isEmpty) return;
    setState(() {
      _findCurrent = (_findCurrent + 1) % _findOffsets.length;
    });
    if (_isEditing) _selectEditMatch(_findCurrent);
  }

  void _findPrev() {
    if (_findOffsets.isEmpty) return;
    setState(() {
      _findCurrent = (_findCurrent - 1 + _findOffsets.length) % _findOffsets.length;
    });
    if (_isEditing) _selectEditMatch(_findCurrent);
  }

  void _selectEditMatch(int matchIndex) {
    final offset = _findOffsets[matchIndex];
    final len = _findController.text.length;
    _editController.selection = TextSelection(
      baseOffset: offset,
      extentOffset: offset + len,
    );
  }

  Widget _buildEditToolbar() {
    final theme = Theme.of(context);

    if (_isEditing) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          border: Border(
            bottom: BorderSide(color: theme.dividerColor),
          ),
        ),
        child: Row(
          children: [
            Text('Editing', style: theme.textTheme.labelLarge),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.search, size: 20),
              tooltip: 'Find (Ctrl+F)',
              onPressed: _toggleFindBar,
            ),
            TextButton(
              onPressed: cancelEditing,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _hasUnsavedChanges ? saveFile : null,
              icon: const Icon(Icons.save, size: 18),
              label: const Text('Save'),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: Row(
        children: [
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.search, size: 20),
            tooltip: 'Find (Ctrl+F)',
            onPressed: _toggleFindBar,
          ),
          IconButton(
            icon: const Icon(Icons.edit, size: 20),
            tooltip: 'Edit',
            onPressed: startEditing,
          ),
        ],
      ),
    );
  }

  Widget _buildEditor() {
    final monoStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      height: 1.5,
    );
    final gutterStyle = monoStyle?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
    );

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(top: 16, right: 16, bottom: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Line number gutter — debounced, rebuilds after 150ms of inactivity
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: ValueListenableBuilder<(int, int?)>(
                valueListenable: _gutterState,
                builder: (context, state, _) {
                  final (lineCount, activeLine) = state;
                  final digits = lineCount.toString().length;
                  final gutterWidth = (digits < 2 ? 2 : digits) * 10.0 + 12.0;

                  return SizedBox(
                    width: gutterWidth,
                    child: SingleChildScrollView(
                      controller: _gutterScrollController,
                      physics: const NeverScrollableScrollPhysics(),
                      child: _buildGutterText(
                        lineCount: lineCount,
                        activeLine: activeLine,
                        baseStyle: gutterStyle,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            // Editor
            Expanded(
              child: TextField(
                controller: _editController,
                scrollController: _editScrollController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: monoStyle,
                decoration: const InputDecoration.collapsed(hintText: ''),
                onChanged: (_) {
                  if (!_hasUnsavedChanges) {
                    setState(() => _hasUnsavedChanges = true);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFindBar() {
    return Positioned(
      top: 8,
      right: 16,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          width: 300,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _findController,
                  focusNode: _findFocusNode,
                  decoration: const InputDecoration(
                    hintText: 'Find...',
                    isDense: true,
                    border: InputBorder.none,
                  ),
                  onChanged: _onFindChanged,
                  onSubmitted: (_) => _findNext(),
                ),
              ),
              Text(
                '${_findOffsets.isEmpty ? 0 : _findCurrent + 1}/${_findOffsets.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 18),
                onPressed: _findPrev,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: const Icon(Icons.arrow_downward, size: 18),
                onPressed: _findNext,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: _closeFindBar,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _wrapWithKeyboardAndFind(Widget content) {
    return Focus(
      focusNode: _keyFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Stack(
        children: [
          content,
          if (_showFindBar) _buildFindBar(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadDocument,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    // Show edit toolbar + editor/viewer for editable types
    if (widget.editable && isEditableType) {
      if (_isEditing) {
        // Always show the save/cancel toolbar when editing
        return _wrapWithKeyboardAndFind(Column(
          children: [
            _buildEditToolbar(),
            _buildEditor(),
          ],
        ));
      }
      if (widget.showEditToolbar) {
        // Show the built-in edit button toolbar
        return _wrapWithKeyboardAndFind(Column(
          children: [
            _buildEditToolbar(),
            Expanded(child: _buildViewer()),
          ],
        ));
      }
      // Editable but toolbar managed externally — just show viewer
      return _wrapWithKeyboardAndFind(_buildViewer());
    }

    return _wrapWithKeyboardAndFind(_buildViewer());
  }

  Widget _buildViewer() {
    switch (_resolvedType) {
      case DocumentViewerType.pdf:
        return _buildPdfViewer();
      case DocumentViewerType.markdown:
        return _buildMarkdownViewer();
      case DocumentViewerType.text:
      case DocumentViewerType.cbz:
      case DocumentViewerType.auto:
      default:
        return _buildTextViewer();
    }
  }

  /// Build PDF viewer with continuous vertical scroll.
  Widget _buildPdfViewer() {
    if (_pdfPages.isEmpty) {
      return const Center(child: Text('No pages found'));
    }

    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          final keys = HardwareKeyboard.instance.logicalKeysPressed;
          final ctrlHeld = keys.contains(LogicalKeyboardKey.controlLeft) ||
              keys.contains(LogicalKeyboardKey.controlRight);
          if (ctrlHeld) {
            const minScale = 0.5;
            const maxScale = 4.0;
            final scaleDelta = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
            final currentScale = _pdfTransformController.value.getMaxScaleOnAxis();
            final newScale = (currentScale * scaleDelta).clamp(minScale, maxScale);
            final focalPoint = event.localPosition;
            final s = newScale / currentScale;
            final dx = focalPoint.dx * (1 - s);
            final dy = focalPoint.dy * (1 - s);
            final matrix = Matrix4.identity()
              ..setEntry(0, 0, s)
              ..setEntry(1, 1, s)
              ..setEntry(0, 3, dx)
              ..setEntry(1, 3, dy);
            _pdfTransformController.value = _pdfTransformController.value * matrix;
          }
        }
      },
      child: InteractiveViewer(
        transformationController: _pdfTransformController,
        minScale: 0.5,
        maxScale: 4.0,
        constrained: false,
        child: SizedBox(
          width: MediaQuery.of(context).size.width,
          child: Column(
            children: _pdfPages.asMap().entries.map((entry) {
              final index = entry.key;
              final pageBytes = entry.value;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    // Page image
                    Image.memory(
                      pageBytes,
                      fit: BoxFit.fitWidth,
                      errorBuilder: (context, error, stackTrace) {
                        return const SizedBox(
                          height: 200,
                          child: Center(child: Icon(Icons.broken_image, color: Colors.grey)),
                        );
                      },
                    ),
                    // Page number
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(
                        'Page ${index + 1} of ${_pdfPages.length}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  /// Build markdown viewer.
  Widget _buildMarkdownViewer() {
    final theme = Theme.of(context);

    return Markdown(
      data: _textContent ?? '',
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        h1: theme.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.bold,
        ),
        h2: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        h3: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        p: theme.textTheme.bodyMedium,
        blockquote: theme.textTheme.bodyMedium?.copyWith(
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: theme.colorScheme.primary,
              width: 4,
            ),
          ),
        ),
        code: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }

  /// Build text spans with find-match highlights applied.
  List<InlineSpan> _buildFindHighlightSpans(String text, TextStyle? baseStyle) {
    final spans = <InlineSpan>[];
    final queryLen = _findController.text.length;
    var pos = 0;
    for (var i = 0; i < _findOffsets.length; i++) {
      final matchStart = _findOffsets[i];
      if (matchStart > pos) {
        spans.add(TextSpan(text: text.substring(pos, matchStart)));
      }
      final isCurrent = i == _findCurrent;
      spans.add(TextSpan(
        text: text.substring(matchStart, matchStart + queryLen),
        style: TextStyle(
          backgroundColor: isCurrent ? Colors.orange : Colors.yellow.withValues(alpha: 0.6),
          color: Colors.black,
        ),
      ));
      pos = matchStart + queryLen;
    }
    if (pos < text.length) {
      spans.add(TextSpan(text: text.substring(pos)));
    }
    return spans;
  }

  /// Build text viewer with optional syntax highlighting and line numbers.
  Widget _buildTextViewer() {
    final appTheme = Theme.of(context);
    final content = _textContent ?? '';
    final monoStyle = appTheme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      height: 1.5,
    );

    // Line number gutter
    final lineCount = '\n'.allMatches(content).length + 1;
    final digits = lineCount.toString().length;
    final gutterWidth = (digits < 2 ? 2 : digits) * 10.0 + 12.0;
    final gutterStyle = monoStyle?.copyWith(
      color: appTheme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
    );
    final lineHeight =
        (monoStyle?.fontSize ?? 14.0) * (monoStyle?.height ?? 1.5);

    Widget wrapWithGutter(Widget textWidget) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            final line = (event.localPosition.dy / lineHeight).floor();
            if (line >= 0 && line < lineCount && _activeLine != line) {
              setState(() => _activeLine = line);
            }
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: gutterWidth,
                child: _buildGutterText(
                  lineCount: lineCount,
                  activeLine: _activeLine,
                  baseStyle: gutterStyle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: textWidget),
            ],
          ),
        ),
      );
    }

    // Apply find highlights to a plain text widget
    Widget applyFindHighlight(String text, TextStyle? style) {
      if (!_showFindBar || _findOffsets.isEmpty) {
        return SelectableText(text, style: style);
      }
      return SelectableText.rich(
        TextSpan(style: style, children: _buildFindHighlightSpans(text, style)),
      );
    }

    // No highlighting for plain text or oversized files
    if (_languageId == null || content.length > 100 * 1024) {
      return wrapWithGutter(applyFindHighlight(content, monoStyle));
    }

    // Parse and highlight
    try {
      final result = highlight.parse(content, languageId: _languageId!);
      final nodes = result.nodes;
      if (nodes == null || nodes.isEmpty) {
        return wrapWithGutter(applyFindHighlight(content, monoStyle));
      }

      final hlTheme = appTheme.brightness == Brightness.dark
          ? vs2015Theme
          : githubTheme;
      final spans = convertNodesToSpans(nodes, hlTheme);

      // Merge root color from theme into the base style
      final rootStyle = hlTheme['root'];
      final mergedStyle = monoStyle?.copyWith(
        color: rootStyle?.color ?? monoStyle.color,
      );

      return wrapWithGutter(
        SelectableText.rich(TextSpan(style: mergedStyle, children: spans)),
      );
    } catch (_) {
      // Fallback to plain text on parse error
      return wrapWithGutter(applyFindHighlight(content, monoStyle));
    }
  }
}

/// Reusable document viewer/editor page.
///
/// Wraps [DocumentViewerWidget] in a Scaffold with an AppBar.
/// For embedding without a Scaffold, use [DocumentViewerWidget] directly.
class DocumentViewerEditorPage extends StatefulWidget {
  /// Path to the document file.
  final String filePath;

  /// Force a specific viewer type (default: auto-detect from extension).
  final DocumentViewerType viewerType;

  /// Custom title for the app bar (default: filename).
  final String? title;

  /// Read-only mode (default: false).
  final bool readOnly;

  /// Called after a successful save when editing.
  final VoidCallback? onSaved;

  const DocumentViewerEditorPage({
    super.key,
    required this.filePath,
    this.viewerType = DocumentViewerType.auto,
    this.title,
    this.readOnly = false,
    this.onSaved,
  });

  @override
  State<DocumentViewerEditorPage> createState() => _DocumentViewerEditorPageState();
}

class _DocumentViewerEditorPageState extends State<DocumentViewerEditorPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? path.basename(widget.filePath)),
      ),
      body: DocumentViewerWidget(
        filePath: widget.filePath,
        viewerType: widget.viewerType,
        editable: !widget.readOnly && DocumentViewerWidget.isEditableExtension(
          path.extension(widget.filePath).replaceFirst('.', ''),
        ),
        onSaved: widget.onSaved,
      ),
    );
  }
}
