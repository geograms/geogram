/*
 * WappOpenWith — file → wapp launch path.
 *
 * Bridges a chosen file (from the OS file picker, a chat
 * attachment, an inbox folder, etc.) to a wapp that registered
 * itself as a handler for that file's extension or MIME type.
 *
 * Flow:
 *   1. lookup() against WappFileAssociations.
 *   2. If a previously-saved default exists for this extension,
 *      launch it directly.
 *   3. Else if exactly one match, launch it (no picker noise).
 *   4. Else show an "Open with…" dialog with the matching wapps;
 *      the user can also tick "Always use this wapp" to persist
 *      the choice.
 *
 * The chosen wapp is launched as a [WappPage] with the file
 * delivered via the Section 18 launch protocol (`file.open`).
 */

import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/log_service.dart';
import '../services/wapp_file_associations.dart';
import 'wapp_page.dart';

class WappOpenWith {
  WappOpenWith._();

  /// Show a system file picker, then route the result through
  /// [openPath]. Useful as the action behind a launcher button or
  /// keyboard shortcut.
  static Future<bool> pickAndOpen(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        dialogTitle: 'Open file with a wapp…',
      );
      if (result == null || result.files.isEmpty) return false;
      final picked = result.files.first.path;
      if (picked == null) return false;
      if (!context.mounted) return false;
      return await openPath(context, picked);
    } catch (e) {
      LogService().log('WappOpenWith: file picker failed: $e');
      return false;
    }
  }

  /// Look up handlers for [path] and either launch directly (when
  /// there's a default or a single match) or show a picker. Returns
  /// true when a wapp was launched.
  static Future<bool> openPath(BuildContext context, String path) async {
    final ext = _extOf(path);
    final assoc = WappFileAssociations.instance;

    // Honour the user's stored default first.
    final userDefault = await assoc.defaultFor(ext);
    if (userDefault != null) {
      _launch(context, userDefault, path, ext);
      return true;
    }

    final hits = await assoc.lookup(extension: ext, mode: 'view');
    if (hits.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No wapp can open .$ext files yet.')),
        );
      }
      return false;
    }

    // Single match → silent launch.
    if (hits.length == 1) {
      _launch(context, hits.first, path, ext);
      return true;
    }

    // Multiple matches → ask the user.
    if (!context.mounted) return false;
    final pick = await showPicker(
      context,
      filename: p.basename(path),
      hits: hits,
      allowSetDefault: true,
    );
    if (pick == null) return false;
    if (pick.setAsDefault) {
      await assoc.setDefaultFor(ext, pick.association.wappId);
    }
    if (!context.mounted) return false;
    _launch(context, pick.association, path, ext);
    return true;
  }

  /// Show the picker UI and return the user's choice. Exposed so
  /// callers that already have a list of associations (e.g. from a
  /// long-press menu) can reuse the same widget.
  static Future<_PickerChoice?> showPicker(
    BuildContext context, {
    required String filename,
    required List<WappAssociation> hits,
    bool allowSetDefault = true,
  }) async {
    return showModalBottomSheet<_PickerChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _OpenWithSheet(
        filename: filename,
        hits: hits,
        allowSetDefault: allowSetDefault,
      ),
    );
  }

  // ── internals ──────────────────────────────────────────────────

  static void _launch(
    BuildContext context,
    WappAssociation choice,
    String path,
    String ext,
  ) {
    final size = _sizeOf(path);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WappPage(
        wappId: choice.wappId,
        title: choice.label,
        openFile: WappOpenFile(
          path: path,
          name: p.basename(path),
          extension: ext,
          mode: 'view',
          size: size,
        ),
      ),
    ));
  }

  static String _extOf(String path) {
    final raw = p.extension(path);
    return raw.startsWith('.') ? raw.substring(1).toLowerCase() : raw.toLowerCase();
  }

  static int _sizeOf(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return -1;
      return f.lengthSync();
    } catch (_) {
      return -1;
    }
  }
}

/// What [WappOpenWith.showPicker] returns: the picked association
/// plus whether the user asked us to remember it.
class _PickerChoice {
  final WappAssociation association;
  final bool setAsDefault;
  _PickerChoice(this.association, this.setAsDefault);
}

class _OpenWithSheet extends StatefulWidget {
  final String filename;
  final List<WappAssociation> hits;
  final bool allowSetDefault;

  const _OpenWithSheet({
    required this.filename,
    required this.hits,
    required this.allowSetDefault,
  });

  @override
  State<_OpenWithSheet> createState() => _OpenWithSheetState();
}

class _OpenWithSheetState extends State<_OpenWithSheet> {
  bool _setDefault = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Open with…',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.filename,
              style: TextStyle(
                fontFamily: 'monospace',
                color: cs.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: widget.hits.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (_, i) {
                  final h = widget.hits[i];
                  return Card(
                    elevation: 0,
                    margin: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(
                          color: cs.outlineVariant.withAlpha(80)),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.extension),
                      title: Text(h.manifest.title),
                      subtitle: Text(
                        '${h.handler.title.isNotEmpty ? h.handler.title : "Open"}'
                        ' • ${h.manifest.id}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).pop(
                          _PickerChoice(h, _setDefault)),
                    ),
                  );
                },
              ),
            ),
            if (widget.allowSetDefault) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _setDefault,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Always use this wapp for these files'),
                onChanged: (v) => setState(() => _setDefault = v ?? false),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
