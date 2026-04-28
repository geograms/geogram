/*
 * I18nContext — per-wapp translation lookup.
 *
 * Every running wapp gets its own context that holds:
 *   - the active locale tag (e.g. `pt_PT`)
 *   - the primary translation map loaded from
 *     `lang/<locale>.json` inside the wapp package
 *   - a fallback map loaded from `lang/en.json` so keys that the
 *     primary locale hasn't translated yet still render in English
 *     rather than as a raw `@key`
 *
 * GeoUI-level strings (labels, tips, hints, defaults, label-block
 * text) and wapp-side strings (via `hal_i18n_get`) both flow through
 * [resolve]. Anything not starting with `@` is returned untouched,
 * so legacy wapps with hard-coded English pass through at zero cost.
 *
 * Phase 1 (docs/plan/wapp-i18n.md) ships:
 *   - this class
 *   - a loader that scans the wapp's `lang/` dir
 *   - integration into GeoUiScreenRenderer + WappEngine + WappPage
 */

import 'profile_storage.dart';

class I18nContext {
  /// The effective locale tag for this wapp. Never empty.
  final String locale;

  /// Primary translation map. `@key` references try this first.
  final Map<String, String> primary;

  /// Fallback map (always the `en.json` file when present). Used
  /// when [primary] doesn't know the requested key.
  final Map<String, String> fallback;

  const I18nContext({
    required this.locale,
    required this.primary,
    required this.fallback,
  });

  /// Empty context — returns every `@key` as its literal value
  /// (minus the `@`). Used when a wapp doesn't ship any `lang/` dir
  /// or when translations failed to load.
  factory I18nContext.empty({String locale = 'en'}) => I18nContext(
        locale: locale,
        primary: const {},
        fallback: const {},
      );

  /// Resolve [raw] against the current translation tables.
  ///
  /// Rules:
  ///   - null → empty string
  ///   - doesn't start with `@` → pass through untouched
  ///   - `@key` → look up `key` in [primary], then [fallback], then
  ///     return the literal `key` (sentinel stripped) as a last-
  ///     resort fallback so the user sees *something* readable
  ///     instead of a broken `@namespace.title`
  String resolve(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    if (!raw.startsWith('@')) return raw;
    final key = raw.substring(1);
    final p = primary[key];
    if (p != null) return p;
    final f = fallback[key];
    if (f != null) return f;
    return key;
  }

  /// Nullable resolver — returns null when the input was null so
  /// callers that want to preserve "absent" semantics (e.g. not
  /// rendering a tip when none was declared) can distinguish
  /// "translate this" from "nothing to say".
  String? resolveOrNull(String? raw) {
    if (raw == null) return null;
    return resolve(raw);
  }

  /// Load a wapp's translation tables from its package directory.
  /// [pkg] is rooted at the wapp folder (the same `ProfileStorage`
  /// used by `_loadWapp`). [locale] is the full preferred tag;
  /// [languageOnly] is the short code derived from it (`pt_PT` →
  /// `pt`). The loader tries files in this order:
  ///
  ///   1. `lang/<exact-tag>.json`
  ///   2. `lang/<language-only>.json`
  ///   3. (fallback only) `lang/en.json`
  ///
  /// Returns an empty context (no entries) when the wapp has no
  /// `lang/` directory at all — resolve() still works, it just
  /// strips the `@` and returns the key.
  static Future<I18nContext> loadFromPackage(
    ProfileStorage pkg, {
    required String locale,
    required String languageOnly,
  }) async {
    Future<Map<String, String>> readMap(String name) async {
      try {
        final json = await pkg.readJson('lang/$name.json');
        if (json == null) return const {};
        final out = <String, String>{};
        for (final e in json.entries) {
          if (e.value is String) out[e.key] = e.value as String;
        }
        return out;
      } catch (_) {
        return const {};
      }
    }

    // Try the exact tag first, then language-only. Whichever hits
    // becomes primary; if both hit (e.g. `pt_PT.json` AND `pt.json`
    // both exist) we merge them with the exact tag winning.
    final exact = await readMap(locale);
    final langOnly = languageOnly == locale
        ? const <String, String>{}
        : await readMap(languageOnly);
    final primary = <String, String>{...langOnly, ...exact};

    // Fallback map is always English. Skip the read when the user
    // already speaks English — the primary map IS the fallback.
    Map<String, String> fallback = const {};
    if (languageOnly != 'en') {
      fallback = await readMap('en');
    }

    return I18nContext(
      locale: locale,
      primary: primary,
      fallback: fallback,
    );
  }
}
