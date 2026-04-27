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
import 'package:url_launcher/url_launcher.dart';

import '../services/app_service.dart';
import '../services/i18n_service.dart';
import '../services/mirror_auto_sync_service.dart';
import '../services/profile_service.dart';
import '../services/profile_storage.dart';
import '../widgets/file_folder_picker.dart';
import '../widgets/video_player_widget.dart';
import 'document_viewer_editor_page.dart';
import 'photo_viewer_page.dart';

/// Built-in file explorer app.
///
/// Embeds [FileFolderPicker] in explorer mode so tapping a file opens it
/// with the appropriate internal viewer, and tapping a folder navigates into it.
///
/// On wide screens (>=800dp), previewable files open in a right-side panel
/// instead of navigating to a full-screen page.
class FilesBrowserPage extends StatefulWidget {
  final String appPath;
  final String appTitle;
  final I18nService i18n;
  final List<Widget>? extraActions;

  const FilesBrowserPage({
    super.key,
    required this.appPath,
    required this.appTitle,
    required this.i18n,
    this.extraActions,
  });

  @override
  State<FilesBrowserPage> createState() => _FilesBrowserPageState();
}

class _FilesBrowserPageState extends State<FilesBrowserPage> {
  final _pickerKey = GlobalKey<FileFolderPickerState>();
  final _viewerKey = GlobalKey<DocumentViewerWidgetState>();
  final _imageFocusNode = FocusNode();
  final _transformController = TransformationController();

  /// Absolute path of the file currently previewed in the right panel.
  String? _previewPath;

  /// Cached extension of the previewed file (no leading dot, lowercase).
  String _previewExt = '';

  /// Sorted list of navigable file paths in the folder of the current preview.
  List<String> _folderFiles = [];

  /// Index of the current preview file within [_folderFiles].
  int _currentFileIndex = 0;

  /// Browser panel width ratio (0.0–1.0). Defaults to 0.4 (40%).
  double _dividerRatio = 0.4;

  @override
  void initState() {
    super.initState();
    // Rebuild after first frame so _pickerKey.currentState is available.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _imageFocusNode.dispose();
    _transformController.dispose();
    super.dispose();
  }

  static const _imageExtensions = {
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg', 'ico', 'heic',
  };

  static const _textExtensions = {
    'txt', 'log', 'json', 'xml', 'csv', 'yaml', 'yml', 'ini', 'conf',
    'dart', 'py', 'js', 'ts', 'css', 'html', 'htm', 'sh', 'c', 'cpp',
    'java', 'kt', 'go', 'rs', 'rb', 'php', 'toml', 'cfg', 'bat',
    'sql', 'lua', 'swift', 'r', 'pl', 'pm', 'scala', 'hs',
    'ex', 'exs', 'clj', 'zig', 'nim', 'makefile', 'dockerfile',
    'gradle', 'tf', 'ps1', 'fish', 'zsh', 'scss', 'sass', 'less',
    'jsx', 'tsx', 'vue', 'svelte', 'graphql', 'gql',
    'bash', 'properties',
  };

  static const _audioExtensions = {
    'mp3', 'wav', 'flac', 'ogg', 'aac', 'm4a', 'opus', 'wma',
  };

  static const _videoExtensions = {
    'mp4', 'avi', 'mkv', 'webm', 'mov', 'wmv', 'm4v', '3gp',
  };

  /// Whether this extension can be shown in the inline preview panel.
  bool _isPreviewable(String ext) {
    return _imageExtensions.contains(ext) ||
        _textExtensions.contains(ext) ||
        _videoExtensions.contains(ext) ||
        ext == 'pdf' ||
        ext == 'md' ||
        ext == 'markdown';
  }

  void _openFile(String path) {
    // For encrypted storage, extract to temp before opening
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
    final tempPath = p.join(Directory.systemTemp.path, 'geogram_preview_$fileName');

    try {
      await storage.copyToExternal(relativePath, tempPath);

      final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
      final isWide = mounted && MediaQuery.of(context).size.width >= 800;

      if (isWide && _isPreviewable(ext)) {
        _transformController.value = Matrix4.identity();
        setState(() {
          _previewPath = tempPath;
          _previewExt = ext;
          // No prev/next navigation for encrypted files
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

  void _scheduleSyncForPath(String filePath) {
    final storage = AppService().profileStorage;
    if (storage == null) return;
    final basePath = storage.basePath;
    if (filePath != basePath && !p.isWithin(basePath, filePath)) return;
    final relativePath =
        filePath == basePath ? '' : p.relative(filePath, from: basePath);
    final firstSegment = relativePath.split(p.separator).first;
    if (firstSegment == 'shared') {
      MirrorAutoSyncService.instance.requestSyncSoon(
        reason: 'shared file saved',
      );
    }
  }

  void _loadFolderFiles(String filePath, Set<String> extensions) {
    final dir = Directory(p.dirname(filePath));
    final files = dir.listSync()
        .whereType<File>()
        .where((f) {
          final ext = p.extension(f.path).toLowerCase().replaceFirst('.', '');
          return extensions.contains(ext);
        })
        .map((f) => f.path)
        .toList()
      ..sort((a, b) => p.basename(a).toLowerCase().compareTo(
          p.basename(b).toLowerCase()));
    _folderFiles = files;
    _currentFileIndex = files.indexOf(filePath).clamp(0, files.length - 1);
  }

  void _goToPrevious() {
    if (_currentFileIndex > 0) {
      _currentFileIndex--;
      _previewPath = _folderFiles[_currentFileIndex];
      _previewExt = p.extension(_previewPath!).toLowerCase().replaceFirst('.', '');
      _transformController.value = Matrix4.identity();
      setState(() {});
      _pickerKey.currentState?.selectFile(_previewPath!);
    }
  }

  void _goToNext() {
    if (_currentFileIndex < _folderFiles.length - 1) {
      _currentFileIndex++;
      _previewPath = _folderFiles[_currentFileIndex];
      _previewExt = p.extension(_previewPath!).toLowerCase().replaceFirst('.', '');
      _transformController.value = Matrix4.identity();
      setState(() {});
      _pickerKey.currentState?.selectFile(_previewPath!);
    }
  }

  /// Navigate to a full-screen viewer for the given file.
  void _openFileFull(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');

    if (_imageExtensions.contains(ext)) {
      // Collect sibling images in the same folder for swipe navigation
      final dir = Directory(p.dirname(path));
      List<String> siblings;
      int index;
      try {
        siblings = dir.listSync()
            .whereType<File>()
            .where((f) {
              final e = p.extension(f.path).toLowerCase().replaceFirst('.', '');
              return _imageExtensions.contains(e);
            })
            .map((f) => f.path)
            .toList()
          ..sort((a, b) => p.basename(a).toLowerCase().compareTo(
              p.basename(b).toLowerCase()));
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
            onSaved: () => _scheduleSyncForPath(path),
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
            onSaved: () => _scheduleSyncForPath(path),
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

  Future<void> _openExternal(String path) async {
    final uri = Uri.file(path);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.appTitle),
        actions: [
          ...?widget.extraActions,
          ...?_pickerKey.currentState?.buildActions(),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 800;

          // Clear preview if screen shrinks below threshold
          if (!isWide && _previewPath != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _previewPath = null);
            });
          }

          if (isWide && _previewPath != null) {
            final totalWidth = constraints.maxWidth;
            final browserWidth = (totalWidth * _dividerRatio)
                .clamp(200.0, totalWidth - 200.0);

            return Row(
              children: [
                SizedBox(width: browserWidth, child: _buildFileBrowser()),
                _buildDragHandle(totalWidth),
                Expanded(child: _buildPreviewPanel()),
              ],
            );
          }

          return _buildFileBrowser();
        },
      ),
    );
  }

  Widget _buildDragHandle(double totalWidth) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) {
          setState(() {
            _dividerRatio = ((_dividerRatio * totalWidth + details.delta.dx) /
                    totalWidth)
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
      extraLocations: [
        StorageLocation(
          name: ProfileService().getProfile().callsign,
          path: widget.appPath,
          icon: Icons.snippet_folder,
        ),
      ],
    );
  }

  /// Whether the current preview file is editable.
  bool get _isPreviewEditable =>
      DocumentViewerWidget.isEditableExtension(_previewExt);

  Widget _buildPreviewPanel() {
    final filename = p.basename(_previewPath!);
    final theme = Theme.of(context);
    final viewerState = _viewerKey.currentState;
    final isEditing = viewerState?.isEditing ?? false;

    return Column(
      children: [
        // Header bar
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
                if (_isPreviewEditable)
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
        // Preview content
        Expanded(
          child: _buildPreviewContent(_previewPath!, _previewExt),
        ),
      ],
    );
  }

  Widget _buildPreviewContent(String path, String ext) {
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
                  final ctrlHeld = keys.contains(LogicalKeyboardKey.controlLeft) ||
                      keys.contains(LogicalKeyboardKey.controlRight);
                  if (ctrlHeld) {
                    const minScale = 0.5;
                    const maxScale = 4.0;
                    final scaleDelta = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
                    final currentScale = _transformController.value.getMaxScaleOnAxis();
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
                    _transformController.value = _transformController.value * matrix;
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
                        child: Icon(Icons.broken_image, size: 64, color: Colors.grey),
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
                    onPressed: _currentFileIndex > 0 ? _goToPrevious : null,
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
                    onPressed: _currentFileIndex < _folderFiles.length - 1
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
                    onPressed: _currentFileIndex > 0 ? _goToPrevious : null,
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
                    onPressed: _currentFileIndex < _folderFiles.length - 1
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
        onSaved: () => _scheduleSyncForPath(path),
      );
    }

    // Text/code/json — all remaining previewable extensions
    return DocumentViewerWidget(
      key: _viewerKey,
      filePath: path,
      viewerType: DocumentViewerType.text,
      editable: true,
      showEditToolbar: false,
      onSaved: () => _scheduleSyncForPath(path),
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
}
