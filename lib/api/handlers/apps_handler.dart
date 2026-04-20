/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Apps discovery handler: `GET /api/apps` returns availability + item
 * counts per app type so a remote device can render accurate tiles on
 * its device-detail page. The per-app counting is delegated to a list
 * of [AppContentProvider]s — adding a new app type is one new provider
 * class, no edit here.
 */

import '../../services/profile_storage.dart';
import 'app_content_provider.dart';
import 'app_content_providers.dart';

class AppsHandler {
  final ProfileStorage storage;
  final List<AppContentProvider> providers;
  final void Function(String level, String message)? log;

  AppsHandler({
    required this.storage,
    List<AppContentProvider>? providers,
    this.log,
  }) : providers = providers ?? defaultAppContentProviders();

  void _log(String level, String message) {
    log?.call(level, message);
  }

  /// GET /api/apps — loops every registered provider and returns its
  /// availability + public-content count. A provider throwing is
  /// reported as `{available: false, count: 0}` so one broken app
  /// doesn't break the whole response.
  Future<Map<String, dynamic>> getApps() async {
    final apps = <String, Map<String, dynamic>>{};
    for (final provider in providers) {
      var count = 0;
      try {
        count = await provider.countPublic(storage: storage);
      } catch (e) {
        _log('DEBUG', '${provider.appType} count failed: $e');
      }
      apps[provider.appType] = {
        'available': count > 0,
        'count': count,
        'title': provider.title,
      };
    }
    return {
      'success': true,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'apps': apps,
    };
  }
}
