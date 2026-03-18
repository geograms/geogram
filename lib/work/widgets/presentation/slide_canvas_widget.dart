/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/presentation_content.dart';

/// Callback type for loading images from NDF archive
typedef ImageLoader = Future<Uint8List?> Function(String assetPath);

/// Widget that renders a slide at the correct aspect ratio
class SlideCanvasWidget extends StatefulWidget {
  final PresentationSlide slide;
  final PresentationTheme theme;
  final SlideTemplate? template;
  final double aspectRatio;
  final String? selectedElementId;
  final void Function(String elementId)? onElementTap;
  final void Function(String elementId)? onElementDoubleTap;
  final void Function(String elementId, SlideElement element)? onElementChanged;
  final ImageLoader? imageLoader;
  final bool isEditing;

  // Inline editing support
  final bool isInlineEditing;
  final TextEditingController? textEditController;
  final FocusNode? textEditFocusNode;
  final VoidCallback? onTextEditSubmit;
  final VoidCallback? onTextEditCancel;
  final void Function(String mark)? onToggleFormatting;

  const SlideCanvasWidget({
    super.key,
    required this.slide,
    required this.theme,
    this.template,
    this.aspectRatio = 16 / 9,
    this.selectedElementId,
    this.onElementTap,
    this.onElementDoubleTap,
    this.onElementChanged,
    this.imageLoader,
    this.isEditing = false,
    this.isInlineEditing = false,
    this.textEditController,
    this.textEditFocusNode,
    this.onTextEditSubmit,
    this.onTextEditCancel,
    this.onToggleFormatting,
  });

  @override
  State<SlideCanvasWidget> createState() => _SlideCanvasWidgetState();
}

class _SlideCanvasWidgetState extends State<SlideCanvasWidget> {
  // Cache for loaded images
  final Map<String, Uint8List> _imageCache = {};

  @override
  Widget build(BuildContext context) {
    final template = widget.template;
    final bgColor = _parseColor(
      widget.slide.background.color ?? widget.theme.colors.background,
    );

    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          gradient: template?.hasGradientBackground == true
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    _parseColor(template!.gradientStart ?? widget.theme.colors.background),
                    _parseColor(template.gradientEnd ?? widget.theme.colors.background),
                  ],
                )
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                // Render template decorations first (behind content)
                if (template != null) ...[
                  // Title bar if specified
                  if (template.titleBarColor != null)
                    _buildTitleBar(template, constraints),
                  // All decorations
                  for (final decoration in template.decorations)
                    _buildDecoration(decoration, constraints),
                ],
                // Render all elements on top
                for (final element in widget.slide.elements)
                  _buildElement(context, element, constraints),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTitleBar(SlideTemplate template, BoxConstraints constraints) {
    final y = ElementPosition.parsePercent(template.titleBarY ?? '0%');
    final h = ElementPosition.parsePercent(template.titleBarH ?? '15%');

    return Positioned(
      left: 0,
      top: y * constraints.maxHeight,
      width: constraints.maxWidth,
      height: h * constraints.maxHeight,
      child: Container(
        color: _parseColor(template.titleBarColor!),
      ),
    );
  }

  Widget _buildDecoration(SlideDecoration decoration, BoxConstraints constraints) {
    final left = decoration.xPercent * constraints.maxWidth;
    final top = decoration.yPercent * constraints.maxHeight;
    final width = decoration.wPercent * constraints.maxWidth;
    final height = decoration.hPercent * constraints.maxHeight;
    final color = _parseColor(decoration.color);
    final color2 = decoration.color2 != null ? _parseColor(decoration.color2!) : null;

    Widget child;
    switch (decoration.shape) {
      case DecorationShape.rectangle:
        child = Container(
          color: color.withValues(alpha: decoration.opacity),
        );

      case DecorationShape.circle:
        child = Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: decoration.opacity),
          ),
        );

      case DecorationShape.gradientBar:
        child = Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                color.withValues(alpha: decoration.opacity),
                (color2 ?? color).withValues(alpha: decoration.opacity),
              ],
            ),
          ),
        );

      case DecorationShape.diagonalStripes:
        child = CustomPaint(
          painter: _DiagonalStripesPainter(
            color: color.withValues(alpha: decoration.opacity),
            count: decoration.count ?? 5,
          ),
          size: Size(width, height),
        );

      case DecorationShape.dots:
        child = CustomPaint(
          painter: _DotsPainter(
            color: color.withValues(alpha: decoration.opacity),
            count: decoration.count ?? 4,
          ),
          size: Size(width, height),
        );

      case DecorationShape.grid:
        child = CustomPaint(
          painter: _GridPainter(
            color: color.withValues(alpha: decoration.opacity),
            count: decoration.count ?? 20,
          ),
          size: Size(width, height),
        );

      case DecorationShape.scanlines:
        child = CustomPaint(
          painter: _ScanlinesPainter(
            color: color.withValues(alpha: decoration.opacity),
            count: decoration.count ?? 100,
          ),
          size: Size(width, height),
        );

      case DecorationShape.cornerAccent:
        child = CustomPaint(
          painter: _CornerAccentPainter(
            color: color.withValues(alpha: decoration.opacity),
          ),
          size: Size(width, height),
        );

      case DecorationShape.wave:
        child = CustomPaint(
          painter: _WavePainter(
            color: color.withValues(alpha: decoration.opacity),
          ),
          size: Size(width, height),
        );

      case DecorationShape.triangle:
        child = CustomPaint(
          painter: _TrianglePainter(
            color: color.withValues(alpha: decoration.opacity),
          ),
          size: Size(width, height),
        );

      case DecorationShape.line:
        child = Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: color.withValues(alpha: decoration.opacity),
                width: decoration.strokeWidth ?? 2,
              ),
            ),
          ),
        );
    }

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: child,
    );
  }

  Widget _buildElement(
    BuildContext context,
    SlideElement element,
    BoxConstraints constraints,
  ) {
    final isSelected = element.id == widget.selectedElementId;
    final pos = element.position;

    final left = pos.xPercent * constraints.maxWidth;
    final top = pos.yPercent * constraints.maxHeight;
    final width = pos.wPercent * constraints.maxWidth;
    final height = pos.hPercent * constraints.maxHeight;

    Widget child;
    switch (element.type) {
      case SlideElementType.text:
        child = _buildTextElement(context, element, constraints);
      case SlideElementType.image:
        child = _buildImageElement(context, element, constraints);
    }

    if (isSelected && widget.isEditing) {
      // Selected element with PowerPoint-style selection frame
      return _SelectionFrame(
        left: left,
        top: top,
        width: width,
        height: height,
        canvasWidth: constraints.maxWidth,
        canvasHeight: constraints.maxHeight,
        onTap: widget.onElementTap != null ? () => widget.onElementTap!(element.id) : null,
        onDoubleTap: widget.onElementDoubleTap != null ? () => widget.onElementDoubleTap!(element.id) : null,
        onLongPress: widget.onElementDoubleTap != null ? () => widget.onElementDoubleTap!(element.id) : null,
        onMove: (newX, newY) {
          _updateElementPosition(element, newX, newY, pos.wPercent, pos.hPercent);
        },
        onResize: (newX, newY, newW, newH) {
          _updateElementPosition(element, newX, newY, newW, newH);
        },
        child: child,
      );
    }

    // Non-selected element
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        onTap: widget.onElementTap != null ? () => widget.onElementTap!(element.id) : null,
        onDoubleTap: widget.onElementDoubleTap != null ? () => widget.onElementDoubleTap!(element.id) : null,
        onLongPress: widget.onElementDoubleTap != null ? () => widget.onElementDoubleTap!(element.id) : null,
        child: MouseRegion(
          cursor: widget.isEditing ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: child,
        ),
      ),
    );
  }

  void _updateElementPosition(
    SlideElement element,
    double xPercent,
    double yPercent,
    double wPercent,
    double hPercent,
  ) {
    if (widget.onElementChanged == null) return;

    // Clamp values to valid range
    final clampedX = xPercent.clamp(0.0, 1.0 - wPercent);
    final clampedY = yPercent.clamp(0.0, 1.0 - hPercent);
    final clampedW = wPercent.clamp(0.05, 1.0 - clampedX);
    final clampedH = hPercent.clamp(0.05, 1.0 - clampedY);

    final newPosition = ElementPosition(
      x: '${(clampedX * 100).toStringAsFixed(1)}%',
      y: '${(clampedY * 100).toStringAsFixed(1)}%',
      w: '${(clampedW * 100).toStringAsFixed(1)}%',
      h: '${(clampedH * 100).toStringAsFixed(1)}%',
    );

    final updatedElement = element.copyWith(position: newPosition);
    widget.onElementChanged!(element.id, updatedElement);
  }

  Color _editingBackground(Color slideBackground) {
    final luminance = slideBackground.computeLuminance();
    if (luminance > 0.5) {
      return Colors.white.withValues(alpha: 0.7);
    } else {
      return Colors.black.withValues(alpha: 0.5);
    }
  }

  Widget _buildTextElement(
    BuildContext context,
    SlideElement element,
    BoxConstraints constraints,
  ) {
    final bgColor = _parseColor(
      widget.slide.background.color ?? widget.theme.colors.background,
    );
    final isSelected = element.id == widget.selectedElementId;
    final style = element.style;
    final baseFontSize = (style?.fontSize ?? 48).toDouble();
    // Scale font size based on canvas width (1920 is reference width)
    final scaleFactor = constraints.maxWidth / 1920;
    final scaledFontSize = baseFontSize * scaleFactor;

    TextAlign textAlign;
    switch (style?.align ?? SlideTextAlign.left) {
      case SlideTextAlign.center:
        textAlign = TextAlign.center;
      case SlideTextAlign.right:
        textAlign = TextAlign.right;
      case SlideTextAlign.left:
        textAlign = TextAlign.left;
    }

    final textColor = _parseColor(style?.color ?? widget.theme.colors.text);

    // Vertical alignment
    final Alignment vAlignment;
    switch (style?.vAlign ?? SlideVerticalAlign.top) {
      case SlideVerticalAlign.top:
        vAlignment = Alignment.topCenter;
      case SlideVerticalAlign.center:
        vAlignment = Alignment.center;
      case SlideVerticalAlign.bottom:
        vAlignment = Alignment.bottomCenter;
    }

    // Inline editing mode - render with rich text overlay for visual formatting
    if (isSelected && widget.isInlineEditing && widget.textEditController != null) {
      return Align(
        alignment: vAlignment,
        child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            final isCtrl = HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed;

            if (event.logicalKey == LogicalKeyboardKey.escape) {
              widget.onTextEditCancel?.call();
              return KeyEventResult.handled;
            } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.enter) {
              widget.onTextEditSubmit?.call();
              return KeyEventResult.handled;
            } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyB) {
              widget.onToggleFormatting?.call('bold');
              return KeyEventResult.handled;
            } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyI) {
              widget.onToggleFormatting?.call('italic');
              return KeyEventResult.handled;
            } else if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyU) {
              widget.onToggleFormatting?.call('underline');
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          decoration: BoxDecoration(
            color: _editingBackground(bgColor),
            border: Border.all(
              color: textColor.withValues(alpha: 0.3),
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          padding: const EdgeInsets.all(4),
          child: TextField(
            controller: widget.textEditController,
            focusNode: widget.textEditFocusNode,
            autofocus: true,
            maxLines: null,
            style: TextStyle(
              fontSize: scaledFontSize,
              color: textColor,
              fontWeight: style?.bold == true ? FontWeight.bold : FontWeight.normal,
              fontStyle: style?.italic == true ? FontStyle.italic : FontStyle.normal,
            ),
            cursorColor: textColor,
            textAlign: textAlign,
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              isDense: true,
            ),
            textInputAction: TextInputAction.newline,
          ),
        ),
      ),
      );
    }

    // Build rich text with spans (normal display mode)
    Widget textWidget;
    if (element.content.isEmpty) {
      textWidget = Text(
        '',
        style: TextStyle(
          fontSize: scaledFontSize,
          color: textColor,
          fontWeight: style?.bold == true ? FontWeight.bold : FontWeight.normal,
          fontStyle: style?.italic == true ? FontStyle.italic : FontStyle.normal,
        ),
        textAlign: textAlign,
      );
    } else {
      final spans = <TextSpan>[];
      for (final span in element.content) {
        spans.add(TextSpan(
          text: span.value,
          style: TextStyle(
            fontSize: scaledFontSize,
            color: textColor,
            fontWeight: (style?.bold == true || span.isBold)
                ? FontWeight.bold
                : FontWeight.normal,
            fontStyle: (style?.italic == true || span.isItalic)
                ? FontStyle.italic
                : FontStyle.normal,
            decoration: span.isUnderline ? TextDecoration.underline : null,
          ),
        ));
      }

      textWidget = RichText(
        text: TextSpan(children: spans),
        textAlign: textAlign,
      );
    }

    return Align(
      alignment: vAlignment,
      child: textWidget,
    );
  }

  Widget _buildImageElement(
    BuildContext context,
    SlideElement element,
    BoxConstraints constraints,
  ) {
    final imagePath = element.imagePath;
    if (imagePath == null || widget.imageLoader == null) {
      // Show placeholder if no image path or loader
      return Container(
        color: Colors.grey.withValues(alpha: 0.2),
        child: const Center(
          child: Icon(Icons.image, size: 48, color: Colors.grey),
        ),
      );
    }

    // Check cache first
    if (_imageCache.containsKey(imagePath)) {
      return Image.memory(
        _imageCache[imagePath]!,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            color: Colors.grey.withValues(alpha: 0.2),
            child: const Center(
              child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
            ),
          );
        },
      );
    }

    // Load image asynchronously
    return FutureBuilder<Uint8List?>(
      future: widget.imageLoader!(imagePath),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            color: Colors.grey.withValues(alpha: 0.1),
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        if (snapshot.hasError || snapshot.data == null) {
          return Container(
            color: Colors.grey.withValues(alpha: 0.2),
            child: const Center(
              child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
            ),
          );
        }

        // Cache the loaded image
        _imageCache[imagePath] = snapshot.data!;

        return Image.memory(
          snapshot.data!,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              color: Colors.grey.withValues(alpha: 0.2),
              child: const Center(
                child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
              ),
            );
          },
        );
      },
    );
  }

  Color _parseColor(String? colorStr) {
    if (colorStr == null || colorStr.isEmpty) {
      return Colors.white;
    }

    // Handle hex colors
    if (colorStr.startsWith('#')) {
      final hex = colorStr.substring(1);
      if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      } else if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    }

    // Handle named colors
    switch (colorStr.toLowerCase()) {
      case 'white':
        return Colors.white;
      case 'black':
        return Colors.black;
      case 'red':
        return Colors.red;
      case 'blue':
        return Colors.blue;
      case 'green':
        return Colors.green;
      case 'yellow':
        return Colors.yellow;
      case 'transparent':
        return Colors.transparent;
      default:
        return Colors.white;
    }
  }
}

/// PowerPoint-style selection frame with resize handles
class _SelectionFrame extends StatefulWidget {
  final double left;
  final double top;
  final double width;
  final double height;
  final double canvasWidth;
  final double canvasHeight;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onLongPress;
  final void Function(double x, double y)? onMove;
  final void Function(double x, double y, double w, double h)? onResize;

  const _SelectionFrame({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.child,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onMove,
    this.onResize,
  });

  @override
  State<_SelectionFrame> createState() => _SelectionFrameState();
}

class _SelectionFrameState extends State<_SelectionFrame> {
  // Handle size
  static const double _handleSize = 10.0;
  static const double _borderWidth = 2.0;

  // Drag state
  Offset? _dragStart;
  double _startLeft = 0;
  double _startTop = 0;
  double _startWidth = 0;
  double _startHeight = 0;
  _ResizeHandle? _activeHandle;

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
          // Main content area with dotted border
          Positioned(
            left: _handleSize / 2,
            top: _handleSize / 2,
            width: widget.width,
            height: widget.height,
            child: GestureDetector(
              onTap: widget.onTap,
              onDoubleTap: widget.onDoubleTap,
              onLongPress: widget.onLongPress,
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
                      strokeAlign: BorderSide.strokeAlignOutside,
                    ),
                  ),
                  child: CustomPaint(
                    painter: _DottedBorderPainter(
                      color: primaryColor,
                      strokeWidth: 1.5,
                      dashWidth: 4,
                      dashSpace: 3,
                    ),
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),

          // Corner handles
          _buildHandle(_ResizeHandle.topLeft, 0, 0, primaryColor),
          _buildHandle(_ResizeHandle.topRight, widget.width, 0, primaryColor),
          _buildHandle(_ResizeHandle.bottomLeft, 0, widget.height, primaryColor),
          _buildHandle(_ResizeHandle.bottomRight, widget.width, widget.height, primaryColor),

          // Edge handles
          _buildHandle(_ResizeHandle.top, widget.width / 2, 0, primaryColor),
          _buildHandle(_ResizeHandle.bottom, widget.width / 2, widget.height, primaryColor),
          _buildHandle(_ResizeHandle.left, 0, widget.height / 2, primaryColor),
          _buildHandle(_ResizeHandle.right, widget.width, widget.height / 2, primaryColor),
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
      case _ResizeHandle.top:
      case _ResizeHandle.bottom:
        return SystemMouseCursors.resizeUpDown;
      case _ResizeHandle.left:
      case _ResizeHandle.right:
        return SystemMouseCursors.resizeLeftRight;
    }
  }

  void _onMoveStart(DragStartDetails details) {
    _dragStart = details.localPosition;
    _startLeft = widget.left;
    _startTop = widget.top;
  }

  void _onMoveUpdate(DragUpdateDetails details) {
    if (_dragStart == null || widget.onMove == null) return;

    final delta = details.localPosition - _dragStart!;
    final newLeft = _startLeft + delta.dx;
    final newTop = _startTop + delta.dy;

    // Convert to percentage
    final xPercent = newLeft / widget.canvasWidth;
    final yPercent = newTop / widget.canvasHeight;

    widget.onMove!(xPercent, yPercent);
  }

  void _onMoveEnd(DragEndDetails details) {
    _dragStart = null;
  }

  void _onResizeStart(DragStartDetails details, _ResizeHandle handle) {
    _dragStart = details.globalPosition;
    _startLeft = widget.left;
    _startTop = widget.top;
    _startWidth = widget.width;
    _startHeight = widget.height;
    _activeHandle = handle;
  }

  void _onResizeUpdate(DragUpdateDetails details) {
    if (_dragStart == null || widget.onResize == null || _activeHandle == null) return;

    final delta = details.globalPosition - _dragStart!;

    double newLeft = _startLeft;
    double newTop = _startTop;
    double newWidth = _startWidth;
    double newHeight = _startHeight;

    switch (_activeHandle!) {
      case _ResizeHandle.topLeft:
        newLeft = _startLeft + delta.dx;
        newTop = _startTop + delta.dy;
        newWidth = _startWidth - delta.dx;
        newHeight = _startHeight - delta.dy;
      case _ResizeHandle.topRight:
        newTop = _startTop + delta.dy;
        newWidth = _startWidth + delta.dx;
        newHeight = _startHeight - delta.dy;
      case _ResizeHandle.bottomLeft:
        newLeft = _startLeft + delta.dx;
        newWidth = _startWidth - delta.dx;
        newHeight = _startHeight + delta.dy;
      case _ResizeHandle.bottomRight:
        newWidth = _startWidth + delta.dx;
        newHeight = _startHeight + delta.dy;
      case _ResizeHandle.top:
        newTop = _startTop + delta.dy;
        newHeight = _startHeight - delta.dy;
      case _ResizeHandle.bottom:
        newHeight = _startHeight + delta.dy;
      case _ResizeHandle.left:
        newLeft = _startLeft + delta.dx;
        newWidth = _startWidth - delta.dx;
      case _ResizeHandle.right:
        newWidth = _startWidth + delta.dx;
    }

    // Minimum size
    if (newWidth < 20) {
      if (_activeHandle == _ResizeHandle.left ||
          _activeHandle == _ResizeHandle.topLeft ||
          _activeHandle == _ResizeHandle.bottomLeft) {
        newLeft = _startLeft + _startWidth - 20;
      }
      newWidth = 20;
    }
    if (newHeight < 20) {
      if (_activeHandle == _ResizeHandle.top ||
          _activeHandle == _ResizeHandle.topLeft ||
          _activeHandle == _ResizeHandle.topRight) {
        newTop = _startTop + _startHeight - 20;
      }
      newHeight = 20;
    }

    // Convert to percentage
    final xPercent = newLeft / widget.canvasWidth;
    final yPercent = newTop / widget.canvasHeight;
    final wPercent = newWidth / widget.canvasWidth;
    final hPercent = newHeight / widget.canvasHeight;

    widget.onResize!(xPercent, yPercent, wPercent, hPercent);
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
  top,
  bottom,
  left,
  right,
}

/// Custom painter for dotted inner border (grainy effect)
class _DottedBorderPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double dashWidth;
  final double dashSpace;

  _DottedBorderPainter({
    required this.color,
    this.strokeWidth = 1.5,
    this.dashWidth = 4,
    this.dashSpace = 3,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final path = Path();

    // Draw dotted lines inside the border
    const inset = 3.0;

    // Top line
    double x = inset;
    while (x < size.width - inset) {
      path.moveTo(x, inset);
      path.lineTo((x + dashWidth).clamp(0, size.width - inset), inset);
      x += dashWidth + dashSpace;
    }

    // Bottom line
    x = inset;
    while (x < size.width - inset) {
      path.moveTo(x, size.height - inset);
      path.lineTo((x + dashWidth).clamp(0, size.width - inset), size.height - inset);
      x += dashWidth + dashSpace;
    }

    // Left line
    double y = inset;
    while (y < size.height - inset) {
      path.moveTo(inset, y);
      path.lineTo(inset, (y + dashWidth).clamp(0, size.height - inset));
      y += dashWidth + dashSpace;
    }

    // Right line
    y = inset;
    while (y < size.height - inset) {
      path.moveTo(size.width - inset, y);
      path.lineTo(size.width - inset, (y + dashWidth).clamp(0, size.height - inset));
      y += dashWidth + dashSpace;
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _DottedBorderPainter oldDelegate) {
    return color != oldDelegate.color ||
        strokeWidth != oldDelegate.strokeWidth ||
        dashWidth != oldDelegate.dashWidth ||
        dashSpace != oldDelegate.dashSpace;
  }
}

/// A minimal slide canvas for presenting (fullscreen, no editing)
class SlidePresenterCanvas extends StatelessWidget {
  final PresentationSlide slide;
  final PresentationTheme theme;
  final SlideTemplate? template;
  final double aspectRatio;
  final ImageLoader? imageLoader;

  const SlidePresenterCanvas({
    super.key,
    required this.slide,
    required this.theme,
    this.template,
    this.aspectRatio = 16 / 9,
    this.imageLoader,
  });

  @override
  Widget build(BuildContext context) {
    return SlideCanvasWidget(
      slide: slide,
      theme: theme,
      template: template,
      aspectRatio: aspectRatio,
      imageLoader: imageLoader,
      isEditing: false,
    );
  }
}

/// Diagonal stripes pattern painter
class _DiagonalStripesPainter extends CustomPainter {
  final Color color;
  final int count;

  _DiagonalStripesPainter({required this.color, required this.count});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.width / count / 2
      ..style = PaintingStyle.stroke;

    final spacing = size.width / count;
    for (int i = 0; i <= count * 2; i++) {
      final x = i * spacing - size.height;
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DiagonalStripesPainter oldDelegate) {
    return color != oldDelegate.color || count != oldDelegate.count;
  }
}

/// Dots pattern painter
class _DotsPainter extends CustomPainter {
  final Color color;
  final int count;

  _DotsPainter({required this.color, required this.count});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final spacingX = size.width / count;
    final spacingY = size.height / count;
    final radius = (spacingX.clamp(0, spacingY)) * 0.2;

    for (int row = 0; row < count; row++) {
      for (int col = 0; col < count; col++) {
        final x = spacingX * (col + 0.5);
        final y = spacingY * (row + 0.5);
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotsPainter oldDelegate) {
    return color != oldDelegate.color || count != oldDelegate.count;
  }
}

/// Grid pattern painter
class _GridPainter extends CustomPainter {
  final Color color;
  final int count;

  _GridPainter({required this.color, required this.count});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final spacingX = size.width / count;
    final spacingY = size.height / (count * 9 / 16).round();

    // Vertical lines
    for (int i = 0; i <= count; i++) {
      final x = i * spacingX;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // Horizontal lines
    final rows = (count * 9 / 16).round();
    for (int i = 0; i <= rows; i++) {
      final y = i * spacingY;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) {
    return color != oldDelegate.color || count != oldDelegate.count;
  }
}

/// Scanlines (CRT effect) painter
class _ScanlinesPainter extends CustomPainter {
  final Color color;
  final int count;

  _ScanlinesPainter({required this.color, required this.count});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final spacing = size.height / count;
    for (int i = 0; i < count; i++) {
      final y = i * spacing;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ScanlinesPainter oldDelegate) {
    return color != oldDelegate.color || count != oldDelegate.count;
  }
}

/// Corner accent (triangle in corner) painter
class _CornerAccentPainter extends CustomPainter {
  final Color color;

  _CornerAccentPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, 0)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerAccentPainter oldDelegate) {
    return color != oldDelegate.color;
  }
}

/// Wave pattern painter
class _WavePainter extends CustomPainter {
  final Color color;

  _WavePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(0, size.height * 0.4);

    // Create wave using cubic bezier curves
    final waveWidth = size.width / 3;
    for (int i = 0; i < 3; i++) {
      final startX = i * waveWidth;
      path.cubicTo(
        startX + waveWidth * 0.25, size.height * 0.1,
        startX + waveWidth * 0.75, size.height * 0.7,
        startX + waveWidth, size.height * 0.4,
      );
    }

    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) {
    return color != oldDelegate.color;
  }
}

/// Triangle painter
class _TrianglePainter extends CustomPainter {
  final Color color;

  _TrianglePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TrianglePainter oldDelegate) {
    return color != oldDelegate.color;
  }
}
