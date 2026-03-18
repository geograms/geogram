/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:math';

import 'package:flutter/material.dart';

import '../../services/i18n_service.dart';
import '../models/element_position.dart';
import '../models/story_element.dart';
import 'anchor_selector_widget.dart';

/// Lively color pairs for buttons (background, text)
const _buttonColorPairs = [
  ('#FF6B6B', '#FFFFFF'), // Coral red
  ('#4ECDC4', '#FFFFFF'), // Teal
  ('#FFE66D', '#333333'), // Sunny yellow
  ('#95E1D3', '#333333'), // Mint
  ('#F38181', '#FFFFFF'), // Salmon pink
  ('#AA96DA', '#FFFFFF'), // Lavender
  ('#FF9F43', '#FFFFFF'), // Orange
  ('#6C5CE7', '#FFFFFF'), // Purple
  ('#00CEC9', '#FFFFFF'), // Cyan
  ('#FD79A8', '#FFFFFF'), // Pink
  ('#00B894', '#FFFFFF'), // Green
  ('#E17055', '#FFFFFF'), // Terracotta
];

int _buttonColorIndex = Random().nextInt(_buttonColorPairs.length);

/// Dialog for adding new elements to a scene
class AddElementDialog extends StatefulWidget {
  final ElementType elementType;
  final I18nService i18n;

  const AddElementDialog({
    super.key,
    required this.elementType,
    required this.i18n,
  });

  @override
  State<AddElementDialog> createState() => _AddElementDialogState();
}

class _AddElementDialogState extends State<AddElementDialog> {
  final _formKey = GlobalKey<FormState>();
  final _textController = TextEditingController();
  final _labelController = TextEditingController();
  final _answerController = TextEditingController();

  AnchorPoint _anchor = AnchorPoint.center;
  ButtonShape _buttonShape = ButtonShape.roundedRect;
  TitleFont _titleFont = TitleFont.bold;

  @override
  void dispose() {
    _textController.dispose();
    _labelController.dispose();
    _answerController.dispose();
    super.dispose();
  }

  /// Check if this button type uses free positioning (drag anywhere)
  bool get _usesFreePosition =>
      widget.elementType == ElementType.button &&
      (_buttonShape == ButtonShape.invisible || _buttonShape == ButtonShape.dot);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_getTitle()),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTypeSpecificFields(),
              // Only show anchor selector for elements that use anchor-based positioning
              if (!_usesFreePosition) ...[
                const SizedBox(height: 16),
                _buildPositionField(),
              ],
              // Show hint for free-position elements
              if (_usesFreePosition) ...[
                const SizedBox(height: 16),
                _buildFreePositionHint(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _onCreate,
          child: Text(widget.i18n.get('element_add', 'stories')),
        ),
      ],
    );
  }

  String _getTitle() {
    switch (widget.elementType) {
      case ElementType.text:
        return widget.i18n.get('element_text', 'stories');
      case ElementType.title:
        return widget.i18n.get('element_title', 'stories');
      case ElementType.button:
        return widget.i18n.get('element_button', 'stories');
      case ElementType.quiz:
        return widget.i18n.get('element_quiz', 'stories');
    }
  }

  Widget _buildTypeSpecificFields() {
    switch (widget.elementType) {
      case ElementType.text:
        return _buildTextFields();
      case ElementType.title:
        return _buildTitleFields();
      case ElementType.button:
        return _buildButtonFields();
      case ElementType.quiz:
        return _buildQuizFields();
    }
  }

  Widget _buildTextFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: _textController,
          decoration: InputDecoration(
            labelText: widget.i18n.get('element_text', 'stories'),
            border: const OutlineInputBorder(),
          ),
          maxLines: 3,
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Please enter some text';
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildTitleFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: _textController,
          decoration: InputDecoration(
            labelText: widget.i18n.get('element_title', 'stories'),
            border: const OutlineInputBorder(),
          ),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Please enter a title';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),

        // Font style
        Text(
          widget.i18n.get('title_font_style', 'stories'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildTitleFontChip(TitleFont.bold, widget.i18n.get('title_font_bold', 'stories')),
            _buildTitleFontChip(TitleFont.serif, widget.i18n.get('title_font_serif', 'stories')),
            _buildTitleFontChip(TitleFont.handwritten, widget.i18n.get('title_font_handwritten', 'stories')),
            _buildTitleFontChip(TitleFont.retro, widget.i18n.get('title_font_retro', 'stories')),
            _buildTitleFontChip(TitleFont.condensed, widget.i18n.get('title_font_condensed', 'stories')),
          ],
        ),
      ],
    );
  }

  Widget _buildTitleFontChip(TitleFont font, String label) {
    final isSelected = _titleFont == font;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() => _titleFont = font);
        }
      },
    );
  }

  Widget _buildButtonFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Shape selector
        Text(
          widget.i18n.get('button_shape', 'stories'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildShapeChip(ButtonShape.roundedRect, widget.i18n.get('button_shape_rounded', 'stories'), Icons.rounded_corner),
            _buildShapeChip(ButtonShape.rectangle, widget.i18n.get('button_shape_rectangle', 'stories'), Icons.rectangle_outlined),
            _buildShapeChip(ButtonShape.circle, widget.i18n.get('button_shape_circle', 'stories'), Icons.circle_outlined),
            _buildShapeChip(ButtonShape.dot, widget.i18n.get('button_shape_dot', 'stories'), Icons.lens),
            _buildShapeChip(ButtonShape.invisible, widget.i18n.get('button_shape_invisible', 'stories'), Icons.visibility_off),
          ],
        ),
        const SizedBox(height: 16),

        // Label (not for invisible buttons)
        if (_buttonShape != ButtonShape.invisible)
          TextFormField(
            controller: _labelController,
            decoration: InputDecoration(
              labelText: widget.i18n.get('button_label', 'stories'),
              border: const OutlineInputBorder(),
            ),
          ),
      ],
    );
  }

  Widget _buildQuizFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: _textController,
          decoration: InputDecoration(
            labelText: widget.i18n.get('quiz_question', 'stories'),
            border: const OutlineInputBorder(),
          ),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Please enter a question';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _answerController,
          decoration: InputDecoration(
            labelText: widget.i18n.get('quiz_answer', 'stories'),
            border: const OutlineInputBorder(),
          ),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Please enter the correct answer';
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildShapeChip(ButtonShape shape, String label, IconData icon) {
    final isSelected = _buttonShape == shape;
    return ChoiceChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() => _buttonShape = shape);
        }
      },
    );
  }

  Widget _buildPositionField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.i18n.get('position_anchor', 'stories'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Center(
          child: AnchorSelectorWidget(
            selected: _anchor,
            onChanged: (anchor) => setState(() => _anchor = anchor),
            size: 120,
          ),
        ),
      ],
    );
  }

  Widget _buildFreePositionHint() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.touch_app,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.i18n.get('button_drag_to_position', 'stories'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  void _onCreate() {
    if (!_formKey.currentState!.validate()) return;

    final elementId = 'elem-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

    // Determine width based on element type
    ElementSize width;
    switch (widget.elementType) {
      case ElementType.text:
        width = ElementSize.large;
        break;
      case ElementType.title:
        width = ElementSize.full;
        break;
      case ElementType.button:
        width = _buttonShape == ButtonShape.invisible ? ElementSize.medium : ElementSize.medium;
        break;
      case ElementType.quiz:
        width = ElementSize.large;
        break;
    }

    final position = ElementPosition(anchor: _anchor, width: width);

    StoryElement element;

    switch (widget.elementType) {
      case ElementType.text:
        element = StoryElement.text(
          id: elementId,
          text: _textController.text,
          position: position,
        );
        break;

      case ElementType.title:
        element = StoryElement.title(
          id: elementId,
          text: _textController.text,
          position: position,
          font: _titleFont,
          color: '#FFFF00',
        );
        break;

      case ElementType.button:
        // Pick next color from the lively palette
        final colorPair = _buttonColorPairs[_buttonColorIndex % _buttonColorPairs.length];
        _buttonColorIndex++;

        element = StoryElement.button(
          id: elementId,
          shape: _buttonShape,
          label: _labelController.text.isEmpty ? null : _labelController.text,
          position: position,
          backgroundColor: colorPair.$1,
          textColor: colorPair.$2,
        );
        break;

      case ElementType.quiz:
        element = StoryElement.quiz(
          id: elementId,
          question: _textController.text,
          answer: _answerController.text,
          position: position,
        );
        break;
    }

    Navigator.pop(context, element);
  }
}

/// Show dialog to add a new element
Future<StoryElement?> showAddElementDialog(
  BuildContext context, {
  required ElementType elementType,
  required I18nService i18n,
}) {
  return showDialog<StoryElement>(
    context: context,
    builder: (context) => AddElementDialog(
      elementType: elementType,
      i18n: i18n,
    ),
  );
}

/// Bottom sheet to select element type to add
class AddElementBottomSheet extends StatelessWidget {
  final I18nService i18n;
  final ValueChanged<ElementType> onTypeSelected;

  const AddElementBottomSheet({
    super.key,
    required this.i18n,
    required this.onTypeSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              i18n.get('element_add', 'stories'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ElementTypeButton(
                  icon: Icons.title,
                  label: i18n.get('element_title', 'stories'),
                  onTap: () {
                    Navigator.pop(context);
                    onTypeSelected(ElementType.title);
                  },
                ),
                _ElementTypeButton(
                  icon: Icons.text_fields,
                  label: i18n.get('element_text', 'stories'),
                  onTap: () {
                    Navigator.pop(context);
                    onTypeSelected(ElementType.text);
                  },
                ),
                _ElementTypeButton(
                  icon: Icons.smart_button,
                  label: i18n.get('element_button', 'stories'),
                  onTap: () {
                    Navigator.pop(context);
                    onTypeSelected(ElementType.button);
                  },
                ),
                _ElementTypeButton(
                  icon: Icons.quiz,
                  label: i18n.get('element_quiz', 'stories'),
                  onTap: () {
                    Navigator.pop(context);
                    onTypeSelected(ElementType.quiz);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ElementTypeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ElementTypeButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 100,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, size: 32, color: theme.colorScheme.primary),
            const SizedBox(height: 8),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
