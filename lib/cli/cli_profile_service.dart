// CLI Profile Service - Uses shared config.json for profile storage
// This ensures CLI and Desktop versions share the same profile data
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'cli_config_service.dart';
import '../models/profile.dart';
import '../util/nostr_key_generator.dart';
import 'pure_storage_config.dart';

// Re-export ProfileType for CLI usage
export '../models/profile.dart' show ProfileType;

/// Cached/contacted device (not owned by us)
class CachedDevice {
  final String callsign;
  final String? npub;
  final String? url;
  final String? description;
  final String? type; // 'client', 'relay', 'unknown'
  DateTime lastSeen;
  DateTime firstSeen;

  CachedDevice({
    required this.callsign,
    this.npub,
    this.url,
    this.description,
    this.type,
    DateTime? lastSeen,
    DateTime? firstSeen,
  }) : lastSeen = lastSeen ?? DateTime.now(),
       firstSeen = firstSeen ?? DateTime.now();

  factory CachedDevice.fromJson(Map<String, dynamic> json) {
    return CachedDevice(
      callsign: json['callsign'] as String,
      npub: json['npub'] as String?,
      url: json['url'] as String?,
      description: json['description'] as String?,
      type: json['type'] as String?,
      lastSeen: json['lastSeen'] != null
          ? DateTime.tryParse(json['lastSeen'] as String)
          : null,
      firstSeen: json['firstSeen'] != null
          ? DateTime.tryParse(json['firstSeen'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'callsign': callsign,
    if (npub != null) 'npub': npub,
    if (url != null) 'url': url,
    if (description != null) 'description': description,
    if (type != null) 'type': type,
    'lastSeen': lastSeen.toIso8601String(),
    'firstSeen': firstSeen.toIso8601String(),
  };
}

/// CLI Profile Service - manages profiles using shared config.json
/// This ensures profiles created in CLI are visible in Desktop and vice versa
class CliProfileService {
  static final CliProfileService _instance = CliProfileService._internal();
  factory CliProfileService() => _instance;
  CliProfileService._internal();

  List<Profile> _profiles = [];
  List<CachedDevice> _cachedDevices = [];
  String? _activeProfileId;
  File? _devicesFile;
  bool _initialized = false;

  List<Profile> get profiles => List.unmodifiable(_profiles);
  List<CachedDevice> get cachedDevices => List.unmodifiable(_cachedDevices);

  Profile? get activeProfile {
    if (_activeProfileId == null) return null;
    try {
      return _profiles.firstWhere((p) => p.id == _activeProfileId);
    } catch (_) {
      return _profiles.isNotEmpty ? _profiles.first : null;
    }
  }

  /// Get all owned callsigns (profiles we have private keys for)
  Set<String> get ownedCallsigns => _profiles.map((p) => p.callsign).toSet();

  /// Check if a callsign is owned by us
  bool isOwnedCallsign(String callsign) {
    return _profiles.any((p) => p.callsign.toLowerCase() == callsign.toLowerCase());
  }

  /// Get profile by callsign
  Profile? getProfileByCallsign(String callsign) {
    try {
      return _profiles.firstWhere(
        (p) => p.callsign.toLowerCase() == callsign.toLowerCase()
      );
    } catch (_) {
      return null;
    }
  }

  /// Check if a profile is a relay we manage
  bool isManagedRelay(String callsign) {
    final profile = getProfileByCallsign(callsign);
    return profile != null && profile.isRelay;
  }

  Future<void> initialize() async {
    if (_initialized) return;

    final storageConfig = PureStorageConfig();
    if (!storageConfig.isInitialized) {
      throw StateError('PureStorageConfig must be initialized first');
    }

    // Initialize CLI config service
    await CliConfigService().init();

    // Cached devices still use separate file (not shared with desktop)
    _devicesFile = File('${storageConfig.baseDir}/cached_devices.json');

    await _loadProfiles();
    await _loadCachedDevices();
    _initialized = true;
  }

  Future<void> _loadProfiles() async {
    try {
      final config = CliConfigService().getAll();

      // Load profiles from shared config
      if (config.containsKey('profiles') && config['profiles'] is List) {
        final profilesList = config['profiles'] as List;
        _profiles = profilesList
            .map((p) => Profile.fromJson(p as Map<String, dynamic>))
            .toList();
        _activeProfileId = config['activeProfileId'] as String?;

        // Ensure active profile is valid
        if (_activeProfileId != null &&
            !_profiles.any((p) => p.id == _activeProfileId)) {
          _activeProfileId = _profiles.isNotEmpty ? _profiles.first.id : null;
        }

      }
    } catch (e) {
      // Silent error - profile loading is not critical
      _profiles = [];
    }
  }

  Future<void> _loadCachedDevices() async {
    try {
      if (await _devicesFile!.exists()) {
        final content = await _devicesFile!.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;

        final devicesList = json['devices'] as List<dynamic>? ?? [];
        _cachedDevices = devicesList
            .map((d) => CachedDevice.fromJson(d as Map<String, dynamic>))
            .toList();

      }
    } catch (e) {
      // Silent error - cached devices loading is not critical
      _cachedDevices = [];
    }
  }

  Future<void> _saveProfiles() async {
    try {
      // Save to shared config.json (same file as desktop ConfigService)
      final configService = CliConfigService();
      configService.set('profiles', _profiles.map((p) => p.toJson()).toList());
      configService.set('activeProfileId', _activeProfileId);

      // Also maintain legacy 'profile' key for backward compatibility
      final active = activeProfile;
      if (active != null) {
        configService.set('profile', active.toJson());
      }

      // Flush to disk immediately to ensure changes are persisted
      await configService.flush();
    } catch (_) {
      // Silent error - will retry on next save
    }
  }

  Future<void> _saveCachedDevices() async {
    try {
      final json = {
        'devices': _cachedDevices.map((d) => d.toJson()).toList(),
      };
      await _devicesFile!.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json)
      );
    } catch (_) {
      // Silent error - will retry on next save
    }
  }

  /// Add a new profile
  Future<void> addProfile(Profile profile) async {
    _profiles.add(profile);
    if (_activeProfileId == null) {
      _activeProfileId = profile.id;
    }
    await _saveProfiles();

    // Create device folder for the profile
    await _createDeviceFolder(profile.callsign);
  }

  /// Update an existing profile
  Future<void> updateProfile(Profile profile) async {
    final index = _profiles.indexWhere((p) => p.id == profile.id);
    if (index >= 0) {
      _profiles[index] = profile;
      await _saveProfiles();
    }
  }

  /// Delete a profile
  Future<void> deleteProfile(String profileId) async {
    _profiles.removeWhere((p) => p.id == profileId);
    if (_activeProfileId == profileId) {
      _activeProfileId = _profiles.isNotEmpty ? _profiles.first.id : null;
    }
    await _saveProfiles();
  }

  /// Set active profile
  Future<void> setActiveProfile(String profileId) async {
    if (_profiles.any((p) => p.id == profileId)) {
      _activeProfileId = profileId;
      await _saveProfiles();
    }
  }

  /// Add or update a cached device
  Future<void> cacheDevice(CachedDevice device) async {
    // Don't cache our own devices
    if (isOwnedCallsign(device.callsign)) return;

    final index = _cachedDevices.indexWhere(
      (d) => d.callsign.toLowerCase() == device.callsign.toLowerCase()
    );
    if (index >= 0) {
      _cachedDevices[index].lastSeen = DateTime.now();
    } else {
      _cachedDevices.add(device);
    }
    await _saveCachedDevices();
  }

  /// Create device folder in the devices directory
  Future<void> _createDeviceFolder(String callsign) async {
    final storageConfig = PureStorageConfig();
    final deviceDir = Directory('${storageConfig.devicesDir}/$callsign');
    if (!await deviceDir.exists()) {
      await deviceDir.create(recursive: true);
    }
  }

  /// Get all devices (owned first, then cached)
  List<Map<String, dynamic>> getAllDevicesSorted() {
    final result = <Map<String, dynamic>>[];

    // Owned devices first (sorted: relays first, then clients)
    final ownedRelays = _profiles.where((p) => p.isRelay).toList();
    final ownedClients = _profiles.where((p) => p.isClient).toList();

    for (final profile in [...ownedRelays, ...ownedClients]) {
      result.add({
        'callsign': profile.callsign,
        'type': profile.isRelay ? 'relay' : 'client',
        'nickname': profile.nickname,
        'owned': true,
        'active': profile.id == _activeProfileId,
      });
    }

    // Cached devices (sorted by last seen)
    final sortedCached = List<CachedDevice>.from(_cachedDevices)
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    for (final device in sortedCached) {
      result.add({
        'callsign': device.callsign,
        'type': device.type ?? 'unknown',
        'nickname': device.description ?? '',
        'owned': false,
        'lastSeen': device.lastSeen.toIso8601String(),
      });
    }

    return result;
  }

  /// Check if setup is needed (no profiles exist)
  bool needsSetup() {
    return _profiles.isEmpty;
  }

  /// Generate proper NOSTR keys using secp256k1
  static Map<String, String> generateKeys() {
    final keys = NostrKeyGenerator.generateKeyPair();
    return {
      'nsec': keys.nsec,
      'npub': keys.npub,
    };
  }

  /// Generate callsign from npub
  static String generateCallsign(String npub, ProfileType type) {
    if (type == ProfileType.relay) {
      return NostrKeyGenerator.deriveRelayCallsign(npub);
    } else {
      return NostrKeyGenerator.deriveCallsign(npub);
    }
  }

  /// Create a new profile with generated identity
  Future<Profile> createProfile({
    required ProfileType type,
    String? nickname,
    String? description,
    int? port,
    String? relayRole,
    String? parentRelayUrl,
    String? networkId,
  }) async {
    final keys = generateKeys();
    final callsign = generateCallsign(keys['npub']!, type);

    // Generate random preferred color
    final colors = ['red', 'blue', 'green', 'yellow', 'purple', 'orange', 'pink', 'cyan'];
    final preferredColor = colors[Random().nextInt(colors.length)];

    final profile = Profile(
      type: type,
      callsign: callsign,
      nickname: nickname ?? '',
      description: description ?? '',
      npub: keys['npub']!,
      nsec: keys['nsec']!,
      preferredColor: preferredColor,
      port: port,
      relayRole: relayRole,
      parentRelayUrl: parentRelayUrl,
      networkId: networkId,
    );

    await addProfile(profile);
    return profile;
  }
}
