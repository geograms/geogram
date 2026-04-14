/*
 * WidgetRegistry — map of widgetId → providers.
 *
 * The launcher rebuilds this whenever it scans for wapps. Providers
 * are just WappManifest entries whose manifest.json declared one or
 * more widget IDs under `provides.widgets`. One wapp can provide any
 * number of widgets by listing them in that array.
 *
 * Widget IDs are free-form dot-separated strings. Convention:
 * `<category>.<action>` (e.g. `file.pick`, `image.gallery`,
 * `text.greet`). Nothing enforces the shape — picking is done by
 * exact match.
 */

import '../main.dart' show WappManifest;

class WidgetRegistry {
  WidgetRegistry._();
  static final WidgetRegistry instance = WidgetRegistry._();

  /// {widgetId → providers that declared it}. Order within each list
  /// is the scan order — the first entry is the fallback default
  /// when no user preference is set.
  final Map<String, List<WappManifest>> _providers = {};

  /// Wipe the registry. Called by the launcher before a re-scan so
  /// removed wapps no longer show up as providers.
  void clear() {
    _providers.clear();
  }

  /// Register one wapp as a provider for every widget id listed in
  /// its manifest.
  void register(WappManifest manifest) {
    for (final id in manifest.providedWidgets) {
      if (id.isEmpty) continue;
      (_providers[id] ??= []).add(manifest);
    }
  }

  /// Providers for a given widget id, in scan order. Empty list if
  /// no wapp has declared it.
  List<WappManifest> providersFor(String widgetId) {
    return List.unmodifiable(_providers[widgetId] ?? const []);
  }

  /// Every widget id any wapp has declared.
  Set<String> get allWidgetIds => _providers.keys.toSet();

  /// Debug helper — whole registry as JSON-friendly structure.
  Map<String, List<String>> toJson() => {
        for (final entry in _providers.entries)
          entry.key: [for (final p in entry.value) p.id],
      };
}
