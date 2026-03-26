/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared update mirror utilities used by both station implementations.
 */

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Shared utilities for the update mirror system.
/// Used by both StationServer (station.dart) and PureStationServer (pure_station.dart).
class UpdateMirrorUtils {
  /// Fetch the latest beta (pre-release) from GitHub and return cached release info
  /// if it's newer than the current stable version. Returns null if no beta found
  /// or beta is older than stable.
  static Future<Map<String, dynamic>?> pollBetaRelease({
    required String mirrorUrl,
    required String stableVersion,
    Future<int> Function(Map<String, dynamic> release)? downloadAssets,
    required Map<String, String> Function() buildAssetUrls,
    required Map<String, String> Function() buildAssetFilenames,
    required void Function(String level, String message) log,
  }) async {
    try {
      final listUrl = mirrorUrl.replaceAll('/releases/latest', '/releases?per_page=5');
      final response = await http.get(
        Uri.parse(listUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'Geogram-Station-Updater',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) return null;

      final releases = jsonDecode(response.body) as List;
      final beta = releases.cast<Map<String, dynamic>>().where(
        (r) => r['prerelease'] == true,
      ).firstOrNull;

      if (beta == null) return null;

      final betaTag = beta['tag_name'] as String? ?? '';
      final betaVersion = betaTag.replaceFirst(RegExp(r'^v'), '');

      if (!isNewerVersion(betaVersion, stableVersion)) return null;

      log('INFO', 'Beta release found: $betaVersion (stable: $stableVersion)');
      if (downloadAssets != null) {
        await downloadAssets(beta);
      }

      // Build GitHub download URLs from the release assets
      final githubAssets = <String, String>{};
      for (final asset in (beta['assets'] as List? ?? [])) {
        final name = asset['name'] as String? ?? '';
        final url = asset['browser_download_url'] as String? ?? '';
        if (name.isNotEmpty && url.isNotEmpty) {
          githubAssets[name] = url;
        }
      }

      return {
        'status': 'available',
        'version': betaVersion,
        'tagName': betaTag,
        'name': beta['name'] as String?,
        'body': beta['body'] as String?,
        'publishedAt': beta['published_at'] as String?,
        'htmlUrl': beta['html_url'] as String?,
        'prerelease': true,
        'assets': downloadAssets != null ? buildAssetUrls() : githubAssets,
        'assetFilenames': downloadAssets != null ? buildAssetFilenames() : <String, String>{},
      };
    } catch (e) {
      log('ERROR', 'Error checking beta releases: $e');
      return null;
    }
  }

  /// Compare semantic versions. Returns true if [a] is newer than [b].
  /// Pre-release suffixes are ignored for base comparison.
  /// Same base version: stable wins (returns false).
  static bool isNewerVersion(String a, String b) {
    final aBase = a.split('-')[0].split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final bBase = b.split('-')[0].split('.').map((s) => int.tryParse(s) ?? 0).toList();
    while (aBase.length < 3) aBase.add(0);
    while (bBase.length < 3) bBase.add(0);
    for (int i = 0; i < 3; i++) {
      if (aBase[i] > bBase[i]) return true;
      if (aBase[i] < bBase[i]) return false;
    }
    return false;
  }

  /// Select the right release to serve based on channel parameter.
  /// Returns beta if channel is 'beta' and beta exists, otherwise stable.
  static Map<String, dynamic>? selectRelease({
    required String channel,
    Map<String, dynamic>? stableRelease,
    Map<String, dynamic>? betaRelease,
  }) {
    if (channel == 'beta' && betaRelease != null) {
      return betaRelease;
    }
    return stableRelease;
  }
}
