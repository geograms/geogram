/*
 * Collection sync manager for AT Protocol.
 *
 * Orchestrates syncing Geogram content into AT Proto repo collections.
 * Each content type is handled by a CollectionAdapter that maps
 * Geogram models to/from AT Proto records.
 *
 * Sync is idempotent — existing records (matched by rkey) are skipped.
 */

import 'collections/collection_adapter.dart';
import 'firehose.dart';
import 'repo.dart';

/// Manages syncing Geogram content collections into the AT Proto repository.
class CollectionSyncManager {
  final AtprotoRepo repo;
  final FirehoseManager? firehose;
  final void Function(String level, String message) log;
  final List<CollectionAdapter> _adapters = [];

  CollectionSyncManager({
    required this.repo,
    this.firehose,
    required this.log,
  });

  /// Register a collection adapter.
  void register(CollectionAdapter adapter) {
    _adapters.add(adapter);
  }

  /// Get all registered adapters.
  List<CollectionAdapter> get adapters => List.unmodifiable(_adapters);

  /// Sync all registered collections.
  ///
  /// Returns a map of NSID -> number of records created.
  Future<Map<String, int>> syncAll() async {
    final results = <String, int>{};
    var totalCreated = 0;

    for (final adapter in _adapters) {
      try {
        final created = await adapter.syncAll(repo);
        results[adapter.nsid] = created;
        totalCreated += created;

        if (created > 0) {
          log('INFO', 'AT Proto sync: ${adapter.displayName} — $created new records');
        }
      } catch (e) {
        log('ERROR', 'AT Proto sync: ${adapter.displayName} failed — $e');
        results[adapter.nsid] = -1; // Error marker
      }
    }

    // Commit all changes in a single commit if any records were created
    if (totalCreated > 0) {
      final commitCid = repo.commit();
      log('INFO', 'AT Proto sync: committed $totalCreated new records (${commitCid.toBase32()})');

      // Emit firehose event for the sync commit
      if (firehose != null) {
        firehose!.emitInfo('CollectionSync', '$totalCreated records synced');
      }
    }

    return results;
  }

  /// Sync a single collection by NSID.
  ///
  /// Returns the number of records created, or -1 on error.
  Future<int> syncCollection(String nsid) async {
    final adapter = _adapters.where((a) => a.nsid == nsid).firstOrNull;
    if (adapter == null) return -1;

    try {
      final created = await adapter.syncAll(repo);

      if (created > 0) {
        repo.commit();
        log('INFO', 'AT Proto sync: ${adapter.displayName} — $created new records');
      }

      return created;
    } catch (e) {
      log('ERROR', 'AT Proto sync: ${adapter.displayName} failed — $e');
      return -1;
    }
  }

  /// Get status info for all registered collections.
  List<Map<String, dynamic>> getCollectionStatus() {
    return _adapters.map((adapter) {
      final records = repo.listRecords(adapter.nsid);
      return {
        'nsid': adapter.nsid,
        'displayName': adapter.displayName,
        'recordCount': records.length,
      };
    }).toList();
  }
}
