import 'package:shared_preferences/shared_preferences.dart';

import '../platform/platform.dart' as platform;

/// Persistent user preferences backed by shared_preferences.
/// Works on all platforms including web (uses localStorage on web).
class PreferencesService {
  static PreferencesService? _instance;
  late final SharedPreferences _prefs;

  PreferencesService._();

  static Future<PreferencesService> instance() async {
    if (_instance != null) return _instance!;
    _instance = PreferencesService._();
    _instance!._prefs = await SharedPreferences.getInstance();
    return _instance!;
  }

  /// Sync accessor — safe to use after the first `instance()` call
  /// has completed (which happens during app startup in main.dart).
  static PreferencesService? get instanceSync => _instance;

  // Terminal settings
  double get terminalFontSize => _prefs.getDouble('terminal.fontSize') ?? 16.0;
  set terminalFontSize(double v) => _prefs.setDouble('terminal.fontSize', v);

  String get terminalFontFamily => _prefs.getString('terminal.fontFamily') ?? 'RobotoMono';
  set terminalFontFamily(String v) => _prefs.setString('terminal.fontFamily', v);

  double get terminalLineHeight => _prefs.getDouble('terminal.lineHeight') ?? 1.5;
  set terminalLineHeight(double v) => _prefs.setDouble('terminal.lineHeight', v);

  String get terminalColorScheme => _prefs.getString('terminal.colorScheme') ?? 'dark';
  set terminalColorScheme(String v) => _prefs.setString('terminal.colorScheme', v);

  bool get terminalShowTimestamps => _prefs.getBool('terminal.showTimestamps') ?? false;
  set terminalShowTimestamps(bool v) => _prefs.setBool('terminal.showTimestamps', v);

  int get terminalMaxLines => _prefs.getInt('terminal.maxLines') ?? 5000;
  set terminalMaxLines(int v) => _prefs.setInt('terminal.maxLines', v);

  // Wapp data directory — root folder for per-wapp user data
  String? get wappDataDir => _prefs.getString('wapp.dataDir');
  set wappDataDir(String? v) {
    if (v == null) {
      _prefs.remove('wapp.dataDir');
    } else {
      _prefs.setString('wapp.dataDir', v);
    }
  }

  // Widget provider preferences — when multiple wapps advertise the
  // same widgetId, this tells the [WidgetBroker] which provider to
  // prefer. Stored as one entry per widgetId keyed
  // `widget.provider.<widget-id>`. `null` means "no preference —
  // pick the first registered provider".
  String? getPreferredProvider(String widgetId) =>
      _prefs.getString('widget.provider.$widgetId');

  void setPreferredProvider(String widgetId, String? providerWappId) {
    final key = 'widget.provider.$widgetId';
    if (providerWappId == null || providerWappId.isEmpty) {
      _prefs.remove(key);
    } else {
      _prefs.setString(key, providerWappId);
    }
  }

  // ── Locale preference ────────────────────────────────────────────
  //
  // The active UI locale controls how wapps resolve their `@key`
  // translation sentinels. An empty / null value means "follow the
  // OS" — [activeLocale] returns [Platform.localeName] in that case
  // so callers don't have to special-case it.
  //
  // Stored as a short tag like `pt_PT`, `en_US`, `de_DE`, `pt`, `en`.
  // Resolving a wapp's language file tries the full tag, then the
  // language-only prefix, then `en`, then the literal source string.

  /// The raw preference value. Null means "auto" (follow the OS).
  String? get localePreference => _prefs.getString('locale');
  set localePreference(String? v) {
    if (v == null || v.isEmpty) {
      _prefs.remove('locale');
    } else {
      _prefs.setString('locale', v);
    }
  }

  /// The effective active locale. Returns the stored preference
  /// when set, otherwise the OS locale (via the platform abstraction),
  /// with a final fallback to `en` so the rest of the app never
  /// sees an empty string.
  String activeLocale() {
    final stored = localePreference;
    if (stored != null && stored.isNotEmpty) return stored;
    return platform.currentLocale();
  }

  /// Language-only portion of [activeLocale] — `pt_PT` → `pt`,
  /// `pt` → `pt`. Used by the fallback chain so a wapp that only
  /// ships `lang/pt.json` still matches `pt_BR` users.
  String activeLanguageCode() {
    final full = activeLocale();
    final sep = full.contains('_')
        ? full.indexOf('_')
        : full.contains('-')
            ? full.indexOf('-')
            : -1;
    return sep < 0 ? full.toLowerCase() : full.substring(0, sep).toLowerCase();
  }
}
