/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../../services/i18n_service.dart';
import '../models/element_position.dart';
import '../models/story_element.dart';
import '../models/story_scene.dart';
import '../models/story_trigger.dart';
import 'anchor_selector_widget.dart';

/// Panel for editing element properties
class ElementPropertiesPanel extends StatelessWidget {
  final StoryElement element;
  final StoryScene scene;
  final List<StoryScene> allScenes;
  final I18nService i18n;
  final ValueChanged<StoryElement> onElementChanged;
  final ValueChanged<StoryTrigger?> onTriggerChanged;

  const ElementPropertiesPanel({
    super.key,
    required this.element,
    required this.scene,
    required this.allScenes,
    required this.i18n,
    required this.onElementChanged,
    required this.onTriggerChanged,
  });

  StoryTrigger? get _trigger => scene.getTriggerForElement(element.id);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context),
          const SizedBox(height: 16),
          _buildTriggerSection(context),
          const SizedBox(height: 16),
          _buildTypeSpecificSection(context),
          const SizedBox(height: 16),
          _buildPositionSection(context),
          const SizedBox(height: 16),
          _buildSizeSection(context),
          const SizedBox(height: 16),
          _buildTimingSection(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(_getElementIcon(), size: 20),
        const SizedBox(width: 8),
        Text(
          _getElementTypeLabel(),
          style: theme.textTheme.titleMedium,
        ),
      ],
    );
  }

  IconData _getElementIcon() {
    switch (element.type) {
      case ElementType.text:
        return Icons.text_fields;
      case ElementType.title:
        return Icons.title;
      case ElementType.button:
        return Icons.smart_button;
      case ElementType.quiz:
        return Icons.quiz;
    }
  }

  String _getElementTypeLabel() {
    switch (element.type) {
      case ElementType.text:
        return i18n.get('element_text', 'stories');
      case ElementType.title:
        return i18n.get('element_title', 'stories');
      case ElementType.button:
        return i18n.get('element_button', 'stories');
      case ElementType.quiz:
        return i18n.get('element_quiz', 'stories');
    }
  }

  Widget _buildPositionSection(BuildContext context) {
    final theme = Theme.of(context);
    return _Section(
      title: i18n.get('position', 'stories'),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  i18n.get('position_anchor', 'stories'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              AnchorSelectorWidget(
                selected: element.position.anchor,
                onChanged: (anchor) {
                  onElementChanged(element.copyWith(
                    position: element.position.copyWith(anchor: anchor),
                  ));
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          _OffsetSlider(
            label: i18n.get('position_offset_x', 'stories'),
            value: element.position.offsetX,
            onChanged: (value) {
              onElementChanged(element.copyWith(
                position: element.position.copyWith(offsetX: value),
              ));
            },
          ),
          const SizedBox(height: 8),
          _OffsetSlider(
            label: i18n.get('position_offset_y', 'stories'),
            value: element.position.offsetY,
            onChanged: (value) {
              onElementChanged(element.copyWith(
                position: element.position.copyWith(offsetY: value),
              ));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSizeSection(BuildContext context) {
    return _Section(
      title: i18n.get('position_width', 'stories'),
      child: Column(
        children: [
          _SizeSelector(
            label: i18n.get('position_width', 'stories'),
            value: element.position.width,
            onChanged: (value) {
              onElementChanged(element.copyWith(
                position: element.position.copyWith(width: value),
              ));
            },
            i18n: i18n,
          ),
          const SizedBox(height: 8),
          _SizeSelector(
            label: i18n.get('position_height', 'stories'),
            value: element.position.height,
            onChanged: (value) {
              onElementChanged(element.copyWith(
                position: element.position.copyWith(height: value),
              ));
            },
            i18n: i18n,
          ),
        ],
      ),
    );
  }

  Widget _buildTimingSection(BuildContext context) {
    return _Section(
      title: i18n.get('timing', 'stories'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${i18n.get('element_appear_at', 'stories')}: ${(element.appearAt / 1000).toStringAsFixed(1)}s',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Slider(
            value: element.appearAt.toDouble(),
            min: 0,
            max: 5000,
            divisions: 50,
            label: '${(element.appearAt / 1000).toStringAsFixed(1)}s',
            onChanged: (value) {
              onElementChanged(element.copyWith(
                appearAt: value.round(),
              ));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTypeSpecificSection(BuildContext context) {
    switch (element.type) {
      case ElementType.text:
        return _buildTextProperties(context);
      case ElementType.title:
        return _buildTitleProperties(context);
      case ElementType.button:
        return _buildButtonProperties(context);
      case ElementType.quiz:
        return _buildQuizProperties(context);
    }
  }

  Widget _buildTextProperties(BuildContext context) {
    final theme = Theme.of(context);
    final props = element.properties;

    return _Section(
      title: i18n.get('element_text', 'stories'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Text content
          TextFormField(
            initialValue: props['text'] as String? ?? '',
            decoration: InputDecoration(
              labelText: i18n.get('element_text', 'stories'),
              border: const OutlineInputBorder(),
            ),
            maxLines: 3,
            onChanged: (value) {
              final newProps = Map<String, dynamic>.from(props);
              newProps['text'] = value;
              onElementChanged(element.copyWith(properties: newProps));
            },
          ),
          const SizedBox(height: 12),

          // Font size
          Text(i18n.get('text_size', 'stories'), style: theme.textTheme.bodySmall),
          SegmentedButton<FontSize>(
            segments: const [
              ButtonSegment(value: FontSize.small, label: Text('A', style: TextStyle(fontSize: 12))),
              ButtonSegment(value: FontSize.medium, label: Text('A', style: TextStyle(fontSize: 16))),
              ButtonSegment(value: FontSize.large, label: Text('A', style: TextStyle(fontSize: 22))),
            ],
            selected: {element.fontSize},
            onSelectionChanged: (value) {
              final newProps = Map<String, dynamic>.from(props);
              newProps['fontSize'] = value.first.name;
              onElementChanged(element.copyWith(properties: newProps));
            },
          ),
          const SizedBox(height: 12),

          // Text color
          _ColorPickerRow(
            label: i18n.get('button_text_color', 'stories'),
            color: _parseColor(props['color'] as String? ?? '#FFFFFF'),
            onColorChanged: (color) {
              if (color == null) return;
              final newProps = Map<String, dynamic>.from(props);
              newProps['color'] = _colorToHex(color);
              onElementChanged(element.copyWith(properties: newProps));
            },
          ),
          const SizedBox(height: 8),

          // Background color (optional)
          _ColorPickerRow(
            label: i18n.get('button_background_color', 'stories'),
            color: props['backgroundColor'] != null
                ? _parseColor(props['backgroundColor'] as String)
                : null,
            onColorChanged: (color) {
              final newProps = Map<String, dynamic>.from(props);
              if (color != null) {
                newProps['backgroundColor'] = _colorToHex(color);
              } else {
                newProps.remove('backgroundColor');
              }
              onElementChanged(element.copyWith(properties: newProps));
            },
            allowNull: true,
          ),
        ],
      ),
    );
  }

  Widget _buildTitleProperties(BuildContext context) {
    final props = element.properties;
    final titleFont = element.titleFont;

    return _Section(
      title: i18n.get('element_title', 'stories'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title text
          TextFormField(
            initialValue: props['text'] as String? ?? '',
            decoration: InputDecoration(
              labelText: i18n.get('element_title', 'stories'),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) {
              final newProps = Map<String, dynamic>.from(props);
              newProps['text'] = value;
              onElementChanged(element.copyWith(properties: newProps));
            },
          ),
          const SizedBox(height: 12),

          // Font style
          Text(i18n.get('title_font_style', 'stories'), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildFontChip(TitleFont.bold, i18n.get('title_font_bold', 'stories'), titleFont),
              _buildFontChip(TitleFont.serif, i18n.get('title_font_serif', 'stories'), titleFont),
              _buildFontChip(TitleFont.handwritten, i18n.get('title_font_handwritten', 'stories'), titleFont),
              _buildFontChip(TitleFont.retro, i18n.get('title_font_retro', 'stories'), titleFont),
              _buildFontChip(TitleFont.condensed, i18n.get('title_font_condensed', 'stories'), titleFont),
            ],
          ),
          const SizedBox(height: 12),

          // Title color
          _ColorPickerRow(
            label: i18n.get('title_color', 'stories'),
            color: _parseColor(props['color'] as String? ?? '#FFFF00'),
            onColorChanged: (color) {
              final newProps = Map<String, dynamic>.from(props);
              newProps['color'] = _colorToHex(color!);
              onElementChanged(element.copyWith(properties: newProps));
            },
          ),
          const SizedBox(height: 8),

          // Shadow color
          _ColorPickerRow(
            label: i18n.get('title_shadow_color', 'stories'),
            color: props['shadowColor'] != null
                ? _parseColor(props['shadowColor'] as String)
                : Colors.black54,
            onColorChanged: (color) {
              final newProps = Map<String, dynamic>.from(props);
              if (color != null) {
                newProps['shadowColor'] = _colorToHex(color);
              }
              onElementChanged(element.copyWith(properties: newProps));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFontChip(TitleFont font, String label, TitleFont selected) {
    return ChoiceChip(
      label: Text(label),
      selected: font == selected,
      onSelected: (isSelected) {
        if (isSelected) {
          final newProps = Map<String, dynamic>.from(element.properties);
          newProps['font'] = font.name;
          onElementChanged(element.copyWith(properties: newProps));
        }
      },
    );
  }

  Widget _buildButtonProperties(BuildContext context) {
    final props = element.properties;
    final shape = element.buttonShape;

    return _Section(
      title: i18n.get('element_button', 'stories'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Shape
          DropdownButtonFormField<ButtonShape>(
            initialValue: shape,
            decoration: InputDecoration(
              labelText: i18n.get('button_shape', 'stories'),
              border: const OutlineInputBorder(),
            ),
            items: [
              DropdownMenuItem(value: ButtonShape.rectangle, child: Text(i18n.get('button_shape_rectangle', 'stories'))),
              DropdownMenuItem(value: ButtonShape.roundedRect, child: Text(i18n.get('button_shape_rounded', 'stories'))),
              DropdownMenuItem(value: ButtonShape.circle, child: Text(i18n.get('button_shape_circle', 'stories'))),
              DropdownMenuItem(value: ButtonShape.dot, child: Text(i18n.get('button_shape_dot', 'stories'))),
              DropdownMenuItem(value: ButtonShape.invisible, child: Text(i18n.get('button_shape_invisible', 'stories'))),
            ],
            onChanged: (value) {
              if (value == null) return;
              final newProps = Map<String, dynamic>.from(props);
              newProps['shape'] = value.name;
              onElementChanged(element.copyWith(properties: newProps));
            },
          ),
          const SizedBox(height: 12),

          // Label
          if (shape != ButtonShape.invisible)
            TextFormField(
              initialValue: props['label'] as String? ?? '',
              decoration: InputDecoration(
                labelText: i18n.get('button_label', 'stories'),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) {
                final newProps = Map<String, dynamic>.from(props);
                newProps['label'] = value;
                onElementChanged(element.copyWith(properties: newProps));
              },
            ),
          if (shape != ButtonShape.invisible) const SizedBox(height: 12),

          // Colors
          if (shape != ButtonShape.invisible) ...[
            _ColorPickerRow(
              label: i18n.get('button_background_color', 'stories'),
              color: _parseColor(props['backgroundColor'] as String? ?? '#2196F3'),
              onColorChanged: (color) {
                final newProps = Map<String, dynamic>.from(props);
                newProps['backgroundColor'] = _colorToHex(color!);
                onElementChanged(element.copyWith(properties: newProps));
              },
            ),
            const SizedBox(height: 8),
            _ColorPickerRow(
              label: i18n.get('button_text_color', 'stories'),
              color: _parseColor(props['textColor'] as String? ?? '#FFFFFF'),
              onColorChanged: (color) {
                final newProps = Map<String, dynamic>.from(props);
                newProps['textColor'] = _colorToHex(color!);
                onElementChanged(element.copyWith(properties: newProps));
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildQuizProperties(BuildContext context) {
    final props = element.properties;

    return _Section(
      title: i18n.get('element_quiz', 'stories'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Question
          TextFormField(
            initialValue: props['question'] as String? ?? '',
            decoration: InputDecoration(
              labelText: i18n.get('quiz_question', 'stories'),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) {
              final newProps = Map<String, dynamic>.from(props);
              newProps['question'] = value;
              onElementChanged(element.copyWith(properties: newProps));
            },
          ),
          const SizedBox(height: 12),

          // Answer
          TextFormField(
            initialValue: props['answer'] as String? ?? '',
            decoration: InputDecoration(
              labelText: i18n.get('quiz_answer', 'stories'),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) {
              final newProps = Map<String, dynamic>.from(props);
              newProps['answer'] = value;
              onElementChanged(element.copyWith(properties: newProps));
            },
          ),
          const SizedBox(height: 12),

          // Color
          _ColorPickerRow(
            label: i18n.get('button_text_color', 'stories'),
            color: _parseColor(props['color'] as String? ?? '#FFFFFF'),
            onColorChanged: (color) {
              if (color == null) return;
              final newProps = Map<String, dynamic>.from(props);
              newProps['color'] = _colorToHex(color);
              onElementChanged(element.copyWith(properties: newProps));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTriggerSection(BuildContext context) {
    final trigger = _trigger;
    final isButton = element.type == ElementType.button;
    final hasNoAction = isButton && trigger == null;

    return _Section(
      title: i18n.get('trigger', 'stories'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Show error for buttons without actions
          if (hasNoAction) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      i18n.get('button_no_action', 'stories'),
                      style: TextStyle(color: Colors.orange.shade800),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          DropdownButtonFormField<TriggerType?>(
            initialValue: trigger?.type,
            decoration: InputDecoration(
              labelText: i18n.get('trigger', 'stories'),
              border: const OutlineInputBorder(),
              errorText: hasNoAction ? '' : null,
              errorStyle: const TextStyle(height: 0),
            ),
            items: [
              DropdownMenuItem(value: null, child: Text('None')),
              DropdownMenuItem(value: TriggerType.goToScene, child: Text(i18n.get('trigger_go_to_scene', 'stories'))),
              DropdownMenuItem(value: TriggerType.showPopup, child: Text(i18n.get('trigger_show_popup', 'stories'))),
              DropdownMenuItem(value: TriggerType.openUrl, child: Text(i18n.get('trigger_open_url', 'stories'))),
            ],
            onChanged: (value) {
              if (value == null) {
                onTriggerChanged(null);
              } else {
                onTriggerChanged(StoryTrigger(
                  id: 'trigger-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
                  type: value,
                  elementId: element.id,
                ));
              }
            },
          ),

          if (trigger?.type == TriggerType.goToScene) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: trigger?.targetSceneId,
              decoration: InputDecoration(
                labelText: i18n.get('trigger_target_scene', 'stories'),
                border: const OutlineInputBorder(),
              ),
              items: allScenes
                  .where((s) => s.id != scene.id)
                  .map((s) => DropdownMenuItem(
                        value: s.id,
                        child: Text(s.title ?? 'Scene ${s.index + 1}'),
                      ))
                  .toList(),
              onChanged: (value) {
                if (value == null || trigger == null) return;
                onTriggerChanged(trigger.copyWith(targetSceneId: value));
              },
            ),
          ],

          if (trigger?.type == TriggerType.showPopup) ...[
            const SizedBox(height: 12),
            TextFormField(
              initialValue: trigger?.popupTitle ?? '',
              decoration: InputDecoration(
                labelText: i18n.get('trigger_popup_title', 'stories'),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) {
                if (trigger == null) return;
                onTriggerChanged(trigger.copyWith(popupTitle: value));
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: trigger?.popupMessage ?? '',
              decoration: InputDecoration(
                labelText: i18n.get('trigger_popup_message', 'stories'),
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
              onChanged: (value) {
                if (trigger == null) return;
                onTriggerChanged(trigger.copyWith(popupMessage: value));
              },
            ),
          ],

          if (trigger?.type == TriggerType.openUrl) ...[
            const SizedBox(height: 12),
            TextFormField(
              initialValue: trigger?.url ?? '',
              decoration: InputDecoration(
                labelText: i18n.get('trigger_url', 'stories'),
                border: const OutlineInputBorder(),
                hintText: 'https://',
              ),
              onChanged: (value) {
                if (trigger == null) return;
                onTriggerChanged(trigger.copyWith(url: value));
              },
            ),
          ],
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
    }
    return Colors.white;
  }

  String _colorToHex(Color color) {
    final r = (color.r * 255).round().clamp(0, 255);
    final g = (color.g * 255).round().clamp(0, 255);
    final b = (color.b * 255).round().clamp(0, 255);
    return '#${r.toRadixString(16).padLeft(2, '0')}${g.toRadixString(16).padLeft(2, '0')}${b.toRadixString(16).padLeft(2, '0')}';
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _OffsetSlider extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _OffsetSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 80, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
        Expanded(
          child: Slider(
            value: value,
            min: -50,
            max: 50,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text('${value.round()}%', style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _SizeSelector extends StatelessWidget {
  final String label;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;
  final I18nService i18n;

  const _SizeSelector({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.i18n,
  });

  @override
  Widget build(BuildContext context) {
    final currentSize = value is ElementSize ? value : ElementSize.auto;

    return Wrap(
      spacing: 4,
      children: [
        for (final size in ElementSize.values)
          ChoiceChip(
            label: Text(_getSizeLabel(size)),
            selected: currentSize == size,
            onSelected: (selected) {
              if (selected) onChanged(size);
            },
          ),
      ],
    );
  }

  String _getSizeLabel(ElementSize size) {
    switch (size) {
      case ElementSize.small:
        return i18n.get('size_small', 'stories');
      case ElementSize.medium:
        return i18n.get('size_medium', 'stories');
      case ElementSize.large:
        return i18n.get('size_large', 'stories');
      case ElementSize.full:
        return i18n.get('size_full', 'stories');
      case ElementSize.auto:
        return i18n.get('size_auto', 'stories');
    }
  }
}

class _ColorPickerRow extends StatelessWidget {
  final String label;
  final Color? color;
  final ValueChanged<Color?> onColorChanged;
  final bool allowNull;

  const _ColorPickerRow({
    required this.label,
    required this.color,
    required this.onColorChanged,
    this.allowNull = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        if (allowNull && color != null)
          IconButton(
            icon: const Icon(Icons.clear, size: 18),
            onPressed: () => onColorChanged(null),
            tooltip: 'Clear',
          ),
        GestureDetector(
          onTap: () => _showColorPicker(context),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color ?? Colors.transparent,
              border: Border.all(color: Colors.grey),
              borderRadius: BorderRadius.circular(4),
            ),
            child: color == null
                ? const Icon(Icons.add, size: 16, color: Colors.grey)
                : null,
          ),
        ),
      ],
    );
  }

  void _showColorPicker(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: color ?? Colors.white,
            onColorChanged: (newColor) => onColorChanged(newColor),
            enableAlpha: false,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
