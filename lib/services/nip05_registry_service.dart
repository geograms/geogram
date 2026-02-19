/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NIP-05 Registry Service - Manages identity registrations (callsign + optional nickname)
 * for serving .well-known/nostr.json identity verification.
 * One record per pubkey, keyed by npub.
 */

import 'dart:convert';
import 'dart:io';

/// A NIP-05 identity registration binding a callsign (and optional nickname) to an npub
class Nip05Registration {
  final String callsign;
  final String? nickname;
  final String npub;
  final DateTime registeredAt;
  final DateTime expiresAt;

  Nip05Registration({
    required this.callsign,
    this.nickname,
    required this.npub,
    required this.registeredAt,
  }) : expiresAt = registeredAt.add(const Duration(days: 365));

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// All names this registration exposes (callsign + nickname if different)
  List<String> get names {
    final result = [callsign.toLowerCase()];
    if (nickname != null && nickname!.toLowerCase() != callsign.toLowerCase()) {
      result.add(nickname!.toLowerCase());
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
        'callsign': callsign,
        if (nickname != null) 'nickname': nickname,
        'npub': npub,
        'registeredAt': registeredAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
      };

  factory Nip05Registration.fromJson(Map<String, dynamic> json) {
    return Nip05Registration(
      callsign: json['callsign'] as String,
      nickname: json['nickname'] as String?,
      npub: json['npub'] as String,
      registeredAt: DateTime.parse(json['registeredAt'] as String),
    );
  }
}

/// Service for managing NIP-05 identity registrations
/// One record per npub, with callsign + optional nickname
class Nip05RegistryService {
  static final Nip05RegistryService _instance = Nip05RegistryService._();
  factory Nip05RegistryService() => _instance;
  Nip05RegistryService._();

  /// Primary storage: npub → registration
  final Map<String, Nip05Registration> _registrations = {};

  /// Secondary index: lowercase name → npub (for fast name lookups)
  final Map<String, String> _nameIndex = {};

  bool _initialized = false;

  // Reserved nicknames for station owner only
  static const reservedNicknames = [
    'admin',
    'mail',
    'support',
    'abuse',
    'security',
    'noreply',
    'postmaster',
    'webmaster',
    'hostmaster',
    'root',
    'info',
    'help',
  ];

  String? _stationOwnerNpub;
  String _profileDir = '.';

  /// Set the station owner's npub (only they can use reserved nicknames)
  void setStationOwner(String npub) => _stationOwnerNpub = npub;

  /// Set the profile directory for storing the registry file
  void setProfileDirectory(String dir) => _profileDir = dir;

  /// Get the file path for the registry JSON
  String get _filePath => '$_profileDir/nip05_registry.json';

  /// Initialize the service by loading from disk
  Future<void> init() async {
    if (_initialized) return;
    await loadFromFile();
    _initialized = true;
  }

  /// Rebuild the _nameIndex from _registrations
  void _rebuildNameIndex() {
    _nameIndex.clear();
    for (final entry in _registrations.entries) {
      if (!entry.value.isExpired) {
        for (final name in entry.value.names) {
          _nameIndex[name] = entry.key; // entry.key is npub
        }
      }
    }
  }

  /// Register or update an identity (callsign + optional nickname) for an npub.
  /// Returns true if successful, false if a name is taken by a different npub or reserved.
  bool registerIdentity(String callsign, String npub, {String? nickname}) {
    final normalizedCallsign = callsign.toLowerCase();
    final normalizedNickname =
        (nickname != null && nickname.toLowerCase() != normalizedCallsign)
            ? nickname.toLowerCase()
            : null;

    // Check reserved names
    for (final name in [normalizedCallsign, if (normalizedNickname != null) normalizedNickname]) {
      if (reservedNicknames.contains(name)) {
        if (_stationOwnerNpub == null || npub != _stationOwnerNpub) {
          return false;
        }
      }
    }

    // Check collisions for both names
    for (final name in [normalizedCallsign, if (normalizedNickname != null) normalizedNickname]) {
      final existingNpub = _nameIndex[name];
      if (existingNpub != null && existingNpub != npub) {
        final existingReg = _registrations[existingNpub];
        if (existingReg != null && !existingReg.isExpired) {
          return false; // Name taken by different npub
        }
      }
    }

    // Remove old name index entries for this npub (in case nickname changed)
    final existingReg = _registrations[npub];
    if (existingReg != null) {
      for (final name in existingReg.names) {
        _nameIndex.remove(name);
      }
    }

    // Create/update registration
    _registrations[npub] = Nip05Registration(
      callsign: normalizedCallsign,
      nickname: normalizedNickname,
      npub: npub,
      registeredAt: DateTime.now(),
    );

    // Update name index
    _nameIndex[normalizedCallsign] = npub;
    if (normalizedNickname != null) {
      _nameIndex[normalizedNickname] = npub;
    }

    _saveToFile();
    return true;
  }

  /// Backward-compatible: register a single name for an npub
  /// Calls registerIdentity with the name as callsign
  bool registerNickname(String nickname, String npub) {
    // If there's already a registration for this npub, preserve existing fields
    final existing = _registrations[npub];
    if (existing != null && !existing.isExpired) {
      final normalizedName = nickname.toLowerCase();
      // If this name matches the existing callsign, just renew
      if (normalizedName == existing.callsign.toLowerCase()) {
        return registerIdentity(existing.callsign, npub,
            nickname: existing.nickname);
      }
      // If this name matches the existing nickname, just renew
      if (existing.nickname != null &&
          normalizedName == existing.nickname!.toLowerCase()) {
        return registerIdentity(existing.callsign, npub,
            nickname: existing.nickname);
      }
      // New name — treat as nickname update
      return registerIdentity(existing.callsign, npub, nickname: nickname);
    }
    return registerIdentity(nickname, npub);
  }

  /// Get registration for a name if valid (not expired)
  Nip05Registration? getRegistration(String name) {
    final npub = _nameIndex[name.toLowerCase()];
    if (npub == null) return null;
    final reg = _registrations[npub];
    if (reg != null && !reg.isExpired) {
      return reg;
    }
    return null;
  }

  /// Check if a name would collide with existing registration
  /// Returns null if no collision, or the conflicting npub if collision exists
  String? checkCollision(String name, String npub) {
    final normalizedName = name.toLowerCase();
    final existingNpub = _nameIndex[normalizedName];

    if (existingNpub != null && existingNpub != npub) {
      final reg = _registrations[existingNpub];
      if (reg != null && !reg.isExpired) {
        return existingNpub;
      }
    }
    return null;
  }

  /// Get all valid (non-expired) registrations as name→npub map
  /// Emits entries for both callsign and nickname from each record
  Map<String, String> getAllValidRegistrations() {
    final result = <String, String>{};
    for (final reg in _registrations.values) {
      if (!reg.isExpired) {
        for (final name in reg.names) {
          result[name] = reg.npub;
        }
      }
    }
    return result;
  }

  /// Get all names registered to a specific npub
  List<String> getNicknamesForNpub(String npub) {
    final reg = _registrations[npub];
    if (reg != null && !reg.isExpired) {
      return reg.names;
    }
    return [];
  }

  /// Remove a registration by name (admin operation)
  /// Removes the entire npub record that owns this name
  bool removeRegistration(String name) {
    final normalizedName = name.toLowerCase();
    final npub = _nameIndex[normalizedName];
    if (npub == null) return false;

    final reg = _registrations.remove(npub);
    if (reg != null) {
      for (final n in reg.names) {
        _nameIndex.remove(n);
      }
      _saveToFile();
      return true;
    }
    return false;
  }

  /// Clean up expired registrations from storage
  void purgeExpiredRegistrations() {
    final expired = _registrations.entries
        .where((e) => e.value.isExpired)
        .map((e) => e.key)
        .toList();

    for (final npub in expired) {
      _registrations.remove(npub);
    }

    if (expired.isNotEmpty) {
      _rebuildNameIndex();
      _saveToFile();
    }
  }

  /// Load registrations from disk (with migration from old format)
  Future<void> loadFromFile() async {
    final file = File(_filePath);
    if (!await file.exists()) return;

    try {
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final registrations = json['registrations'] as List?;

      if (registrations != null) {
        _registrations.clear();

        // Check if this is old format (has 'nickname' key but no 'callsign' key)
        final isOldFormat = registrations.isNotEmpty &&
            registrations.first is Map &&
            (registrations.first as Map).containsKey('nickname') &&
            !(registrations.first as Map).containsKey('callsign');

        if (isOldFormat) {
          _migrateOldFormat(registrations);
        } else {
          for (final reg in registrations) {
            final registration =
                Nip05Registration.fromJson(reg as Map<String, dynamic>);
            _registrations[registration.npub] = registration;
          }
        }
      }

      _rebuildNameIndex();
      purgeExpiredRegistrations();
    } catch (e) {
      // Ignore errors, start fresh
    }
  }

  /// Migrate old format (keyed by nickname) to new format (keyed by npub)
  void _migrateOldFormat(List registrations) {
    // Group old entries by npub
    final byNpub = <String, List<Map<String, dynamic>>>{};
    for (final reg in registrations) {
      final map = reg as Map<String, dynamic>;
      final npub = map['npub'] as String;
      byNpub.putIfAbsent(npub, () => []).add(map);
    }

    // Merge entries sharing the same npub
    for (final entry in byNpub.entries) {
      final npub = entry.key;
      final entries = entry.value;

      if (entries.length == 1) {
        // Single entry — use the nickname as callsign
        final name = entries[0]['nickname'] as String;
        _registrations[npub] = Nip05Registration(
          callsign: name,
          npub: npub,
          registeredAt:
              DateTime.parse(entries[0]['registeredAt'] as String),
        );
      } else {
        // Multiple entries — figure out which is callsign vs nickname
        // Callsigns match pattern: letter + digit + 4 alphanum (e.g. x1su86)
        String? callsign;
        String? nickname;
        DateTime latestDate = DateTime(2000);

        for (final e in entries) {
          final name = e['nickname'] as String;
          final date = DateTime.parse(e['registeredAt'] as String);
          if (date.isAfter(latestDate)) latestDate = date;

          if (_looksLikeCallsign(name)) {
            callsign = name;
          } else {
            nickname = name;
          }
        }

        // Fallback: if no callsign detected, use first entry
        callsign ??= entries[0]['nickname'] as String;
        if (nickname == callsign) nickname = null;

        _registrations[npub] = Nip05Registration(
          callsign: callsign,
          nickname: nickname,
          npub: npub,
          registeredAt: latestDate,
        );
      }
    }

    // Save migrated format
    _saveToFile();
  }

  /// Heuristic: callsigns are typically letter + digit + alphanums (e.g. x1su86)
  static bool _looksLikeCallsign(String name) {
    final lower = name.toLowerCase();
    if (lower.length < 4 || lower.length > 8) return false;
    // Pattern: starts with letter, second char is digit
    return RegExp(r'^[a-z]\d[a-z0-9]+$').hasMatch(lower);
  }

  /// Save registrations to disk
  Future<void> _saveToFile() async {
    final file = File(_filePath);
    final json = {
      'registrations': _registrations.values.map((r) => r.toJson()).toList(),
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
  }
}
