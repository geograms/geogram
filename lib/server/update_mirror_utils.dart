/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared update mirror utilities used by both station implementations.
 */

import 'dart:convert';
import 'package:http/http.dart' as http;

/// Result of polling GitHub for releases.
class PollResult {
  final Map<String, dynamic>? stableRelease;
  final Map<String, dynamic>? betaRelease;
  final Map<String, dynamic>? stableGitHub; // Raw GitHub JSON for downloading
  final Map<String, dynamic>? betaGitHub;   // Raw GitHub JSON for downloading

  PollResult({this.stableRelease, this.betaRelease, this.stableGitHub, this.betaGitHub});
}

/// Shared utilities for the update mirror system.
/// Used by both StationServer (station.dart) and PureStationServer (pure_station.dart).
class UpdateMirrorUtils {

  /// Fetch releases from GitHub and return both stable and beta.
  /// [repoApiBase] should be like: https://api.github.com/repos/geograms/geogram
  static Future<PollResult> fetchReleases(String mirrorUrl, {
    required void Function(String level, String message) log,
  }) async {
    // Derive releases list URL from the configured mirror URL
    final releasesUrl = mirrorUrl.replaceAll('/releases/latest', '/releases?per_page=5');
    log('INFO', 'Checking for updates from: $releasesUrl');

    final response = await http.get(
      Uri.parse(releasesUrl),
      headers: {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'Geogram-Station-Updater',
      },
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      log('ERROR', 'GitHub API error: ${response.statusCode}');
      return PollResult();
    }

    final releases = jsonDecode(response.body) as List<dynamic>;
    if (releases.isEmpty) {
      log('INFO', 'No releases found on GitHub');
      return PollResult();
    }

    // Find latest stable (first non-prerelease) and latest beta (first prerelease)
    Map<String, dynamic>? latestStable;
    Map<String, dynamic>? latestBeta;

    for (final release in releases) {
      final r = release as Map<String, dynamic>;
      final isPrerelease = r['prerelease'] as bool? ?? false;
      if (!isPrerelease && latestStable == null) latestStable = r;
      if (isPrerelease && latestBeta == null) latestBeta = r;
      if (latestStable != null && latestBeta != null) break;
    }

    return PollResult(
      stableRelease: latestStable != null ? _buildCacheEntry(latestStable, false) : null,
      betaRelease: latestBeta != null ? _buildCacheEntry(latestBeta, true) : null,
      stableGitHub: latestStable,
      betaGitHub: latestBeta,
    );
  }

  /// Build a cache entry from a GitHub release JSON.
  static Map<String, dynamic> _buildCacheEntry(Map<String, dynamic> ghRelease, bool isPrerelease) {
    final tagName = ghRelease['tag_name'] as String? ?? '';
    final version = tagName.replaceFirst(RegExp(r'^v'), '');

    // Build GitHub download URLs from assets
    final assets = <String, String>{};
    for (final asset in (ghRelease['assets'] as List? ?? [])) {
      final name = asset['name'] as String? ?? '';
      final url = asset['browser_download_url'] as String? ?? '';
      if (name.isNotEmpty && url.isNotEmpty) assets[name] = url;
    }

    return {
      'status': 'available',
      'version': version,
      'tagName': tagName,
      'name': ghRelease['name'] as String?,
      'body': ghRelease['body'] as String?,
      'publishedAt': ghRelease['published_at'] as String?,
      'htmlUrl': ghRelease['html_url'] as String?,
      'isPrerelease': isPrerelease,
      'githubAssets': assets,
    };
  }

  /// Merge locally downloaded asset URLs into a cache entry.
  static void mergeLocalAssets(
    Map<String, dynamic> cacheEntry,
    Map<String, String> localAssetUrls,
    Map<String, String> localAssetFilenames,
  ) {
    cacheEntry['assets'] = localAssetUrls;
    cacheEntry['assetFilenames'] = localAssetFilenames;
  }

  /// Select the right release based on query parameters.
  /// Supports both `?channel=beta` and `?prerelease=true` for backward compat.
  static Map<String, dynamic>? selectRelease({
    required Map<String, String> queryParams,
    Map<String, dynamic>? stableRelease,
    Map<String, dynamic>? betaRelease,
  }) {
    final wantsBeta = queryParams['channel'] == 'beta' ||
        queryParams['prerelease'] == 'true';
    if (wantsBeta && betaRelease != null) {
      return betaRelease;
    }
    return stableRelease;
  }

  /// Compare semantic versions. Returns true if [a] is newer than [b].
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
}
