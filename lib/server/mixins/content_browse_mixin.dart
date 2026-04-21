/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Mounts the generic /api/content/… browse surface on whichever HTTP
 * server runs on this device — station-mode (lib/station.dart, raw
 * HttpServer) or regular-device-mode (lib/services/log_api_service.dart,
 * shelf). Both classes mix this in; route registration is one early-
 * return per server. All real work lives in the shared
 * [ContentBrowseHandler], so adding a new app type means a new
 * AppContentProvider — no edit to either server.
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../../platform/io_stub.dart';

import 'package:shelf/shelf.dart' as shelf;

import '../../api/handlers/content_browse_handler.dart';
import '../../services/profile_storage.dart';

mixin ContentBrowseMixin {
  /// The implementing class supplies the storage rooted at the
  /// device's per-callsign data folder. The handler then scopes
  /// further (events/blog/…) via path prefixes that match how each
  /// app stores its content.
  ProfileStorage get contentBrowseStorage;

  /// Optional log sink — falls back to print when not overridden.
  void contentBrowseLog(String level, String message) {
    // ignore: avoid_print
    print('[$level] ContentBrowse: $message');
  }

  /// Built fresh on each request so profile-switch picks up a new
  /// storage immediately. The constructor is cheap (just maps the
  /// provider list by appType).
  ContentBrowseHandler get contentBrowse => ContentBrowseHandler(
        storage: contentBrowseStorage,
        log: contentBrowseLog,
      );

  // ─────────────────────────── HttpRequest ──────────────────────
  // (used by lib/station.dart)

  /// Returns true when the request was handled (caller must return
  /// from its dispatcher); false when the path didn't match.
  Future<bool> handleContentBrowseRequest(HttpRequest request) async {
    final path = request.uri.path;
    if (!path.startsWith('/api/content')) return false;

    // Strip /api/content[/…] → segments after that point.
    final after = path.length > '/api/content'.length
        ? path.substring('/api/content'.length)
        : '';
    var trimmed = after;
    while (trimmed.startsWith('/')) {
      trimmed = trimmed.substring(1);
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    final segments = trimmed.isEmpty
        ? const <String>[]
        : trimmed.split('/').map(Uri.decodeComponent).toList();

    final result = await contentBrowse.handle(
      method: request.method,
      segments: segments,
      query: request.uri.queryParameters,
    );

    request.response.statusCode = result.statusCode;
    if (result.bytes != null) {
      request.response.headers
          .set(HttpHeaders.contentTypeHeader, result.contentType);
      request.response.add(result.bytes!);
    } else {
      request.response.headers
          .set(HttpHeaders.contentTypeHeader, result.contentType);
      request.response.write(jsonEncode(result.json));
    }
    await request.response.close();
    return true;
  }

  // ─────────────────────────── shelf.Request ────────────────────
  // (used by lib/services/log_api_service.dart)

  /// Returns a non-null Response when the path was handled; null
  /// when the path didn't match `/api/content/…` so the caller can
  /// continue its own dispatch.
  Future<shelf.Response?> handleContentBrowseShelf(
    shelf.Request request,
    String urlPath,
  ) async {
    if (urlPath != 'api/content' && !urlPath.startsWith('api/content/')) {
      return null;
    }

    final after = urlPath.length > 'api/content'.length
        ? urlPath.substring('api/content'.length)
        : '';
    var trimmed = after;
    while (trimmed.startsWith('/')) {
      trimmed = trimmed.substring(1);
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    final segments = trimmed.isEmpty
        ? const <String>[]
        : trimmed.split('/').map(Uri.decodeComponent).toList();

    final result = await contentBrowse.handle(
      method: request.method,
      segments: segments,
      query: request.url.queryParameters,
    );

    final headers = <String, String>{
      'Content-Type': result.contentType,
      'Access-Control-Allow-Origin': '*',
    };
    if (result.bytes != null) {
      return shelf.Response(result.statusCode,
          body: result.bytes, headers: headers);
    }
    return shelf.Response(
      result.statusCode,
      body: jsonEncode(result.json),
      headers: headers,
    );
  }
}
