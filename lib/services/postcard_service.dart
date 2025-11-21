/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';
import '../models/postcard.dart';

/// Service for managing postcards (sneakernet message delivery)
class PostcardService {
  static final PostcardService _instance = PostcardService._internal();
  factory PostcardService() => _instance;
  PostcardService._internal();

  String? _collectionPath;

  /// Initialize postcard service for a collection
  Future<void> initializeCollection(String collectionPath) async {
    print('PostcardService: Initializing with collection path: $collectionPath');
    _collectionPath = collectionPath;

    // Ensure postcards directory exists
    final postcardsDir = Directory('$collectionPath/postcards');
    if (!await postcardsDir.exists()) {
      await postcardsDir.create(recursive: true);
      print('PostcardService: Created postcards directory');
    }
  }

  /// Get available years (folders in postcards directory)
  Future<List<int>> getYears() async {
    if (_collectionPath == null) return [];

    final postcardsDir = Directory('$_collectionPath/postcards');
    if (!await postcardsDir.exists()) return [];

    final years = <int>[];
    await for (var entity in postcardsDir.list()) {
      if (entity is Directory) {
        final name = entity.path.split('/').last;
        final year = int.tryParse(name);
        if (year != null) {
          years.add(year);
        }
      }
    }

    years.sort((a, b) => b.compareTo(a)); // Most recent first
    return years;
  }

  /// Load postcards for a specific year or all years
  Future<List<Postcard>> loadPostcards({
    int? year,
    String? filterByStatus,
  }) async {
    if (_collectionPath == null) return [];

    final postcards = <Postcard>[];
    final years = year != null ? [year] : await getYears();

    for (var y in years) {
      final yearDir = Directory('$_collectionPath/postcards/$y');
      if (!await yearDir.exists()) continue;

      await for (var entity in yearDir.list()) {
        if (entity is Directory) {
          try {
            final folderName = entity.path.split('/').last;
            // Postcard folders are like: YYYY-MM-DD_msg-{id}
            if (RegExp(r'^\d{4}-\d{2}-\d{2}_msg-').hasMatch(folderName)) {
              final postcard = await loadPostcard(folderName);
              if (postcard != null) {
                // Apply status filter if specified
                if (filterByStatus == null || postcard.status == filterByStatus) {
                  postcards.add(postcard);
                }
              }
            }
          } catch (e) {
            print('PostcardService: Error loading postcard ${entity.path}: $e');
          }
        }
      }
    }

    // Sort by created timestamp (most recent first)
    postcards.sort((a, b) => b.createdDateTime.compareTo(a.createdDateTime));

    return postcards;
  }

  /// Load full postcard with stamps, delivery receipt, and acknowledgment
  Future<Postcard?> loadPostcard(String postcardId) async {
    if (_collectionPath == null) return null;

    // Extract year from postcardId (format: YYYY-MM-DD_msg-{id})
    final year = postcardId.substring(0, 4);
    final postcardDir = Directory('$_collectionPath/postcards/$year/$postcardId');

    if (!await postcardDir.exists()) {
      print('PostcardService: Postcard directory not found: ${postcardDir.path}');
      return null;
    }

    // Load postcard.txt
    final postcardFile = File('${postcardDir.path}/postcard.txt');
    if (!await postcardFile.exists()) {
      print('PostcardService: postcard.txt not found in ${postcardDir.path}');
      return null;
    }

    try {
      final content = await postcardFile.readAsString();
      final postcard = Postcard.fromText(content, postcardId);

      return postcard;
    } catch (e) {
      print('PostcardService: Error loading postcard: $e');
      return null;
    }
  }

  /// Sanitize message ID to create valid folder name
  String sanitizeMessageId(String messageId) {
    // Convert to lowercase, replace spaces with hyphens
    String sanitized = messageId.toLowerCase().trim();

    // Replace spaces and underscores with hyphens
    sanitized = sanitized.replaceAll(RegExp(r'[\s_]+'), '-');

    // Remove non-alphanumeric characters except hyphens
    sanitized = sanitized.replaceAll(RegExp(r'[^a-z0-9-]'), '');

    // Remove multiple consecutive hyphens
    sanitized = sanitized.replaceAll(RegExp(r'-+'), '-');

    // Remove leading/trailing hyphens
    sanitized = sanitized.replaceAll(RegExp(r'^-+|-+$'), '');

    // Truncate to 30 characters
    if (sanitized.length > 30) {
      sanitized = sanitized.substring(0, 30);
    }

    return sanitized;
  }

  /// Check if folder name already exists, add suffix if needed
  Future<String> _ensureUniqueFolderName(String baseFolderName, int year) async {
    String folderName = baseFolderName;
    int suffix = 1;

    while (await Directory('$_collectionPath/postcards/$year/$folderName').exists()) {
      // Extract the base without the suffix
      final baseWithoutSuffix = baseFolderName.replaceAll(RegExp(r'-\d+$'), '');
      folderName = '$baseWithoutSuffix-$suffix';
      suffix++;
    }

    return folderName;
  }

  /// Format DateTime to timestamp string
  String _formatTimestamp(DateTime dt) {
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute\_$second';
  }

  /// Create new postcard
  Future<Postcard?> createPostcard({
    required String title,
    required String senderCallsign,
    required String senderNpub,
    String? recipientCallsign,
    required String recipientNpub,
    required List<RecipientLocation> recipientLocations,
    required String type, // "open" or "encrypted"
    required String content,
    int? ttl,
    String priority = 'normal',
    bool paymentRequested = false,
    String? messageId,
  }) async {
    if (_collectionPath == null) return null;

    try {
      final now = DateTime.now();
      final year = now.year;

      // Generate message ID if not provided
      final msgId = messageId ?? sanitizeMessageId(title);

      // Format folder name: YYYY-MM-DD_msg-{id}
      final dateStr = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final baseFolderName = '${dateStr}_msg-$msgId';
      final folderName = await _ensureUniqueFolderName(baseFolderName, year);

      // Ensure year directory exists
      final yearDir = Directory('$_collectionPath/postcards/$year');
      if (!await yearDir.exists()) {
        await yearDir.create(recursive: true);
      }

      // Create postcard directory
      final postcardDir = Directory('$_collectionPath/postcards/$year/$folderName');
      await postcardDir.create(recursive: true);

      // Create contributors directory
      final contributorsDir = Directory('${postcardDir.path}/contributors');
      await contributorsDir.create(recursive: true);

      // Create postcard object
      final postcard = Postcard(
        id: folderName,
        title: title,
        createdTimestamp: _formatTimestamp(now),
        senderCallsign: senderCallsign,
        senderNpub: senderNpub,
        recipientCallsign: recipientCallsign,
        recipientNpub: recipientNpub,
        recipientLocations: recipientLocations,
        type: type,
        status: 'in-transit',
        ttl: ttl,
        priority: priority,
        paymentRequested: paymentRequested,
        content: content,
        stamps: [],
        returnStamps: [],
      );

      // Write postcard.txt
      final postcardFile = File('${postcardDir.path}/postcard.txt');
      await postcardFile.writeAsString(postcard.exportAsText(), flush: true);

      print('PostcardService: Created postcard: $folderName');
      return postcard;
    } catch (e) {
      print('PostcardService: Error creating postcard: $e');
      return null;
    }
  }

  /// Add stamp to postcard journey
  Future<bool> addStamp({
    required String postcardId,
    required String stamperCallsign,
    required String stamperNpub,
    required double latitude,
    required double longitude,
    String? locationName,
    required String receivedFrom,
    required String receivedVia,
    required String signature,
  }) async {
    if (_collectionPath == null) return false;

    try {
      final year = postcardId.substring(0, 4);
      final postcardDir = Directory('$_collectionPath/postcards/$year/$postcardId');

      if (!await postcardDir.exists()) return false;

      // Load existing postcard
      final postcard = await loadPostcard(postcardId);
      if (postcard == null) return false;

      // Create new stamp
      final now = DateTime.now();
      final stamp = PostcardStamp(
        number: postcard.stamps.length + 1,
        stamperCallsign: stamperCallsign,
        stamperNpub: stamperNpub,
        timestamp: _formatTimestamp(now),
        latitude: latitude,
        longitude: longitude,
        locationName: locationName,
        receivedFrom: receivedFrom,
        receivedVia: receivedVia,
        hopNumber: postcard.stamps.length + 1,
        signature: signature,
      );

      // Add stamp to postcard
      final updatedStamps = [...postcard.stamps, stamp];
      final updatedPostcard = postcard.copyWith(stamps: updatedStamps);

      // Write updated postcard
      final postcardFile = File('${postcardDir.path}/postcard.txt');
      await postcardFile.writeAsString(updatedPostcard.exportAsText(), flush: true);

      print('PostcardService: Added stamp #${stamp.number} to $postcardId');
      return true;
    } catch (e) {
      print('PostcardService: Error adding stamp: $e');
      return false;
    }
  }

  /// Deliver postcard to recipient
  Future<bool> deliverPostcard({
    required String postcardId,
    required String carrierCallsign,
    required String carrierNpub,
    required double latitude,
    required double longitude,
    String? locationName,
    String? deliveryNote,
    required String signature,
  }) async {
    if (_collectionPath == null) return false;

    try {
      final year = postcardId.substring(0, 4);
      final postcardDir = Directory('$_collectionPath/postcards/$year/$postcardId');

      if (!await postcardDir.exists()) return false;

      // Load existing postcard
      final postcard = await loadPostcard(postcardId);
      if (postcard == null) return false;

      // Create delivery receipt
      final now = DateTime.now();
      final deliveryReceipt = PostcardDeliveryReceipt(
        recipientNpub: postcard.recipientNpub,
        timestamp: _formatTimestamp(now),
        carrierCallsign: carrierCallsign,
        carrierNpub: carrierNpub,
        deliveryLatitude: latitude,
        deliveryLongitude: longitude,
        deliveryLocationName: locationName,
        deliveryNote: deliveryNote,
        signature: signature,
      );

      // Update postcard status and add delivery receipt
      final updatedPostcard = postcard.copyWith(
        status: 'delivered',
        deliveryReceipt: deliveryReceipt,
      );

      // Write updated postcard
      final postcardFile = File('${postcardDir.path}/postcard.txt');
      await postcardFile.writeAsString(updatedPostcard.exportAsText(), flush: true);

      print('PostcardService: Delivered postcard: $postcardId');
      return true;
    } catch (e) {
      print('PostcardService: Error delivering postcard: $e');
      return false;
    }
  }

  /// Add return stamp to postcard
  Future<bool> addReturnStamp({
    required String postcardId,
    required String stamperCallsign,
    required String stamperNpub,
    required double latitude,
    required double longitude,
    String? locationName,
    required String receivedFrom,
    required String receivedVia,
    required String signature,
  }) async {
    if (_collectionPath == null) return false;

    try {
      final year = postcardId.substring(0, 4);
      final postcardDir = Directory('$_collectionPath/postcards/$year/$postcardId');

      if (!await postcardDir.exists()) return false;

      // Load existing postcard
      final postcard = await loadPostcard(postcardId);
      if (postcard == null) return false;

      // Create return stamp
      final now = DateTime.now();
      final stamp = PostcardStamp(
        number: postcard.returnStamps.length + 1,
        stamperCallsign: stamperCallsign,
        stamperNpub: stamperNpub,
        timestamp: _formatTimestamp(now),
        latitude: latitude,
        longitude: longitude,
        locationName: locationName,
        receivedFrom: receivedFrom,
        receivedVia: receivedVia,
        hopNumber: postcard.returnStamps.length + 1,
        signature: signature,
      );

      // Add return stamp
      final updatedReturnStamps = [...postcard.returnStamps, stamp];
      final updatedPostcard = postcard.copyWith(returnStamps: updatedReturnStamps);

      // Write updated postcard
      final postcardFile = File('${postcardDir.path}/postcard.txt');
      await postcardFile.writeAsString(updatedPostcard.exportAsText(), flush: true);

      print('PostcardService: Added return stamp #${stamp.number} to $postcardId');
      return true;
    } catch (e) {
      print('PostcardService: Error adding return stamp: $e');
      return false;
    }
  }

  /// Acknowledge postcard receipt by sender
  Future<bool> acknowledgePostcard({
    required String postcardId,
    required String receivedTimestamp,
    String? acknowledgmentNote,
    required String signature,
  }) async {
    if (_collectionPath == null) return false;

    try {
      final year = postcardId.substring(0, 4);
      final postcardDir = Directory('$_collectionPath/postcards/$year/$postcardId');

      if (!await postcardDir.exists()) return false;

      // Load existing postcard
      final postcard = await loadPostcard(postcardId);
      if (postcard == null) return false;

      // Create acknowledgment
      final acknowledgment = PostcardAcknowledgment(
        senderNpub: postcard.senderNpub,
        timestamp: receivedTimestamp,
        acknowledgmentNote: acknowledgmentNote,
        signature: signature,
      );

      // Update postcard status and add acknowledgment
      final updatedPostcard = postcard.copyWith(
        status: 'acknowledged',
        acknowledgment: acknowledgment,
      );

      // Write updated postcard
      final postcardFile = File('${postcardDir.path}/postcard.txt');
      await postcardFile.writeAsString(updatedPostcard.exportAsText(), flush: true);

      print('PostcardService: Acknowledged postcard: $postcardId');
      return true;
    } catch (e) {
      print('PostcardService: Error acknowledging postcard: $e');
      return false;
    }
  }

  /// Get postcards by status
  Future<List<Postcard>> getPostcardsByStatus(String status) async {
    return loadPostcards(filterByStatus: status);
  }

  /// Get in-transit postcards
  Future<List<Postcard>> getInTransitPostcards() async {
    return getPostcardsByStatus('in-transit');
  }

  /// Get delivered postcards
  Future<List<Postcard>> getDeliveredPostcards() async {
    return getPostcardsByStatus('delivered');
  }

  /// Get acknowledged postcards
  Future<List<Postcard>> getAcknowledgedPostcards() async {
    return getPostcardsByStatus('acknowledged');
  }

  /// Get expired postcards
  Future<List<Postcard>> getExpiredPostcards() async {
    return getPostcardsByStatus('expired');
  }

  /// Load contributor files from contributors folder
  Future<List<String>> loadContributorFiles(String postcardId) async {
    if (_collectionPath == null) return [];

    try {
      final year = postcardId.substring(0, 4);
      final contributorsDir = Directory(
        '$_collectionPath/postcards/$year/$postcardId/contributors',
      );

      if (!await contributorsDir.exists()) return [];

      final files = <String>[];
      await for (var entity in contributorsDir.list()) {
        if (entity is File) {
          final filename = entity.path.split('/').last;
          // Skip hidden files
          if (!filename.startsWith('.')) {
            files.add(filename);
          }
        }
      }

      // Sort alphabetically
      files.sort();
      return files;
    } catch (e) {
      print('PostcardService: Error loading contributor files: $e');
      return [];
    }
  }

  /// Check if postcard has expired
  bool isExpired(Postcard postcard) {
    if (postcard.ttl == null) return false;

    final created = postcard.createdDateTime;
    final expiryDate = created.add(Duration(days: postcard.ttl!));
    return DateTime.now().isAfter(expiryDate);
  }

  /// Mark postcard as expired
  Future<bool> markAsExpired(String postcardId) async {
    if (_collectionPath == null) return false;

    try {
      final year = postcardId.substring(0, 4);
      final postcardDir = Directory('$_collectionPath/postcards/$year/$postcardId');

      if (!await postcardDir.exists()) return false;

      // Load existing postcard
      final postcard = await loadPostcard(postcardId);
      if (postcard == null) return false;

      // Update status to expired
      final updatedPostcard = postcard.copyWith(status: 'expired');

      // Write updated postcard
      final postcardFile = File('${postcardDir.path}/postcard.txt');
      await postcardFile.writeAsString(updatedPostcard.exportAsText(), flush: true);

      print('PostcardService: Marked postcard as expired: $postcardId');
      return true;
    } catch (e) {
      print('PostcardService: Error marking postcard as expired: $e');
      return false;
    }
  }
}
