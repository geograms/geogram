/// GeoUI Flutter renderer — turns AST blocks into Material 3 widgets.

import 'package:flutter/material.dart';

import 'geoui_ast.dart';

/// Bindings interface for reading/writing field values.
abstract class GeoUiBindings {
  dynamic getValue(String fieldName);
  void setValue(String fieldName, dynamic value);
}

/// Action callback: fired when an action block is triggered.
typedef GeoUiActionCallback = void Function(String actionName);

/// Renders a GeoUI screen block as a Flutter widget.
class GeoUiScreenRenderer extends StatefulWidget {
  final GeoUiBlock screen;
  final GeoUiBindings bindings;
  final GeoUiActionCallback? onAction;

  const GeoUiScreenRenderer({
    super.key,
    required this.screen,
    required this.bindings,
    this.onAction,
  });

  @override
  State<GeoUiScreenRenderer> createState() => _GeoUiScreenRendererState();
}

class _GeoUiScreenRendererState extends State<GeoUiScreenRenderer> {
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Screen tip
          if (widget.screen.getString('tip') != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                widget.screen.getString('tip')!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          // Render children
          for (final child in widget.screen.children)
            _renderBlock(child),
        ],
      ),
    );
  }

  Widget _renderBlock(GeoUiBlock block) {
    return switch (block.keyword) {
      'group' => _renderGroup(block),
      'field' => _renderField(block),
      'action' => _renderAction(block),
      'label' => _renderLabel(block),
      _ => const SizedBox.shrink(),
    };
  }

  // ── Group ───────────────────────────────────────────────────────────

  Widget _renderGroup(GeoUiBlock group) {
    final tip = group.getString('tip');
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (group.name != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  group.name!,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            if (tip != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  tip,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            for (final child in group.children)
              _renderBlock(child),
          ],
        ),
      ),
    );
  }

  // ── Field ───────────────────────────────────────────────────────────

  Widget _renderField(GeoUiBlock field) {
    final fieldName = field.name ?? '';
    final type = field.type ?? 'string';
    final label = field.getString('label') ?? fieldName;
    final tip = field.getString('tip');

    Widget w;
    switch (type) {
      case 'bool':
        w = _renderBoolField(fieldName, label, tip);
      case 'int':
        w = _renderNumericField(fieldName, label, tip, isInt: true, block: field);
      case 'float':
        w = _renderNumericField(fieldName, label, tip, isInt: false, block: field);
      case 'enum':
        w = _renderEnumField(fieldName, label, tip, field);
      default: // string, text
        w = _renderStringField(fieldName, label, tip, field);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: w,
    );
  }

  Widget _renderBoolField(String name, String label, String? tip) {
    final val = widget.bindings.getValue(name) as bool? ?? false;
    return SwitchListTile(
      title: Text(label),
      subtitle: tip != null ? Text(tip) : null,
      value: val,
      contentPadding: EdgeInsets.zero,
      onChanged: (v) {
        widget.bindings.setValue(name, v);
        setState(() {});
      },
    );
  }

  Widget _renderNumericField(
    String name,
    String label,
    String? tip, {
    required bool isInt,
    required GeoUiBlock block,
  }) {
    final min = block.getNumber('min');
    final max = block.getNumber('max');
    final step = block.getNumber('step');
    final val = widget.bindings.getValue(name);
    final numVal = val is int ? val.toDouble() : (val as double? ?? min ?? 0);

    if (min != null && max != null) {
      final divisions = step != null ? ((max - min) / step).round() : null;
      final displayVal = isInt ? numVal.round().toString() : numVal.toStringAsFixed(1);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(displayVal,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      )),
            ],
          ),
          if (tip != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(tip,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      )),
            ),
          Slider(
            value: numVal.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: displayVal,
            onChanged: (v) {
              widget.bindings.setValue(name, isInt ? v.round() : v);
              setState(() {});
            },
          ),
        ],
      );
    }

    // No range — use text field
    return TextField(
      decoration: InputDecoration(
        labelText: label,
        helperText: tip,
        border: const OutlineInputBorder(),
      ),
      keyboardType: TextInputType.number,
      controller: TextEditingController(text: numVal.toString()),
      onChanged: (v) {
        final parsed = isInt ? int.tryParse(v) : double.tryParse(v);
        if (parsed != null) widget.bindings.setValue(name, parsed);
      },
    );
  }

  Widget _renderEnumField(
      String name, String label, String? tip, GeoUiBlock field) {
    final options = field.childrenOf('option');
    final current = widget.bindings.getValue(name)?.toString() ?? '';

    if (options.length <= 4) {
      // SegmentedButton
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          if (tip != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text(tip,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      )),
            ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: options.map((o) {
                final optName = o.name ?? '';
                final optLabel = o.getString('label') ?? optName;
                return ButtonSegment(value: optName, label: Text(optLabel));
              }).toList(),
              selected: {current},
              onSelectionChanged: (v) {
                widget.bindings.setValue(name, v.first);
                setState(() {});
              },
            ),
          ),
        ],
      );
    }

    // Dropdown for many options
    return DropdownButtonFormField<String>(
      value: current.isEmpty ? null : current,
      decoration: InputDecoration(
        labelText: label,
        helperText: tip,
        border: const OutlineInputBorder(),
      ),
      items: options.map((o) {
        final optName = o.name ?? '';
        final optLabel = o.getString('label') ?? optName;
        return DropdownMenuItem(value: optName, child: Text(optLabel));
      }).toList(),
      onChanged: (v) {
        if (v != null) {
          widget.bindings.setValue(name, v);
          setState(() {});
        }
      },
    );
  }

  Widget _renderStringField(
      String name, String label, String? tip, GeoUiBlock field) {
    final hint = field.getString('hint');
    final readOnly = field.getBool('readonly') ?? false;
    final val = widget.bindings.getValue(name)?.toString() ?? '';
    return TextField(
      decoration: InputDecoration(
        labelText: label,
        helperText: tip,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
      readOnly: readOnly,
      controller: TextEditingController(text: val),
      onChanged: (v) => widget.bindings.setValue(name, v),
    );
  }

  // ── Action ──────────────────────────────────────────────────────────

  Widget _renderAction(GeoUiBlock action) {
    final name = action.name ?? '';
    final label = action.getString('label') ?? name;
    final style = action.getString('style') ?? 'secondary';
    final tip = action.getString('tip');
    final confirm = action.getBool('confirm') ?? false;
    final confirmLabel = action.getString('confirm-label');

    Widget button;
    final onPressed = () {
      if (confirm) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(confirmLabel ?? 'Confirm?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  widget.onAction?.call(name);
                },
                child: Text(label),
              ),
            ],
          ),
        );
      } else {
        widget.onAction?.call(name);
      }
    };

    button = switch (style) {
      'primary' => FilledButton(onPressed: onPressed, child: Text(label)),
      'danger' => FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: onPressed,
          child: Text(label),
        ),
      _ => OutlinedButton(onPressed: onPressed, child: Text(label)),
    };

    if (tip != null) button = Tooltip(message: tip, child: button);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8, right: 8),
      child: button,
    );
  }

  // ── Label ───────────────────────────────────────────────────────────

  Widget _renderLabel(GeoUiBlock label) {
    final text = label.getString('text') ?? label.name ?? '';
    final style = label.getString('style');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: style == 'meta'
            ? Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                )
            : null,
      ),
    );
  }
}

/// Convenience: render a GeoUI screen as a dialog.
Future<void> showGeoUiDialog({
  required BuildContext context,
  required GeoUiBlock screen,
  required GeoUiBindings bindings,
  GeoUiActionCallback? onAction,
}) {
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(screen.name ?? 'Settings'),
      content: SizedBox(
        width: 460,
        height: 520,
        child: GeoUiScreenRenderer(
          screen: screen,
          bindings: bindings,
          onAction: (action) {
            onAction?.call(action);
            if (action == 'cancel' || action == 'save') {
              Navigator.of(ctx).pop();
            }
          },
        ),
      ),
    ),
  );
}
