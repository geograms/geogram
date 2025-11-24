/// Stub for web storage on native platforms
/// This should never be called on native platforms as kIsWeb will be false

/// Helper class for web localStorage operations (stub for native)
class WebStorage {
  /// Get a value from localStorage
  static String? get(String key) {
    throw UnsupportedError('WebStorage is only available on web');
  }

  /// Set a value in localStorage
  static void set(String key, String value) {
    throw UnsupportedError('WebStorage is only available on web');
  }

  /// Remove a value from localStorage
  static void remove(String key) {
    throw UnsupportedError('WebStorage is only available on web');
  }

  /// Check if a key exists in localStorage
  static bool containsKey(String key) {
    throw UnsupportedError('WebStorage is only available on web');
  }

  /// Clear all localStorage
  static void clear() {
    throw UnsupportedError('WebStorage is only available on web');
  }
}
