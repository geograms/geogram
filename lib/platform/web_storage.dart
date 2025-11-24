/// Web storage implementation using localStorage
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Helper class for web localStorage operations
class WebStorage {
  /// Get a value from localStorage
  static String? get(String key) {
    return html.window.localStorage[key];
  }

  /// Set a value in localStorage
  static void set(String key, String value) {
    html.window.localStorage[key] = value;
  }

  /// Remove a value from localStorage
  static void remove(String key) {
    html.window.localStorage.remove(key);
  }

  /// Check if a key exists in localStorage
  static bool containsKey(String key) {
    return html.window.localStorage.containsKey(key);
  }

  /// Clear all localStorage
  static void clear() {
    html.window.localStorage.clear();
  }
}
