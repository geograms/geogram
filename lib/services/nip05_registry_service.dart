/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NIP-05 Registry Service - Manages nickname to npub registrations
 * for serving .well-known/nostr.json identity verification
 */

import 'dart:convert';
import 'dart:io';

/// A NIP-05 nickname registration binding a nickname to an npub
class Nip05Registration {
  final String nickname;
  final String npub;
  final DateTime registeredAt;
  final DateTime expiresAt;

  Nip05Registration({
    required this.nickname,
    required this.npub,
    required this.registeredAt,
  }) : expiresAt = registeredAt.add(const Duration(days: 365));

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
        'nickname': nickname,
        'npub': npub,
        'registeredAt': registeredAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
      };

  factory Nip05Registration.fromJson(Map<String, dynamic> json) {
    return Nip05Registration(
      nickname: json['nickname'] as String,
      npub: json['npub'] as String,
      registeredAt: DateTime.parse(json['registeredAt'] as String),
    );
  }
}

/// Service for managing NIP-05 nickname registrations
/// Prevents nickname spoofing by binding nicknames to npubs for 12 months
class Nip05RegistryService {
  static final Nip05RegistryService _instance = Nip05RegistryService._();
  factory Nip05RegistryService() => _instance;
  Nip05RegistryService._();

  final Map<String, Nip05Registration> _registrations = {};
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

  /// Register or renew a nickname for an npub
  /// Returns true if successful, false if nickname is taken or reserved
  bool registerNickname(String nickname, String npub) {
    final normalizedNickname = nickname.toLowerCase();

    // Check if reserved (only station owner can use these)
    if (reservedNicknames.contains(normalizedNickname)) {
      if (_stationOwnerNpub == null || npub != _stationOwnerNpub) {
        return false; // Reserved nickname, not station owner
      }
    }

    final existing = _registrations[normalizedNickname];

    if (existing != null && !existing.isExpired && existing.npub != npub) {
      // Nickname taken by someone else and not expired
      return false;
    }

    // Register or renew
    _registrations[normalizedNickname] = Nip05Registration(
      nickname: normalizedNickname,
      npub: npub,
      registeredAt: DateTime.now(),
    );
    _saveToFile();
    return true;
  }

  /// Get registration for a nickname if valid (not expired)
  Nip05Registration? getRegistration(String nickname) {
    final reg = _registrations[nickname.toLowerCase()];
    if (reg != null && !reg.isExpired) {
      return reg;
    }
    return null; // Expired or not found
  }

  /// Check if a nickname would collide with existing registration
  /// Returns null if no collision, or the conflicting npub if collision exists
  /// Used to reject connections before they're established
  String? checkCollision(String nickname, String npub) {
    final normalizedNickname = nickname.toLowerCase();
    final existing = _registrations[normalizedNickname];

    if (existing != null && !existing.isExpired && existing.npub != npub) {
      return existing.npub; // Collision: different npub owns this name
    }
    return null; // No collision
  }

  /// Get all valid (non-expired) registrations
  Map<String, String> getAllValidRegistrations() {
    final result = <String, String>{};
    _registrations.forEach((nickname, reg) {
      if (!reg.isExpired) {
        result[nickname] = reg.npub;
      }
    });
    return result;
  }

  /// Get all nicknames registered to a specific npub
  /// Supports multiple nicknames per npub (e.g., callsign + nickname)
  List<String> getNicknamesForNpub(String npub) {
    return _registrations.entries
        .where((e) => e.value.npub == npub && !e.value.isExpired)
        .map((e) => e.key)
        .toList();
  }

  /// Remove a registration by nickname (admin operation)
  /// Returns true if found and removed, false if not found
  bool removeRegistration(String nickname) {
    final normalizedNickname = nickname.toLowerCase();
    final removed = _registrations.remove(normalizedNickname);
    if (removed != null) {
      _saveToFile();
      return true;
    }
    return false;
  }

  /// Clean up expired registrations from storage
  /// Called on startup and can be called periodically
  void purgeExpiredRegistrations() {
    final expired = _registrations.entries
        .where((e) => e.value.isExpired)
        .map((e) => e.key)
        .toList();

    for (final nickname in expired) {
      _registrations.remove(nickname);
    }

    if (expired.isNotEmpty) {
      _saveToFile();
    }
  }

  /// Load registrations from disk
  Future<void> loadFromFile() async {
    final file = File(_filePath);
    if (!await file.exists()) return;

    try {
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final registrations = json['registrations'] as List?;

      if (registrations != null) {
        _registrations.clear();
        for (final reg in registrations) {
          final registration =
              Nip05Registration.fromJson(reg as Map<String, dynamic>);
          _registrations[registration.nickname] = registration;
        }
      }

      // Clean up expired entries on load
      purgeExpiredRegistrations();
    } catch (e) {
      // Ignore errors, start fresh
    }
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
