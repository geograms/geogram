import 'package:shared_preferences/shared_preferences.dart';

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
}
