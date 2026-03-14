import 'dart:convert';

/// Utility for parsing app.js files that use the JavaScript format:
///   window.APP_DATA = { ... };
class AppJsUtils {
  /// Extract and parse the JSON object from an app.js file content.
  ///
  /// app.js files are JavaScript, not pure JSON — they contain:
  ///   window.APP_DATA = { "app": { "type": "blog", ... } };
  ///
  /// Returns the parsed Map, or null if parsing fails.
  static Map<String, dynamic>? parseAppJsContent(String content) {
    final match = RegExp(
      r'window\.APP_DATA\s*=\s*({[\s\S]*?});',
    ).firstMatch(content);
    if (match == null) return null;

    try {
      return jsonDecode(match.group(1)!) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
