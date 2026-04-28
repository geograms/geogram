/*
 * CodeEditorField — syntax-highlighted monospace editor for use inside
 * the GeoUI renderer. Backs the new `$type:"code"` field type.
 *
 * The editor is a single [TextField] whose controller is a
 * [SyntaxHighlightController]; that controller re-parses on every
 * text change and returns styled [TextSpan]s via
 * `buildTextSpan(...)`. Syntax colouring is therefore free — no
 * repainting in this widget — we only handle the chrome (border,
 * label, tip, optional line-number gutter).
 */

import 'package:flutter/material.dart';

import '../../widgets/syntax_highlight_controller.dart';

class CodeEditorField extends StatefulWidget {
  /// GeoUI field name used as the key in the bindings map.
  final String fieldName;

  /// Label shown above the editor. May be empty.
  final String label;

  /// Short help text shown below the editor. May be null.
  final String? tip;

  /// highlight.js language id — `c`, `cpp`, `dart`, etc. See
  /// [extensionToLanguageId] for the full list.
  final String languageId;

  /// Initial text. Subsequent updates come through [onChanged].
  final String initialValue;

  /// Fired on every keystroke with the full current text.
  final ValueChanged<String> onChanged;

  /// When true, the underlying [TextField] is read-only (text still
  /// selectable for copy, but no edits) and the text dims. Used by
  /// App Creator to lock the Code tab when a loaded wapp doesn't
  /// ship `main.c` so the user can't accidentally type into a
  /// nothing-burger.
  final bool readOnly;

  const CodeEditorField({
    super.key,
    required this.fieldName,
    required this.label,
    required this.languageId,
    required this.initialValue,
    required this.onChanged,
    this.tip,
    this.readOnly = false,
  });

  @override
  State<CodeEditorField> createState() => _CodeEditorFieldState();
}

class _CodeEditorFieldState extends State<CodeEditorField> {
  late final SyntaxHighlightController _controller;

  // Matched between the editor and the gutter so line numbers align.
  static const double _fontSize = 13;
  static const double _lineHeight = 1.45;
  static const String _fontFamily = 'monospace';

  @override
  void initState() {
    super.initState();
    _controller = SyntaxHighlightController(
      languageId: widget.languageId,
      text: widget.initialValue,
    );
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    widget.onChanged(_controller.text);
    // A rebuild is needed so the line-number gutter catches up.
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(CodeEditorField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent (GeoUI renderer) passes `initialValue` from the
    // bindings map on every rebuild. When the host mutates those
    // bindings outside the widget (e.g. App Creator's load_existing
    // action pushes a whole new source string), the new initialValue
    // differs from BOTH the old widget value and the current
    // controller text. That combination means "someone replaced the
    // content from underneath us" — sync the controller.
    //
    // The double comparison is important: during normal typing the
    // new initialValue equals the current controller text (because
    // onChanged already ran and wrote it back to the bindings), so
    // we must not reset.
    if (oldWidget.initialValue != widget.initialValue &&
        widget.initialValue != _controller.text) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  int get _lineCount {
    final text = _controller.text;
    if (text.isEmpty) return 1;
    return '\n'.allMatches(text).length + 1;
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
          Container(
            constraints:
                const BoxConstraints(minHeight: 240, maxHeight: 520),
            decoration: BoxDecoration(
              // vs2015 background matches the highlighting theme chosen
              // by SyntaxHighlightController when brightness == dark.
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: cs.outlineVariant.withAlpha(80)),
            ),
            child: Scrollbar(
              child: SingleChildScrollView(
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _LineNumberGutter(
                        lineCount: _lineCount,
                        fontSize: _fontSize,
                        lineHeight: _lineHeight,
                        fontFamily: _fontFamily,
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                          child: TextField(
                            controller: _controller,
                            maxLines: null,
                            minLines: 10,
                            readOnly: widget.readOnly,
                            enableInteractiveSelection: true,
                            keyboardType: TextInputType.multiline,
                            textAlignVertical: TextAlignVertical.top,
                            cursorColor: Colors.white,
                            style: TextStyle(
                              fontFamily: _fontFamily,
                              fontSize: _fontSize,
                              height: _lineHeight,
                              // Dim the text when read-only so the
                              // state is visually obvious — matches
                              // the muted look of a disabled input.
                              color: widget.readOnly
                                  ? Colors.white54
                                  : Colors.white,
                            ),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              isDense: true,
                              isCollapsed: true,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
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

/// Left-hand gutter with 1-indexed line numbers. Uses the same font
/// metrics as the editor so rows line up. Soft-wrapped lines in the
/// editor will visually drift — acceptable for small wapp sources.
class _LineNumberGutter extends StatelessWidget {
  final int lineCount;
  final double fontSize;
  final double lineHeight;
  final String fontFamily;

  const _LineNumberGutter({
    required this.lineCount,
    required this.fontSize,
    required this.lineHeight,
    required this.fontFamily,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0x40000000),
        border: Border(
          right: BorderSide(color: Color(0x33FFFFFF)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 1; i <= lineCount; i++)
            SizedBox(
              height: fontSize * lineHeight,
              child: Text(
                '$i',
                style: TextStyle(
                  fontFamily: fontFamily,
                  fontSize: fontSize,
                  height: lineHeight,
                  color: Colors.white.withAlpha(100),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
