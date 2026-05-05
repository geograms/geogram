import 'config_service.dart';

/// Persisted user preferences for the in-app code/log editor surfaces
/// rendered by `\$type:"code"` and `\$type:"log"` GeoUI fields. Backed
/// by ConfigService so changes survive restart.
///
/// Singleton — read at widget build time so changes propagate next
/// rebuild without explicit notifiers.
class WappEditorSettings {
  WappEditorSettings._();
  static final WappEditorSettings _instance = WappEditorSettings._();
  factory WappEditorSettings() => _instance;

  static const _kFontFamily = 'editor.fontFamily';
  static const _kFontSize = 'editor.fontSize';
  static const _kLineHeight = 'editor.lineHeight';
  static const _kLogFontSize = 'editor.logFontSize';

  static const String defaultFontFamily = 'monospace';
  static const double defaultFontSize = 16.0;
  static const double defaultLineHeight = 1.5;
  static const double defaultLogFontSize = 14.0;

  String get fontFamily =>
      (ConfigService().get(_kFontFamily, defaultFontFamily) as String);

  double get fontSize {
    final v = ConfigService().get(_kFontSize, defaultFontSize);
    if (v is num) return v.toDouble();
    return defaultFontSize;
  }

  double get lineHeight {
    final v = ConfigService().get(_kLineHeight, defaultLineHeight);
    if (v is num) return v.toDouble();
    return defaultLineHeight;
  }

  double get logFontSize {
    final v = ConfigService().get(_kLogFontSize, defaultLogFontSize);
    if (v is num) return v.toDouble();
    return defaultLogFontSize;
  }

  set fontFamily(String value) => ConfigService().set(_kFontFamily, value);
  set fontSize(double value) => ConfigService().set(_kFontSize, value);
  set lineHeight(double value) => ConfigService().set(_kLineHeight, value);
  set logFontSize(double value) => ConfigService().set(_kLogFontSize, value);

  /// Reset all editor preferences to defaults.
  void resetToDefaults() {
    fontFamily = defaultFontFamily;
    fontSize = defaultFontSize;
    lineHeight = defaultLineHeight;
    logFontSize = defaultLogFontSize;
  }
}
