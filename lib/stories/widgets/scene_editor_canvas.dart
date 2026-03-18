/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/story.dart';
import '../models/story_element.dart';
import '../models/story_scene.dart';
import '../models/story_trigger.dart';
import '../services/stories_storage_service.dart';
import 'story_element_widget.dart';

/// Editable canvas for story scenes in Story Studio
class SceneEditorCanvas extends StatefulWidget {
  final StoryScene scene;
  final Story story;
  final StoriesStorageService storage;
  final String? selectedElementId;
  final ValueChanged<String?> onSelectionChanged;
  final ValueChanged<StoryElement> onElementChanged;
  final VoidCallback? onDeleteSelected;

  const SceneEditorCanvas({
    super.key,
    required this.scene,
    required this.story,
    required this.storage,
    this.selectedElementId,
    required this.onSelectionChanged,
    required this.onElementChanged,
    this.onDeleteSelected,
  });

  @override
  State<SceneEditorCanvas> createState() => _SceneEditorCanvasState();
}

class _SceneEditorCanvasState extends State<SceneEditorCanvas> {
  String? _backgroundImagePath;
  Player? _videoPlayer;
  VideoController? _videoController;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadBackground();
  }

  @override
  void didUpdateWidget(SceneEditorCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bg = widget.scene.background;
    final oldBg = oldWidget.scene.background;
    if (oldWidget.scene.id != widget.scene.id ||
        oldBg.asset != bg.asset ||
        oldBg.videoAsset != bg.videoAsset) {
      _backgroundImagePath = null;
      _disposeVideoPlayer();
      _loadBackground();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _disposeVideoPlayer();
    super.dispose();
  }

  void _disposeVideoPlayer() {
    _videoPlayer?.dispose();
    _videoPlayer = null;
    _videoController = null;
  }

  Future<void> _loadBackground() async {
    final bg = widget.scene.background;

    // Load video if present (video takes priority)
    if (bg.hasVideo) {
      final path = await widget.storage.extractMedia(
        widget.story,
        bg.videoAsset!,
      );
      if (mounted && path != null) {
        await _initVideoPlayer(path);
      }
    }
    // Otherwise load image
    else if (bg.hasImage) {
      final path = await widget.storage.extractMedia(
        widget.story,
        bg.asset!,
      );
      if (mounted && path != null) {
        setState(() => _backgroundImagePath = path);
      }
    }
  }

  Future<void> _initVideoPlayer(String videoPath) async {
    _disposeVideoPlayer();

    _videoPlayer = Player();
    _videoController = VideoController(_videoPlayer!);

    // In editor, loop the video for preview
    await _videoPlayer!.setPlaylistMode(PlaylistMode.loop);
    await _videoPlayer!.open(Media(videoPath));
    await _videoPlayer!.play();
    if (mounted) setState(() {});
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.delete ||
          event.logicalKey == LogicalKeyboardKey.backspace) {
        if (widget.selectedElementId != null && widget.onDeleteSelected != null) {
          widget.onDeleteSelected!();
        }
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        widget.onSelectionChanged(null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: GestureDetector(
        onTap: () {
          _focusNode.requestFocus();
          widget.onSelectionChanged(null);
        },
        child: Container(
          decoration: BoxDecoration(
            color: Colors.grey.shade900,
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 9 / 16, // Portrait mobile format
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Stack(
                    children: [
                      // Background
                      _buildBackground(constraints),

                      // Touch area indicators (for triggers)
                      ..._buildTouchAreaIndicators(constraints),

                      // Elements
                      ..._buildElements(constraints),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBackground(BoxConstraints constraints) {
    final bg = widget.scene.background;
    final bgColor = _parseColor(bg.placeholder);

    // Always use cover to ensure consistent element positioning across orientations
    const fit = BoxFit.cover;

    Widget mediaWidget;

    // Video background (takes priority over image)
    if (bg.hasVideo && _videoController != null) {
      mediaWidget = Video(
        controller: _videoController!,
        controls: NoVideoControls,
        fit: fit,
        width: constraints.maxWidth,
        height: constraints.maxHeight,
      );
    }
    // Image background
    else if (_backgroundImagePath != null) {
      mediaWidget = Image.file(
        File(_backgroundImagePath!),
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        fit: fit,
        errorBuilder: (context, error, stackTrace) => _buildMediaPlaceholder(),
      );
    } else {
      mediaWidget = _buildMediaPlaceholder();
    }

    return Container(
      width: constraints.maxWidth,
      height: constraints.maxHeight,
      color: bgColor,
      child: mediaWidget,
    );
  }

  Widget _buildMediaPlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add_photo_alternate, size: 48, color: Colors.white.withValues(alpha: 0.5)),
          const SizedBox(height: 8),
          Text(
            'Select background media',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildTouchAreaIndicators(BoxConstraints constraints) {
    final triggers = widget.scene.touchAreaTriggers;
    if (triggers.isEmpty) return [];

    return triggers.map((trigger) {
      if (trigger.touchArea == null) return const SizedBox.shrink();

      final rect = _getTouchAreaRect(trigger.touchArea!, constraints);
      return Positioned(
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: Colors.cyan.withValues(alpha: 0.5),
              width: 2,
            ),
            color: Colors.cyan.withValues(alpha: 0.1),
          ),
          child: Center(
            child: Text(
              _getTouchAreaLabel(trigger.touchArea!),
              style: TextStyle(
                color: Colors.cyan.withValues(alpha: 0.8),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  Rect _getTouchAreaRect(TouchArea area, BoxConstraints constraints) {
    final w = constraints.maxWidth;
    final h = constraints.maxHeight;

    switch (area) {
      case TouchArea.leftHalf:
        return Rect.fromLTWH(0, 0, w / 2, h);
      case TouchArea.rightHalf:
        return Rect.fromLTWH(w / 2, 0, w / 2, h);
      case TouchArea.topHalf:
        return Rect.fromLTWH(0, 0, w, h / 2);
      case TouchArea.bottomHalf:
        return Rect.fromLTWH(0, h / 2, w, h / 2);
      case TouchArea.topLeft:
        return Rect.fromLTWH(0, 0, w / 2, h / 2);
      case TouchArea.topRight:
        return Rect.fromLTWH(w / 2, 0, w / 2, h / 2);
      case TouchArea.bottomLeft:
        return Rect.fromLTWH(0, h / 2, w / 2, h / 2);
      case TouchArea.bottomRight:
        return Rect.fromLTWH(w / 2, h / 2, w / 2, h / 2);
      case TouchArea.center:
        return Rect.fromLTWH(w / 4, h / 4, w / 2, h / 2);
    }
  }

  String _getTouchAreaLabel(TouchArea area) {
    switch (area) {
      case TouchArea.leftHalf:
        return 'Left';
      case TouchArea.rightHalf:
        return 'Right';
      case TouchArea.topHalf:
        return 'Top';
      case TouchArea.bottomHalf:
        return 'Bottom';
      case TouchArea.topLeft:
        return 'TL';
      case TouchArea.topRight:
        return 'TR';
      case TouchArea.bottomLeft:
        return 'BL';
      case TouchArea.bottomRight:
        return 'BR';
      case TouchArea.center:
        return 'Center';
    }
  }

  List<Widget> _buildElements(BoxConstraints constraints) {
    return widget.scene.elements.map((element) {
      final isSelected = element.id == widget.selectedElementId;

      return _EditableElementWrapper(
        key: ValueKey(element.id),
        element: element,
        scene: widget.scene,
        story: widget.story,
        storage: widget.storage,
        constraints: constraints,
        isSelected: isSelected,
        onTap: () {
          _focusNode.requestFocus();
          widget.onSelectionChanged(element.id);
        },
        onChanged: widget.onElementChanged,
      );
    }).toList();
  }

  Color _parseColor(String colorString) {
    if (colorString.startsWith('#')) {
      final hex = colorString.substring(1);
      if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      } else if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    }
    return Colors.black;
  }
}

/// Wrapper widget that adds selection frame and drag handling to elements
class _EditableElementWrapper extends StatefulWidget {
  final StoryElement element;
  final StoryScene scene;
  final Story story;
  final StoriesStorageService storage;
  final BoxConstraints constraints;
  final bool isSelected;
  final VoidCallback onTap;
  final ValueChanged<StoryElement> onChanged;

  const _EditableElementWrapper({
    super.key,
    required this.element,
    required this.scene,
    required this.story,
    required this.storage,
    required this.constraints,
    required this.isSelected,
    required this.onTap,
    required this.onChanged,
  });

  @override
  State<_EditableElementWrapper> createState() => _EditableElementWrapperState();
}

class _EditableElementWrapperState extends State<_EditableElementWrapper> {
  final GlobalKey _childKey = GlobalKey();
  Size? _measuredSize;

  @override
  void initState() {
    super.initState();
    // Measure size after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureChild());
  }

  @override
  void didUpdateWidget(_EditableElementWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.element.properties != widget.element.properties) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureChild());
    }
  }

  void _measureChild() {
    final renderBox = _childKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null && mounted) {
      setState(() {
        _measuredSize = renderBox.size;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final position = widget.element.position;

    final w = widget.constraints.maxWidth;
    final h = widget.constraints.maxHeight;

    // For text/title/quiz elements, use intrinsic sizing; for buttons use percentage
    final isTextOrTitle = widget.element.type == ElementType.text ||
        widget.element.type == ElementType.title ||
        widget.element.type == ElementType.quiz;

    // Calculate position differently for text/title vs other elements
    final double leftPx;
    final double topPx;
    if (isTextOrTitle) {
      // For text/title, position at anchor point (will use FractionalTranslation to center)
      final (anchorX, anchorY) = position.anchorPercent;
      leftPx = (anchorX / 100) * w + (position.offsetX / 100) * w;
      topPx = (anchorY / 100) * h + (position.offsetY / 100) * h;
    } else {
      // For buttons, use calculated position with width adjustment
      final (left, top) = position.calculatePosition();
      leftPx = (left / 100) * w;
      topPx = (top / 100) * h;
    }

    final widthPx = isTextOrTitle ? null : (position.widthPercent > 0 ? (position.widthPercent / 100) * w : null);
    final heightPx = isTextOrTitle ? null : (position.heightPercent != null ? (position.heightPercent! / 100) * h : null);

    // Check if button has a valid action (trigger)
    final hasValidAction = widget.element.type != ElementType.button ||
        widget.scene.getTriggerForElement(widget.element.id) != null;

    final child = KeyedSubtree(
      key: _childKey,
      child: StoryElementWidget(
        element: widget.element,
        story: widget.story,
        storage: widget.storage,
        constraints: widget.constraints,
        isEditing: true,
        hasValidAction: hasValidAction,
      ),
    );

    if (widget.isSelected) {
      // Use measured size for text/title, percentage for others
      final frameWidth = isTextOrTitle
          ? (_measuredSize?.width ?? 100)
          : (widthPx ?? 100);
      final frameHeight = isTextOrTitle
          ? (_measuredSize?.height ?? 30)
          : (heightPx ?? 50);

      // For text/title, adjust left position to account for centering
      final frameLeft = isTextOrTitle ? leftPx - frameWidth / 2 : leftPx;

      return _SelectionFrame(
        left: frameLeft,
        top: topPx,
        width: frameWidth,
        height: frameHeight,
        canvasWidth: w,
        canvasHeight: h,
        onTap: widget.onTap,
        onMove: _handleMove,
        onResize: isTextOrTitle ? null : _handleResize, // Disable resize for text/title
        child: child,
      );
    }

    if (isTextOrTitle) {
      // For text/title, use FractionalTranslation to center on anchor
      return Positioned(
        left: leftPx,
        top: topPx,
        child: FractionalTranslation(
          translation: const Offset(-0.5, 0), // Center horizontally on anchor
          child: GestureDetector(
            onTap: widget.onTap,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: child,
            ),
          ),
        ),
      );
    }

    return Positioned(
      left: leftPx,
      top: topPx,
      width: widthPx,
      height: heightPx,
      child: GestureDetector(
        onTap: widget.onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: child,
        ),
      ),
    );
  }

  void _handleMove(double deltaXPercent, double deltaYPercent) {
    final position = widget.element.position;

    // Invisible and dot buttons can be freely positioned anywhere on the image
    final isFreePosition = widget.element.type == ElementType.button &&
        (widget.element.buttonShape == ButtonShape.invisible ||
         widget.element.buttonShape == ButtonShape.dot);

    final minOffset = isFreePosition ? -100.0 : -50.0;
    final maxOffset = isFreePosition ? 100.0 : 50.0;

    final newOffsetX = (position.offsetX + deltaXPercent).clamp(minOffset, maxOffset);
    final newOffsetY = (position.offsetY + deltaYPercent).clamp(minOffset, maxOffset);

    final updated = widget.element.copyWith(
      position: position.copyWith(
        offsetX: newOffsetX,
        offsetY: newOffsetY,
      ),
    );
    widget.onChanged(updated);
  }

  void _handleResize(double newWidthPercent, double? newHeightPercent) {
    final position = widget.element.position;
    final updated = widget.element.copyWith(
      position: position.copyWith(
        width: newWidthPercent.clamp(5.0, 100.0),
        height: newHeightPercent?.clamp(5.0, 100.0),
      ),
    );
    widget.onChanged(updated);
  }
}

/// Selection frame with resize handles
class _SelectionFrame extends StatefulWidget {
  final double left;
  final double top;
  final double width;
  final double height;
  final double canvasWidth;
  final double canvasHeight;
  final Widget child;
  final VoidCallback? onTap;
  final void Function(double deltaXPercent, double deltaYPercent)? onMove;
  final void Function(double widthPercent, double? heightPercent)? onResize;

  const _SelectionFrame({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.child,
    this.onTap,
    this.onMove,
    this.onResize,
  });

  @override
  State<_SelectionFrame> createState() => _SelectionFrameState();
}

class _SelectionFrameState extends State<_SelectionFrame> {
  static const double _handleSize = 10.0;
  static const double _borderWidth = 2.0;

  Offset? _dragStart;
  _ResizeHandle? _activeHandle;
  double _startWidth = 0;
  double _startHeight = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return Positioned(
      left: widget.left - _handleSize / 2,
      top: widget.top - _handleSize / 2,
      width: widget.width + _handleSize,
      height: widget.height + _handleSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Main content with border
          Positioned(
            left: _handleSize / 2,
            top: _handleSize / 2,
            width: widget.width,
            height: widget.height,
            child: GestureDetector(
              onTap: widget.onTap,
              onPanStart: _onMoveStart,
              onPanUpdate: _onMoveUpdate,
              onPanEnd: _onMoveEnd,
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: primaryColor,
                      width: _borderWidth,
                    ),
                  ),
                  child: widget.child,
                ),
              ),
            ),
          ),

          // Corner and edge handles (only show if resizing is enabled)
          if (widget.onResize != null) ...[
            _buildHandle(_ResizeHandle.topLeft, 0, 0, primaryColor),
            _buildHandle(_ResizeHandle.topRight, widget.width, 0, primaryColor),
            _buildHandle(_ResizeHandle.bottomLeft, 0, widget.height, primaryColor),
            _buildHandle(_ResizeHandle.bottomRight, widget.width, widget.height, primaryColor),
            _buildHandle(_ResizeHandle.right, widget.width, widget.height / 2, primaryColor),
            _buildHandle(_ResizeHandle.bottom, widget.width / 2, widget.height, primaryColor),
          ],
        ],
      ),
    );
  }

  Widget _buildHandle(_ResizeHandle handle, double x, double y, Color color) {
    return Positioned(
      left: x,
      top: y,
      child: GestureDetector(
        onPanStart: (details) => _onResizeStart(details, handle),
        onPanUpdate: _onResizeUpdate,
        onPanEnd: _onResizeEnd,
        child: MouseRegion(
          cursor: _getCursorForHandle(handle),
          child: Container(
            width: _handleSize,
            height: _handleSize,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: color, width: 1.5),
              borderRadius: BorderRadius.circular(2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  MouseCursor _getCursorForHandle(_ResizeHandle handle) {
    switch (handle) {
      case _ResizeHandle.topLeft:
      case _ResizeHandle.bottomRight:
        return SystemMouseCursors.resizeUpLeftDownRight;
      case _ResizeHandle.topRight:
      case _ResizeHandle.bottomLeft:
        return SystemMouseCursors.resizeUpRightDownLeft;
      case _ResizeHandle.right:
        return SystemMouseCursors.resizeLeftRight;
      case _ResizeHandle.bottom:
        return SystemMouseCursors.resizeUpDown;
    }
  }

  void _onMoveStart(DragStartDetails details) {
    _dragStart = details.localPosition;
  }

  void _onMoveUpdate(DragUpdateDetails details) {
    if (_dragStart == null || widget.onMove == null) return;

    final delta = details.localPosition - _dragStart!;
    final deltaXPercent = (delta.dx / widget.canvasWidth) * 100;
    final deltaYPercent = (delta.dy / widget.canvasHeight) * 100;

    widget.onMove!(deltaXPercent, deltaYPercent);
    _dragStart = details.localPosition;
  }

  void _onMoveEnd(DragEndDetails details) {
    _dragStart = null;
  }

  void _onResizeStart(DragStartDetails details, _ResizeHandle handle) {
    _dragStart = details.globalPosition;
    _startWidth = widget.width;
    _startHeight = widget.height;
    _activeHandle = handle;
  }

  void _onResizeUpdate(DragUpdateDetails details) {
    if (_dragStart == null || widget.onResize == null || _activeHandle == null) return;

    final delta = details.globalPosition - _dragStart!;
    double newWidth = _startWidth;
    double newHeight = _startHeight;

    switch (_activeHandle!) {
      case _ResizeHandle.topLeft:
        newWidth = _startWidth - delta.dx;
        newHeight = _startHeight - delta.dy;
      case _ResizeHandle.topRight:
        newWidth = _startWidth + delta.dx;
        newHeight = _startHeight - delta.dy;
      case _ResizeHandle.bottomLeft:
        newWidth = _startWidth - delta.dx;
        newHeight = _startHeight + delta.dy;
      case _ResizeHandle.bottomRight:
        newWidth = _startWidth + delta.dx;
        newHeight = _startHeight + delta.dy;
      case _ResizeHandle.right:
        newWidth = _startWidth + delta.dx;
      case _ResizeHandle.bottom:
        newHeight = _startHeight + delta.dy;
    }

    // Convert to percentages
    final widthPercent = (newWidth / widget.canvasWidth) * 100;
    final heightPercent = (newHeight / widget.canvasHeight) * 100;

    widget.onResize!(widthPercent, heightPercent);
  }

  void _onResizeEnd(DragEndDetails details) {
    _dragStart = null;
    _activeHandle = null;
  }
}

enum _ResizeHandle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  right,
  bottom,
}
