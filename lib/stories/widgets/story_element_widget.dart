/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../models/story.dart';
import '../models/story_element.dart';
import '../services/quiz_state_store.dart';
import '../services/stories_storage_service.dart';

/// Widget that renders a single story element (text or button)
class StoryElementWidget extends StatefulWidget {
  final StoryElement element;
  final Story story;
  final StoriesStorageService storage;
  final BoxConstraints constraints;
  final VoidCallback? onTap;
  final bool isEditing;
  final bool hasValidAction;
  final QuizState? quizState;
  final ValueChanged<String>? onQuizAnswer;

  const StoryElementWidget({
    super.key,
    required this.element,
    required this.story,
    required this.storage,
    required this.constraints,
    this.onTap,
    this.isEditing = false,
    this.hasValidAction = true,
    this.quizState,
    this.onQuizAnswer,
  });

  @override
  State<StoryElementWidget> createState() => _StoryElementWidgetState();
}

class _StoryElementWidgetState extends State<StoryElementWidget> {
  @override
  Widget build(BuildContext context) {
    // Positioning is handled by parent widgets (scene_editor_canvas, scene_viewer)
    return _buildElement();
  }

  Widget _buildElement() {
    Widget child;

    switch (widget.element.type) {
      case ElementType.text:
        child = _buildTextElement();
        break;
      case ElementType.title:
        child = _buildTitleElement();
        break;
      case ElementType.button:
        child = _buildButtonElement();
        break;
      case ElementType.quiz:
        child = _buildQuizElement();
        break;
    }

    // Wrap with GestureDetector if tappable
    if (widget.onTap != null) {
      return GestureDetector(
        onTap: widget.onTap,
        child: child,
      );
    }

    return child;
  }

  Widget _buildTextElement() {
    final props = widget.element.properties;
    final text = props['text'] as String? ?? '';
    final fontSize = widget.element.fontSizeSp;
    final fontWeight = props['fontWeight'] == 'bold' ? FontWeight.bold : FontWeight.normal;
    final fontStyle = props['fontStyle'] == 'italic' ? FontStyle.italic : FontStyle.normal;
    final color = _parseColor(props['color'] as String? ?? '#FFFFFF');
    final backgroundColor = props['backgroundColor'] != null
        ? _parseColor(props['backgroundColor'] as String)
        : null;
    final align = _parseTextAlign(props['align'] as String? ?? 'left');

    return Container(
      padding: backgroundColor != null ? const EdgeInsets.all(8) : null,
      decoration: backgroundColor != null
          ? BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(4),
            )
          : null,
      child: Text(
        text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          color: color,
        ),
        textAlign: align,
      ),
    );
  }

  Widget _buildTitleElement() {
    final props = widget.element.properties;
    final text = props['text'] as String? ?? '';
    final color = _parseColor(props['color'] as String? ?? '#FFFF00');
    final strokeColor = props['strokeColor'] != null
        ? _parseColor(props['strokeColor'] as String)
        : null;
    final shadowColor = props['shadowColor'] != null
        ? _parseColor(props['shadowColor'] as String)
        : Colors.black54;
    final align = _parseTextAlign(props['align'] as String? ?? 'center');
    final titleFont = widget.element.titleFont;

    // Get font family based on title font style
    final fontFamily = _getTitleFontFamily(titleFont);
    final fontSize = 42.0;

    return Text(
      text,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.bold,
        fontFamily: fontFamily,
        color: color,
        shadows: [
          Shadow(
            color: shadowColor,
            blurRadius: 4,
            offset: const Offset(2, 2),
          ),
        ],
        foreground: strokeColor != null
            ? (Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = strokeColor)
            : null,
      ),
      textAlign: align,
    );
  }

  String? _getTitleFontFamily(TitleFont font) {
    switch (font) {
      case TitleFont.bold:
        return null; // System default bold
      case TitleFont.serif:
        return 'serif';
      case TitleFont.handwritten:
        return 'cursive';
      case TitleFont.retro:
        return 'monospace';
      case TitleFont.condensed:
        return 'sans-serif-condensed';
    }
  }

  Widget _buildButtonElement() {
    final shape = widget.element.buttonShape;
    final props = widget.element.properties;
    final label = props['label'] as String?;
    final backgroundColor = props['backgroundColor'] != null
        ? _parseColor(props['backgroundColor'] as String)
        : Colors.blue;
    final textColor = props['textColor'] != null
        ? _parseColor(props['textColor'] as String)
        : Colors.white;

    // Show error indicator for buttons without valid action in edit mode
    final showNoActionError = widget.isEditing && !widget.hasValidAction;

    // Handle invisible buttons
    if (shape == ButtonShape.invisible) {
      if (widget.isEditing) {
        // Show with red dotted border in editing mode
        return Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: Colors.red,
              width: 2,
              style: BorderStyle.solid,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.visibility_off, color: Colors.red, size: 20),
                if (showNoActionError) ...[
                  const SizedBox(height: 4),
                  const Icon(Icons.warning_amber, color: Colors.orange, size: 16),
                ],
              ],
            ),
          ),
        );
      }
      // Completely invisible in view mode, but still tappable
      return const SizedBox.expand();
    }

    // Handle dot shape
    if (shape == ButtonShape.dot) {
      final labelPosition = props['labelPosition'] as String? ?? 'right';
      final dotButton = _buildDotButton(
        backgroundColor: backgroundColor,
        textColor: textColor,
        label: label,
        labelPosition: labelPosition,
      );
      if (showNoActionError) {
        return _wrapWithErrorIndicator(dotButton);
      }
      return dotButton;
    }

    // Regular buttons
    final regularButton = _buildRegularButton(
      shape: shape,
      backgroundColor: backgroundColor,
      textColor: textColor,
      label: label,
    );
    if (showNoActionError) {
      return _wrapWithErrorIndicator(regularButton);
    }
    return regularButton;
  }

  Widget _wrapWithErrorIndicator(Widget child) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: -8,
          right: -8,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
              color: Colors.orange,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.warning_amber,
              color: Colors.white,
              size: 14,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDotButton({
    required Color backgroundColor,
    required Color textColor,
    String? label,
    required String labelPosition,
  }) {
    const dotSize = 16.0;

    final dot = Container(
      width: dotSize,
      height: dotSize,
      decoration: BoxDecoration(
        color: backgroundColor,
        shape: BoxShape.circle,
      ),
    );

    if (label == null || label.isEmpty) {
      return dot;
    }

    final labelWidget = Text(
      label,
      style: TextStyle(
        color: textColor,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        shadows: const [
          Shadow(color: Colors.black54, blurRadius: 2),
        ],
      ),
    );

    switch (labelPosition) {
      case 'left':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [labelWidget, const SizedBox(width: 8), dot],
        );
      case 'top':
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [labelWidget, const SizedBox(height: 4), dot],
        );
      case 'bottom':
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [dot, const SizedBox(height: 4), labelWidget],
        );
      case 'right':
      default:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [dot, const SizedBox(width: 8), labelWidget],
        );
    }
  }

  Widget _buildRegularButton({
    required ButtonShape shape,
    required Color backgroundColor,
    required Color textColor,
    String? label,
  }) {
    BorderRadius borderRadius;

    switch (shape) {
      case ButtonShape.rectangle:
        borderRadius = BorderRadius.zero;
        break;
      case ButtonShape.roundedRect:
        borderRadius = BorderRadius.circular(8);
        break;
      case ButtonShape.circle:
        borderRadius = BorderRadius.circular(100);
        break;
      default:
        borderRadius = BorderRadius.circular(8);
    }

    // Use intrinsic sizing - button sizes to content, centered in parent
    // with min width for short labels to look balanced
    final labelLength = label?.length ?? 0;
    final minWidth = labelLength <= 5 ? 100.0 : 80.0;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: minWidth,
          maxWidth: 300,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: borderRadius,
          ),
          child: Text(
            label ?? '',
            style: TextStyle(
              color: textColor,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  Widget _buildQuizElement() {
    final props = widget.element.properties;
    final question = props['question'] as String? ?? '';
    final color = _parseColor(props['color'] as String? ?? '#FFFFFF');
    final quizState = widget.quizState ?? const QuizState();

    // In editor, show a static preview (FittedBox prevents overflow in small canvas)
    if (widget.isEditing) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.quiz, color: color, size: 36),
              const SizedBox(height: 8),
              Text(
                question,
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Quiz',
                style: TextStyle(
                  fontSize: 18,
                  color: color.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Viewer mode
    if (quizState.solved) {
      return _buildQuizSolved(question, color);
    }
    if (quizState.isLocked) {
      return _buildQuizLocked(question, color);
    }
    return _QuizInput(
      question: question,
      color: color,
      attemptsRemaining: quizState.attemptsRemaining,
      onSubmit: widget.onQuizAnswer,
    );
  }

  Widget _buildQuizSolved(String question, Color color) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            question,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.bold,
              color: color,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          const Icon(Icons.check_circle, color: Colors.green, size: 48),
          const SizedBox(height: 8),
          const Text(
            'Correct!',
            style: TextStyle(
              color: Colors.green,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuizLocked(String question, Color color) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            question,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.bold,
              color: color,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          const Icon(Icons.cancel, color: Colors.red, size: 48),
          const SizedBox(height: 8),
          const Text(
            'No more attempts',
            style: TextStyle(
              color: Colors.red,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Color _parseColor(String colorString) {
    if (colorString.startsWith('#')) {
      final hex = colorString.substring(1);
      if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      } else if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    } else if (colorString.startsWith('rgba')) {
      final match = RegExp(r'rgba\((\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)')
          .firstMatch(colorString);
      if (match != null) {
        return Color.fromRGBO(
          int.parse(match.group(1)!),
          int.parse(match.group(2)!),
          int.parse(match.group(3)!),
          double.parse(match.group(4)!),
        );
      }
    }
    return Colors.white;
  }

  TextAlign _parseTextAlign(String align) {
    switch (align) {
      case 'center':
        return TextAlign.center;
      case 'right':
        return TextAlign.right;
      case 'left':
      default:
        return TextAlign.left;
    }
  }
}

/// Interactive quiz input widget with text field and submit button
class _QuizInput extends StatefulWidget {
  final String question;
  final Color color;
  final int attemptsRemaining;
  final ValueChanged<String>? onSubmit;

  const _QuizInput({
    required this.question,
    required this.color,
    required this.attemptsRemaining,
    this.onSubmit,
  });

  @override
  State<_QuizInput> createState() => _QuizInputState();
}

class _QuizInputState extends State<_QuizInput> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSubmit?.call(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Question
          Text(
            widget.question,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.bold,
              color: widget.color,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),

          // Text input
          SizedBox(
            width: 280,
            child: TextField(
              controller: _controller,
              style: const TextStyle(color: Colors.white, fontSize: 20),
              decoration: InputDecoration(
                hintText: 'Your answer...',
                hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 20),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.15),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              ),
              onSubmitted: (_) => _submit(),
              textInputAction: TextInputAction.go,
            ),
          ),
          const SizedBox(height: 14),

          // Submit button
          SizedBox(
            width: 180,
            child: ElevatedButton(
              onPressed: _submit,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              child: const Text('Submit', style: TextStyle(fontSize: 18)),
            ),
          ),
          const SizedBox(height: 14),

          // Attempts indicator (3 dots)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final isUsed = i >= widget.attemptsRemaining;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isUsed ? Colors.red : Colors.green,
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}
