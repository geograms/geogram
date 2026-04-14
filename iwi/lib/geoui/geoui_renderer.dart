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
    final cs = Theme.of(context).colorScheme;
    final children = widget.screen.children;

    // Render children in document order. Runs of adjacent `action`
    // children get collapsed into a single Wrap so many buttons flow
    // naturally (multiple rows on narrow screens, a single row on
    // wide ones) and stay grouped next to the preceding heading.
    final rendered = <Widget>[];
    var i = 0;
    while (i < children.length) {
      if (children[i].keyword == 'action') {
        final run = <GeoUiBlock>[];
        while (i < children.length && children[i].keyword == 'action') {
          run.add(children[i]);
          i++;
        }
        rendered.add(Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.start,
            children: [for (final a in run) _renderAction(a)],
          ),
        ));
      } else {
        rendered.add(_renderBlock(children[i]));
        i++;
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Screen tip
          if (widget.screen.getString('tip') != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                widget.screen.getString('tip')!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ),
          ...rendered,
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
    final cs = Theme.of(context).colorScheme;
    final tip = group.getString('tip');

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          if (group.name != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                group.name!,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
              ),
            ),
          if (tip != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Text(
                tip,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ),
          // Card containing fields
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
            ),
            color: cs.surfaceContainerLow,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < group.children.length; i++) ...[
                  _renderGroupChild(group.children[i]),
                  if (i < group.children.length - 1)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: cs.outlineVariant.withAlpha(50),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Render a child inside a group card — each field gets consistent
  /// list-tile-style padding.
  Widget _renderGroupChild(GeoUiBlock block) {
    return switch (block.keyword) {
      'field' => _renderFieldInCard(block),
      'label' => _renderLabel(block),
      _ => _renderBlock(block),
    };
  }

  // ── Field ───────────────────────────────────────────────────────────

  Widget _renderField(GeoUiBlock field) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _renderFieldWidget(field),
    );
  }

  /// Field rendered inside a group card — with consistent padding.
  Widget _renderFieldInCard(GeoUiBlock field) {
    final type = field.type ?? 'string';
    // Sliders need special layout
    if ((type == 'float' || type == 'int') &&
        field.getNumber('min') != null &&
        field.getNumber('max') != null) {
      return _renderSliderField(field);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: _renderFieldWidget(field),
    );
  }

  Widget _renderFieldWidget(GeoUiBlock field) {
    final fieldName = field.name ?? '';
    final type = field.type ?? 'string';
    final label = field.getString('label') ?? fieldName;
    final tip = field.getString('tip');

    return switch (type) {
      'bool' => _renderBoolField(fieldName, label, tip),
      'int' => _renderNumericField(fieldName, label, tip,
          isInt: true, block: field),
      'float' => _renderNumericField(fieldName, label, tip,
          isInt: false, block: field),
      'enum' => _renderEnumField(fieldName, label, tip, field),
      _ => _renderStringField(fieldName, label, tip, field),
    };
  }

  Widget _renderBoolField(String name, String label, String? tip) {
    final cs = Theme.of(context).colorScheme;
    final val = widget.bindings.getValue(name) as bool? ?? false;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 0),
      title: Text(label, style: Theme.of(context).textTheme.bodyLarge),
      subtitle: tip != null
          ? Text(tip,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ))
          : null,
      trailing: Switch.adaptive(
        value: val,
        onChanged: (v) {
          widget.bindings.setValue(name, v);
          setState(() {});
        },
      ),
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
    final val = widget.bindings.getValue(name);
    final numVal = val is int ? val.toDouble() : (val as double? ?? min ?? 0);

    if (min != null && max != null) {
      return _renderSliderField(block);
    }

    // No range — use text field
    return TextField(
      decoration: InputDecoration(
        labelText: label,
        helperText: tip,
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      keyboardType: TextInputType.number,
      controller: TextEditingController(text: numVal.toString()),
      onChanged: (v) {
        final parsed = isInt ? int.tryParse(v) : double.tryParse(v);
        if (parsed != null) widget.bindings.setValue(name, parsed);
      },
    );
  }

  /// Slider field rendered inside a card — edge-to-edge slider look.
  Widget _renderSliderField(GeoUiBlock block) {
    final cs = Theme.of(context).colorScheme;
    final fieldName = block.name ?? '';
    final type = block.type ?? 'float';
    final isInt = type == 'int';
    final label = block.getString('label') ?? fieldName;
    final tip = block.getString('tip');
    final min = block.getNumber('min')!;
    final max = block.getNumber('max')!;
    final step = block.getNumber('step');
    final val = widget.bindings.getValue(fieldName);
    final numVal = val is int ? val.toDouble() : (val as double? ?? min);
    final divisions = step != null ? ((max - min) / step).round() : null;
    final displayVal =
        isInt ? numVal.round().toString() : numVal.toStringAsFixed(1);

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(label,
                      style: Theme.of(context).textTheme.bodyLarge),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    displayVal,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: cs.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ],
            ),
          ),
          if (tip != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text(tip,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      )),
            ),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              activeTrackColor: cs.primary,
              inactiveTrackColor: cs.surfaceContainerHighest,
              thumbColor: cs.primary,
            ),
            child: Slider(
              value: numVal.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: (v) {
                widget.bindings.setValue(fieldName, isInt ? v.round() : v);
                setState(() {});
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _renderEnumField(
      String name, String label, String? tip, GeoUiBlock field) {
    final cs = Theme.of(context).colorScheme;
    final options = field.childrenOf('option');
    final current = widget.bindings.getValue(name)?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyLarge),
          if (tip != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Text(tip,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      )),
            ),
          if (tip == null) const SizedBox(height: 8),
          if (options.length <= 4)
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                style: SegmentedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                segments: options.map((o) {
                  final optName = o.name ?? '';
                  final optLabel = o.getString('label') ?? optName;
                  return ButtonSegment(
                      value: optName, label: Text(optLabel));
                }).toList(),
                selected: {current},
                onSelectionChanged: (v) {
                  widget.bindings.setValue(name, v.first);
                  setState(() {});
                },
              ),
            )
          else
            DropdownButtonFormField<String>(
              value: current.isEmpty ? null : current,
              decoration: InputDecoration(
                labelText: label,
                helperText: tip,
                filled: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
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
            ),
        ],
      ),
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
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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

    final onPressed = () {
      if (confirm) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(confirmLabel ?? 'Confirm?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
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

    Widget button = switch (style) {
      'primary' => FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: onPressed,
          child: Text(label),
        ),
      'danger' => FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: onPressed,
          child: Text(label),
        ),
      _ => TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: onPressed,
          child: Text(label),
        ),
    };

    if (tip != null) button = Tooltip(message: tip, child: button);
    return button;
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
  final cs = Theme.of(context).colorScheme;

  return showDialog(
    context: context,
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: cs.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      screen.name ?? 'Settings',
                      style: Theme.of(ctx).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      onAction?.call('cancel');
                      Navigator.of(ctx).pop();
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Content
            Flexible(
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
          ],
        ),
      ),
    ),
  );
}
