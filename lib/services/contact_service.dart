/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';
import '../models/contact.dart';
import 'log_service.dart';
import 'profile_storage.dart';

/// Minimal contact info for fast loading
class ContactSummary {
  final String callsign;
  final String displayName;
  final String? profilePicture;
  final String? groupPath;
  final String filePath;
  final int popularityScore;
  final String? secondaryInfo; // Phone, email, or other relevant info for display

  ContactSummary({
    required this.callsign,
    required this.displayName,
    this.profilePicture,
    this.groupPath,
    required this.filePath,
    this.popularityScore = 0,
    this.secondaryInfo,
  });

  Map<String, dynamic> toJson() => {
    'callsign': callsign,
    'displayName': displayName,
    if (profilePicture != null) 'profilePicture': profilePicture,
    if (groupPath != null && groupPath!.isNotEmpty) 'groupPath': groupPath,
    'filePath': filePath,
    if (popularityScore > 0) 'popularityScore': popularityScore,
    if (secondaryInfo != null && secondaryInfo!.isNotEmpty) 'secondaryInfo': secondaryInfo,
  };

  factory ContactSummary.fromJson(Map<String, dynamic> json) {
    return ContactSummary(
      callsign: json['callsign'] as String,
      displayName: json['displayName'] as String,
      profilePicture: json['profilePicture'] as String?,
      groupPath: json['groupPath'] as String?,
      filePath: json['filePath'] as String,
      popularityScore: json['popularityScore'] as int? ?? 0,
      secondaryInfo: json['secondaryInfo'] as String?,
    );
  }

  /// Create from full Contact
  factory ContactSummary.fromContact(Contact contact, {int popularityScore = 0}) {
    return ContactSummary(
      callsign: contact.callsign,
      displayName: contact.displayName,
      profilePicture: contact.profilePicture,
      groupPath: contact.groupPath,
      filePath: contact.filePath ?? '',
      popularityScore: popularityScore,
      secondaryInfo: _getSecondaryInfo(contact),
    );
  }

  /// Get the most relevant secondary info (phone > email > website > address)
  static String? _getSecondaryInfo(Contact contact) {
    if (contact.phones.isNotEmpty) return contact.phones.first;
    if (contact.emails.isNotEmpty) return contact.emails.first;
    if (contact.websites.isNotEmpty) return contact.websites.first;
    if (contact.addresses.isNotEmpty) return contact.addresses.first;
    if (contact.radioCallsigns.isNotEmpty) return contact.radioCallsigns.first;
    return null;
  }
}

/// Sanitize a string by removing invalid UTF-16 characters (unpaired surrogates)
/// This prevents Flutter from crashing when rendering malformed text
String _sanitizeUtf16(String input) {
  final buffer = StringBuffer();
  for (int i = 0; i < input.length; i++) {
    final codeUnit = input.codeUnitAt(i);
    // Check for unpaired surrogates (high surrogate: 0xD800-0xDBFF, low surrogate: 0xDC00-0xDFFF)
    if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
      // High surrogate - check if next character is a valid low surrogate
      if (i + 1 < input.length) {
        final nextCodeUnit = input.codeUnitAt(i + 1);
        if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
          // Valid surrogate pair - keep both
          buffer.write(input[i]);
          buffer.write(input[i + 1]);
          i++; // Skip next character as we've processed it
          continue;
        }
      }
      // Unpaired high surrogate - replace with replacement character
      buffer.write('\uFFFD');
    } else if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) {
      // Unpaired low surrogate - replace with replacement character
      buffer.write('\uFFFD');
    } else {
      buffer.write(input[i]);
    }
  }
  return buffer.toString();
}

/// Service for managing contacts collection (people and machines)
class ContactService {
  static final ContactService _instance = ContactService._internal();
  factory ContactService() => _instance;
  ContactService._internal();

  /// Profile storage for file operations (encrypted or filesystem)
  /// IMPORTANT: This MUST be set before using the service.
  late ProfileStorage _storage;

  String? _appPath;

  /// Get the current collection path
  String? get appPath => _appPath;

  /// Whether using encrypted storage
  bool get useEncryptedStorage => _storage.isEncrypted;

  /// Set the profile storage for file operations
  /// MUST be called before initializeApp
  void setStorage(ProfileStorage storage) {
    _storage = storage;
  }

  /// Get the relative path from collection path
  String _getRelativePath(String fullPath) {
    if (_appPath == null) return fullPath;
    if (fullPath.startsWith(_appPath!)) {
      final rel = fullPath.substring(_appPath!.length);
      return rel.startsWith('/') ? rel.substring(1) : rel;
    }
    return fullPath;
  }

  /// Cache for contact summaries (loaded from fast.json)
  List<ContactSummary>? _summaryCache;
  DateTime? _summaryCacheTime;

  /// Initialize contact service for a collection
  Future<void> initializeApp(String appPath) async {
    LogService().log('ContactService: Initializing with collection path: $appPath');
    _appPath = appPath;

    // Using ProfileStorage - directories are created implicitly
    await _storage.createDirectory('');
    await _storage.createDirectory('media');
    LogService().log('ContactService: Initialized with storage abstraction');
  }

  /// Load all contacts (with optional group filter)
  Future<List<Contact>> loadContacts({String? groupPath}) async {
    if (_appPath == null) return [];

    final contacts = <Contact>[];
    final relativePath = groupPath ?? '';

    // Use ProfileStorage abstraction
    final entries = await _storage.listDirectory(relativePath);
    for (final entry in entries) {
      if (!entry.isDirectory && entry.name.endsWith('.txt')) {
        // Skip group.txt and hidden files
        if (entry.name == 'group.txt' || entry.name.startsWith('.')) continue;

        try {
          final contact = await _loadContactFromStorage(entry.path);
          if (contact != null) {
            contacts.add(contact);
          }
        } catch (e) {
          LogService().log('ContactService: Error loading contact ${entry.path}: $e');
        }
      }
    }

    // Sort by display name
    contacts.sort((a, b) => a.displayName.compareTo(b.displayName));

    return contacts;
  }

  /// Load a contact from storage using relative path
  Future<Contact?> _loadContactFromStorage(String relativePath) async {
    final content = await _storage.readString(relativePath);
    if (content == null) return null;

    final fullPath = _storage.getAbsolutePath(relativePath);
    return parseContactFile(content, fullPath);
  }

  /// Load all contacts recursively (including subgroups)
  Future<List<Contact>> loadAllContactsRecursively() async {
    if (_appPath == null) return [];

    final contacts = <Contact>[];

    // Use ProfileStorage abstraction with recursive listing
    await _loadContactsRecursiveFromStorage('', contacts);

    // Sort by display name
    contacts.sort((a, b) => a.displayName.compareTo(b.displayName));

    return contacts;
  }

  /// Load contacts recursively from storage
  Future<void> _loadContactsRecursiveFromStorage(
    String relativePath,
    List<Contact> contacts,
  ) async {
    final entries = await _storage.listDirectory(relativePath);
    for (final entry in entries) {
      if (entry.isDirectory) {
        // Skip media directory and hidden directories
        if (entry.name == 'media' || entry.name.startsWith('.')) continue;
        await _loadContactsRecursiveFromStorage(entry.path, contacts);
      } else if (entry.name.endsWith('.txt')) {
        // Skip group.txt, fast.json and hidden files
        if (entry.name == 'group.txt' || entry.name.startsWith('.')) continue;

        try {
          final contact = await _loadContactFromStorage(entry.path);
          if (contact != null) {
            contacts.add(contact);
          }
        } catch (e) {
          LogService().log('ContactService: Error loading contact ${entry.path}: $e');
        }
      }
    }
  }

  /// Stream contacts incrementally, prioritizing popular contacts first.
  /// This provides a better UX by showing contacts as they load.
  Stream<Contact> loadAllContactsStream() async* {
    if (_appPath == null) return;

    // Use ProfileStorage - collect all paths then yield
    final allFilePaths = <String>[];
    await _collectContactFilePathsFromStorage('', allFilePaths);

    if (allFilePaths.isEmpty) return;

    final metrics = await loadMetrics();
    final sortedPaths = _sortPathsByPopularity(allFilePaths, metrics);

    for (final filePath in sortedPaths) {
      try {
        final contact = await _loadContactFromStorage(filePath);
        if (contact != null) {
          yield contact;
        }
      } catch (e) {
        LogService().log('ContactService: Error loading contact $filePath: $e');
      }
    }
  }

  /// Collect contact file paths from storage recursively
  Future<void> _collectContactFilePathsFromStorage(
    String relativePath,
    List<String> paths,
  ) async {
    final entries = await _storage.listDirectory(relativePath);
    for (final entry in entries) {
      if (entry.isDirectory) {
        if (entry.name == 'media' || entry.name.startsWith('.')) continue;
        await _collectContactFilePathsFromStorage(entry.path, paths);
      } else if (entry.name.endsWith('.txt') && entry.name != 'group.txt') {
        paths.add(entry.path);
      }
    }
  }

  /// Load contact summaries from fast.json (instant)
  /// Returns null if fast.json doesn't exist or is invalid
  Future<List<ContactSummary>?> loadContactSummaries() async {
    if (_appPath == null) return null;

    // Use in-memory cache if still valid (5 seconds)
    final now = DateTime.now();
    if (_summaryCache != null &&
        _summaryCacheTime != null &&
        now.difference(_summaryCacheTime!) < const Duration(seconds: 5)) {
      return _summaryCache;
    }

    final content = await _storage.readString('fast.json');
    if (content == null) {
      LogService().log('ContactService: fast.json not found, need to rebuild');
      return null;
    }

    try {
      final sanitizedContent = _sanitizeUtf16(content);
      final List<dynamic> jsonList = json.decode(sanitizedContent);
      final summaries = jsonList
          .map((item) => ContactSummary.fromJson(item as Map<String, dynamic>))
          .toList();

      // Sort by popularity score (descending) then alphabetically
      summaries.sort((a, b) {
        if (a.popularityScore != b.popularityScore) {
          return b.popularityScore.compareTo(a.popularityScore);
        }
        return a.displayName.compareTo(b.displayName);
      });

      _summaryCache = summaries;
      _summaryCacheTime = now;

      LogService().log('ContactService: Loaded ${summaries.length} contact summaries from fast.json');
      return summaries;
    } catch (e) {
      LogService().log('ContactService: Error loading fast.json: $e');
      return null;
    }
  }

  /// Build a map of uppercase callsign -> display nickname from contact summaries.
  /// Skips entries where displayName equals callsign (no useful nickname).
  Future<Map<String, String>> buildNicknameMap() async {
    final summaries = await loadContactSummaries();
    if (summaries == null) return {};

    final map = <String, String>{};
    for (final s in summaries) {
      if (s.displayName != s.callsign) {
        map[s.callsign.toUpperCase()] = s.displayName;
      }
    }
    return map;
  }

  /// Save contact summaries to fast.json
  Future<void> saveContactSummaries(List<ContactSummary> summaries) async {
    if (_appPath == null) return;

    try {
      final jsonList = summaries.map((s) => s.toJson()).toList();
      await _storage.writeString('fast.json', json.encode(jsonList));
      _summaryCache = summaries;
      _summaryCacheTime = DateTime.now();
      LogService().log('ContactService: Saved ${summaries.length} contact summaries to fast.json');
    } catch (e) {
      LogService().log('ContactService: Error saving fast.json: $e');
    }
  }

  /// Rebuild fast.json from all contact files
  /// This should be called when contacts change or initially if fast.json is missing
  Future<void> rebuildFastJson() async {
    if (_appPath == null) return;

    LogService().log('ContactService: Rebuilding fast.json...');

    // Load metrics for popularity scores
    final metrics = await loadMetrics();

    // Collect all contact file paths using storage
    final allFilePaths = <String>[];
    await _collectContactFilePathsFromStorage('', allFilePaths);

    // Build summaries by quickly parsing just the header info from each file
    final summaries = <ContactSummary>[];
    for (final relativePath in allFilePaths) {
      try {
        final summary = await _parseContactSummaryFromStorage(relativePath, metrics);
        if (summary != null) {
          summaries.add(summary);
        }
      } catch (e) {
        LogService().log('ContactService: Error parsing summary for $relativePath: $e');
      }
    }

    await saveContactSummaries(summaries);
    LogService().log('ContactService: Rebuilt fast.json with ${summaries.length} contacts');
  }

  /// Parse just the essential fields from a contact file using storage (very fast)
  Future<ContactSummary?> _parseContactSummaryFromStorage(String relativePath, ContactMetrics metrics) async {
    final content = await _storage.readString(relativePath);
    if (content == null) return null;

    try {
      final sanitizedContent = _sanitizeUtf16(content);
      final lines = sanitizedContent.split('\n');

      String? displayName;
      String? callsign;
      String? profilePicture;
      String? firstPhone;
      String? firstEmail;
      String? firstWebsite;
      String? firstAddress;
      String? firstRadioCallsign;

      // Parse the file to extract essential fields and secondary info
      for (int i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trim();

        if (trimmed.startsWith('# CONTACT:')) {
          displayName = trimmed.substring('# CONTACT:'.length).trim();
        } else if (trimmed.startsWith('CALLSIGN:')) {
          callsign = trimmed.substring('CALLSIGN:'.length).trim();
        } else if (trimmed.startsWith('PROFILE_PICTURE:')) {
          profilePicture = trimmed.substring('PROFILE_PICTURE:'.length).trim();
        } else if (trimmed.startsWith('PHONE:') && firstPhone == null) {
          firstPhone = trimmed.substring('PHONE:'.length).trim();
        } else if (trimmed.startsWith('EMAIL:') && firstEmail == null) {
          firstEmail = trimmed.substring('EMAIL:'.length).trim();
        } else if (trimmed.startsWith('WEBSITE:') && firstWebsite == null) {
          firstWebsite = trimmed.substring('WEBSITE:'.length).trim();
        } else if (trimmed.startsWith('ADDRESS:') && firstAddress == null) {
          firstAddress = trimmed.substring('ADDRESS:'.length).trim();
        } else if (trimmed.startsWith('RADIO_CALLSIGN:') && firstRadioCallsign == null) {
          firstRadioCallsign = trimmed.substring('RADIO_CALLSIGN:'.length).trim();
        }

        // Stop early if we have all essential fields and at least one secondary info
        if (displayName != null && callsign != null && firstPhone != null) break;
      }

      if (displayName == null || callsign == null) return null;

      // Determine secondary info (priority: phone > email > website > address > radio callsign)
      final secondaryInfo = firstPhone ?? firstEmail ?? firstWebsite ?? firstAddress ?? firstRadioCallsign;

      // Determine group path from relative path
      String? groupPath;
      final parts = relativePath.split('/');
      if (parts.length > 1) {
        parts.removeLast(); // Remove filename
        groupPath = parts.join('/');
      }

      final fullPath = _storage.getAbsolutePath(relativePath);
      final popularityScore = metrics.contacts[callsign]?.totalScore ?? 0;

      return ContactSummary(
        callsign: callsign,
        displayName: displayName,
        profilePicture: profilePicture,
        groupPath: groupPath,
        filePath: fullPath,
        popularityScore: popularityScore,
        secondaryInfo: secondaryInfo,
      );
    } catch (e) {
      LogService().log('ContactService: Error parsing summary $relativePath: $e');
      return null;
    }
  }

  /// Stream contacts with fast initial load
  /// First yields from fast.json (instant), then loads full details in background
  Stream<Contact> loadAllContactsStreamFast() async* {
    if (_appPath == null) return;

    // Try to load from fast.json first
    final summaries = await loadContactSummaries();

    if (summaries != null && summaries.isNotEmpty) {
      // Yield placeholder contacts from summaries (instant)
      for (final summary in summaries) {
        yield _placeholderContactFromSummary(summary);
      }
    } else {
      // No fast.json, fall back to regular stream and rebuild cache
      await for (final contact in loadAllContactsStream()) {
        yield contact;
      }
      // Rebuild fast.json for next time
      await rebuildFastJson();
    }
  }

  /// Create a placeholder contact from summary (for display while loading)
  Contact _placeholderContactFromSummary(ContactSummary summary) {
    final now = DateTime.now();
    final timestamp = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}_'
        '${now.second.toString().padLeft(2, '0')}';

    // Include secondary info as a phone number so Contact.secondaryInfo returns it
    // (This is a temporary placeholder - full contact details will be loaded later)
    final phones = summary.secondaryInfo != null ? [summary.secondaryInfo!] : <String>[];

    return Contact(
      displayName: summary.displayName,
      callsign: summary.callsign,
      created: timestamp,
      firstSeen: timestamp,
      profilePicture: summary.profilePicture,
      groupPath: summary.groupPath,
      filePath: summary.filePath,
      phones: phones,
    );
  }

  /// Invalidate the fast.json cache (call after contact changes)
  void invalidateSummaryCache() {
    _summaryCache = null;
    _summaryCacheTime = null;
  }

  /// Search contacts that have email addresses
  /// Returns a list of (displayName, email, callsign, profilePicture) for autocomplete
  Future<List<Map<String, String?>>> searchContactsWithEmail(String query) async {
    if (_appPath == null) return [];

    final results = <Map<String, String?>>[];
    final queryLower = query.toLowerCase();

    // Load summaries from fast.json
    final summaries = await loadContactSummaries();
    if (summaries == null) return results;

    // Filter summaries where secondaryInfo looks like an email or name matches
    for (final summary in summaries) {
      final matchesQuery = summary.displayName.toLowerCase().contains(queryLower) ||
          summary.callsign.toLowerCase().contains(queryLower) ||
          (summary.secondaryInfo?.toLowerCase().contains(queryLower) ?? false);

      if (!matchesQuery) continue;

      // Check if secondaryInfo is an email (contains @)
      if (summary.secondaryInfo != null && summary.secondaryInfo!.contains('@')) {
        results.add({
          'displayName': summary.displayName,
          'email': summary.secondaryInfo,
          'callsign': summary.callsign,
          'profilePicture': summary.profilePicture,
        });
      } else {
        // Need to load full contact to get emails
        final contact = await getContactByCallsign(summary.callsign);
        if (contact != null && contact.emails.isNotEmpty) {
          for (final email in contact.emails) {
            results.add({
              'displayName': summary.displayName,
              'email': email,
              'callsign': summary.callsign,
              'profilePicture': summary.profilePicture,
            });
          }
        }
      }

      // Limit results for performance
      if (results.length >= 10) break;
    }

    return results;
  }

  /// Get all contacts with emails (for autocomplete suggestions)
  /// Returns cached list of (displayName, email, callsign) tuples
  List<Map<String, String?>>? _emailContactsCache;
  DateTime? _emailContactsCacheTime;

  Future<List<Map<String, String?>>> getContactsWithEmails() async {
    if (_appPath == null) return [];

    // Return cached if recent (5 minutes)
    final now = DateTime.now();
    if (_emailContactsCache != null &&
        _emailContactsCacheTime != null &&
        now.difference(_emailContactsCacheTime!).inMinutes < 5) {
      return _emailContactsCache!;
    }

    final results = <Map<String, String?>>[];

    // Load all contacts and extract emails
    final contacts = await loadAllContactsRecursively();
    for (final contact in contacts) {
      for (final email in contact.emails) {
        results.add({
          'displayName': contact.displayName,
          'email': email,
          'callsign': contact.callsign,
          'profilePicture': contact.profilePicture,
        });
      }
    }

    _emailContactsCache = results;
    _emailContactsCacheTime = now;

    return results;
  }

  /// Delete all cache and metrics files to reset the contacts app state
  /// This removes: fast.json, .contact_metrics.txt, .click_stats.txt, .favorites.json
  Future<int> deleteAllCacheFiles() async {
    if (_appPath == null) return 0;

    int deletedCount = 0;
    final filesToDelete = [
      'fast.json',
      '.contact_metrics.txt',
      '.click_stats.txt',
      '.favorites.json',
    ];

    for (final relativePath in filesToDelete) {
      try {
        if (await _storage.exists(relativePath)) {
          await _storage.delete(relativePath);
          deletedCount++;
          LogService().log('ContactService: Deleted cache file: $relativePath');
        }
      } catch (e) {
        LogService().log('ContactService: Error deleting $relativePath: $e');
      }
    }

    // Clear in-memory cache
    invalidateSummaryCache();

    LogService().log('ContactService: Deleted $deletedCount cache files');
    return deletedCount;
  }

  /// Sort file paths by popularity score, with popular contacts first
  List<String> _sortPathsByPopularity(List<String> paths, ContactMetrics metrics) {
    // Extract callsign from file path (filename without .txt)
    String getCallsign(String path) {
      final filename = path.split('/').last;
      return filename.replaceAll('.txt', '');
    }

    // Sort by score (descending) then alphabetically
    paths.sort((a, b) {
      final callsignA = getCallsign(a);
      final callsignB = getCallsign(b);

      final scoreA = metrics.contacts[callsignA]?.totalScore ?? 0;
      final scoreB = metrics.contacts[callsignB]?.totalScore ?? 0;

      if (scoreA != scoreB) {
        return scoreB.compareTo(scoreA); // Higher score first
      }
      return callsignA.compareTo(callsignB); // Alphabetical fallback
    });

    return paths;
  }

  /// Load single contact from file path (accepts both absolute and relative paths)
  Future<Contact?> loadContactFromFile(String filePath) async {
    // Convert absolute path to relative if needed
    final relativePath = _getRelativePath(filePath);

    final content = await _storage.readString(relativePath);
    if (content == null) return null;

    try {
      final sanitizedContent = _sanitizeUtf16(content);
      final fullPath = _storage.getAbsolutePath(relativePath);
      final contact = await parseContactFile(sanitizedContent, fullPath);
      return contact;
    } catch (e) {
      LogService().log('ContactService: Error reading contact file $filePath: $e');
      return null;
    }
  }

  /// Load single contact by callsign
  Future<Contact?> loadContact(String callsign, {String? groupPath}) async {
    if (_appPath == null) return null;

    final relativePath = groupPath != null && groupPath.isNotEmpty
        ? '$groupPath/$callsign.txt'
        : '$callsign.txt';

    if (!await _storage.exists(relativePath)) return null;

    return await _loadContactFromStorage(relativePath);
  }

  /// Parse contact file content
  Future<Contact?> parseContactFile(String content, String filePath) async {
    final lines = content.split('\n');
    if (lines.isEmpty) return null;

    String? displayName;
    String? callsign;
    String? npub;
    String? created;
    String? firstSeen;

    final emails = <String>[];
    final phones = <String>[];
    final addresses = <String>[];
    final websites = <String>[];
    final locations = <ContactLocation>[];
    String? profilePicture;

    // New fields
    final tags = <String>[];
    final radioCallsigns = <String>[];
    final socialHandles = <String, String>{};
    final dateReminders = <ContactDateReminder>[];
    bool isTemporaryIdentity = false;
    String? temporaryNsec;

    bool revoked = false;
    String? revocationReason;
    String? successor;
    String? successorSince;
    String? previousIdentity;
    String? previousIdentitySince;

    final historyEntries = <ContactHistoryEntry>[];
    final notesLines = <String>[];
    String? metadataNpub;
    String? signature;

    bool inNotes = false;
    bool inMetadata = false;
    bool inHistoryLog = false;
    final historyBuffer = StringBuffer();

    for (var line in lines) {
      final trimmed = line.trim();

      // Parse header
      if (trimmed.startsWith('# CONTACT:')) {
        displayName = trimmed.substring('# CONTACT:'.length).trim();
        continue;
      }

      // Check for history log markers
      if (trimmed == '## HISTORY LOG') {
        inHistoryLog = true;
        inNotes = false;
        continue;
      }

      if (trimmed == '## END HISTORY') {
        // Parse the accumulated history buffer
        if (historyBuffer.isNotEmpty) {
          _parseHistoryEntries(historyBuffer.toString(), historyEntries);
        }
        inHistoryLog = false;
        continue;
      }

      // If in history log, accumulate lines
      if (inHistoryLog) {
        historyBuffer.writeln(line);
        continue;
      }

      // Parse metadata section (at end of file)
      if (trimmed.startsWith('--> npub:')) {
        inNotes = false;
        inMetadata = true;
        metadataNpub = trimmed.substring('--> npub:'.length).trim();
        continue;
      }

      if (trimmed.startsWith('--> signature:')) {
        signature = trimmed.substring('--> signature:'.length).trim();
        continue;
      }

      // Skip empty lines unless in notes
      if (trimmed.isEmpty) {
        if (inNotes) {
          notesLines.add('');
        }
        continue;
      }

      // Parse fields
      if (trimmed.startsWith('CALLSIGN:')) {
        callsign = trimmed.substring('CALLSIGN:'.length).trim();
      } else if (trimmed.startsWith('NPUB:')) {
        npub = trimmed.substring('NPUB:'.length).trim();
      } else if (trimmed.startsWith('CREATED:')) {
        created = trimmed.substring('CREATED:'.length).trim();
      } else if (trimmed.startsWith('FIRST_SEEN:')) {
        firstSeen = trimmed.substring('FIRST_SEEN:'.length).trim();
      } else if (trimmed.startsWith('EMAIL:')) {
        emails.add(trimmed.substring('EMAIL:'.length).trim());
      } else if (trimmed.startsWith('PHONE:')) {
        phones.add(trimmed.substring('PHONE:'.length).trim());
      } else if (trimmed.startsWith('ADDRESS:')) {
        addresses.add(trimmed.substring('ADDRESS:'.length).trim());
      } else if (trimmed.startsWith('WEBSITE:')) {
        websites.add(trimmed.substring('WEBSITE:'.length).trim());
      } else if (trimmed.startsWith('LOCATIONS:')) {
        final locationsStr = trimmed.substring('LOCATIONS:'.length).trim();
        locations.addAll(_parseLocations(locationsStr));
      } else if (trimmed.startsWith('PROFILE_PICTURE:')) {
        profilePicture = trimmed.substring('PROFILE_PICTURE:'.length).trim();
      } else if (trimmed.startsWith('TAGS:')) {
        final tagsStr = trimmed.substring('TAGS:'.length).trim();
        tags.addAll(tagsStr.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty));
      } else if (trimmed.startsWith('RADIO_CALLSIGN:')) {
        radioCallsigns.add(trimmed.substring('RADIO_CALLSIGN:'.length).trim());
      } else if (trimmed.startsWith('SOCIAL_')) {
        // Parse SOCIAL_NETWORK: handle format
        final colonIndex = trimmed.indexOf(':');
        if (colonIndex > 7) { // 'SOCIAL_' is 7 chars
          final networkId = trimmed.substring(7, colonIndex).toLowerCase();
          final handle = trimmed.substring(colonIndex + 1).trim();
          if (handle.isNotEmpty) {
            socialHandles[networkId] = handle;
          }
        }
      } else if (trimmed.startsWith('TEMPORARY_IDENTITY:')) {
        final value = trimmed.substring('TEMPORARY_IDENTITY:'.length).trim().toLowerCase();
        isTemporaryIdentity = value == 'true';
      } else if (trimmed.startsWith('TEMPORARY_NSEC:')) {
        temporaryNsec = trimmed.substring('TEMPORARY_NSEC:'.length).trim();
      } else if (trimmed.startsWith('REVOKED:')) {
        final value = trimmed.substring('REVOKED:'.length).trim().toLowerCase();
        revoked = value == 'true';
      } else if (trimmed.startsWith('REVOCATION_REASON:')) {
        revocationReason = trimmed.substring('REVOCATION_REASON:'.length).trim();
      } else if (trimmed.startsWith('SUCCESSOR:')) {
        successor = trimmed.substring('SUCCESSOR:'.length).trim();
      } else if (trimmed.startsWith('SUCCESSOR_SINCE:')) {
        successorSince = trimmed.substring('SUCCESSOR_SINCE:'.length).trim();
      } else if (trimmed.startsWith('PREVIOUS_IDENTITY:')) {
        previousIdentity = trimmed.substring('PREVIOUS_IDENTITY:'.length).trim();
      } else if (trimmed.startsWith('PREVIOUS_IDENTITY_SINCE:')) {
        previousIdentitySince = trimmed.substring('PREVIOUS_IDENTITY_SINCE:'.length).trim();
      } else if (trimmed.startsWith('DATE_REMINDER:')) {
        final reminderStr = trimmed.substring('DATE_REMINDER:'.length).trim();
        final reminder = ContactDateReminder.fromFileFormat(reminderStr);
        if (reminder != null) {
          dateReminders.add(reminder);
        }
      } else if (!inMetadata && !trimmed.startsWith('#') && !trimmed.startsWith('##')) {
        // This is notes content (legacy format without history log)
        inNotes = true;
        notesLines.add(line); // Preserve original formatting
      }
    }

    // Validate required fields (npub is now optional)
    if (displayName == null || callsign == null || created == null || firstSeen == null) {
      LogService().log('ContactService: Missing required fields in contact file');
      return null;
    }

    // Determine group path from file path
    // Use LAST occurrence of /contacts/ to handle cases where collection folder is named "contacts"
    String? groupPath;
    final contactsMarker = '/contacts/';
    final lastContactsIndex = filePath.lastIndexOf(contactsMarker);
    if (lastContactsIndex != -1) {
      final afterContacts = filePath.substring(lastContactsIndex + contactsMarker.length);
      final parts = afterContacts.split('/');
      if (parts.length > 1) {
        // Remove filename and join remaining parts
        parts.removeLast();
        groupPath = parts.join('/');
      }
    }

    return Contact(
      displayName: displayName,
      callsign: callsign,
      npub: npub,
      created: created,
      firstSeen: firstSeen,
      emails: emails,
      phones: phones,
      addresses: addresses,
      websites: websites,
      locations: locations,
      socialHandles: socialHandles,
      profilePicture: profilePicture,
      tags: tags,
      radioCallsigns: radioCallsigns,
      dateReminders: dateReminders,
      isTemporaryIdentity: isTemporaryIdentity,
      temporaryNsec: temporaryNsec,
      revoked: revoked,
      revocationReason: revocationReason,
      successor: successor,
      successorSince: successorSince,
      previousIdentity: previousIdentity,
      previousIdentitySince: previousIdentitySince,
      historyEntries: historyEntries,
      notes: notesLines.join('\n').trim(),
      metadataNpub: metadataNpub,
      signature: signature,
      filePath: filePath,
      groupPath: groupPath ?? '',
    );
  }

  /// Parse history entries from accumulated text
  void _parseHistoryEntries(String historyText, List<ContactHistoryEntry> entries) {
    final blocks = historyText.split(RegExp(r'\n(?=>)'));

    for (var block in blocks) {
      block = block.trim();
      if (block.isEmpty) continue;

      final entry = ContactHistoryEntry.parseFromText(block);
      if (entry != null) {
        entries.add(entry);
      }
    }

    // Sort by timestamp descending (newest first)
    entries.sort();
  }

  /// Parse locations string
  /// Format: "Name (lat,lon)", "Name (online)", "Name (place:/path/to/place)"
  List<ContactLocation> _parseLocations(String locationsStr) {
    final locations = <ContactLocation>[];
    // Split by | to support multiple locations
    final parts = locationsStr.split('|');

    for (var part in parts) {
      part = part.trim();
      if (part.isEmpty) continue;

      // Check if it's online type: Name (online)
      final onlineMatch = RegExp(r'(.+?)\s*\(online\)$', caseSensitive: false).firstMatch(part);
      if (onlineMatch != null) {
        final name = onlineMatch.group(1)!.trim();
        locations.add(ContactLocation(
          name: name,
          type: ContactLocationType.online,
        ));
        continue;
      }

      // Check if it's place type: Name (place:/path/to/place)
      final placeMatch = RegExp(r'(.+?)\s*\(place:(.+)\)$').firstMatch(part);
      if (placeMatch != null) {
        final name = placeMatch.group(1)!.trim();
        final placePath = placeMatch.group(2)!.trim();
        locations.add(ContactLocation(
          name: name,
          type: ContactLocationType.place,
          placePath: placePath,
        ));
        continue;
      }

      // Check if it has coordinates: Name (lat,lon)
      final coordsMatch = RegExp(r'(.+?)\s*\((-?\d+\.?\d*),(-?\d+\.?\d*)\)$').firstMatch(part);
      if (coordsMatch != null) {
        final name = coordsMatch.group(1)!.trim();
        final lat = double.tryParse(coordsMatch.group(2)!);
        final lon = double.tryParse(coordsMatch.group(3)!);
        if (lat != null && lon != null) {
          locations.add(ContactLocation(
            name: name,
            type: ContactLocationType.coordinates,
            latitude: lat,
            longitude: lon,
          ));
          continue;
        }
      }

      // Legacy: Just a name without type/coordinates (default to coordinates)
      locations.add(ContactLocation(name: part, type: ContactLocationType.coordinates));
    }

    return locations;
  }

  /// Format location to string for storage
  String _formatLocation(ContactLocation loc) {
    switch (loc.type) {
      case ContactLocationType.online:
        return '${loc.name} (online)';
      case ContactLocationType.place:
        if (loc.placePath != null) {
          return '${loc.name} (place:${loc.placePath})';
        }
        return loc.name;
      case ContactLocationType.coordinates:
        if (loc.latitude != null && loc.longitude != null) {
          return '${loc.name} (${loc.latitude},${loc.longitude})';
        }
        return loc.name;
    }
  }

  /// Format contact to file content
  String formatContactFile(Contact contact) {
    final buffer = StringBuffer();

    // Header
    buffer.writeln('# CONTACT: ${contact.displayName}');
    buffer.writeln();

    // Required fields
    buffer.writeln('CALLSIGN: ${contact.callsign}');
    if (contact.npub != null && contact.npub!.isNotEmpty) {
      buffer.writeln('NPUB: ${contact.npub}');
    }
    buffer.writeln('CREATED: ${contact.created}');
    buffer.writeln('FIRST_SEEN: ${contact.firstSeen}');

    // Temporary identity
    if (contact.isTemporaryIdentity) {
      buffer.writeln('TEMPORARY_IDENTITY: true');
      if (contact.temporaryNsec != null) {
        buffer.writeln('TEMPORARY_NSEC: ${contact.temporaryNsec}');
      }
    }
    buffer.writeln();

    // Optional contact information
    for (var email in contact.emails) {
      buffer.writeln('EMAIL: $email');
    }
    for (var phone in contact.phones) {
      buffer.writeln('PHONE: $phone');
    }
    for (var address in contact.addresses) {
      buffer.writeln('ADDRESS: $address');
    }
    for (var website in contact.websites) {
      buffer.writeln('WEBSITE: $website');
    }

    if (contact.locations.isNotEmpty) {
      buffer.write('LOCATIONS: ');
      buffer.writeln(contact.locations.map(_formatLocation).join(' | '));
    }

    if (contact.profilePicture != null) {
      buffer.writeln('PROFILE_PICTURE: ${contact.profilePicture}');
    }

    // Tags
    if (contact.tags.isNotEmpty) {
      buffer.writeln('TAGS: ${contact.tags.join(', ')}');
    }

    // Radio callsigns (amateur radio)
    for (var callsign in contact.radioCallsigns) {
      buffer.writeln('RADIO_CALLSIGN: $callsign');
    }

    // Social handles
    for (var entry in contact.socialHandles.entries) {
      buffer.writeln('SOCIAL_${entry.key.toUpperCase()}: ${entry.value}');
    }

    // Date reminders
    for (var reminder in contact.dateReminders) {
      buffer.writeln('DATE_REMINDER: ${reminder.toFileFormat()}');
    }

    if (contact.emails.isNotEmpty || contact.phones.isNotEmpty ||
        contact.addresses.isNotEmpty || contact.websites.isNotEmpty ||
        contact.locations.isNotEmpty || contact.profilePicture != null ||
        contact.tags.isNotEmpty || contact.radioCallsigns.isNotEmpty ||
        contact.socialHandles.isNotEmpty || contact.dateReminders.isNotEmpty) {
      buffer.writeln();
    }

    // Identity management
    if (contact.revoked || contact.revocationReason != null ||
        contact.successor != null || contact.previousIdentity != null) {
      buffer.writeln('REVOKED: ${contact.revoked}');
      if (contact.revocationReason != null) {
        buffer.writeln('REVOCATION_REASON: ${contact.revocationReason}');
      }
      if (contact.successor != null) {
        buffer.writeln('SUCCESSOR: ${contact.successor}');
      }
      if (contact.successorSince != null) {
        buffer.writeln('SUCCESSOR_SINCE: ${contact.successorSince}');
      }
      if (contact.previousIdentity != null) {
        buffer.writeln('PREVIOUS_IDENTITY: ${contact.previousIdentity}');
      }
      if (contact.previousIdentitySince != null) {
        buffer.writeln('PREVIOUS_IDENTITY_SINCE: ${contact.previousIdentitySince}');
      }
      buffer.writeln();
    }

    // History log
    if (contact.historyEntries.isNotEmpty) {
      buffer.writeln('## HISTORY LOG');
      buffer.writeln();
      for (var entry in contact.historyEntries) {
        buffer.writeln(entry.exportAsText());
        buffer.writeln();
      }
      buffer.writeln('## END HISTORY');
      buffer.writeln();
    } else if (contact.notes.isNotEmpty) {
      // Legacy notes (if no history entries but notes exist)
      buffer.writeln(contact.notes);
      buffer.writeln();
    }

    // Metadata
    if (contact.metadataNpub != null) {
      buffer.writeln('--> npub: ${contact.metadataNpub}');
    }
    if (contact.signature != null) {
      buffer.writeln('--> signature: ${contact.signature}');
    }

    return buffer.toString();
  }

  /// Save contact (create or update)
  /// Returns error message if duplicate found, null on success
  Future<String?> saveContact(
    Contact contact, {
    String? groupPath,
    bool skipDuplicateCheck = false,
    bool skipFastJsonRebuild = false,
  }) async {
    if (_appPath == null) return 'Collection not initialized';

    // Check for duplicates (callsign and npub)
    if (!skipDuplicateCheck) {
      final duplicateError = await _checkDuplicates(
        contact.callsign,
        contact.npub,
        excludeFilePath: contact.filePath,
      );
      if (duplicateError != null) {
        return duplicateError;
      }
    }

    final fileContent = formatContactFile(contact);
    final relativePath = groupPath != null && groupPath.isNotEmpty
        ? '$groupPath/${contact.callsign}.txt'
        : '${contact.callsign}.txt';

    try {
      // Use ProfileStorage abstraction
      if (groupPath != null && groupPath.isNotEmpty) {
        await _storage.createDirectory(groupPath);
      }
      await _storage.writeString(relativePath, fileContent);
      final newFilePath = _storage.getAbsolutePath(relativePath);
      LogService().log('ContactService: Saved contact ${contact.callsign} to $newFilePath');

      // Delete old file if it exists at a different location (contact was moved)
      if (contact.filePath != null && contact.filePath != newFilePath) {
        final oldRelativePath = _getRelativePath(contact.filePath!);
        if (await _storage.exists(oldRelativePath)) {
          await _storage.delete(oldRelativePath);
          LogService().log('ContactService: Deleted old file at ${contact.filePath}');
        }
      }

      // Invalidate and rebuild fast.json cache (await to ensure UI sees updated data)
      invalidateSummaryCache();
      if (!skipFastJsonRebuild) {
        await rebuildFastJson();
      }

      return null; // Success
    } catch (e) {
      LogService().log('ContactService: Error saving contact: $e');
      return 'Error saving contact: $e';
    }
  }

  /// Check for duplicate callsign or npub
  /// Returns error message if duplicate found, null if no duplicates
  Future<String?> _checkDuplicates(
    String callsign,
    String? npub, {
    String? excludeFilePath,
  }) async {
    final allContacts = await loadAllContactsRecursively();

    for (var contact in allContacts) {
      // Skip the contact we're updating
      if (excludeFilePath != null && contact.filePath == excludeFilePath) {
        continue;
      }

      // Check callsign duplicate
      if (contact.callsign == callsign) {
        final location = (contact.groupPath == null || contact.groupPath!.isEmpty) ? 'root' : contact.groupPath;
        return 'Contact with callsign "$callsign" already exists in $location';
      }

      // Check npub duplicate (only if both have npub)
      if (npub != null && npub.isNotEmpty && contact.npub != null && contact.npub == npub) {
        final location = (contact.groupPath == null || contact.groupPath!.isEmpty) ? 'root' : contact.groupPath;
        return 'Contact with this NPUB already exists: ${contact.displayName} in $location';
      }
    }

    return null; // No duplicates found
  }

  /// Get contact by callsign (searches all groups)
  Future<Contact?> getContactByCallsign(String callsign) async {
    final allContacts = await loadAllContactsRecursively();
    for (var contact in allContacts) {
      if (contact.callsign == callsign) {
        return contact;
      }
    }
    return null;
  }

  /// Generate a unique callsign for a contact based on their name
  /// Format: First 4 letters of name (uppercase) + number if needed
  Future<String> generateUniqueCallsign(String displayName) async {
    // Extract alphanumeric characters and take first 4, uppercase
    final cleaned = displayName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
    final base = cleaned.length >= 4 ? cleaned.substring(0, 4) : cleaned.padRight(4, 'X');

    // Check if base callsign is available
    var candidate = base;
    var suffix = 1;
    var existing = await getContactByCallsign(candidate);

    while (existing != null) {
      candidate = '$base$suffix';
      suffix++;
      existing = await getContactByCallsign(candidate);

      // Safety limit
      if (suffix > 999) {
        candidate = '$base${DateTime.now().millisecondsSinceEpoch % 10000}';
        break;
      }
    }

    return candidate;
  }

  /// Delete contact
  /// Set [skipFastJsonRebuild] to true when doing batch operations (e.g., merge)
  /// and you'll manually call rebuildFastJson() at the end
  Future<bool> deleteContact(String callsign, {String? groupPath, bool skipFastJsonRebuild = false}) async {
    if (_appPath == null) return false;

    final relativePath = groupPath != null && groupPath.isNotEmpty
        ? '$groupPath/$callsign.txt'
        : '$callsign.txt';

    try {
      // Use ProfileStorage abstraction
      if (!await _storage.exists(relativePath)) return false;
      await _storage.delete(relativePath);

      LogService().log('ContactService: Deleted contact $callsign');

      // Also delete profile picture if exists
      await _deleteProfilePicture(callsign);

      // Invalidate and rebuild fast.json cache (await to ensure UI sees updated data)
      if (!skipFastJsonRebuild) {
        invalidateSummaryCache();
        await rebuildFastJson();
      }

      return true;
    } catch (e) {
      LogService().log('ContactService: Error deleting contact: $e');
      return false;
    }
  }

  /// Move contact to a different group/folder
  Future<bool> moveContactToGroup(String callsign, String? newGroupPath) async {
    if (_appPath == null) return false;

    // Find the contact file
    final oldRelativePath = await _findContactFileInStorage(callsign);
    if (oldRelativePath == null) return false;

    // Load the contact
    final contact = await _loadContactFromStorage(oldRelativePath);
    if (contact == null) return false;

    // Determine new relative path
    final newRelativePath = newGroupPath != null && newGroupPath.isNotEmpty
        ? '$newGroupPath/$callsign.txt'
        : '$callsign.txt';

    // If already in the target location, do nothing
    if (oldRelativePath == newRelativePath) return true;

    try {
      // Create new group directory if needed
      if (newGroupPath != null && newGroupPath.isNotEmpty) {
        await _storage.createDirectory(newGroupPath);
      }

      // Read content and write to new location
      final content = await _storage.readString(oldRelativePath);
      if (content == null) return false;

      await _storage.writeString(newRelativePath, content);
      await _storage.delete(oldRelativePath);

      LogService().log('ContactService: Moved contact $callsign to ${newGroupPath ?? 'root'}');

      // Invalidate and rebuild fast.json cache (await to ensure UI sees updated data)
      invalidateSummaryCache();
      await rebuildFastJson();

      return true;
    } catch (e) {
      LogService().log('ContactService: Error moving contact: $e');
      return false;
    }
  }

  /// Find a contact file by callsign across all directories using storage
  /// Returns the relative path if found, null otherwise
  Future<String?> _findContactFileInStorage(String callsign) async {
    if (_appPath == null) return null;

    return await _findContactFileInStorageRecursive('', callsign);
  }

  Future<String?> _findContactFileInStorageRecursive(String relativePath, String callsign) async {
    final entries = await _storage.listDirectory(relativePath);

    for (final entry in entries) {
      if (!entry.isDirectory && entry.name == '$callsign.txt') {
        return entry.path;
      } else if (entry.isDirectory && !entry.name.startsWith('.')) {
        final found = await _findContactFileInStorageRecursive(entry.path, callsign);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// Delete profile picture for a contact
  Future<void> _deleteProfilePicture(String callsign) async {
    if (_appPath == null) return;

    // Check for common image extensions
    final extensions = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
    for (var ext in extensions) {
      final relativePath = 'media/$callsign.$ext';
      if (await _storage.exists(relativePath)) {
        await _storage.delete(relativePath);
        LogService().log('ContactService: Deleted profile picture for $callsign');
        break;
      }
    }
  }

  /// Load all groups (folders)
  Future<List<ContactGroup>> loadGroups() async {
    if (_appPath == null) return [];

    final groups = <ContactGroup>[];
    await _loadGroupsRecursiveFromStorage('', groups);

    return groups;
  }

  /// System folders to ignore at root level (not contact groups)
  static const _ignoredRootFolders = {'media', 'extra', 'profile-pictures'};

  /// Recursively load groups from storage
  Future<void> _loadGroupsRecursiveFromStorage(
    String relativePath,
    List<ContactGroup> groups,
  ) async {
    final entries = await _storage.listDirectory(relativePath);
    final isRootLevel = relativePath.isEmpty;

    for (var entry in entries) {
      if (entry.isDirectory) {
        final dirname = entry.name;

        // Skip hidden directories
        if (dirname.startsWith('.')) continue;

        // Skip system folders at root level only
        if (isRootLevel && _ignoredRootFolders.contains(dirname.toLowerCase())) continue;

        final groupPath = relativePath.isEmpty ? dirname : '$relativePath/$dirname';

        // Count contacts in this group (non-recursive)
        int contactCount = 0;
        final groupEntries = await _storage.listDirectory(groupPath);

        for (var file in groupEntries) {
          if (!file.isDirectory && file.name.endsWith('.txt')) {
            if (file.name != 'group.txt' && !file.name.startsWith('.')) {
              contactCount++;
            }
          }
        }

        // Load group metadata if exists
        final groupFilePath = '$groupPath/group.txt';
        String? description;
        String? created;
        String? author;

        if (await _storage.exists(groupFilePath)) {
          final metadata = await _parseGroupFileFromStorage(groupFilePath);
          description = metadata['description'];
          created = metadata['created'];
          author = metadata['author'];
        }

        groups.add(ContactGroup(
          name: dirname,
          path: groupPath,
          description: description,
          created: created,
          author: author,
          contactCount: contactCount,
        ));

        // Recurse into subdirectories
        await _loadGroupsRecursiveFromStorage(groupPath, groups);
      }
    }
  }

  /// Parse group.txt file from storage
  Future<Map<String, String?>> _parseGroupFileFromStorage(String relativePath) async {
    final content = await _storage.readString(relativePath);
    if (content == null) return {};

    final lines = content.split('\n');

    String? description;
    String? created;
    String? author;
    final descLines = <String>[];
    bool inDescription = false;

    for (var line in lines) {
      final trimmed = line.trim();

      if (trimmed.startsWith('CREATED:')) {
        created = trimmed.substring('CREATED:'.length).trim();
        inDescription = true;
      } else if (trimmed.startsWith('AUTHOR:')) {
        author = trimmed.substring('AUTHOR:'.length).trim();
      } else if (trimmed.startsWith('-->')) {
        break; // End of content
      } else if (inDescription && trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        descLines.add(line);
      }
    }

    if (descLines.isNotEmpty) {
      description = descLines.join('\n').trim();
    }

    return {
      'description': description,
      'created': created,
      'author': author,
    };
  }

  /// Create new group
  Future<bool> createGroup(String groupPath, {
    String? description,
    String? author,
  }) async {
    if (_appPath == null) return false;

    if (await _storage.exists(groupPath)) {
      LogService().log('ContactService: Group already exists: $groupPath');
      return false;
    }

    try {
      await _storage.createDirectory(groupPath);

      // Create group.txt if description or author provided
      if (description != null || author != null) {
        final buffer = StringBuffer();

        buffer.writeln('# GROUP: ${groupPath.split('/').last}');
        buffer.writeln();

        final now = DateTime.now();
        final timestamp = '${now.year.toString().padLeft(4, '0')}-'
            '${now.month.toString().padLeft(2, '0')}-'
            '${now.day.toString().padLeft(2, '0')} '
            '${now.hour.toString().padLeft(2, '0')}:'
            '${now.minute.toString().padLeft(2, '0')}_'
            '${now.second.toString().padLeft(2, '0')}';

        buffer.writeln('CREATED: $timestamp');
        if (author != null) {
          buffer.writeln('AUTHOR: $author');
        }
        buffer.writeln();

        if (description != null) {
          buffer.writeln(description);
          buffer.writeln();
        }

        await _storage.writeString('$groupPath/group.txt', buffer.toString());
      }

      LogService().log('ContactService: Created group $groupPath');
      return true;
    } catch (e) {
      LogService().log('ContactService: Error creating group: $e');
      return false;
    }
  }

  /// Delete group (only if empty)
  Future<bool> deleteGroup(String groupPath) async {
    if (_appPath == null) return false;

    if (!await _storage.exists(groupPath)) return false;

    // Check if group has any contacts or subdirectories
    final entries = await _storage.listDirectory(groupPath);

    for (var entry in entries) {
      if (!entry.isDirectory && entry.name.endsWith('.txt')) {
        if (entry.name != 'group.txt' && !entry.name.startsWith('.')) {
          // Has contacts
          LogService().log('ContactService: Cannot delete non-empty group $groupPath');
          return false;
        }
      } else if (entry.isDirectory && !entry.name.startsWith('.')) {
        // Has subdirectories
        return false;
      }
    }

    try {
      await _storage.deleteDirectory(groupPath, recursive: true);
      LogService().log('ContactService: Deleted group $groupPath');
      return true;
    } catch (e) {
      LogService().log('ContactService: Error deleting group: $e');
      return false;
    }
  }

  /// Delete group with all contacts inside (force delete)
  Future<bool> deleteGroupWithContacts(String groupPath) async {
    if (_appPath == null) return false;

    if (!await _storage.exists(groupPath)) return false;

    try {
      // First, delete profile pictures for all contacts in this group
      await _deleteGroupContactMediaFromStorage(groupPath);

      // Then delete the entire group directory
      await _storage.deleteDirectory(groupPath, recursive: true);
      LogService().log('ContactService: Deleted group with contacts: $groupPath');
      return true;
    } catch (e) {
      LogService().log('ContactService: Error deleting group with contacts: $e');
      return false;
    }
  }

  /// Helper to delete profile pictures for contacts in a directory using storage
  Future<void> _deleteGroupContactMediaFromStorage(String relativePath) async {
    final entries = await _storage.listDirectory(relativePath);

    for (var entry in entries) {
      if (!entry.isDirectory && entry.name.endsWith('.txt')) {
        if (entry.name != 'group.txt' && !entry.name.startsWith('.')) {
          // Extract callsign and delete profile picture
          final callsign = entry.name.replaceAll('.txt', '');
          await _deleteContactMedia(callsign);
        }
      } else if (entry.isDirectory && !entry.name.startsWith('.')) {
        // Recurse into subdirectories
        await _deleteGroupContactMediaFromStorage(entry.path);
      }
    }
  }

  /// Helper to delete media files for a contact using storage
  Future<void> _deleteContactMedia(String callsign) async {
    if (_appPath == null) return;

    final extensions = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
    for (var ext in extensions) {
      final relativePath = 'media/$callsign.$ext';
      if (await _storage.exists(relativePath)) {
        await _storage.delete(relativePath);
        LogService().log('ContactService: Deleted media for $callsign');
      }
    }
  }

  /// Delete ALL contacts and groups (destructive operation)
  Future<bool> deleteAllContactsAndGroups() async {
    if (_appPath == null) return false;

    try {
      // Delete all profile pictures in media folder
      if (await _storage.exists('media')) {
        await _storage.deleteDirectory('media', recursive: true);
        await _storage.createDirectory('media');
        LogService().log('ContactService: Cleared media folder');
      }

      // Delete all contacts and groups but keep hidden files
      final entries = await _storage.listDirectory('');
      for (var entry in entries) {
        // Keep hidden files/folders like .contact_metrics.txt
        if (!entry.name.startsWith('.')) {
          if (entry.isDirectory) {
            await _storage.deleteDirectory(entry.path, recursive: true);
          } else {
            await _storage.delete(entry.path);
          }
        }
      }

      LogService().log('ContactService: Deleted all contacts and groups');
      return true;
    } catch (e) {
      LogService().log('ContactService: Error deleting all contacts: $e');
      return false;
    }
  }

  /// Get count of all contacts (for confirmation dialog)
  Future<int> getTotalContactCount() async {
    final allContacts = await loadAllContactsRecursively();
    return allContacts.length;
  }

  /// Get count of all groups
  Future<int> getTotalGroupCount() async {
    final groups = await loadGroups();
    return groups.length;
  }

  /// Get profile picture file for a contact (synchronous)
  /// Returns File if profile picture exists, null otherwise.
  /// NOTE: Only works for filesystem storage (not encrypted).
  File? getProfilePictureFile(String callsign) {
    if (_appPath == null) return null;
    // Encrypted storage doesn't support direct file access
    if (_storage.isEncrypted) return null;

    final extensions = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
    for (var ext in extensions) {
      final file = File('$_appPath/media/$callsign.$ext');
      if (file.existsSync()) {
        return file;
      }
    }
    return null;
  }

  /// Get profile picture path for a contact (synchronous, cross-platform safe)
  /// Returns path if profile picture exists, null otherwise.
  /// NOTE: Only works for filesystem storage (not encrypted).
  String? getProfilePicturePath(String callsign) {
    final file = getProfilePictureFile(callsign);
    return file?.path;
  }

  /// Get profile picture path for a contact (async version)
  /// Works with both filesystem and encrypted storage.
  Future<String?> getProfilePicturePathAsync(String callsign) async {
    if (_appPath == null) return null;

    final extensions = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
    for (var ext in extensions) {
      final relativePath = 'media/$callsign.$ext';
      if (await _storage.exists(relativePath)) {
        return _storage.getAbsolutePath(relativePath);
      }
    }
    return null;
  }

  /// Get profile picture bytes for a contact (async, works with all storage types)
  Future<Uint8List?> getProfilePictureBytes(String callsign) async {
    if (_appPath == null) return null;

    final extensions = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
    for (var ext in extensions) {
      final relativePath = 'media/$callsign.$ext';
      if (await _storage.exists(relativePath)) {
        return _storage.readBytes(relativePath);
      }
    }
    return null;
  }

  /// Save profile picture for a contact
  Future<String?> saveProfilePicture(String callsign, File sourceFile) async {
    if (_appPath == null) return null;

    await _storage.createDirectory('media');

    // Get file extension
    final extension = sourceFile.path.split('.').last.toLowerCase();
    final relativePath = 'media/$callsign.$extension';

    try {
      await _storage.copyFromExternal(sourceFile.path, relativePath);
      LogService().log('ContactService: Saved profile picture for $callsign');
      return '$callsign.$extension'; // Return filename for PROFILE_PICTURE field
    } catch (e) {
      LogService().log('ContactService: Error saving profile picture: $e');
      return null;
    }
  }

  /// Save profile picture from bytes (for imported contacts)
  Future<String?> saveProfilePictureFromBytes(String callsign, Uint8List bytes, String extension) async {
    if (_appPath == null) return null;

    await _storage.createDirectory('media');
    final relativePath = 'media/$callsign.$extension';

    try {
      await _storage.writeBytes(relativePath, bytes);
      LogService().log('ContactService: Saved profile picture for $callsign from bytes');
      return '$callsign.$extension'; // Return filename for PROFILE_PICTURE field
    } catch (e) {
      LogService().log('ContactService: Error saving profile picture from bytes: $e');
      return null;
    }
  }

  // ============ Click Tracking ============

  /// Load click statistics
  Future<Map<String, int>> loadClickStats() async {
    if (_appPath == null) return {};

    final content = await _storage.readString('.click_stats.txt');
    if (content == null) return {};

    final stats = <String, int>{};

    try {
      final lines = content.split('\n');

      for (var line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

        final parts = trimmed.split('|');
        if (parts.length >= 2) {
          final callsign = parts[0];
          final count = int.tryParse(parts[1]) ?? 0;
          stats[callsign] = count;
        }
      }
    } catch (e) {
      LogService().log('ContactService: Error loading click stats: $e');
    }

    return stats;
  }

  /// Record a contact click
  Future<void> recordContactClick(String callsign) async {
    if (_appPath == null) return;

    final stats = await loadClickStats();
    stats[callsign] = (stats[callsign] ?? 0) + 1;

    await _saveClickStats(stats);
  }

  /// Save click statistics
  Future<void> _saveClickStats(Map<String, int> stats) async {
    if (_appPath == null) return;

    final buffer = StringBuffer();
    buffer.writeln('# CONTACT CLICK STATISTICS');
    buffer.writeln('# Format: CALLSIGN|count|last_clicked');

    final now = DateTime.now();
    final timestamp = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}_'
        '${now.second.toString().padLeft(2, '0')}';

    // Sort by count descending
    final sortedEntries = stats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    for (var entry in sortedEntries) {
      buffer.writeln('${entry.key}|${entry.value}|$timestamp');
    }

    try {
      await _storage.writeString('.click_stats.txt', buffer.toString());
    } catch (e) {
      LogService().log('ContactService: Error saving click stats: $e');
    }
  }

  /// Get top N most popular contacts based on metrics (views + interactions)
  /// Only returns contacts with score > 0
  /// Uses cached favorites for instant loading
  Future<List<Contact>> getTopContacts(int limit) async {
    if (_appPath == null) return [];

    // Load from favorites cache (instant)
    final favorites = await loadFavorites();

    if (favorites.isEmpty) {
      // No cache yet - rebuild it in background and return empty for now
      rebuildFavorites(limit: limit);
      return [];
    }

    // Convert summaries to placeholder contacts (instant)
    final topContacts = favorites.take(limit).map((summary) {
      return _placeholderContactFromSummary(summary);
    }).toList();

    return topContacts;
  }

  // ============ Favorites Cache ============

  /// In-memory favorites cache
  List<ContactSummary>? _favoritesCache;

  /// Load favorites from cache (instant)
  Future<List<ContactSummary>> loadFavorites() async {
    if (_appPath == null) return [];

    // Return in-memory cache if available
    if (_favoritesCache != null) {
      return _favoritesCache!;
    }

    final content = await _storage.readString('.favorites.json');
    if (content == null) {
      return [];
    }

    try {
      final sanitizedContent = _sanitizeUtf16(content);
      final List<dynamic> jsonList = json.decode(sanitizedContent);
      _favoritesCache = jsonList
          .map((item) => ContactSummary.fromJson(item as Map<String, dynamic>))
          .toList();
      return _favoritesCache!;
    } catch (e) {
      LogService().log('ContactService: Error loading favorites: $e');
      return [];
    }
  }

  /// Rebuild favorites cache from metrics (call after metrics change)
  Future<void> rebuildFavorites({int limit = 30}) async {
    if (_appPath == null) return;

    try {
      final metrics = await loadMetrics();
      if (metrics.contacts.isEmpty) {
        _favoritesCache = [];
        await _saveFavorites([]);
        return;
      }

      // Filter contacts with score > 0 and sort by score descending
      final sortedEntries = metrics.contacts.entries
          .where((e) => e.value.totalScore > 0)
          .toList()
        ..sort((a, b) => b.value.totalScore.compareTo(a.value.totalScore));

      if (sortedEntries.isEmpty) {
        _favoritesCache = [];
        await _saveFavorites([]);
        return;
      }

      // Load summaries from fast.json and filter to top callsigns
      final allSummaries = await loadContactSummaries();
      if (allSummaries == null) {
        // Fall back to loading contacts if no fast.json
        final allContacts = await loadAllContactsRecursively();
        final favorites = <ContactSummary>[];
        for (final entry in sortedEntries.take(limit)) {
          final contact = allContacts.where((c) => c.callsign == entry.key).firstOrNull;
          if (contact != null) {
            favorites.add(ContactSummary.fromContact(contact, popularityScore: entry.value.totalScore));
          }
        }
        _favoritesCache = favorites;
        await _saveFavorites(favorites);
        return;
      }

      // Build favorites list maintaining score order
      final summaryMap = {for (var s in allSummaries) s.callsign: s};
      final favorites = <ContactSummary>[];
      for (final entry in sortedEntries.take(limit)) {
        final summary = summaryMap[entry.key];
        if (summary != null) {
          favorites.add(ContactSummary(
            callsign: summary.callsign,
            displayName: summary.displayName,
            profilePicture: summary.profilePicture,
            groupPath: summary.groupPath,
            filePath: summary.filePath,
            popularityScore: entry.value.totalScore,
          ));
        }
      }

      _favoritesCache = favorites;
      await _saveFavorites(favorites);
    } catch (e) {
      LogService().log('ContactService: Error rebuilding favorites: $e');
    }
  }

  /// Save favorites to cache file
  Future<void> _saveFavorites(List<ContactSummary> favorites) async {
    if (_appPath == null) return;

    try {
      final jsonList = favorites.map((s) => s.toJson()).toList();
      await _storage.writeString('.favorites.json', json.encode(jsonList));
      LogService().log('ContactService: Saved ${favorites.length} favorites to cache');
    } catch (e) {
      LogService().log('ContactService: Error saving favorites: $e');
    }
  }

  /// Invalidate favorites cache
  void invalidateFavoritesCache() {
    _favoritesCache = null;
  }

  // ============ Contact Metrics ============

  /// Model for contact metrics
  ContactMetrics? _metricsCache;
  DateTime? _metricsCacheTime;
  static const _metricsCacheDuration = Duration(seconds: 5);

  /// Load contact metrics
  Future<ContactMetrics> loadMetrics() async {
    if (_appPath == null) return ContactMetrics();

    // Use cache if still valid
    final now = DateTime.now();
    if (_metricsCache != null &&
        _metricsCacheTime != null &&
        now.difference(_metricsCacheTime!) < _metricsCacheDuration) {
      return _metricsCache!;
    }

    final content = await _storage.readString('.contact_metrics.txt');
    if (content == null) {
      _metricsCache = ContactMetrics();
      _metricsCacheTime = now;
      return _metricsCache!;
    }

    try {
      final metrics = ContactMetrics.parse(content);
      _metricsCache = metrics;
      _metricsCacheTime = now;
      return metrics;
    } catch (e) {
      LogService().log('ContactService: Error loading metrics: $e');
      _metricsCache = ContactMetrics();
      _metricsCacheTime = now;
      return _metricsCache!;
    }
  }

  /// Save contact metrics
  Future<void> _saveMetrics(ContactMetrics metrics) async {
    if (_appPath == null) return;

    _metricsCache = metrics;
    _metricsCacheTime = DateTime.now();

    try {
      await _storage.writeString('.contact_metrics.txt', metrics.serialize());

      // Rebuild favorites cache in background (don't await)
      invalidateFavoritesCache();
      rebuildFavorites();
    } catch (e) {
      LogService().log('ContactService: Error saving metrics: $e');
    }
  }

  /// Record a contact view (when viewing contact details)
  Future<void> recordContactView(String callsign) async {
    if (_appPath == null) return;

    final metrics = await loadMetrics();
    metrics.recordView(callsign);
    await _saveMetrics(metrics);
  }

  /// Record a contact method interaction (phone call, email click, etc.)
  /// [type] is one of: phone, email, website, address, social
  /// [index] is the index of the value in the contact's list (e.g., first phone = 0)
  /// [value] is the actual value (e.g., phone number) for more accurate tracking
  Future<void> recordMethodInteraction(
    String callsign,
    String type,
    int index, {
    String? value,
  }) async {
    if (_appPath == null) return;

    final metrics = await loadMetrics();
    metrics.recordInteraction(callsign, type, index, value: value);
    await _saveMetrics(metrics);
  }

  /// Record an event association for a contact
  Future<void> recordEventAssociation(String callsign) async {
    if (_appPath == null) return;

    final metrics = await loadMetrics();
    metrics.recordEvent(callsign);
    await _saveMetrics(metrics);
  }

  /// Record event associations for multiple contacts
  Future<void> recordEventAssociations(List<String> callsigns) async {
    if (_appPath == null || callsigns.isEmpty) return;

    final metrics = await loadMetrics();
    for (final callsign in callsigns) {
      metrics.recordEvent(callsign);
    }
    await _saveMetrics(metrics);
  }

  /// Get metrics for a specific contact
  Future<ContactCallsignMetrics?> getContactMetrics(String callsign) async {
    final metrics = await loadMetrics();
    return metrics.contacts[callsign];
  }

  /// Get interaction count for a specific method value
  Future<int> getMethodInteractionCount(
    String callsign,
    String type,
    int index, {
    String? value,
  }) async {
    final metrics = await loadMetrics();
    final contactMetrics = metrics.contacts[callsign];
    if (contactMetrics == null) return 0;
    return contactMetrics.getInteractionCount(type, index, value: value);
  }

  /// Sort contacts by popularity (views + interactions)
  Future<List<Contact>> sortContactsByPopularity(List<Contact> contacts) async {
    final metrics = await loadMetrics();

    // Create a copy to sort
    final sorted = List<Contact>.from(contacts);

    sorted.sort((a, b) {
      final aMetrics = metrics.contacts[a.callsign];
      final bMetrics = metrics.contacts[b.callsign];

      final aScore = aMetrics?.totalScore ?? 0;
      final bScore = bMetrics?.totalScore ?? 0;

      // Sort descending (most popular first)
      if (bScore != aScore) {
        return bScore.compareTo(aScore);
      }

      // If same score, sort alphabetically
      return a.displayName.compareTo(b.displayName);
    });

    return sorted;
  }

  // ============ Folder Management ============

  /// Rename a group/folder
  /// Note: ProfileStorage doesn't support rename, so this copies all files and deletes old folder
  Future<bool> renameGroup(String oldPath, String newName) async {
    if (_appPath == null) return false;

    if (!await _storage.exists(oldPath)) return false;

    // Build new path (same parent, new name)
    final pathParts = oldPath.split('/');
    pathParts[pathParts.length - 1] = newName;
    final newPath = pathParts.join('/');

    if (await _storage.exists(newPath)) {
      LogService().log('ContactService: Cannot rename - destination already exists: $newPath');
      return false;
    }

    try {
      // Copy all files from old to new location
      await _copyDirectoryContents(oldPath, newPath);

      // Delete old folder
      await _storage.deleteDirectory(oldPath, recursive: true);

      LogService().log('ContactService: Renamed group $oldPath to $newPath');
      return true;
    } catch (e) {
      LogService().log('ContactService: Error renaming group: $e');
      return false;
    }
  }

  /// Helper to copy directory contents recursively
  Future<void> _copyDirectoryContents(String sourcePath, String destPath) async {
    await _storage.createDirectory(destPath);

    final entries = await _storage.listDirectory(sourcePath);
    for (final entry in entries) {
      final sourceEntryPath = entry.path;
      final destEntryPath = destPath.isEmpty
          ? entry.name
          : '$destPath/${entry.name}';

      if (entry.isDirectory) {
        await _copyDirectoryContents(sourceEntryPath, destEntryPath);
      } else {
        final content = await _storage.readBytes(sourceEntryPath);
        if (content != null) {
          await _storage.writeBytes(destEntryPath, content);
        }
      }
    }
  }

  // ============ History Entries ============

  /// Add a history entry to a contact
  Future<String?> addHistoryEntry(
    String callsign,
    ContactHistoryEntry entry, {
    String? groupPath,
  }) async {
    final contact = await loadContact(callsign, groupPath: groupPath);
    if (contact == null) return 'Contact not found';

    final updatedEntries = [...contact.historyEntries, entry];
    updatedEntries.sort(); // Sort by timestamp descending

    final updatedContact = contact.copyWith(historyEntries: updatedEntries);
    return await saveContact(updatedContact, groupPath: groupPath);
  }

  /// Edit a history entry
  Future<String?> editHistoryEntry(
    String callsign,
    String entryTimestamp,
    String newContent, {
    String? groupPath,
    ContactHistoryEntryType? newType,
    Map<String, String>? newMetadata,
  }) async {
    final contact = await loadContact(callsign, groupPath: groupPath);
    if (contact == null) return 'Contact not found';

    final updatedEntries = contact.historyEntries.map((e) {
      if (e.timestamp == entryTimestamp) {
        return ContactHistoryEntry(
          author: e.author,
          timestamp: e.timestamp,
          content: newContent,
          type: newType ?? e.type,
          metadata: newMetadata ?? e.metadata,
        );
      }
      return e;
    }).toList();

    final updatedContact = contact.copyWith(historyEntries: updatedEntries);
    return await saveContact(updatedContact, groupPath: groupPath);
  }

  /// Delete a history entry
  Future<String?> deleteHistoryEntry(
    String callsign,
    String entryTimestamp, {
    String? groupPath,
  }) async {
    final contact = await loadContact(callsign, groupPath: groupPath);
    if (contact == null) return 'Contact not found';

    final updatedEntries = contact.historyEntries
        .where((e) => e.timestamp != entryTimestamp)
        .toList();

    final updatedContact = contact.copyWith(historyEntries: updatedEntries);
    return await saveContact(updatedContact, groupPath: groupPath);
  }
}

/// Metrics for a single contact
class ContactCallsignMetrics {
  int views = 0;
  int totalInteractions = 0;
  int events = 0;
  String? lastAccessed;

  /// Method interactions: key is "type:index" or "type:value", value is count
  /// e.g., "phone:0" -> 5, "phone:+1234567890" -> 5
  final Map<String, int> methodInteractions = {};

  ContactCallsignMetrics();

  /// Get total popularity score (views + interactions + events weighted)
  int get totalScore => views + (totalInteractions * 2) + (events * 3);

  /// Record a view
  void recordView() {
    views++;
    _updateLastAccessed();
  }

  /// Record an event association
  void recordEvent() {
    events++;
    _updateLastAccessed();
  }

  /// Record an interaction with a specific method
  void recordInteraction(String type, int index, {String? value}) {
    totalInteractions++;
    _updateLastAccessed();

    // Track by index
    final indexKey = '$type:$index';
    methodInteractions[indexKey] = (methodInteractions[indexKey] ?? 0) + 1;

    // Also track by value if provided (for more accurate matching)
    if (value != null && value.isNotEmpty) {
      final valueKey = '$type:$value';
      methodInteractions[valueKey] = (methodInteractions[valueKey] ?? 0) + 1;
    }
  }

  /// Get interaction count for a specific method
  int getInteractionCount(String type, int index, {String? value}) {
    // Try to get by value first (more accurate)
    if (value != null && value.isNotEmpty) {
      final valueKey = '$type:$value';
      final byValue = methodInteractions[valueKey];
      if (byValue != null) return byValue;
    }

    // Fall back to index
    final indexKey = '$type:$index';
    return methodInteractions[indexKey] ?? 0;
  }

  /// Get all interaction counts for a type (e.g., all phone interactions)
  Map<String, int> getTypeInteractions(String type) {
    final result = <String, int>{};
    for (var entry in methodInteractions.entries) {
      if (entry.key.startsWith('$type:')) {
        result[entry.key] = entry.value;
      }
    }
    return result;
  }

  void _updateLastAccessed() {
    final now = DateTime.now();
    lastAccessed = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}_'
        '${now.second.toString().padLeft(2, '0')}';
  }

  /// Serialize to string format
  String serialize() {
    final methodsStr = methodInteractions.entries
        .map((e) => '${e.key}=${e.value}')
        .join(',');
    return '$views|$totalInteractions|${lastAccessed ?? ''}|$methodsStr|$events';
  }

  /// Parse from string format
  static ContactCallsignMetrics parse(String data) {
    final metrics = ContactCallsignMetrics();
    final parts = data.split('|');

    if (parts.isNotEmpty) metrics.views = int.tryParse(parts[0]) ?? 0;
    if (parts.length > 1) metrics.totalInteractions = int.tryParse(parts[1]) ?? 0;
    if (parts.length > 2 && parts[2].isNotEmpty) metrics.lastAccessed = parts[2];

    if (parts.length > 3 && parts[3].isNotEmpty) {
      final methodParts = parts[3].split(',');
      for (var method in methodParts) {
        final kv = method.split('=');
        if (kv.length == 2) {
          metrics.methodInteractions[kv[0]] = int.tryParse(kv[1]) ?? 0;
        }
      }
    }

    // Parse events count (added in newer version, backward compatible)
    if (parts.length > 4) metrics.events = int.tryParse(parts[4]) ?? 0;

    return metrics;
  }
}

/// Collection of all contact metrics
class ContactMetrics {
  final Map<String, ContactCallsignMetrics> contacts = {};

  ContactMetrics();

  /// Record a view for a contact
  void recordView(String callsign) {
    contacts.putIfAbsent(callsign, () => ContactCallsignMetrics());
    contacts[callsign]!.recordView();
  }

  /// Record an interaction for a contact
  void recordInteraction(String callsign, String type, int index, {String? value}) {
    contacts.putIfAbsent(callsign, () => ContactCallsignMetrics());
    contacts[callsign]!.recordInteraction(type, index, value: value);
  }

  /// Record an event association for a contact
  void recordEvent(String callsign) {
    contacts.putIfAbsent(callsign, () => ContactCallsignMetrics());
    contacts[callsign]!.recordEvent();
  }

  /// Serialize to file content
  String serialize() {
    final buffer = StringBuffer();
    buffer.writeln('# CONTACT METRICS');
    buffer.writeln('# Format: CALLSIGN|views|total_interactions|last_accessed|method_interactions');
    buffer.writeln('# method_interactions: type:index=count,type:value=count,...');
    buffer.writeln();

    // Sort by total score descending
    final sortedEntries = contacts.entries.toList()
      ..sort((a, b) => b.value.totalScore.compareTo(a.value.totalScore));

    for (var entry in sortedEntries) {
      buffer.writeln('${entry.key}|${entry.value.serialize()}');
    }

    return buffer.toString();
  }

  /// Parse from file content
  static ContactMetrics parse(String content) {
    final metrics = ContactMetrics();
    final lines = content.split('\n');

    for (var line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final pipeIndex = trimmed.indexOf('|');
      if (pipeIndex == -1) continue;

      final callsign = trimmed.substring(0, pipeIndex);
      final data = trimmed.substring(pipeIndex + 1);

      metrics.contacts[callsign] = ContactCallsignMetrics.parse(data);
    }

    return metrics;
  }
}
