/*
 * LogViewField — scrollable, monospace, append-only log surface for
 * use inside the GeoUI renderer. Backs the new `$type:"log"` field
 * type.
 *
 * The wapp does not write directly to this widget; the host appends
 * lines by mutating the same `List<String>` that lives in the
 * bindings map. When a `{"type":"ui.log.append","field":"<name>",
 * "line":"..."}` message lands in [wapp_page.dart] `_drainOutbox`,
 * it pushes into the list and triggers a rebuild via the bindings
 * notifier.
 */

import 'package:flutter/material.dart';

class LogViewField extends StatefulWidget {
  /// GeoUI field name — used as the key when appending lines from
  /// the host side. The host looks up the matching field and pushes
  /// into its backing list.
  final String fieldName;

  /// Label shown above the log view. May be empty.
  final String label;

  /// Short help text shown below the log view. May be null.
  final String? tip;

  /// Mutable backing list shared with the host — the host appends
  /// lines here and calls the rebuild notifier. The widget reads but
  /// does not mutate.
  final List<String> lines;

  /// Fires when the widget wants the parent to rebuild it after
  /// scrolling or line changes. The GeoUI bindings setup calls
  /// setState on the enclosing wapp page so this is a no-op in the
  /// common case.
  final VoidCallback? onTick;

  const LogViewField({
    super.key,
    required this.fieldName,
    required this.label,
    required this.lines,
    this.tip,
    this.onTick,
  });

  @override
  State<LogViewField> createState() => _LogViewFieldState();
}

class _LogViewFieldState extends State<LogViewField> {
  final _scrollController = ScrollController();
  int _lastLineCount = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _autoScroll() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lines = widget.lines;

    // Auto-scroll to the bottom whenever new lines arrive.
    if (lines.length != _lastLineCount) {
      _lastLineCount = lines.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoScroll());
    }

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
                const BoxConstraints(minHeight: 120, maxHeight: 300),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1115),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: cs.outlineVariant.withAlpha(80)),
            ),
            child: lines.isEmpty
                ? Center(
                    child: Text(
                      '(no output)',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Colors.white.withAlpha(100),
                      ),
                    ),
                  )
                : Scrollbar(
                    controller: _scrollController,
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      itemCount: lines.length,
                      itemBuilder: (context, i) => Text(
                        lines[i],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.4,
                          color: Colors.white,
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
