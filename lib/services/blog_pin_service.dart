/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Local-only pin store for blog posts. Mirrors EventPinService —
 * persistence in [ConfigService] under `pinnedBlogPosts`, key
 * format `${author_npub_or_callsign}|${postId}` so the same key
 * works whether the post is local or fetched from another device.
 */

import '../models/blog_post.dart';
import 'config_service.dart';

class BlogPinService {
  BlogPinService._();

  static const String _key = 'pinnedBlogPosts';

  static String keyFor(BlogPost post) {
    final author = (post.npub != null && post.npub!.isNotEmpty)
        ? post.npub!
        : post.author;
    return '$author|${post.id}';
  }

  static Set<String> all() {
    final raw = ConfigService().get(_key, <dynamic>[]) as List<dynamic>;
    return raw.map((e) => e.toString()).toSet();
  }

  static bool isPinned(BlogPost post) => all().contains(keyFor(post));

  /// Flip the pin state for [post]. Returns the new state.
  static bool toggle(BlogPost post) {
    final key = keyFor(post);
    final current = all();
    final nowPinned = !current.contains(key);
    if (nowPinned) {
      current.add(key);
    } else {
      current.remove(key);
    }
    ConfigService().set(_key, current.toList());
    return nowPinned;
  }
}
