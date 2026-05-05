/// GeoUI Flutter renderer — turns AST blocks into Material 3 widgets.

import 'package:flutter/material.dart';

import '../services/i18n_context.dart';
import 'geoui_ast.dart';
import 'widgets/code_editor_field.dart';
import 'widgets/icon_field.dart';
import 'widgets/log_view_field.dart';

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

  /// Per-wapp translation context. Every string attribute (label,
  /// tip, hint, default, option label, action label, confirm label,
  /// the text of `label` blocks …) is piped through
  /// [I18nContext.resolve] so authors can use `@key` sentinels in
  /// their .ui.json and ship `lang/<locale>.json` sidecars. When
  /// null (legacy or test callers), an empty context is used and
  /// everything passes through as-is.
  final I18nContext? i18n;

  /// Outer padding around the rendered content. Defaults to the
  /// standard screen padding (20 horizontal × 16 vertical). Hosts
  /// rendering the renderer in tight contexts (e.g. an overlay
  /// chip on a video) can pass [EdgeInsets.zero] to suppress it.
  final EdgeInsetsGeometry padding;

  const GeoUiScreenRenderer({
    super.key,
    required this.screen,
    required this.bindings,
    this.onAction,
    this.i18n,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
  });

  @override
  State<GeoUiScreenRenderer> createState() => _GeoUiScreenRendererState();
}

class _GeoUiScreenRendererState extends State<GeoUiScreenRenderer> {
  /// Cached controllers keyed by field name. Prevents the cursor-reset
  /// bug caused by creating a new TextEditingController on every build.
  final Map<String, TextEditingController> _controllers = {};

  TextEditingController _controllerFor(String fieldName, String text) {
    final existing = _controllers[fieldName];
    if (existing != null) {
      // Only update if the text changed externally (e.g. project load),
      // not from the user typing (which already updated the controller).
      if (existing.text != text) {
        existing.text = text;
      }
      return existing;
    }
    final ctrl = TextEditingController(text: text);
    _controllers[fieldName] = ctrl;
    return ctrl;
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Lazy shortcut for [I18nContext.resolve] that also preserves the
  /// "null in → null out" contract of nullable string getters. Every
  /// user-visible string in this renderer goes through here so wapps
  /// can swap `label: "Title"` for `label: "@settings.title"` with
  /// zero code changes on the author side.
  String? _t(String? raw) {
    if (raw == null) return null;
    return widget.i18n?.resolve(raw) ?? raw;
  }

  /// Non-null variant for sites that always have a value (action
  /// labels, options, ...).
  String _tRequired(String raw) => widget.i18n?.resolve(raw) ?? raw;

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

    final screenTip = _t(widget.screen.getString('tip'));
    return SingleChildScrollView(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Screen tip
          if (screenTip != null && screenTip.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                screenTip,
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
    // Spec §14.2 — header-actions are hoisted into the host's AppBar
    // by the wapp page; rendering them inline would duplicate them.
    if (group.type == 'header-actions') return const SizedBox.shrink();
    // Spec §14.1 — popup menu primitive. Renders as a single icon
    // button that opens a Material popup with the group's action
    // children as items. Selection dispatches the same
    // {type:"action","action":"<name>"} message wapps already
    // handle.
    if (group.type == 'menu') return _renderMenuGroup(group);

    final cs = Theme.of(context).colorScheme;
    final tip = _t(group.getString('tip'));
    // Group names aren't usually translatable (they're slugs more
    // than labels), but authors can still opt in by passing
    // `@key` — the resolver is lossless for literal strings.
    final name = _t(group.name);

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          if (name != null && name.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                name,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
              ),
            ),
          if (tip != null && tip.isNotEmpty)
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

  // ── Menu group (`$type="menu"`) ─────────────────────────────────────
  // Trigger button + popup containing the group's action children.

  Widget _renderMenuGroup(GeoUiBlock group) {
    final actions = group.children
        .where((c) => c.keyword == 'action' && (c.name ?? '').isNotEmpty)
        .toList();
    if (actions.isEmpty) return const SizedBox.shrink();

    final iconName = group.getString('icon') ?? 'menu';
    final tip = _t(group.getString('tip')) ?? 'Menu';
    final groupLabel = _t(group.name);

    final button = PopupMenuButton<String>(
      tooltip: tip,
      icon: Icon(_iconFromName(iconName)),
      onSelected: (name) => widget.onAction?.call(name),
      itemBuilder: (_) => [
        for (final a in actions)
          PopupMenuItem<String>(
            value: a.name!,
            child: Text(_t(a.getString('label')) ?? a.name!),
          ),
      ],
    );

    if (groupLabel == null || groupLabel.isEmpty) return button;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        const SizedBox(width: 4),
        Text(groupLabel),
      ],
    );
  }

  IconData _iconFromName(String name) => geoUiResolveIcon(name);

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
    // Field labels and tips are the most translation-heavy surface
    // in GeoUI — every input has at least one. They all route
    // through _t() so `label: "@settings.title_label"` Just Works.
    final label = _t(field.getString('label')) ?? fieldName;
    final tip = _t(field.getString('tip'));

    return switch (type) {
      'bool' => _renderBoolField(fieldName, label, tip),
      'int' => _renderNumericField(fieldName, label, tip,
          isInt: true, block: field),
      'float' => _renderNumericField(fieldName, label, tip,
          isInt: false, block: field),
      'enum' => _renderEnumField(fieldName, label, tip, field),
      'code' => _renderCodeField(fieldName, label, tip, field),
      'log' => _renderLogField(fieldName, label, tip, field),
      'icon' => _renderIconField(fieldName, label, tip, field),
      _ => _renderStringField(fieldName, label, tip, field),
    };
  }

  Widget _renderCodeField(
      String name, String label, String? tip, GeoUiBlock field) {
    final languageId = field.getString('language') ?? 'c';
    // Pure read — _loadWapp's _seedFieldDefaults has already written
    // the default text into bindings before the first build. Calling
    // setValue here would trigger setState() inside a build method.
    final current = widget.bindings.getValue(name)?.toString() ?? '';
    // Companion flag in the bindings map that the host can flip at
    // runtime (e.g. App Creator's _loadProject sets
    // `source__readonly = true` when the loaded wapp doesn't ship a
    // main.c). Absent / non-true means the editor stays editable.
    final readOnly = widget.bindings.getValue('${name}__readonly') == true;
    return CodeEditorField(
      fieldName: name,
      label: label,
      tip: readOnly
          ? '${tip ?? ''}\n(read-only — no source shipped with this wapp; '
              'click "Create new wapp" to start fresh)'
          : tip,
      languageId: languageId,
      initialValue: current,
      readOnly: readOnly,
      // Wapp-owned typography: font_size / font_family / line_height
      // come from the block's decls so each wapp picks its own look.
      fontSize: field.getNumber('font_size') ?? 16,
      fontFamily: field.getString('font_family') ?? 'monospace',
      lineHeight: field.getNumber('line_height') ?? 1.5,
      onChanged: (v) => widget.bindings.setValue(name, v),
    );
  }

  Widget _renderIconField(
      String name, String label, String? tip, GeoUiBlock field) {
    // Pure read — _seedFieldDefaults has already written the default
    // into bindings before the first build.
    final current = widget.bindings.getValue(name)?.toString() ?? '';
    return IconField(
      fieldName: name,
      label: label,
      tip: tip,
      initialValue: current,
      onChanged: (v) => widget.bindings.setValue(name, v),
    );
  }

  Widget _renderLogField(
      String name, String label, String? tip, GeoUiBlock field) {
    // Pure read — _loadWapp's _seedFieldDefaults seeds an empty
    // List<String> for every log field before the first build. If a
    // log field somehow slips past the seeder (e.g. dynamic screen
    // injection later) we fall back to a throwaway empty list rather
    // than mutating bindings from inside build().
    final stored = widget.bindings.getValue(name);
    final lines = stored is List<String> ? stored : const <String>[];
    return LogViewField(
      fieldName: name,
      label: label,
      tip: tip,
      lines: lines,
      fontSize: field.getNumber('font_size') ?? 14,
      fontFamily: field.getString('font_family') ?? 'monospace',
      lineHeight: field.getNumber('line_height') ?? 1.5,
    );
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
      controller: _controllerFor('__num_$name', numVal.toString()),
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
    final label = _t(block.getString('label')) ?? fieldName;
    final tip = _t(block.getString('tip'));
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
                  final optLabel =
                      _t(o.getString('label')) ?? optName;
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
                final optLabel =
                    _t(o.getString('label')) ?? optName;
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
    final hint = _t(field.getString('hint'));
    final readOnly = field.getBool('readonly') ?? false;
    // Multi-line attribute: when true, the TextField grows to [lines]
    // visible rows and accepts the Enter key as a newline. Useful for
    // fields like the install wapp's "Repositories" list where one
    // URL/path lives per line.
    final multiline = field.getBool('multiline') ?? false;
    final lines = (field.getNumber('lines') ?? 6).toInt();
    final val = widget.bindings.getValue(name)?.toString() ?? '';
    return TextField(
      decoration: InputDecoration(
        labelText: label,
        helperText: tip,
        helperMaxLines: 3,
        hintText: hint,
        alignLabelWithHint: multiline,
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      readOnly: readOnly,
      maxLines: multiline ? lines : 1,
      minLines: multiline ? 3 : 1,
      keyboardType:
          multiline ? TextInputType.multiline : TextInputType.text,
      style: multiline
          ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
          : null,
      controller: _controllerFor(name, val),
      onChanged: (v) => widget.bindings.setValue(name, v),
    );
  }

  // ── Action ──────────────────────────────────────────────────────────

  Widget _renderAction(GeoUiBlock action) {
    final name = action.name ?? '';
    final label = _t(action.getString('label')) ?? name;
    final style = action.getString('style') ?? 'secondary';
    final tip = _t(action.getString('tip'));
    final confirm = action.getBool('confirm') ?? false;
    final confirmLabel = _t(action.getString('confirm-label'));

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
    final rawText = label.getString('text') ?? label.name ?? '';
    final text = _tRequired(rawText);
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

/// Whitelist of Material icon names wapps may reference in their
/// `.ui.json` (menu trigger icons, header-action icons, …). Anything
/// outside the list falls back to `Icons.menu` so wapps can't reach
/// into arbitrary Material icons by surprise.
IconData geoUiResolveIcon(String name) {
  switch (name) {
    case 'menu':
      return Icons.menu;
    case 'more_vert':
      return Icons.more_vert;
    case 'more_horiz':
      return Icons.more_horiz;
    case 'settings':
      return Icons.settings;
    case 'add':
      return Icons.add;
    case 'edit':
      return Icons.edit;
    case 'tune':
      return Icons.tune;
    case 'filter_list':
      return Icons.filter_list;
    case 'sort':
      return Icons.sort;
    case 'apps':
      return Icons.apps;
    case 'refresh':
      return Icons.refresh;
    case 'search':
      return Icons.search;
    case 'share':
      return Icons.share;
    case 'save':
      return Icons.save;
    case 'delete':
      return Icons.delete;
    case 'info':
      return Icons.info_outline;
    case 'help':
      return Icons.help_outline;
    case 'download':
      return Icons.download;
    case 'upload':
      return Icons.upload;
    case 'play':
      return Icons.play_arrow;
    case 'pause':
      return Icons.pause;
    case 'stop':
      return Icons.stop;
    case 'open':
      return Icons.folder_open;
    case 'close':
      return Icons.close;
    case 'check':
      return Icons.check;
    case 'star':
      return Icons.star_outline;
    case 'favorite':
      return Icons.favorite_border;
    case 'visibility':
      return Icons.visibility;
    default:
      return Icons.menu;
  }
}

/// Render a `<group $type="header-actions">`'s direct children as a
/// list of host AppBar action widgets. Spec §14.2 — each child is
/// either a single `<action icon="…">` (rendered as IconButton) or a
/// nested `<group $type="menu">` (rendered as the same PopupMenuButton
/// the inline renderer would produce). Anything else is silently
/// dropped so future child kinds don't break older hosts.
///
/// The list order matches the AppBar `actions` slot, which Flutter
/// renders right-aligned next to the title.
List<Widget> buildGeoUiAppBarActions({
  required List<GeoUiBlock> children,
  required GeoUiActionCallback onAction,
  I18nContext? i18n,
}) {
  String? translate(String? raw) {
    if (raw == null) return null;
    return i18n?.resolve(raw) ?? raw;
  }

  final widgets = <Widget>[];
  for (final block in children) {
    if (block.keyword == 'action') {
      final name = block.name;
      if (name == null || name.isEmpty) continue;
      final iconName = block.getString('icon');
      if (iconName == null) continue; // header-actions are icon-only
      final tip = translate(block.getString('tip')) ??
          translate(block.getString('label')) ??
          name;
      widgets.add(IconButton(
        tooltip: tip,
        icon: Icon(geoUiResolveIcon(iconName)),
        onPressed: () => onAction(name),
      ));
      continue;
    }
    if (block.keyword == 'group' && block.type == 'menu') {
      final actions = block.children
          .where((c) => c.keyword == 'action' && (c.name ?? '').isNotEmpty)
          .toList();
      if (actions.isEmpty) continue;
      final iconName = block.getString('icon') ?? 'menu';
      final tip = translate(block.getString('tip')) ?? 'Menu';
      widgets.add(PopupMenuButton<String>(
        tooltip: tip,
        icon: Icon(geoUiResolveIcon(iconName)),
        onSelected: onAction,
        itemBuilder: (_) => [
          for (final a in actions)
            PopupMenuItem<String>(
              value: a.name!,
              child: Text(translate(a.getString('label')) ?? a.name!),
            ),
        ],
      ));
      continue;
    }
  }
  return widgets;
}
