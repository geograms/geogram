/*
 * IconField — "pick an icon" input for the GeoUI renderer. Backs the
 * `$type:"icon"` field type used by App Creator's Settings tab.
 *
 * The binding stores one of three shapes:
 *   - empty string        → fall back to Material icon on the launcher
 *   - a short emoji / char → launcher renders it as text in the tile
 *   - "svg:<xml>"          → inline SVG XML; on install the host
 *                            writes it to media/icons/icon.svg and
 *                            rewrites manifest.icon to that path
 *
 * The widget shows a single text input for the emoji case plus a
 * "Choose SVG…" button that reads a .svg file from disk via the
 * native file selector and stuffs the content into the binding under
 * the `svg:` prefix. A live preview below the controls renders
 * whichever shape is currently in the binding.
 */

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const String svgPrefix = 'svg:';

class IconField extends StatefulWidget {
  /// GeoUI field name used as the key in the bindings map.
  final String fieldName;

  /// Label shown above the control. May be empty.
  final String label;

  /// Short help text shown below the control. May be null.
  final String? tip;

  /// Initial value from the bindings map. Subsequent updates flow
  /// back through [onChanged].
  final String initialValue;

  /// Fired on every change with the full current value.
  final ValueChanged<String> onChanged;

  const IconField({
    super.key,
    required this.fieldName,
    required this.label,
    required this.initialValue,
    required this.onChanged,
    this.tip,
  });

  @override
  State<IconField> createState() => _IconFieldState();
}

class _IconFieldState extends State<IconField> {
  late final TextEditingController _textController;
  String _current = '';

  bool get _isSvg => _current.startsWith(svgPrefix);

  @override
  void initState() {
    super.initState();
    _current = widget.initialValue;
    _textController =
        TextEditingController(text: _isSvg ? '' : _current);
  }

  @override
  void didUpdateWidget(IconField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Host replaced the binding from underneath us (e.g. App
    // Creator's _loadProject pushed a new project). Resync both the
    // internal state and the text controller.
    if (oldWidget.initialValue != widget.initialValue &&
        widget.initialValue != _current) {
      _current = widget.initialValue;
      final next = _isSvg ? '' : _current;
      if (_textController.text != next) {
        _textController.text = next;
      }
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _setValue(String next) {
    if (next == _current) return;
    setState(() => _current = next);
    widget.onChanged(next);
  }

  void _onTextChanged(String text) {
    // Typing into the text field clears any inlined SVG; the two
    // shapes are mutually exclusive.
    _setValue(text);
  }

  Future<void> _pickSvg() async {
    const typeGroup = XTypeGroup(
      label: 'SVG',
      extensions: ['svg'],
      mimeTypes: ['image/svg+xml'],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    try {
      // XFile.readAsString works on both desktop (dart:io File
      // under the hood) and web (FileReader via file_selector_web),
      // so this stays dart:io-free.
      final content = await file.readAsString();
      if (content.trim().isEmpty) return;
      // Text input is meaningless once an SVG is loaded — clear it
      // so re-entering editor mode later doesn't show a stale char.
      _textController.text = '';
      _setValue('$svgPrefix$content');
    } catch (_) {
      // Silent failure — user can try again. A log-line hook could
      // be added here later if the empty-state is too opaque.
    }
  }

  void _clear() {
    _textController.text = '';
    _setValue('');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Text(
                widget.label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _Preview(value: _current, color: cs.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _textController,
                      enabled: !_isSvg,
                      maxLength: 8,
                      decoration: InputDecoration(
                        hintText: _isSvg
                            ? 'SVG selected — clear to type an emoji'
                            : 'Type an emoji or single character',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        counterText: '',
                      ),
                      onChanged: _onTextChanged,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _pickSvg,
                          icon: const Icon(Icons.image, size: 16),
                          label: const Text('Choose SVG…'),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        if (_current.isNotEmpty)
                          TextButton.icon(
                            onPressed: _clear,
                            icon: const Icon(Icons.clear, size: 16),
                            label: const Text('Clear'),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (widget.tip != null && widget.tip!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 6),
              child: Text(
                widget.tip!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 56x56 preview tile that mirrors the launcher grid appearance so
/// the user sees exactly what their chosen icon will look like in
/// situ. Empty binding shows a subtle placeholder.
class _Preview extends StatelessWidget {
  final String value;
  final Color color;

  const _Preview({required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    Widget inner;
    if (value.isEmpty) {
      inner = Icon(
        Icons.extension_outlined,
        size: 28,
        color: Colors.white.withAlpha(120),
      );
    } else if (value.startsWith(svgPrefix)) {
      final svgXml = value.substring(svgPrefix.length);
      inner = Padding(
        padding: const EdgeInsets.all(8),
        child: SvgPicture.string(
          svgXml,
          fit: BoxFit.contain,
          placeholderBuilder: (_) => const SizedBox.shrink(),
        ),
      );
    } else {
      inner = FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 32,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: inner,
    );
  }
}
