/*
 * Platform-aware SQLite loader.
 *
 * Exports the correct implementation based on runtime:
 * - Flutter builds use sqlite3_flutter_libs to provide bundled native libs.
 * - Pure Dart/CLI builds load bundled native libs from third_party/sqlite or libs/.
 */
export 'sqlite_loader_pure.dart'
    if (dart.library.ui) 'sqlite_loader_flutter.dart';
