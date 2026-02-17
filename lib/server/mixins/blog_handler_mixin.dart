// Blog handling mixin for station servers
// Provides shared blog URL detection, request handling, and callsign resolution
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:markdown/markdown.dart' as md;

import '../../models/blog_post.dart';
import '../../services/nip05_registry_service.dart';
import '../../util/nostr_key_generator.dart';
import '../../util/station_html_templates.dart';

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
      // First, try to find a connected WebSocket client with this nickname/callsign
      final client = blogFindConnectedClientByIdentifier(identifier);

      if (client != null) {
        blogLog('INFO',
            'Proxying blog request to connected client: ${client.callsign} (${client.nickname ?? "no nickname"})');
        final handled = await blogProxyToClient(client, request, filename);
        if (handled) return;
        // If proxy failed, fall through to local search
      }

      // Fallback: Try to find the blog locally on the station server
      final callsign = await findCallsignByIdentifier(identifier);
      if (callsign == null) {
        request.response.statusCode = 404;
        request.response.write('User not found (not connected and no local data)');
        return;
      }

      // Extract year from filename (format: YYYY-MM-DD_title)
      final yearMatch = RegExp(r'^(\d{4})-').firstMatch(filename);
      if (yearMatch == null) {
        request.response.statusCode = 400;
        request.response.write('Invalid blog filename format');
        return;
      }
      final year = yearMatch.group(1)!;

      // Build path to the blog markdown file
      final blogDir = Directory('$blogDevicesDir/$callsign');

      // Find blog post in any collection
      BlogPost? foundPost;

      if (await blogDir.exists()) {
        await for (final entity in blogDir.list()) {
          if (entity is Directory) {
            // Check if this is a blog collection by looking for app.js
            final appFile = File('${entity.path}/app.js');
            if (await appFile.exists()) {
              try {
                final appJson = await appFile.readAsString();
                final appData = jsonDecode(appJson) as Map<String, dynamic>;
                if (appData['type'] != 'blog') continue;
              } catch (_) {
                continue;
              }
            }

            // Blog structure: {collection}/{year}/{postId}/post.md
            final blogPath = '${entity.path}/$year/$filename/post.md';
            final blogFile = File(blogPath);
            if (await blogFile.exists()) {
              try {
                final content = await blogFile.readAsString();
                foundPost = BlogPost.fromText(content, filename);
                break;
              } catch (e) {
                blogLog('ERROR', 'Error parsing blog file: $e');
              }
            }
          }
        }
      }

      if (foundPost == null) {
        request.response.statusCode = 404;
        request.response.write('Blog post not found');
        return;
      }

      // Only serve published posts
      if (foundPost.isDraft) {
        request.response.statusCode = 403;
        request.response.write('This post is not published');
        return;
      }

      // Convert markdown content to HTML
      final htmlContent = md.markdownToHtml(
        foundPost.content,
        extensionSet: md.ExtensionSet.gitHubWeb,
      );

      // Build full HTML page
      final html = StationHtmlTemplates.buildBlogPostPage(
        postTitle: foundPost.title,
        postDate: foundPost.displayDate,
        author: identifier,
        htmlContent: htmlContent,
        description: foundPost.description,
        tags: foundPost.tags,
        globalStyles: StationHtmlTemplates.getBaseStyles(),
        appStyles: '',
      );

      request.response.headers.contentType = ContentType.html;
      request.response.write(html);
    } catch (e) {
      blogLog('ERROR', 'Error serving blog post: $e');
      request.response.statusCode = 500;
      request.response.write('Internal server error');
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
}
