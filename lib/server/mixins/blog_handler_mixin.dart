// Blog handling mixin for station servers
// Provides shared blog URL detection, request handling, and callsign resolution
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:markdown/markdown.dart' as md;

import '../../models/blog_post.dart';
import '../../services/nip05_registry_service.dart';
import '../../services/profile_storage.dart';
import '../../util/app_js_utils.dart';
import '../../util/feedback_folder_utils.dart';
import '../../util/nostr_crypto.dart';
import '../../util/nostr_key_generator.dart';
import '../../util/station_html_templates.dart';

/// Lightweight blog post summary for the station homepage feed.
class RecentBlogEntry {
  final String callsign;
  final String postId;
  final String title;
  final String author;
  final String? description;
  final String displayDate;
  final DateTime dateTime;
  final int likesCount;

  RecentBlogEntry({
    required this.callsign,
    required this.postId,
    required this.title,
    required this.author,
    this.description,
    required this.displayDate,
    required this.dateTime,
    this.likesCount = 0,
  });
}

/// Connected client interface needed by the blog handler.
/// Both PureConnectedClient implementations satisfy this.
abstract class BlogClient {
  String? get callsign;
  String? get nickname;
}

/// Mixin providing blog handling methods shared across station implementations.
///
/// Handles pretty blog URLs like /{identifier}/blog/{filename}.html,
/// resolving nicknames to callsigns (including via NIP-05 registry),
/// proxying to connected clients, and serving local blog files.
mixin BlogHandlerMixin {
  // Abstract dependencies to be provided by the using class
  void blogLog(String level, String message);

  /// The devices directory path (e.g., PureStorageConfig().devicesDir)
  String get blogDevicesDir;

  /// The config.json path (e.g., PureStorageConfig().configPath)
  String get blogConfigPath;

  /// Find a connected WebSocket client by nickname or callsign.
  BlogClient? blogFindConnectedClientByIdentifier(String identifier);

  /// Find ALL connected WebSocket clients by nickname or callsign (multi-device).
  List<BlogClient> blogFindAllClientsByIdentifier(String identifier);

  /// Proxy a blog request to a connected client. Returns true if handled.
  Future<bool> blogProxyToClient(
      BlogClient client, HttpRequest request, String filename);

  // ── Shared blog methods ──────────────────────────────────────────

  /// Check if path is a blog URL (/{identifier}/blog/{filename}.html)
  bool isBlogPath(String path) {
    final regex = RegExp(r'^/([^/]+)/blog/([^/]+)\.html$');
    return regex.hasMatch(path);
  }

  /// Handle blog post request - serves markdown as HTML
  Future<void> handleBlogRequest(HttpRequest request) async {
    final path = request.uri.path;
    final regex = RegExp(r'^/([^/]+)/blog/([^/]+)\.html$');
    final match = regex.firstMatch(path);

    if (match == null) {
      request.response.statusCode = 400;
      request.response.write('Invalid blog URL');
      return;
    }

    final identifier = match.group(1)!; // nickname or callsign
    final filename = match.group(2)!; // blog filename without .html

    try {
      // Try all connected WebSocket clients with this nickname/callsign (multi-device)
      final clients = blogFindAllClientsByIdentifier(identifier);

      for (final client in clients) {
        blogLog('INFO',
            'Proxying blog request to connected client: ${client.callsign} (${client.nickname ?? "no nickname"})');
        final handled = await blogProxyToClient(client, request, filename);
        if (handled) return;
        // If proxy failed for this device, try next one
      }

      // Fallback: Try to find the blog locally on the station server
      final callsign = await findCallsignByIdentifier(identifier);
      if (callsign == null) {
        request.response.statusCode = 404;
        request.response.write('User not found (not connected and no local data)');
        return;
      }

      await serveBlogFromDisk(
        request: request,
        devicesDir: blogDevicesDir,
        callsign: callsign,
        filename: filename,
        identifier: identifier,
        log: blogLog,
      );
    } catch (e) {
      blogLog('ERROR', 'Error serving blog post: $e');
      request.response.statusCode = 500;
      request.response.write('Internal server error');
    }
  }

  /// Route shortcut used by both station implementations.
  ///
  /// Matches `/{identifier}/blog/{slug}.html`. When the identifier equals
  /// [selfCallsign] (case-insensitive), serves the post from local disk
  /// via [serveBlogFromDisk] and returns true. Returns false for any
  /// non-matching URL or non-self identifier — callers fall back to
  /// their normal proxy / 404 path.
  ///
  /// This exists because handleGenericDeviceProxy looks the identifier up
  /// in its live proxy-client registry and the station is never its own
  /// client, so `/{selfCallsign}/blog/*.html` otherwise 404s with
  /// "Device not connected" even though the post is right there on disk.
  static Future<bool> tryServeOwnBlogPost({
    required HttpRequest request,
    required String selfCallsign,
    required String devicesDir,
    required void Function(String level, String message) log,
  }) async {
    if (selfCallsign.isEmpty) return false;
    final match = RegExp(r'^/([^/]+)/blog/([^/]+)\.html$')
        .firstMatch(request.uri.path);
    if (match == null) return false;
    final identifier = match.group(1)!;
    final filename = match.group(2)!;
    if (identifier.toLowerCase() != selfCallsign.toLowerCase()) return false;

    await serveBlogFromDisk(
      request: request,
      devicesDir: devicesDir,
      callsign: selfCallsign,
      filename: filename,
      identifier: identifier,
      log: log,
    );
    return true;
  }

  /// Serve a single blog post from the station's local disk.
  ///
  /// Reads `{devicesDir}/{callsign}/{collection}/{year}/{filename}/post.md`
  /// (scanning every collection folder whose app.js declares type=="blog"),
  /// renders the markdown to HTML, and writes the full blog-post page
  /// (using StationHtmlTemplates) to the response.
  ///
  /// Returns the HTTP status code that was written so callers can log /
  /// chain on it. All I/O and templating errors are caught and turned into
  /// 5xx responses.
  ///
  /// Exposed as a static helper so station implementations that do not use
  /// [BlogHandlerMixin] (currently PureStationServer) can still fall back
  /// to local-disk serving for requests targeting their own callsign.
  static Future<int> serveBlogFromDisk({
    required HttpRequest request,
    required String devicesDir,
    required String callsign,
    required String filename,
    required String identifier,
    required void Function(String level, String message) log,
  }) async {
    try {
      // Extract year from filename (format: YYYY-MM-DD_title)
      final yearMatch = RegExp(r'^(\d{4})-').firstMatch(filename);
      if (yearMatch == null) {
        request.response.statusCode = 400;
        request.response.write('Invalid blog filename format');
        return 400;
      }
      final year = yearMatch.group(1)!;

      final blogDir = Directory('$devicesDir/$callsign');

      BlogPost? foundPost;
      String? appFolderName;

      if (await blogDir.exists()) {
        await for (final entity in blogDir.list()) {
          if (entity is Directory) {
            // Check if this is a blog collection by looking for app.js
            final appFile = File('${entity.path}/app.js');
            if (await appFile.exists()) {
              final appContent = await appFile.readAsString();
              final appData = AppJsUtils.parseAppJsContent(appContent);
              if (appData == null) continue;
              // app.js has nested structure: {"app": {"type": "blog"}}
              final appInfo = appData['app'] as Map<String, dynamic>?;
              final type = appInfo?['type'] ?? appData['type'];
              if (type != 'blog') continue;
            }

            // Blog structure: {collection}/{year}/{postId}/post.md
            final blogPath = '${entity.path}/$year/$filename/post.md';
            final blogFile = File(blogPath);
            if (await blogFile.exists()) {
              try {
                final content = await blogFile.readAsString();
                foundPost = BlogPost.fromText(content, filename);
                appFolderName = entity.path.split('/').last;
                break;
              } catch (e) {
                log('ERROR', 'Error parsing blog file: $e');
              }
            }
          }
        }
      }

      if (foundPost == null) {
        request.response.statusCode = 404;
        request.response.write('Blog post not found');
        return 404;
      }

      if (foundPost.isDraft) {
        request.response.statusCode = 403;
        request.response.write('This post is not published');
        return 403;
      }

      // Load feedback counts
      final blogPath = '$devicesDir/$callsign/$appFolderName/$year/$filename';
      final blogFeedbackStorage = FilesystemProfileStorage('$devicesDir/$callsign');
      final feedbackCounts = await FeedbackFolderUtils.getAllFeedbackCounts(
        blogPath,
        storage: blogFeedbackStorage,
      );
      foundPost = foundPost.copyWith(
        likesCount: feedbackCounts[FeedbackFolderUtils.feedbackTypeLikes] ?? 0,
        dislikesCount: feedbackCounts[FeedbackFolderUtils.feedbackTypeDislikes] ?? 0,
        pointsCount: feedbackCounts[FeedbackFolderUtils.feedbackTypePoints] ?? 0,
      );

      // Read liked npubs and convert to hex pubkeys for client-side checking
      final likedNpubs = await FeedbackFolderUtils.readFeedbackFile(
        blogPath,
        FeedbackFolderUtils.feedbackTypeLikes,
        storage: blogFeedbackStorage,
      );
      final likedHexPubkeys = <String>[];
      for (final npub in likedNpubs) {
        try {
          likedHexPubkeys.add(NostrCrypto.decodeNpub(npub));
        } catch (_) {}
      }

      final htmlContent = md.markdownToHtml(
        foundPost.content,
        extensionSet: md.ExtensionSet.gitHubWeb,
      );

      final html = StationHtmlTemplates.buildBlogPostPage(
        postTitle: foundPost.title,
        postDate: foundPost.displayDate,
        postTime: foundPost.displayTime,
        author: foundPost.author.isNotEmpty ? foundPost.author : identifier,
        htmlContent: htmlContent,
        description: foundPost.description,
        tags: foundPost.tags,
        postId: foundPost.id,
        npub: foundPost.npub,
        likesCount: foundPost.likesCount,
        likedHexPubkeys: likedHexPubkeys,
        showSignedBadge: foundPost.isSigned,
        globalStyles: StationHtmlTemplates.getBaseStyles(),
        appStyles: '',
      );

      request.response.headers.contentType = ContentType.html;
      request.response.write(html);
      return 200;
    } catch (e) {
      log('ERROR', 'Error serving blog post from disk: $e');
      request.response.statusCode = 500;
      request.response.write('Internal server error');
      return 500;
    }
  }

  /// Find callsign by identifier (nickname or callsign).
  /// Checks: 1) directory names, 2) config.json profiles, 3) NIP-05 registry
  Future<String?> findCallsignByIdentifier(String identifier) async {
    final devicesDir = blogDevicesDir;
    final dir = Directory(devicesDir);

    if (!await dir.exists()) return null;

    // 1. Direct callsign match (case-insensitive)
    await for (final entity in dir.list()) {
      if (entity is Directory) {
        final callsign = entity.path.split('/').last;
        if (callsign.toLowerCase() == identifier.toLowerCase()) {
          return callsign;
        }
      }
    }

    // 2. Search for nickname in config.json profiles
    final configFile = File(blogConfigPath);
    if (await configFile.exists()) {
      try {
        final content = await configFile.readAsString();
        final config = jsonDecode(content) as Map<String, dynamic>;
        final profiles = config['profiles'] as List<dynamic>?;
        if (profiles != null) {
          for (final profile in profiles) {
            if (profile is Map<String, dynamic>) {
              final nickname = profile['nickname'] as String?;
              final callsign = profile['callsign'] as String?;
              if (nickname != null &&
                  callsign != null &&
                  nickname.toLowerCase() == identifier.toLowerCase()) {
                final callsignDir = Directory('$devicesDir/$callsign');
                if (await callsignDir.exists()) {
                  return callsign;
                }
              }
            }
          }
        }
      } catch (e) {
        blogLog('ERROR', 'Error reading config.json: $e');
      }
    }

    // 3. NIP-05 registry lookup (nickname → npub → callsign)
    // Don't require directory to exist — the callsign is still valid for
    // proxying to a connected client, and disk lookup will naturally 404.
    final registration = Nip05RegistryService().getRegistration(identifier);
    if (registration != null) {
      try {
        return NostrKeyGenerator.deriveCallsign(registration.npub);
      } catch (e) {
        blogLog('ERROR', 'Error deriving callsign from NIP-05 registry: $e');
      }
    }

    return null;
  }

  /// Scan all devices' blog directories for recent published posts.
  ///
  /// This is a static utility so it can be called without mixing in the full
  /// BlogHandlerMixin (which requires implementing abstract dependencies).
  static Future<List<RecentBlogEntry>> scanRecentBlogPosts(
    String devicesDir, {
    int limit = 10,
  }) async {
    final dir = Directory(devicesDir);
    if (!await dir.exists()) return [];

    final allPosts = <RecentBlogEntry>[];

    // Iterate over callsign directories
    await for (final callsignEntity in dir.list()) {
      if (callsignEntity is! Directory) continue;
      final callsign = callsignEntity.path.split('/').last;

      // Find blog collections inside this callsign directory
      try {
        await for (final collectionEntity in callsignEntity.list()) {
          if (collectionEntity is! Directory) continue;

          // Check if this is a blog collection via app.js
          final appFile = File('${collectionEntity.path}/app.js');
          if (await appFile.exists()) {
            final appContent = await appFile.readAsString();
            final appData = AppJsUtils.parseAppJsContent(appContent);
            if (appData == null) continue;
            final appInfo = appData['app'] as Map<String, dynamic>?;
            final type = appInfo?['type'] ?? appData['type'];
            if (type != 'blog') continue;
          }

          // Scan year directories inside this blog collection
          try {
            await for (final yearEntity in collectionEntity.list()) {
              if (yearEntity is! Directory) continue;
              final yearName = yearEntity.path.split('/').last;
              if (!RegExp(r'^\d{4}$').hasMatch(yearName)) continue;

              // Scan post directories inside this year
              try {
                await for (final postEntity in yearEntity.list()) {
                  if (postEntity is! Directory) continue;
                  final postId = postEntity.path.split('/').last;

                  final postFile = File('${postEntity.path}/post.md');
                  if (!await postFile.exists()) continue;

                  try {
                    final content = await postFile.readAsString();
                    final post = BlogPost.fromText(content, postId);
                    if (!post.isPublished) continue;

                    // Read likes count from per-callsign feedback storage
                    int likes = 0;
                    try {
                      final blogPath =
                          '${collectionEntity.path.split('/').last}/$yearName/$postId';
                      final feedbackStorage =
                          FilesystemProfileStorage(callsignEntity.path);
                      final counts = await FeedbackFolderUtils.getAllFeedbackCounts(
                        blogPath,
                        storage: feedbackStorage,
                      );
                      likes = counts[FeedbackFolderUtils.feedbackTypeLikes] ?? 0;
                    } catch (_) {}

                    allPosts.add(RecentBlogEntry(
                      callsign: callsign,
                      postId: postId,
                      title: post.title,
                      author: post.author.isNotEmpty ? post.author : callsign,
                      description: post.description,
                      displayDate: post.displayDate,
                      dateTime: post.dateTime,
                      likesCount: likes,
                    ));
                  } catch (_) {
                    // Skip malformed posts
                  }
                }
              } catch (_) {}
            }
          } catch (_) {}
        }
      } catch (_) {}
    }

    // Sort by date descending and return top entries
    allPosts.sort((a, b) => b.dateTime.compareTo(a.dateTime));
    return allPosts.length > limit ? allPosts.sublist(0, limit) : allPosts;
  }
}
