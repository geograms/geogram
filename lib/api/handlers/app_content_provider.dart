/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Reusable per-app content contract. Each app (blog, events, chat,
 * alerts, shared — and future apps like polls, places, …) ships one
 * implementation that knows its own on-disk layout. The `/api/apps`
 * discovery handler and the `/api/content/{appType}/…` browse
 * endpoint both iterate the registered list so adding a new app
 * type means writing one provider + adding one line in the factory.
 * No new routes, no edits to station.dart or log_api_service.dart.
 */

import '../../services/profile_storage.dart';

/// Bytes + content-type returned when a remote caller fetches a file
/// that lives inside an app's public content tree (e.g. an event
/// flyer image, a blog post attachment).
class RemoteFile {
  final List<int> bytes;
  final String contentType;
  const RemoteFile({required this.bytes, required this.contentType});
}

abstract class AppContentProvider {
  /// Stable identifier used as the JSON key under `/api/apps → apps{}`
  /// and the path segment for `/api/content/{appType}/…`.
  String get appType;

  /// Human-readable label the remote device can show on its tile
  /// without hardcoding a mapping of its own.
  String get title;

  /// Number of publicly-visible pieces of content this app owns.
  /// Cheap (reads disk only, no rendering). Returns 0 when the app
  /// isn't installed or has no public content. Implementations
  /// should swallow their own exceptions.
  Future<int> countPublic({required ProfileStorage storage});

  /// List the publicly-visible items for `/api/content/{appType}`.
  /// Each map is a compact summary — title / author / timestamp /
  /// visibility plus any engagement counters the UI would want in a
  /// list view. Visibility gating belongs here.
  ///
  /// [query] forwards the URL query parameters (year, limit, offset,
  /// tag, …) so the provider can filter / paginate.
  ///
  /// The default implementation throws — providers that don't yet
  /// support browse will surface 501 Not Implemented to the caller.
  Future<List<Map<String, dynamic>>> listPublic({
    required ProfileStorage storage,
    Map<String, String> query = const {},
  }) =>
      throw UnimplementedError(
          'listPublic not implemented for $appType');

  /// Load full public details for one item (the detail payload the
  /// remote UI renders). Returns `null` when the item doesn't exist
  /// or isn't public. For partially-public items (e.g.
  /// `request_access` events) the provider strips private fields and
  /// marks the payload with an appropriate flag before returning.
  Future<Map<String, dynamic>?> getPublicItem(
    String itemId, {
    required ProfileStorage storage,
  }) =>
      throw UnimplementedError(
          'getPublicItem not implemented for $appType');

  /// Fetch a file attached to an item. `relativePath` is a safe
  /// path relative to the item's folder — implementations must
  /// reject `..` / absolute paths / escapes. Returns `null` for
  /// not-found or not-public.
  Future<RemoteFile?> getPublicFile(
    String itemId,
    String relativePath, {
    required ProfileStorage storage,
  }) =>
      throw UnimplementedError(
          'getPublicFile not implemented for $appType');
}
