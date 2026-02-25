/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Lightweight wrapper around NostrEvent for UI display.
 */

import '../../../util/nostr_event.dart';

class NostrFeedItem {
  final NostrEvent event;
  final String relayUrl;
  String? authorName;
  String? authorNip05;
  String? authorPicture;
  bool isFollowed;

  NostrFeedItem({
    required this.event,
    required this.relayUrl,
    this.authorName,
    this.authorNip05,
    this.authorPicture,
    this.isFollowed = false,
  });

  /// Display name: resolved author name, or truncated npub.
  String get displayName {
    if (authorName != null && authorName!.isNotEmpty) return authorName!;
    final npub = event.npub;
    if (npub.length > 16) return '${npub.substring(0, 12)}...';
    return npub;
  }

  /// Unix timestamp in seconds.
  int get createdAt => event.createdAt;

  /// Content text.
  String get content => event.content;

  /// Event ID (globally unique).
  String? get id => event.id;

  /// Author pubkey hex.
  String get pubkey => event.pubkey;
}
