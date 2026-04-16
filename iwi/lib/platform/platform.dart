/*
 * Platform abstraction — conditional export.
 *
 * The rest of iwi/lib/ imports from this file. At build time the
 * Dart compiler picks `platform_io.dart` when `dart.library.io`
 * is available (desktop + mobile) and `platform_stubs.dart`
 * otherwise (Flutter web). Every public symbol in the two
 * implementations is identical, so callers write target-agnostic
 * code:
 *
 *   import '../platform/platform.dart' as platform;
 *   final loc = platform.currentLocale();
 *
 * See docs/plan/wapp-i18n.md and the pattern the Flutter team
 * itself uses in flutter_tools for reference.
 */

export 'platform_stubs.dart'
    if (dart.library.io) 'platform_io.dart';
