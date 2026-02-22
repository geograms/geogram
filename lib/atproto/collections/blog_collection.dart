/*
 * Blog post collection adapter for AT Protocol.
 *
 * Maps Geogram BlogPost model to radio.geogram.blog.post records.
 *
 * Lexicon: radio.geogram.blog.post
 * Required: title, content, createdAt
 * Optional: summary, tags, location, image (blob ref)
 */

import '../../models/blog_post.dart';
import '../repo.dart';
import 'collection_adapter.dart';

/// Adapter mapping BlogPost <-> radio.geogram.blog.post AT Proto records.
class BlogCollection extends CollectionAdapter {
  @override
  String get nsid => 'radio.geogram.blog.post';

  @override
  String get displayName => 'Blog Posts';

  /// Provider function to list all blog posts from Geogram storage.
  final Future<List<BlogPost>> Function() listPosts;

  BlogCollection({required this.listPosts});

  /// Convert a Geogram BlogPost to an AT Proto record map.
  static Map<String, dynamic> toRecord(BlogPost post) {
    final record = <String, dynamic>{
      '\$type': 'radio.geogram.blog.post',
      'title': post.title,
      'content': post.content,
      'createdAt': post.dateTime.toUtc().toIso8601String(),
    };

    if (post.description != null && post.description!.isNotEmpty) {
      record['summary'] = post.description;
    }
    if (post.tags.isNotEmpty) {
      record['tags'] = post.tags;
    }
    if (post.hasLocation) {
      record['latitude'] = post.latitude;
      record['longitude'] = post.longitude;
    }
    if (post.imageFile != null) {
      record['imageName'] = post.imageFile;
    }
    if (post.status == BlogStatus.published) {
      record['status'] = 'published';
    }
    if (post.edited != null && post.edited!.isNotEmpty) {
      final normalizedEdited = post.edited!.replaceAll('_', ':');
      try {
        record['editedAt'] = DateTime.parse(normalizedEdited).toUtc().toIso8601String();
      } catch (_) {}
    }
    if (post.author.isNotEmpty) {
      record['author'] = post.author;
    }

    return record;
  }

  /// Convert an AT Proto record map back to a BlogPost.
  static BlogPost fromRecord(String rkey, Map<String, dynamic> record) {
    final createdAt = record['createdAt'] as String? ?? DateTime.now().toIso8601String();
    final dt = DateTime.tryParse(createdAt) ?? DateTime.now();

    final metadata = <String, String>{};
    if (record['imageName'] != null) {
      metadata['image'] = record['imageName'] as String;
    }

    return BlogPost(
      id: rkey,
      author: record['author'] as String? ?? '',
      timestamp: '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}_${dt.second.toString().padLeft(2, '0')}',
      title: record['title'] as String? ?? '',
      description: record['summary'] as String?,
      location: record['latitude'] != null && record['longitude'] != null
          ? '${record['latitude']}, ${record['longitude']}'
          : null,
      status: record['status'] == 'published' ? BlogStatus.published : BlogStatus.draft,
      tags: (record['tags'] as List?)?.cast<String>() ?? [],
      content: record['content'] as String? ?? '',
      metadata: metadata,
    );
  }

  @override
  Future<int> syncAll(AtprotoRepo repo) async {
    final posts = await listPosts();
    var created = 0;

    for (final post in posts) {
      if (!post.isPublished) continue; // Only sync published posts

      final rkey = CollectionAdapter.rkeyFromTimestamp(post.timestamp);
      final record = toRecord(post);

      if (createIfAbsent(repo, rkey, record)) {
        created++;
      }
    }

    return created;
  }
}
