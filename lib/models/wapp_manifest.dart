/*
 * WappManifest — parsed shape of a wapp's manifest.json
 *
 * Stage 1: bare-string functionality declarations only. Rich
 * endpoint API definitions (FunctionalityDef) will land alongside
 * the functionality registry/broker port in Stage 2.
 */

import 'package:characters/characters.dart';
import 'package:path/path.dart' as p;

class WappManifest {
  /// Reverse-domain identifier (e.g. "tools.geogram.maps").
  final String id;

  /// On-disk folder name (last segment of [dirPath]).
  final String name;

  /// Human-readable display name. Read from manifest.description.
  final String title;

  /// Long-form description. Read from manifest.summary.
  final String description;

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

  WappManifest({
    required this.id,
    required this.name,
    required this.title,
    required this.description,
    required this.kind,
    this.icon,
    required this.dirPath,
    this.publisherNpub = '',
    this.providedFunctionalities = const [],
    this.tickIntervalMs = 5000,
    this.halRequires = const ['log'],
  });

  factory WappManifest.fromJson(
    Map<String, dynamic> json,
    String dirPath, {
    String publisherNpub = '',
  }) {
    final id = json['id'] as String? ?? '';
    final folderName = p.basename(dirPath);
    final manifestDescription = json['description'] as String? ?? '';
    final manifestSummary = json['summary'] as String? ?? '';

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

    return WappManifest(
      id: id,
      name: folderName.isNotEmpty ? folderName : id.split('.').last,
      title: manifestDescription.isNotEmpty ? manifestDescription : folderName,
      description: manifestSummary.isNotEmpty
          ? manifestSummary
          : manifestDescription,
      kind: json['kind'] as String? ?? 'app',
      icon: json['icon'] as String?,
      dirPath: dirPath,
      publisherNpub: publisherNpub,
      providedFunctionalities: funcIds,
      tickIntervalMs: (json['tick_interval_ms'] as num?)?.toInt() ?? 5000,
      halRequires: hal,
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
