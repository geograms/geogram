/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Reusable per-app content discovery contract. Each app (blog, events,
 * chat, alerts, shared — and future apps like polls, places, …) ships
 * one implementation that knows its own on-disk layout. The /api/apps
 * discovery handler iterates the registered list so adding a new app
 * type is one new provider + one line in the factory — no edit to the
 * discovery handler or to the remote-device UI that reads it.
 */

import '../../services/profile_storage.dart';

abstract class AppContentProvider {
  /// Stable identifier used as the JSON key under /api/apps → apps{}.
  /// Example: `blog`, `events`, `chat`.
  String get appType;

  /// Human-readable label the remote device can show on its tile
  /// without hardcoding a mapping of its own.
  String get title;

  /// Number of publicly-visible pieces of content this app owns. Must
  /// be cheap (reads disk only; no rendering). Returns 0 when the app
  /// isn't installed or has no public content — implementations
  /// should swallow their own exceptions.
  Future<int> countPublic({required ProfileStorage storage});
}
