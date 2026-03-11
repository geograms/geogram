/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import '../../models/station_activity_event.dart';
import '../../services/station_activity_store.dart';
import '../../services/station_group_access_service.dart';

/// Shared station activity API logic used by both station server implementations.
class ActivityHandler {
  final StationActivityStore store;
  final StationGroupAccessService? groupAccess;
  final void Function(String level, String message)? log;

  ActivityHandler({required this.store, this.groupAccess, this.log});

  Future<Map<String, dynamic>> postActivity(StationActivityEvent event) async {
    try {
      final result = await store.insertEvent(
        event.copyWith(clearIndex: true, clearReceivedAt: true),
      );

      return {
        'success': true,
        'inserted': result.inserted,
        'activity': result.event.toJson(),
      };
    } catch (e) {
      _log('ERROR', 'Activity insert failed: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  Future<Map<String, dynamic>> getFeed({
    String? requesterNpub,
    int? sinceIndex,
    int limit = 50,
    List<String>? appTypes,
  }) async {
    try {
      final normalizedRequester = requesterNpub?.trim();
      final normalizedLimit = limit.clamp(1, 200);
      final fetchLimit =
          normalizedRequester == null || normalizedRequester.isEmpty
          ? normalizedLimit
          : (normalizedLimit * 5).clamp(normalizedLimit, 1000);

      final candidates = await store.listEvents(
        sinceIndex: sinceIndex,
        limit: fetchLimit,
        appTypes: appTypes,
        publicOnly: normalizedRequester == null || normalizedRequester.isEmpty,
      );

      final activities = <StationActivityEvent>[];
      for (final candidate in candidates) {
        if (candidate.isPublic) {
          activities.add(candidate);
        } else if (normalizedRequester != null &&
            normalizedRequester.isNotEmpty) {
          final hasGroupAccess =
              candidate.allowedGroups.isNotEmpty &&
              await groupAccess?.hasAnyMatchingGroup(
                    normalizedRequester,
                    candidate.allowedGroups,
                  ) ==
                  true;
          if (candidate.isVisibleTo(
            normalizedRequester,
            hasAllowedGroup: hasGroupAccess,
          )) {
            activities.add(candidate);
          }
        }

        if (activities.length >= normalizedLimit) {
          break;
        }
      }

      return {
        'success': true,
        'authenticated':
            normalizedRequester != null && normalizedRequester.isNotEmpty,
        'requester_npub': normalizedRequester,
        'since_index': sinceIndex,
        'limit': normalizedLimit,
        'count': activities.length,
        'latest_index': await store.latestIndex(),
        'activities': activities.map((event) => event.toJson()).toList(),
      };
    } catch (e) {
      _log('ERROR', 'Activity feed query failed: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  void _log(String level, String message) {
    log?.call(level, message);
  }
}
