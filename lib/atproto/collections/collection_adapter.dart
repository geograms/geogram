/*
 * Base interface for AT Protocol collection adapters.
 *
 * Each adapter maps a Geogram content type to/from AT Proto records
 * within a specific NSID collection.
 */

import '../repo.dart';
import '../tid.dart';

/// Base class for collection adapters that map Geogram content to AT Proto records.
abstract class CollectionAdapter {
  /// The AT Protocol NSID for this collection (e.g. 'radio.geogram.blog.post').
  String get nsid;

  /// Human-readable name for logging.
  String get displayName;

  /// Sync all existing content into the AT Proto repo.
  ///
  /// Idempotent — skips records whose rkey already exists.
  /// Returns the number of records created.
  Future<int> syncAll(AtprotoRepo repo);

  /// Helper: create a record if it doesn't already exist.
  ///
  /// Returns true if created, false if already existed.
  bool createIfAbsent(
    AtprotoRepo repo,
    String rkey,
    Map<String, dynamic> record,
  ) {
    final existing = repo.getRecord(nsid, rkey);
    if (existing != null) return false;
    repo.createRecord(nsid, record, rkey: rkey);
    return true;
  }

  /// Generate a TID rkey from a Geogram timestamp string.
  ///
  /// Geogram timestamps use format "YYYY-MM-DD HH:MM_ss".
  static String rkeyFromTimestamp(String timestamp) {
    try {
      final normalized = timestamp.replaceAll('_', ':');
      final dt = DateTime.parse(normalized);
      return Tid.fromDateTime(dt);
    } catch (_) {
      return Tid.next();
    }
  }
}
