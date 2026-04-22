/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * On-disk cache for blog posts fetched from other devices. Mirrors
 * the canonical layout the local user uses for their own blog —
 * `{baseDir}/devices/{AUTHOR_CALLSIGN}/blog/{YEAR}/{postId}/` —
 * so the cached folder walks identically to a real local blog.
 *
 *   {baseDir}/devices/{AUTHOR}/blog/{YEAR}/{postId}/
 *     ├── post.md                ← post body + headers
 *     ├── feedback/
 *     │   ├── likes.txt
 *     │   ├── points.txt
 *     │   ├── dislikes.txt
 *     │   └── comments/{id}.txt
 *     └── <attachments>          ← lazy-cached on view
 *
 * Goes through ProfileStorage so an encrypted-archive backend
 * could slot in without changes. Cache writes are best-effort —
 * IO failures never break the live UI.
 *
 * Followed-callsign auto-warmup (FollowService) is the main caller
 * but the helper is generic enough to be reused for one-off cache
 * writes (e.g. on detail open).
 */

import 'dart:typed_data';

import 'log_service.dart';
import 'profile_storage.dart';
import 'storage_config.dart';

class RemoteBlogCache {
  RemoteBlogCache._();

  /// `{baseDir}/devices/{CALLSIGN}/blog` — root for one author's
  /// cached blog. Plain filesystem (cache folders are not
  /// profiles), same pattern RemoteEventCache uses.
  static ProfileStorage _storageFor(String authorCallsign) {
    final base = StorageConfig().baseDir;
    return FilesystemProfileStorage(
      '$base/devices/${authorCallsign.toUpperCase()}/blog',
    );
  }

  static String _yearFor(String postId, String fallbackTimestamp) {
    if (postId.length >= 4 &&
        int.tryParse(postId.substring(0, 4)) != null) {
      return postId.substring(0, 4);
    }
    if (fallbackTimestamp.length >= 4 &&
        int.tryParse(fallbackTimestamp.substring(0, 4)) != null) {
      return fallbackTimestamp.substring(0, 4);
    }
    return '0000';
  }

  static String _postFolder(String postId, String fallbackTimestamp) =>
      '${_yearFor(postId, fallbackTimestamp)}/$postId';

  // ── Reads ─────────────────────────────────────────────────────────

  static Future<bool> hasPost(
      String authorCallsign, String postId, String timestamp) async {
    try {
      return await _storageFor(authorCallsign)
          .exists('${_postFolder(postId, timestamp)}/post.md');
    } catch (_) {
      return false;
    }
  }

  static Future<Uint8List?> readFile({
    required String authorCallsign,
    required String postId,
    required String timestamp,
    required String relativePath,
  }) async {
    if (_isUnsafePath(relativePath)) return null;
    try {
      return await _storageFor(authorCallsign)
          .readBytes('${_postFolder(postId, timestamp)}/$relativePath');
    } catch (_) {
      return null;
    }
  }

  // ── Writes ────────────────────────────────────────────────────────

  /// Persist post.md. The blog detail JSON returned by
  /// /api/content/blog/{id} carries a fully-rendered `content`
  /// field; this helper writes it in the canonical post.md layout
  /// the local BlogService produces.
  static Future<void> writePost({
    required String authorCallsign,
    required Map<String, dynamic> detailJson,
  }) async {
    final id = (detailJson['id'] as String?) ?? '';
    if (id.isEmpty) return;
    final timestamp = (detailJson['timestamp'] as String?) ?? '';
    try {
      final body = StringBuffer();
      // Header lines mirror BlogPost.exportAsText shape so a future
      // local read parses cleanly.
      body.writeln('# BLOG POST: ${detailJson['title'] ?? ''}');
      body.writeln('AUTHOR: ${detailJson['author'] ?? ''}');
      if (timestamp.isNotEmpty) body.writeln('CREATED: $timestamp');
      final edited = detailJson['edited'] as String?;
      if (edited != null && edited.isNotEmpty) {
        body.writeln('EDITED: $edited');
      }
      final status = detailJson['status'];
      if (status is String && status.isNotEmpty) {
        body.writeln('STATUS: $status');
      }
      final desc = detailJson['description'] as String?;
      if (desc != null && desc.isNotEmpty) {
        body.writeln('DESCRIPTION: $desc');
      }
      final loc = detailJson['location'] as String?;
      if (loc != null && loc.isNotEmpty) body.writeln('LOCATION: $loc');
      final tags = detailJson['tags'];
      if (tags is List && tags.isNotEmpty) {
        body.writeln('TAGS: ${tags.join(', ')}');
      }
      final npub = detailJson['npub'] as String?;
      if (npub != null && npub.isNotEmpty) body.writeln('--> npub: $npub');
      final sig = detailJson['signature'] as String?;
      if (sig != null && sig.isNotEmpty) body.writeln('--> signature: $sig');
      body.writeln();
      body.write((detailJson['content'] as String?) ?? '');
      await _storageFor(authorCallsign).writeString(
        '${_postFolder(id, timestamp)}/post.md',
        body.toString(),
      );
    } catch (e) {
      LogService().log(
          'RemoteBlogCache.writePost($authorCallsign/$id) failed: $e');
    }
  }

  static Future<void> writeFile({
    required String authorCallsign,
    required String postId,
    required String timestamp,
    required String relativePath,
    required List<int> bytes,
  }) async {
    if (_isUnsafePath(relativePath)) return;
    try {
      await _storageFor(authorCallsign).writeBytes(
        '${_postFolder(postId, timestamp)}/$relativePath',
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      );
    } catch (e) {
      LogService().log(
          'RemoteBlogCache.writeFile($authorCallsign/$postId/$relativePath) failed: $e');
    }
  }

  /// Persist a feedback npub list (likes / points / dislikes /
  /// subscribe). Same on-disk format the local FeedbackFolderUtils
  /// uses.
  static Future<void> writeFeedbackList({
    required String authorCallsign,
    required String postId,
    required String timestamp,
    required String filename, // e.g. 'likes.txt'
    required Iterable<String> npubs,
  }) async {
    try {
      final cleaned = npubs
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      await _storageFor(authorCallsign).writeString(
        '${_postFolder(postId, timestamp)}/feedback/$filename',
        cleaned.isEmpty ? '' : '${cleaned.join('\n')}\n',
      );
    } catch (e) {
      LogService().log(
          'RemoteBlogCache.writeFeedbackList($authorCallsign/$postId/$filename) failed: $e');
    }
  }

  /// Persist comments under feedback/comments/{id}.txt using the
  /// FeedbackCommentUtils format. Items shape:
  /// `[{id, author, timestamp, content, npub?, signature?}, …]`.
  static Future<void> writeComments({
    required String authorCallsign,
    required String postId,
    required String timestamp,
    required List<Map<String, dynamic>> comments,
  }) async {
    if (comments.isEmpty) return;
    try {
      final storage = _storageFor(authorCallsign);
      for (final c in comments) {
        final id = (c['id'] as String?)?.trim();
        if (id == null || id.isEmpty || _isUnsafePath(id)) continue;
        final author = (c['author'] as String?) ?? '';
        final ts = (c['timestamp'] as String?) ?? '';
        final content = (c['content'] as String?) ?? '';
        final npub = c['npub'] as String?;
        final signature = c['signature'] as String?;
        final body = StringBuffer()
          ..writeln('AUTHOR: $author')
          ..writeln('CREATED: $ts')
          ..writeln()
          ..writeln(content);
        if (npub != null && npub.isNotEmpty) {
          body
            ..writeln()
            ..writeln('--> npub: $npub');
        }
        if (signature != null && signature.isNotEmpty) {
          body.writeln('--> signature: $signature');
        }
        await storage.writeString(
          '${_postFolder(postId, timestamp)}/feedback/comments/$id.txt',
          body.toString(),
        );
      }
    } catch (e) {
      LogService().log(
          'RemoteBlogCache.writeComments($authorCallsign/$postId) failed: $e');
    }
  }

  static bool _isUnsafePath(String relativePath) {
    if (relativePath.isEmpty) return true;
    if (relativePath.startsWith('/') || relativePath.startsWith('\\')) {
      return true;
    }
    for (final segment in relativePath.split(RegExp(r'[\\/]'))) {
      if (segment == '..' || segment.isEmpty) return true;
    }
    return false;
  }
}
