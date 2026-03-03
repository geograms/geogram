/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared Apps Discovery handler for station servers.
 * Returns aggregated app availability and item counts in a single response.
 * Used by both PureStationServer (CLI) and LogApiService (Desktop).
 */

import '../../services/profile_storage.dart';

/// Shared Apps Discovery handler for station servers
class AppsHandler {
  final ProfileStorage storage;
  final void Function(String level, String message)? log;

  AppsHandler({
    required this.storage,
    this.log,
  });

  void _log(String level, String message) {
    log?.call(level, message);
  }

  /// GET /api/apps — returns all app availability + item counts
  Future<Map<String, dynamic>> getApps() async {
    try {
      final apps = <String, Map<String, dynamic>>{};

      // Count blog posts (scan for .json files, exclude tree.json and other non-post files)
      apps['blog'] = await _countBlog();

      // Count chat rooms (scan for subdirectories)
      apps['chat'] = await _countChat();

      // Count events (scan events dir)
      apps['events'] = await _countEvents();

      // Count alerts (scan alerts dir)
      apps['alerts'] = await _countAlerts();

      // Count shared folders (scan shared entries)
      apps['shared'] = await _countShared();

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'apps': apps,
      };
    } catch (e) {
      _log('ERROR', 'Error in apps discovery API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> _countBlog() async {
    try {
      final entries = await storage.listDirectory('blog');
      // Count .json files, exclude known non-post files
      const skipFiles = {'tree.json', 'app.js', 'data.js'};
      int count = 0;
      for (final entry in entries) {
        if (!entry.isDirectory &&
            entry.name.endsWith('.json') &&
            !entry.name.startsWith('.') &&
            !skipFiles.contains(entry.name)) {
          count++;
        }
      }
      return {'available': count > 0, 'count': count};
    } catch (e) {
      _log('DEBUG', 'Blog scan: $e');
      return {'available': false, 'count': 0};
    }
  }

  Future<Map<String, dynamic>> _countChat() async {
    try {
      final entries = await storage.listDirectory('chat');
      int count = 0;
      for (final entry in entries) {
        if (entry.isDirectory) {
          count++;
        }
      }
      return {'available': count > 0, 'count': count};
    } catch (e) {
      _log('DEBUG', 'Chat scan: $e');
      return {'available': false, 'count': 0};
    }
  }

  Future<Map<String, dynamic>> _countEvents() async {
    try {
      final entries = await storage.listDirectory('events');
      int count = 0;
      for (final entry in entries) {
        if (entry.isDirectory) {
          count++;
        }
      }
      return {'available': count > 0, 'count': count};
    } catch (e) {
      _log('DEBUG', 'Events scan: $e');
      return {'available': false, 'count': 0};
    }
  }

  Future<Map<String, dynamic>> _countAlerts() async {
    try {
      final entries = await storage.listDirectory('alerts');
      int count = 0;
      for (final entry in entries) {
        // Alert entries are directories named by callsign, each containing alert subdirs
        if (entry.isDirectory) {
          try {
            final alertEntries = await storage.listDirectory('alerts/${entry.name}');
            for (final alertEntry in alertEntries) {
              if (alertEntry.isDirectory) {
                count++;
              }
            }
          } catch (_) {
            // Skip inaccessible subdirs
          }
        }
      }
      return {'available': count > 0, 'count': count};
    } catch (e) {
      _log('DEBUG', 'Alerts scan: $e');
      return {'available': false, 'count': 0};
    }
  }

  Future<Map<String, dynamic>> _countShared() async {
    try {
      final entries = await storage.listDirectory('shared');
      const skipFiles = {'tree.json', 'app.js', 'data.js'};
      int count = 0;
      for (final entry in entries) {
        if (!entry.isDirectory &&
            entry.name.endsWith('.json') &&
            !entry.name.startsWith('.') &&
            !skipFiles.contains(entry.name)) {
          count++;
        }
      }
      return {'available': count > 0, 'count': count};
    } catch (e) {
      _log('DEBUG', 'Shared scan: $e');
      return {'available': false, 'count': 0};
    }
  }
}
