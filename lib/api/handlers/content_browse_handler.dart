/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Generic /api/content/{appType}/… browse dispatcher. Each app
 * registers an [AppContentProvider] in [defaultAppContentProviders];
 * adding a new app type means writing one provider class — this
 * handler picks it up automatically and so does every HTTP server
 * that mixes in [ContentBrowseMixin].
 */

import '../../services/profile_storage.dart';
import 'app_content_provider.dart';
import 'app_content_providers.dart';

/// Result returned to the calling HTTP server. Either [json] or
/// [bytes] is set; the server writes whichever is non-null using the
/// reported [contentType] and [statusCode].
class ContentBrowseResult {
  final int statusCode;
  final Object? json;       // Map or List (encoded by the caller)
  final List<int>? bytes;
  final String contentType;

  ContentBrowseResult.json({
    required this.statusCode,
    required Object body,
    this.contentType = 'application/json; charset=utf-8',
  })  : json = body,
        bytes = null;

  ContentBrowseResult.bytes({
    required this.statusCode,
    required this.bytes,
    required this.contentType,
  }) : json = null;

  ContentBrowseResult.error({
    required this.statusCode,
    required String error,
    String? message,
  })  : contentType = 'application/json; charset=utf-8',
        bytes = null,
        json = {
          'success': false,
          'error': error,
          if (message != null) 'message': message,
        };
}

class ContentBrowseHandler {
  final ProfileStorage storage;
  final Map<String, AppContentProvider> providers;
  final void Function(String level, String message)? log;

  ContentBrowseHandler({
    required this.storage,
    List<AppContentProvider>? providers,
    this.log,
  }) : providers = {
          for (final p in providers ?? defaultAppContentProviders())
            p.appType: p,
        };

  /// Dispatches a request that has already been parsed into method +
  /// path segments + query parameters. The first two segments
  /// (`api/content`) are stripped before this is called — i.e.
  /// `segments` starts at the appType (or is empty for the index).
  Future<ContentBrowseResult> handle({
    required String method,
    required List<String> segments,
    Map<String, String> query = const {},
  }) async {
    if (method != 'GET') {
      return ContentBrowseResult.error(
        statusCode: 405,
        error: 'Method not allowed',
      );
    }

    // /api/content — list the providers (acts like /api/apps but also
    // tells the caller which appTypes have a working browse surface).
    if (segments.isEmpty) {
      final apps = <Map<String, dynamic>>[];
      for (final p in providers.values) {
        int count = 0;
        try {
          count = await p.countPublic(storage: storage);
        } catch (_) {}
        apps.add({
          'appType': p.appType,
          'title': p.title,
          'count': count,
        });
      }
      return ContentBrowseResult.json(
        statusCode: 200,
        body: {
          'success': true,
          'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'apps': apps,
        },
      );
    }

    final provider = providers[segments[0]];
    if (provider == null) {
      return ContentBrowseResult.error(
        statusCode: 404,
        error: 'Unknown appType: ${segments[0]}',
      );
    }

    try {
      // /api/content/{appType} — list items
      if (segments.length == 1) {
        final items = await provider.listPublic(
          storage: storage,
          query: query,
        );
        return ContentBrowseResult.json(
          statusCode: 200,
          body: {
            'success': true,
            'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'appType': provider.appType,
            'count': items.length,
            'items': items,
          },
        );
      }

      // /api/content/{appType}/{itemId} — one item detail
      if (segments.length == 2) {
        final item = await provider.getPublicItem(
          segments[1],
          storage: storage,
        );
        if (item == null) {
          return ContentBrowseResult.error(
            statusCode: 404,
            error: 'Item not found',
          );
        }
        return ContentBrowseResult.json(statusCode: 200, body: item);
      }

      // /api/content/{appType}/{itemId}/files/{path…} — raw file
      // or a ~480 px preview when `?thumb=1` is set. The provider
      // applies visibility gating and decides whether the file is
      // eligible for thumbnailing (see MediaThumbnailUtils).
      if (segments.length >= 4 && segments[2] == 'files') {
        final relativePath = segments.sublist(3).join('/');
        final wantThumb = query['thumb'] == '1';
        final file = await provider.getPublicFile(
          segments[1],
          relativePath,
          storage: storage,
          thumbnail: wantThumb,
        );
        if (file == null) {
          return ContentBrowseResult.error(
            statusCode: 404,
            error: 'File not found',
          );
        }
        return ContentBrowseResult.bytes(
          statusCode: 200,
          bytes: file.bytes,
          contentType: file.contentType,
        );
      }

      return ContentBrowseResult.error(
        statusCode: 400,
        error: 'Unsupported content path: ${segments.join('/')}',
      );
    } on UnimplementedError {
      return ContentBrowseResult.error(
        statusCode: 501,
        error: 'Browse not implemented for ${provider.appType}',
      );
    } catch (e) {
      log?.call('ERROR', 'ContentBrowseHandler ${segments.join('/')}: $e');
      return ContentBrowseResult.error(
        statusCode: 500,
        error: 'Internal server error',
        message: e.toString(),
      );
    }
  }
}
