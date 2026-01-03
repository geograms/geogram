/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:video_player/video_player.dart';
import '../platform/file_image_helper.dart' as file_helper;
import '../platform/video_controller_factory.dart'
    if (dart.library.html) '../platform/video_controller_factory_web.dart'
    as video_factory;
import '../services/i18n_service.dart';
import '../util/file_icon_helper.dart';

/// Full-screen photo viewer with zoom, pan, and swipe navigation
class PhotoViewerPage extends StatefulWidget {
  final List<String> imagePaths;
  final int initialIndex;

  const PhotoViewerPage({
    super.key,
    required this.imagePaths,
    this.initialIndex = 0,
  });

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late PageController _pageController;
  late int _currentIndex;
  final Map<int, TransformationController> _transformationControllers = {};
  final Map<int, VideoPlayerController> _videoControllers = {};
  final FocusNode _focusNode = FocusNode();
  final I18nService _i18n = I18nService();
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _focusNode.dispose();
    for (final controller in _transformationControllers.values) {
      controller.dispose();
    }
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        _goToPrevious();
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _goToNext();
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        Navigator.pop(context);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  TransformationController _getTransformationController(int index) {
    if (!_transformationControllers.containsKey(index)) {
      _transformationControllers[index] = TransformationController();
    }
    return _transformationControllers[index]!;
  }

  void _goToPrevious() {
    if (_currentIndex > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToNext() {
    if (_currentIndex < widget.imagePaths.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _resetZoom() {
    final controller = _transformationControllers[_currentIndex];
    if (controller != null) {
      controller.value = Matrix4.identity();
    }
  }

  /// Save the current media file to a user-selected location
  Future<void> _saveMedia() async {
    if (kIsWeb) return;

    final mediaPath = widget.imagePaths[_currentIndex];
    if (_isNetworkImage(mediaPath)) {
      // For network files, we'd need to download first - not implemented yet
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('cannot_save_network_image'))),
        );
      }
      return;
    }

    setState(() {
      _isSaving = true;
    });

    final isVideo = FileIconHelper.isVideo(mediaPath);

    try {
      final sourceFile = File(mediaPath);
      if (!await sourceFile.exists()) {
        throw Exception(_i18n.t('file_not_found'));
      }

      // Get the original filename
      final originalName = path.basename(mediaPath);

      // Let user pick save location
      final result = await FilePicker.platform.saveFile(
        dialogTitle: isVideo ? _i18n.t('save_video_as') : _i18n.t('save_image_as'),
        fileName: originalName,
        type: isVideo ? FileType.video : FileType.image,
      );

      if (result == null) {
        // User cancelled
        return;
      }

      // Copy file to the selected location
      await sourceFile.copy(result);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isVideo ? _i18n.t('video_saved') : _i18n.t('image_saved')),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('failed_to_save_image', params: ['$e'])),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '${_currentIndex + 1} / ${widget.imagePaths.length}',
          style: const TextStyle(color: Colors.white),
        ),
        centerTitle: true,
        actions: [
          // Save/Download button
          if (!kIsWeb)
            IconButton(
              icon: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.download, color: Colors.white),
              onPressed: _isSaving ? null : _saveMedia,
              tooltip: _i18n.t('save_image'),
            ),
          IconButton(
            icon: const Icon(Icons.zoom_out_map, color: Colors.white),
            onPressed: _resetZoom,
            tooltip: 'Reset zoom',
          ),
        ],
      ),
      body: Stack(
        children: [
          // Photo PageView
          PageView.builder(
            controller: _pageController,
            itemCount: widget.imagePaths.length,
            onPageChanged: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            itemBuilder: (context, index) {
              return _buildPhotoView(index);
            },
          ),

          // Left navigation button
          if (widget.imagePaths.length > 1)
            Positioned(
              left: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: _buildNavigationButton(
                  icon: Icons.chevron_left,
                  onPressed: _currentIndex > 0 ? _goToPrevious : null,
                ),
              ),
            ),

          // Right navigation button
          if (widget.imagePaths.length > 1)
            Positioned(
              right: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: _buildNavigationButton(
                  icon: Icons.chevron_right,
                  onPressed: _currentIndex < widget.imagePaths.length - 1 ? _goToNext : null,
                ),
              ),
            ),

          // Page indicator dots
          if (widget.imagePaths.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 32,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  widget.imagePaths.length,
                  (index) => Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: index == _currentIndex
                          ? Colors.white
                          : Colors.white.withOpacity(0.4),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
    );
  }

  Widget _buildPhotoView(int index) {
    final mediaPath = widget.imagePaths[index];

    // Check if it's a video file
    if (!_isNetworkImage(mediaPath) && FileIconHelper.isVideo(mediaPath)) {
      return _buildVideoView(index, mediaPath);
    }

    if (_isNetworkImage(mediaPath)) {
      return InteractiveViewer(
        transformationController: _getTransformationController(index),
        minScale: 0.5,
        maxScale: 4.0,
        child: Center(
          child: Image.network(
            mediaPath,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return const Center(
                child: Icon(
                  Icons.broken_image,
                  color: Colors.white54,
                  size: 64,
                ),
              );
            },
          ),
        ),
      );
    }

    final imageProvider = file_helper.getFileImageProvider(mediaPath);

    if (imageProvider == null) {
      return const Center(
        child: Icon(
          Icons.broken_image,
          color: Colors.white54,
          size: 64,
        ),
      );
    }

    return InteractiveViewer(
      transformationController: _getTransformationController(index),
      minScale: 0.5,
      maxScale: 4.0,
      child: Center(
        child: Image(
          image: imageProvider,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return const Center(
              child: Icon(
                Icons.broken_image,
                color: Colors.white54,
                size: 64,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildVideoView(int index, String videoPath) {
    // Initialize controller if needed (uses platform-specific factory)
    if (!_videoControllers.containsKey(index)) {
      final controller = video_factory.createVideoController(videoPath);
      if (controller == null) {
        // Video file playback not supported on this platform (e.g., web)
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, size: 64, color: Colors.white54),
              const SizedBox(height: 16),
              Text(
                path.basename(videoPath),
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 8),
              const Text(
                'Video playback not available on this platform',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        );
      }
      controller.initialize().then((_) {
        if (mounted) setState(() {});
      });
      controller.addListener(() {
        if (mounted) setState(() {});
      });
      _videoControllers[index] = controller;
    }

    final controller = _videoControllers[index]!;

    if (!controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    return GestureDetector(
      onTap: () {
        if (controller.value.isPlaying) {
          controller.pause();
        } else {
          controller.play();
        }
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
          // Play button overlay when paused
          if (!controller.value.isPlaying)
            Container(
              decoration: const BoxDecoration(
                color: Colors.black45,
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(16),
              child: const Icon(Icons.play_arrow, size: 48, color: Colors.white),
            ),
          // Progress bar at bottom
          Positioned(
            bottom: 48,
            left: 16,
            right: 16,
            child: VideoProgressIndicator(
              controller,
              allowScrubbing: true,
              colors: const VideoProgressColors(
                playedColor: Colors.white,
                bufferedColor: Colors.white38,
                backgroundColor: Colors.white24,
              ),
            ),
          ),
          // Duration display
          Positioned(
            bottom: 60,
            right: 16,
            child: Text(
              '${_formatDuration(controller.value.position)} / ${_formatDuration(controller.value.duration)}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      return '${duration.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  bool _isNetworkImage(String path) {
    return path.startsWith('http://') || path.startsWith('https://');
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
            color: onPressed != null
                ? Colors.black54
                : Colors.black26,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: onPressed != null
                ? Colors.white
                : Colors.white38,
            size: 32,
          ),
        ),
      ),
    );
  }
}
