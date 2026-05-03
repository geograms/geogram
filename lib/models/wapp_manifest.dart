/*
 * WappManifest — parsed shape of a wapp's manifest.json
 *
 * Stage 1: bare-string functionality declarations only. Rich
 * endpoint API definitions (FunctionalityDef) will land alongside
 * the functionality registry/broker port in Stage 2.
 */

import 'package:characters/characters.dart';
import 'package:path/path.dart' as p;

/// One declaration that this wapp can open files of a particular
/// kind. A wapp may declare multiple handlers (e.g. one for audio,
/// one for playlists). The lookup registry indexes both
/// [extensions] (lowercased, no leading dot) and [mimeTypes].
class WappFileHandler {
  /// File extensions this handler accepts, lowercased and without
  /// the leading dot. The literal "*" means "catch-all" (lowest
  /// priority — only chosen when no specific extension match
  /// exists).
  final List<String> extensions;

  /// MIME types this handler accepts. Wildcards are honoured at the
  /// type level — e.g. "audio/*" matches "audio/mpeg".
  final List<String> mimeTypes;

  /// Short verb shown in an "Open with…" picker — "Play", "Edit",
  /// "Preview". Falls back to the wapp's title when empty.
  final String title;

  /// Modes this handler supports. Two reserved values for now:
  ///   - "view"  — read-only display (default)
  ///   - "edit"  — open for modification, possibly saving back
  /// Other values are passed through unchanged so future modes can
  /// be added without an engine update.
  final List<String> modes;

  const WappFileHandler({
    this.extensions = const [],
    this.mimeTypes = const [],
    this.title = '',
    this.modes = const ['view'],
  });

  /// True when [ext] (no dot, any case) matches this handler.
  bool matchesExtension(String ext) {
    final normalized = ext.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    return extensions.contains(normalized) || extensions.contains('*');
  }

  /// True when [mime] (e.g. "audio/mpeg") matches one of this
  /// handler's MIME entries, honouring "type/*" wildcards.
  bool matchesMime(String mime) {
    final m = mime.toLowerCase();
    for (final pattern in mimeTypes) {
      final pat = pattern.toLowerCase();
      if (pat == m) return true;
      if (pat.endsWith('/*')) {
        final prefix = pat.substring(0, pat.length - 1);
        if (m.startsWith(prefix)) return true;
      }
      if (pat == '*/*' || pat == '*') return true;
    }
    return false;
  }

  /// True when this handler advertises [mode] (case-insensitive). An
  /// empty [mode] always matches.
  bool supportsMode(String mode) {
    if (mode.isEmpty) return true;
    final lower = mode.toLowerCase();
    for (final m in modes) {
      if (m.toLowerCase() == lower) return true;
    }
    return false;
  }

  factory WappFileHandler.fromJson(Map<String, dynamic> json) {
    List<String> readList(dynamic v) {
      if (v is List) return v.whereType<String>().toList();
      if (v is String) return [v];
      return const [];
    }

    final exts = readList(json['extensions'])
        .map((e) => e.toLowerCase().replaceFirst(RegExp(r'^\.'), ''))
        .where((e) => e.isNotEmpty)
        .toList();
    final mimes = readList(json['mime'])
        .map((m) => m.toLowerCase())
        .where((m) => m.isNotEmpty)
        .toList();
    final modes = readList(json['modes']);
    return WappFileHandler(
      extensions: exts,
      mimeTypes: mimes,
      title: (json['title'] as String? ?? '').trim(),
      modes: modes.isEmpty ? const ['view'] : modes,
    );
  }
}

class WappManifest {
  /// Reverse-domain identifier (e.g. "tools.geogram.maps").
  final String id;

  /// On-disk folder name (last segment of [dirPath]).
  final String name;

  /// Short launcher label (1–3 words). Read from manifest.title.
  final String title;

  /// One-line explanation, used in list views (catalog row, picker).
  /// Read from manifest.description.
  final String description;

  /// Paragraph-long explanation for detail / about views. Read from
  /// manifest.summary.
  final String summary;

  /// "app" by default; can be "system", "addon", etc.
  final String kind;

  /// Optional icon — emoji char or relative path to an SVG file
  /// (e.g. "media/icons/icon.svg").
  final String? icon;

  /// Absolute path to the wapp folder.
  final String dirPath;

  /// Publisher npub from signature.json (empty when unsigned).
  final String publisherNpub;

  /// Functionality IDs this wapp provides.
  final List<String> providedFunctionalities;

  /// Tick interval in milliseconds (0 = no tick).
  final int tickIntervalMs;

  /// HAL capabilities required (subset of: log, kv, msg, i18n_get, ...).
  final List<String> halRequires;

  /// File-type handlers this wapp registers (see [WappFileHandler]).
  /// Indexed by [WappFileAssociations] so the host can answer
  /// "which wapps can open *.mp3?".
  final List<WappFileHandler> fileHandlers;

  WappManifest({
    required this.id,
    required this.name,
    required this.title,
    required this.description,
    this.summary = '',
    required this.kind,
    this.icon,
    required this.dirPath,
    this.publisherNpub = '',
    this.providedFunctionalities = const [],
    this.tickIntervalMs = 5000,
    this.halRequires = const ['log'],
    this.fileHandlers = const [],
  });

  factory WappManifest.fromJson(
    Map<String, dynamic> json,
    String dirPath, {
    String publisherNpub = '',
  }) {
    final id = json['id'] as String? ?? '';
    final folderName = p.basename(dirPath);
    // New schema (preferred):
    //   title        — short launcher label
    //   description  — one-line explanation
    //   summary      — paragraph-long explanation
    // Legacy schema (pre-rename, still produced by older wapps):
    //   description  — was the title
    //   summary      — was the long description
    // Detect legacy by absence of an explicit `title` field.
    final hasTitle =
        json['title'] is String && (json['title'] as String).isNotEmpty;
    final manifestTitle = hasTitle
        ? (json['title'] as String)
        : ((json['description'] as String?) ?? '');
    final manifestDescription = hasTitle
        ? ((json['description'] as String?) ?? '')
        // Legacy: short description doesn't exist — collapse to empty.
        : '';
    final manifestSummary = (json['summary'] as String?) ?? '';

    // Parse provides.functionalities — bare strings or {id: "..."} objects.
    final provides = json['provides'];
    final funcList = provides is Map<String, dynamic>
        ? (provides['functionalities'] ?? provides['widgets'])
        : null;
    final funcIds = <String>[];
    if (funcList is List) {
      for (final entry in funcList) {
        if (entry is String) {
          funcIds.add(entry);
        } else if (entry is Map<String, dynamic>) {
          final eid = entry['id'] as String?;
          if (eid != null && eid.isNotEmpty) funcIds.add(eid);
        }
      }
    }

    final requires = json['requires'];
    final halList = requires is Map<String, dynamic> ? requires['hal'] : null;
    final hal = halList is List
        ? halList.whereType<String>().toList()
        : const <String>['log'];

    // Parse provides.file_handlers — list of WappFileHandler entries
    // declaring which extensions / MIME types this wapp can open.
    final handlerList = provides is Map<String, dynamic>
        ? provides['file_handlers']
        : null;
    final handlers = <WappFileHandler>[];
    if (handlerList is List) {
      for (final entry in handlerList) {
        if (entry is Map<String, dynamic>) {
          final h = WappFileHandler.fromJson(entry);
          if (h.extensions.isNotEmpty || h.mimeTypes.isNotEmpty) {
            handlers.add(h);
          }
        }
      }
    }

    return WappManifest(
      id: id,
      name: folderName.isNotEmpty ? folderName : id.split('.').last,
      title: manifestTitle.isNotEmpty ? manifestTitle : folderName,
      description: manifestDescription,
      summary: manifestSummary,
      kind: json['kind'] as String? ?? 'app',
      icon: json['icon'] as String?,
      dirPath: dirPath,
      publisherNpub: publisherNpub,
      providedFunctionalities: funcIds,
      tickIntervalMs: (json['tick_interval_ms'] as num?)?.toInt() ?? 5000,
      halRequires: hal,
      fileHandlers: handlers,
    );
  }

  /// Absolute path to the SVG icon, when manifest.icon points to one.
  /// Returns null for emoji icons or missing entries.
  String? get svgIconRelativePath {
    final raw = icon;
    if (raw == null || raw.isEmpty) return null;
    if (!raw.toLowerCase().endsWith('.svg')) return null;
    if (!raw.contains('/') && !raw.contains('\\')) return null;
    return raw;
  }

  /// Short text icon (emoji / single char) when manifest.icon is not
  /// a path. Returns null for path-shaped icons.
  String? get textIcon {
    final raw = icon;
    if (raw == null || raw.isEmpty) return null;
    if (raw.contains('/') || raw.contains('\\')) return null;
    return raw.characters.take(2).toString();
  }
}
