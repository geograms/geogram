import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:file_picker/file_picker.dart';
import '../models/profile.dart';
import '../services/log_service.dart';
import '../services/config_service.dart';
import '../services/app_service.dart';
import '../services/encrypted_storage_stub.dart'
    if (dart.library.ui) '../services/encrypted_storage_service.dart';
import '../services/storage_config.dart';
import '../services/signing_service.dart';
import '../services/file_index_service.dart';
import '../services/mirror_auto_sync_service.dart';
import '../services/mirror_config_service.dart';
import '../services/mirror_sync_service.dart';
import '../services/chat_service.dart';
import '../services/chat_notification_service.dart';
import '../services/app_args.dart';
import '../util/event_bus.dart';
import '../util/nostr_key_generator.dart';
import '../util/nostr_crypto.dart';

/// Service for managing user profiles (supports multiple callsigns)
class ProfileService {
  static final ProfileService _instance = ProfileService._internal();
  factory ProfileService() => _instance;
  ProfileService._internal();

  /// List of all user profiles/callsigns
  List<Profile> _profiles = [];

  /// ID of the currently active profile
  String? _activeProfileId;

  bool _initialized = false;

  /// Notifier for profile changes (incremented on any change)
  final ValueNotifier<int> profileNotifier = ValueNotifier<int>(0);

  /// Notifier specifically for active profile switches
  final ValueNotifier<String?> activeProfileNotifier = ValueNotifier<String?>(
    null,
  );

  /// Initialize profile service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      // Check if --new-identity flag was passed
      final appArgs = AppArgs();
      if (appArgs.newIdentity) {
        await _createNewIdentityFromArgs();
        _initialized = true;
        LogService().log(
          'ProfileService initialized with new identity from command line',
        );
        return;
      }

      await _loadProfiles();
      await _repairProfilesIfNeeded();
      _initialized = true;
      LogService().log(
        'ProfileService initialized with ${_profiles.length} profile(s)',
      );
    } catch (e) {
      LogService().log('Error initializing ProfileService: $e');
      // Try to salvage any loaded profiles before falling back
      try {
        await _repairProfilesIfNeeded();
      } catch (_) {}
      // Still mark as initialized with a default profile to avoid blocking the app
      if (_profiles.isEmpty) {
        final newProfile = Profile();
        await _generateIdentityForProfile(newProfile);
        _profiles = [newProfile];
        _activeProfileId = newProfile.id;
      }
      _initialized = true;
    }
  }

  /// Create a new identity based on command line arguments
  Future<void> _createNewIdentityFromArgs() async {
    final appArgs = AppArgs();
    final profileType = appArgs.isStation
        ? ProfileType.station
        : ProfileType.client;

    final newProfile = Profile(
      type: profileType,
      nickname: appArgs.nickname ?? (appArgs.isStation ? 'Station' : 'User'),
    );

    await _generateIdentityForProfile(newProfile, type: profileType);

    _profiles = [newProfile];
    _activeProfileId = newProfile.id;
    _saveAllProfiles();

    LogService().log(
      'Created new ${profileType.name} identity: ${newProfile.callsign} (${newProfile.nickname})',
    );
  }

  /// Load profiles from config (supports both legacy single profile and new multi-profile format)
  Future<void> _loadProfiles() async {
    final config = ConfigService().getAll();

    // Check for new multi-profile format first
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

      // Enforce single-active invariant
      for (final p in _profiles) {
        p.isActive = (p.id == _activeProfileId);
      }

      // Validate and fix any profiles with invalid NOSTR keys
      bool profilesUpdated = false;
      for (final profile in _profiles) {
        if (!_hasValidNostrKeys(profile)) {
          LogService().log(
            'Profile ${profile.callsign} has invalid NOSTR keys, regenerating...',
          );
          await _generateIdentityForProfile(profile);
          profilesUpdated = true;
        }
      }
      if (profilesUpdated) {
        _saveAllProfiles();
      }

      LogService().log('Loaded ${_profiles.length} profiles from config');
    }
    // Fall back to legacy single profile format for migration
    else if (config.containsKey('profile')) {
      final profileData = config['profile'] as Map<String, dynamic>;
      final legacyProfile = Profile.fromJson(profileData);

      // Auto-generate identity if missing or invalid
      if (!_hasValidNostrKeys(legacyProfile)) {
        LogService().log(
          'Legacy profile has invalid NOSTR keys, regenerating...',
        );
        await _generateIdentityForProfile(legacyProfile);
      } else if (legacyProfile.callsign.isEmpty) {
        // Derive callsign from existing npub if missing
        legacyProfile.callsign = NostrKeyGenerator.deriveCallsign(
          legacyProfile.npub,
        );
      }

      _profiles = [legacyProfile];
      _activeProfileId = legacyProfile.id;

      // Migrate to new format
      _saveAllProfiles();
      LogService().log('Migrated legacy profile to multi-profile format');
    } else {
      // No profile data in config — attempt filesystem recovery before creating new identity
      final recovered = await _tryRecoverFromFilesystem();
      if (!recovered) {
        final newProfile = Profile();
        await _generateIdentityForProfile(newProfile);
        _profiles = [newProfile];
        _activeProfileId = newProfile.id;
        _saveAllProfiles();
        LogService().log('Created default profile with new identity');
      }
    }

    // Update active profile notifier
    activeProfileNotifier.value = _activeProfileId;
  }

  /// Last-resort recovery: scan devices/ for existing profile folders when config is empty.
  /// Recovered profiles will have no nsec (user must re-import), but unencrypted data
  /// is preserved and the app won't show onboarding as if it were a fresh install.
  Future<bool> _tryRecoverFromFilesystem() async {
    if (kIsWeb) return false;

    try {
      final devicesDir = Directory(StorageConfig().devicesDir);
      if (!await devicesDir.exists()) return false;

      final List<Profile> recovered = [];
      await for (final entity in devicesDir.list()) {
        String? callsign;

        if (entity is File && entity.path.endsWith('.sqlite')) {
          // Encrypted profile: derive callsign from filename
          callsign = path.basenameWithoutExtension(entity.path);
        } else if (entity is Directory) {
          // Plain profile folder — only count if it has contents
          try {
            await entity.list().first; // cancels stream after first element
            callsign = path.basename(entity.path);
          } catch (_) {
            // Empty directory — skip
          }
        }

        if (callsign != null && callsign.isNotEmpty) {
          final profile = Profile(callsign: callsign);
          // Set a placeholder color
          final colors = [
            'red',
            'blue',
            'green',
            'yellow',
            'purple',
            'orange',
            'pink',
            'cyan',
          ];
          profile.preferredColor = colors[recovered.length % colors.length];
          recovered.add(profile);
          LogService().log(
            'ProfileService: Recovered profile folder for $callsign (nsec missing — re-import required)',
          );
        }
      }

      if (recovered.isEmpty) return false;

      _profiles = recovered;
      _activeProfileId = recovered.first.id;
      _saveAllProfiles();

      // Skip onboarding since this is clearly not a fresh install
      ConfigService().set('firstLaunchComplete', true);

      LogService().log(
        'ProfileService: Recovered ${recovered.length} profile(s) from filesystem. Private keys must be re-imported.',
      );
      return true;
    } catch (e) {
      LogService().log('ProfileService: Filesystem recovery failed: $e');
      return false;
    }
  }

  /// Attempt to repair corrupted profiles (missing npub/callsign but have nsec)
  Future<void> _repairProfilesIfNeeded() async {
    bool changed = false;
    for (var i = 0; i < _profiles.length; i++) {
      final repaired = await _repairProfile(_profiles[i]);
      if (repaired) {
        _profiles[i] = _profiles[i];
        changed = true;
      }
    }

    // Ensure we have an active profile after repairs
    if (_activeProfileId == null && _profiles.isNotEmpty) {
      _activeProfileId = _profiles.first.id;
      changed = true;
    }

    // Keep recovered profiles even when their nsec is missing so reinstall or
    // config-loss recovery does not discard the user's on-disk data.
    // Callers that require signing must continue to check _hasUsableNsec().
    if (_activeProfileId != null &&
        !_profiles.any((p) => p.id == _activeProfileId)) {
      _activeProfileId = _profiles.isNotEmpty ? _profiles.first.id : null;
      changed = true;
    }

    if (changed) {
      _saveAllProfiles();
      LogService().log(
        'ProfileService: repaired profiles and refreshed config',
      );
    }
  }

  /// Repair a single profile in-place. Returns true if the profile was modified.
  Future<bool> _repairProfile(Profile profile) async {
    bool updated = false;
    String? privateHex;

    // Normalize nsec: accept hex and encode to nsec
    if (profile.nsec.isNotEmpty) {
      privateHex = NostrKeyGenerator.getPrivateKeyHex(profile.nsec);
      // If nsec is hex (64 chars), encode it to nsec bech32
      if (privateHex == null &&
          profile.nsec.length == 64 &&
          RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(profile.nsec)) {
        try {
          profile.nsec = NostrCrypto.encodeNsec(profile.nsec);
          privateHex = profile.nsec.isNotEmpty
              ? NostrKeyGenerator.getPrivateKeyHex(profile.nsec)
              : null;
          updated = true;
          LogService().log(
            'ProfileService: recovered nsec from raw hex for ${profile.id}',
          );
        } catch (_) {}
      }
    }

    // Rebuild npub from valid nsec
    if ((profile.npub.isEmpty ||
            !NostrKeyGenerator.isValidNpub(profile.npub)) &&
        privateHex != null) {
      try {
        final pubHex = NostrCrypto.derivePublicKey(privateHex);
        profile.npub = NostrCrypto.encodeNpub(pubHex);
        updated = true;
        LogService().log('ProfileService: regenerated npub for ${profile.id}');
      } catch (e) {
        LogService().log(
          'ProfileService: failed to regenerate npub for ${profile.id}: $e',
        );
      }
    }

    // Rebuild callsign from npub when missing
    if (profile.callsign.isEmpty && profile.npub.isNotEmpty) {
      try {
        profile.callsign = profile.type == ProfileType.station
            ? NostrKeyGenerator.deriveStationCallsign(profile.npub)
            : NostrKeyGenerator.deriveCallsign(profile.npub);
        updated = true;
        LogService().log('ProfileService: derived callsign for ${profile.id}');
      } catch (e) {
        LogService().log(
          'ProfileService: failed to derive callsign for ${profile.id}: $e',
        );
      }
    }

    // Ensure we have a display-friendly callsign even if keys are still bad
    if (profile.callsign.isEmpty) {
      profile.callsign = 'Recovered-${profile.id.substring(0, 6)}';
      updated = true;
    }

    // Set a preferred color if missing
    if (profile.preferredColor.isEmpty) {
      final colors = [
        'red',
        'blue',
        'green',
        'yellow',
        'purple',
        'orange',
        'pink',
        'cyan',
      ];
      profile.preferredColor = colors[Random().nextInt(colors.length)];
      updated = true;
    }

    return updated;
  }

  /// Generate new NOSTR identity for a specific profile
  Future<void> _generateIdentityForProfile(
    Profile profile, {
    ProfileType? type,
  }) async {
    final keys = NostrKeyGenerator.generateKeyPair();
    profile.npub = keys.npub;
    profile.nsec = keys.nsec;

    // Generate callsign with appropriate prefix based on type
    final profileType = type ?? profile.type;
    if (profileType == ProfileType.station) {
      // Station callsigns start with X3
      profile.callsign = 'X3${keys.callsign.substring(2)}';
    } else {
      // Client callsigns start with X1
      profile.callsign = keys.callsign;
    }

    // Set random preferred color if not set
    if (profile.preferredColor.isEmpty) {
      final colors = [
        'red',
        'blue',
        'green',
        'yellow',
        'purple',
        'orange',
        'pink',
        'cyan',
      ];
      profile.preferredColor = colors[Random().nextInt(colors.length)];
    }

    LogService().log(
      'Generated new identity: ${profile.callsign} (${profileType.name})',
    );
  }

  /// Regenerate identity for the active profile (generates new keys and callsign)
  Future<void> regenerateActiveProfileIdentity() async {
    final profile = getProfile();
    await _generateIdentityForProfile(profile, type: profile.type);
    _saveAllProfiles();
    await _applyActiveIdentityChanges(profile);
    LogService().log(
      'Regenerated identity for active profile: ${profile.callsign}',
    );
  }

  /// Check if a profile has valid NOSTR keys (proper bech32 encoding)
  bool _hasValidNostrKeys(Profile profile) {
    if (profile.npub.isEmpty || profile.nsec.isEmpty) {
      return false;
    }

    // Verify keys are proper bech32 by attempting to decode them
    try {
      final pubkeyHex = NostrKeyGenerator.getPublicKeyHex(profile.npub);
      final privkeyHex = NostrKeyGenerator.getPrivateKeyHex(profile.nsec);

      // Both must decode successfully and be correct length
      if (pubkeyHex == null || privkeyHex == null) {
        return false;
      }
      if (pubkeyHex.length != 64 || privkeyHex.length != 64) {
        return false;
      }

      return true;
    } catch (e) {
      LogService().log('Key validation failed: $e');
      return false;
    }
  }

  /// Save all profiles to config
  void _saveAllProfiles() {
    ConfigService().set('profiles', _profiles.map((p) => p.toJson()).toList());
    ConfigService().set('activeProfileId', _activeProfileId);

    // Also maintain legacy 'profile' key for backward compatibility
    final activeProfile = getProfile();
    ConfigService().set('profile', activeProfile.toJson());

    profileNotifier.value++; // Notify listeners
  }

  /// Save a specific profile (updates it in the list)
  Future<void> saveProfile(Profile profile) async {
    final index = _profiles.indexWhere((p) => p.id == profile.id);
    if (index >= 0) {
      _profiles[index] = profile;
    } else {
      _profiles.add(profile);
    }
    _saveAllProfiles();
    AppService().invalidateWwwIndex();
    LogService().log('Profile saved: ${profile.callsign}');
  }

  /// Get current active profile
  /// Returns an empty profile if not initialized (for safety during startup)
  Profile getProfile() {
    if (!_initialized || _profiles.isEmpty) {
      return Profile();
    }
    final byId = _profiles.firstWhere(
      (p) => p.id == _activeProfileId && _hasUsableNsec(p),
      orElse: () =>
          _profiles.firstWhere(_hasUsableNsec, orElse: () => _profiles.first),
    );
    return byId;
  }

  /// Get all profiles
  /// Returns empty list if not initialized (for safety during startup)
  List<Profile> getAllProfiles() {
    if (!_initialized) {
      return [];
    }
    return List.unmodifiable(_profiles.where(_hasUsableNsec));
  }

  /// Get all stored profiles, including recovered profiles without usable keys.
  List<Profile> getAllStoredProfiles() {
    if (!_initialized) {
      return [];
    }
    return List.unmodifiable(_profiles);
  }

  /// Get profile by ID
  Profile? getProfileById(String id) {
    try {
      final profile = _profiles.firstWhere((p) => p.id == id);
      return _hasUsableNsec(profile) ? profile : null;
    } catch (_) {
      return null;
    }
  }

  /// Get profile by callsign
  Profile? getProfileByCallsign(String callsign) {
    try {
      return _profiles.firstWhere(
        (p) => p.callsign.toLowerCase() == callsign.toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Switch to a different profile by ID
  Future<void> switchToProfile(String profileId) async {
    if (!_profiles.any((p) => p.id == profileId && _hasUsableNsec(p))) {
      throw Exception('Profile not found: $profileId');
    }

    // Stop background file indexing for old profile
    FileIndexService.stopBackgroundIndexing();

    // Close encrypted storage for old profile before switching
    final oldProfile = _activeProfileId != null ? getProfile() : null;
    if (oldProfile != null) {
      await EncryptedStorageService().closeArchive(oldProfile.callsign);
    }

    _activeProfileId = profileId;
    for (final p in _profiles) {
      p.isActive = (p.id == profileId);
    }
    _saveAllProfiles();

    // Update AppService to use the new profile's storage path BEFORE notifying listeners
    final newProfile = getProfile();
    // Set nsec for encrypted storage access (must be before setActiveCallsign)
    if (newProfile.nsec.isNotEmpty) {
      AppService().setNsec(newProfile.nsec);
    }
    await AppService().setActiveCallsign(newProfile.callsign);

    // Clear stale mirror runtime state from the old profile, then load
    // the new profile's mirror config so listeners see correct state.
    MirrorAutoSyncService.instance.stop();
    MirrorSyncService.instance.resetForProfileSwitch();
    await MirrorConfigService.instance.setStorage(AppService().profileStorage);
    MirrorSyncService.instance.loadAllowedPeersFromConfig();
    MirrorAutoSyncService.instance.start();

    // Restart background file indexing for new profile
    FileIndexService.startBackgroundIndexing(
      dbPath: StorageConfig().getFileIndexPath(newProfile.callsign),
      storage: AppService().profileStorage,
    );

    // Switch logs to profile-specific directory
    await LogService().switchToProfile(newProfile.callsign);

    // Reset chat state for profile isolation
    ChatService().reset();
    ChatNotificationService().resetForProfileSwitch();

    // Ensure default collections exist for this profile
    await AppService().ensureDefaultApps();

    // Notify listeners AFTER callsign is updated so they load correct collections
    activeProfileNotifier.value = profileId;

    LogService().log('Switched to profile: ${newProfile.callsign}');
  }

  /// Activate a profile (switches to it as the single active profile)
  Future<void> activateProfile(String profileId) async {
    await switchToProfile(profileId);
  }

  /// Deactivate a profile (cannot deactivate the currently active profile)
  void deactivateProfile(String profileId) {
    if (profileId == _activeProfileId) {
      LogService().log('Cannot deactivate the currently active profile');
      return;
    }
    final profile = _profiles.firstWhere(
      (p) => p.id == profileId,
      orElse: () => throw Exception('Profile not found: $profileId'),
    );
    profile.isActive = false;
    _saveAllProfiles();
    profileNotifier.notifyListeners();
  }

  /// Toggle profile active state (activating switches to it; cannot deactivate current)
  Future<void> toggleProfileActive(String profileId) async {
    final profile = _profiles.firstWhere(
      (p) => p.id == profileId,
      orElse: () => throw Exception('Profile not found: $profileId'),
    );
    if (!profile.isActive) {
      await switchToProfile(profileId);
    }
    // Cannot deactivate the current profile — no-op
  }

  /// Get all active profiles
  List<Profile> getActiveProfiles() {
    return _profiles.where((p) => p.isActive).toList();
  }

  /// Check if profile has a usable signing key (nsec or raw hex)
  bool _hasUsableNsec(Profile profile) {
    if (profile.nsec.isEmpty) return false;
    if (NostrKeyGenerator.getPrivateKeyHex(profile.nsec) != null) return true;
    if (profile.nsec.length == 64 &&
        RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(profile.nsec)) {
      return true;
    }
    return false;
  }

  /// Create a new profile with generated identity
  Future<Profile> createNewProfile({
    String? nickname,
    ProfileType type = ProfileType.client,
  }) async {
    final newProfile = Profile(
      nickname: nickname ?? '',
      type: type,
      isActive: false,
    );
    await _generateIdentityForProfile(newProfile, type: type);
    _profiles.add(newProfile);
    _saveAllProfiles();
    LogService().log(
      'Created new profile: ${newProfile.callsign} (${type.name})',
    );
    return newProfile;
  }

  /// Create a new profile with pre-generated keys (for callsign preview/selection)
  Future<Profile> createNewProfileWithKeys({
    required String npub,
    required String nsec,
    required String callsign,
    String? nickname,
    ProfileType type = ProfileType.client,
  }) async {
    final newProfile = Profile(
      nickname: nickname ?? '',
      type: type,
      isActive: false,
    );
    newProfile.npub = npub;
    newProfile.nsec = nsec;
    newProfile.callsign = callsign;

    // Set random preferred color
    if (newProfile.preferredColor.isEmpty) {
      final colors = [
        'red',
        'blue',
        'green',
        'yellow',
        'purple',
        'orange',
        'pink',
        'cyan',
      ];
      newProfile.preferredColor = colors[Random().nextInt(colors.length)];
    }

    _profiles.add(newProfile);
    _saveAllProfiles();
    LogService().log(
      'Created new profile with pre-generated keys: $callsign (${type.name})',
    );
    return newProfile;
  }

  /// Create a new profile using NIP-07 browser extension (web only)
  /// This creates a profile without storing the nsec - signing is done via extension
  Future<Profile?> createProfileWithExtension({String? nickname}) async {
    if (!kIsWeb) {
      LogService().log('Extension login only available on web');
      return null;
    }

    try {
      final signingService = SigningService();
      await signingService.initialize();

      if (!signingService.isExtensionAvailable) {
        LogService().log('NIP-07 extension not available');
        return null;
      }

      // Get public key from extension
      final pubkeyHex = await signingService.getExtensionPublicKey();
      if (pubkeyHex == null || pubkeyHex.isEmpty) {
        LogService().log('Failed to get public key from extension');
        return null;
      }

      // Convert pubkey hex to npub
      final npub = NostrCrypto.encodeNpub(pubkeyHex);

      // Derive callsign from npub
      final callsign = NostrKeyGenerator.deriveCallsign(npub);

      // Create profile with extension mode enabled
      final newProfile = Profile(
        nickname: nickname ?? '',
        type: ProfileType.client,
        npub: npub,
        nsec: '', // No nsec stored - using extension
        useExtension: true,
        callsign: callsign,
      );

      // Set random preferred color
      final colors = [
        'red',
        'blue',
        'green',
        'yellow',
        'purple',
        'orange',
        'pink',
        'cyan',
      ];
      newProfile.preferredColor = colors[Random().nextInt(colors.length)];

      _profiles.add(newProfile);
      _activeProfileId = newProfile.id;
      _saveAllProfiles();

      LogService().log(
        'Created profile with extension: ${newProfile.callsign}',
      );
      return newProfile;
    } catch (e) {
      LogService().log('Error creating profile with extension: $e');
      return null;
    }
  }

  /// Check if NIP-07 extension is available (web only)
  Future<bool> isExtensionAvailable() async {
    if (!kIsWeb) return false;

    try {
      final signingService = SigningService();
      await signingService.initialize();
      return signingService.isExtensionAvailable;
    } catch (e) {
      return false;
    }
  }

  /// Delete a profile by ID (cannot delete the last profile)
  Future<bool> deleteProfile(String profileId) async {
    if (_profiles.length <= 1) {
      LogService().log('Cannot delete the last profile');
      return false;
    }

    final index = _profiles.indexWhere((p) => p.id == profileId);
    if (index < 0) {
      return false;
    }

    final deletedProfile = _profiles.removeAt(index);

    // If we deleted the active profile, switch to the first remaining one
    if (_activeProfileId == profileId) {
      _activeProfileId = _profiles.first.id;
      activeProfileNotifier.value = _activeProfileId;
    }

    _saveAllProfiles();

    // Clean up profile data from disk
    if (!kIsWeb) {
      final callsign = deletedProfile.callsign;

      // Close any open encrypted archive first
      await EncryptedStorageService().closeArchive(callsign);

      // Delete encrypted SQLite archive if it exists
      final archivePath = StorageConfig().getEncryptedArchivePath(callsign);
      final archiveFile = File(archivePath);
      if (await archiveFile.exists()) {
        await archiveFile.delete();
        LogService().log('Deleted encrypted archive for $callsign');
      }

      // Delete profile folder if it exists
      final profileDir = Directory(StorageConfig().getCallsignDir(callsign));
      if (await profileDir.exists()) {
        await profileDir.delete(recursive: true);
        LogService().log('Deleted profile folder for $callsign');
      }
    }

    LogService().log('Deleted profile: ${deletedProfile.callsign}');
    return true;
  }

  /// Check if there are multiple profiles
  bool get hasMultipleProfiles => _profiles.length > 1;

  /// Get the number of profiles
  int get profileCount => _profiles.length;

  /// Get the active profile ID
  String? get activeProfileId => _activeProfileId;

  /// Update profile fields for the active profile
  Future<void> updateProfile({
    String? nickname,
    String? description,
    String? profileImagePath,
    String? preferredColor,
    double? latitude,
    double? longitude,
    String? locationName,
  }) async {
    final currentProfile = getProfile();
    final updatedProfile = currentProfile.copyWith(
      nickname: nickname,
      description: description,
      profileImagePath: profileImagePath,
      preferredColor: preferredColor,
      latitude: latitude,
      longitude: longitude,
      locationName: locationName,
    );
    await saveProfile(updatedProfile);
  }

  /// Generate new identity for active profile (reset keys)
  Future<void> regenerateIdentity() async {
    final profile = getProfile();
    await _generateIdentityForProfile(profile);
    await saveProfile(profile);
    await _applyActiveIdentityChanges(profile);
  }

  Future<void> _applyActiveIdentityChanges(Profile profile) async {
    try {
      // Set nsec for encrypted storage access (must be before setActiveCallsign)
      if (profile.nsec.isNotEmpty) {
        AppService().setNsec(profile.nsec);
      }
      await AppService().setActiveCallsign(profile.callsign);

      // Clear stale mirror runtime state, then load new profile's config
      MirrorAutoSyncService.instance.stop();
      MirrorSyncService.instance.resetForProfileSwitch();
      await MirrorConfigService.instance.setStorage(
        AppService().profileStorage,
      );
      MirrorSyncService.instance.loadAllowedPeersFromConfig();
      MirrorAutoSyncService.instance.start();

      // Reset chat state for profile isolation
      ChatService().reset();
      ChatNotificationService().resetForProfileSwitch();

      // Switch logs to profile-specific directory
      await LogService().switchToProfile(profile.callsign);

      await AppService().ensureDefaultApps();
    } catch (e) {
      LogService().log('ProfileService: Failed to update callsign path: $e');
    }

    activeProfileNotifier.notifyListeners();

    if (EventBus().hasSubscribers<ProfileChangedEvent>()) {
      EventBus().fire(
        ProfileChangedEvent(callsign: profile.callsign, npub: profile.npub),
      );
    }
  }

  /// Finalize a profile identity by creating default collections/folders.
  /// Called after user confirms their chosen callsign (e.g., from WelcomePage).
  /// This is separate from saveProfile() to allow previewing callsigns without
  /// creating folders on disk.
  Future<void> finalizeProfileIdentity(Profile profile) async {
    await _applyActiveIdentityChanges(profile);
    LogService().log(
      'ProfileService: Finalized identity for ${profile.callsign}',
    );
  }

  /// Set profile picture from file
  Future<String?> setProfilePicture(String sourcePath) async {
    // On web, profile pictures are handled differently (e.g., base64 in config)
    if (kIsWeb) {
      LogService().log('Profile picture file storage not supported on web');
      return null;
    }

    try {
      final file = File(sourcePath);
      if (!await file.exists()) {
        LogService().log('Profile picture file not found: $sourcePath');
        return null;
      }

      // Store in callsign folder via ProfileStorage (handles encryption)
      final storage = AppService().profileStorage;
      if (storage == null) {
        LogService().log('Profile picture: no active profile storage');
        return null;
      }

      final extension = path.extension(sourcePath);
      final relativePath = 'profile_picture$extension';
      await storage.copyFromExternal(sourcePath, relativePath);

      final destPath = storage.getAbsolutePath(relativePath);

      // For encrypted storage, also extract to filesystem for display
      if (storage.isEncrypted) {
        await Directory(path.dirname(destPath)).create(recursive: true);
        await storage.copyToExternal(relativePath, destPath);
      }

      LogService().log('Profile picture saved to: $destPath');

      return destPath;
    } catch (e) {
      LogService().log('Error setting profile picture: $e');
      return null;
    }
  }

  /// Remove profile picture
  Future<void> removeProfilePicture() async {
    final profile = getProfile();
    if (profile.profileImagePath != null) {
      // Only try to delete file on native platforms
      if (!kIsWeb) {
        try {
          final file = File(profile.profileImagePath!);
          if (await file.exists()) {
            await file.delete();
          }
          // Also delete from encrypted storage archive if applicable
          final storage = AppService().profileStorage;
          if (storage != null && storage.isEncrypted) {
            final relativePath = path.basename(profile.profileImagePath!);
            if (await storage.exists(relativePath)) {
              await storage.delete(relativePath);
            }
          }
          LogService().log('Profile picture deleted');
        } catch (e) {
          LogService().log('Error deleting profile picture: $e');
        }
      }

      // Update profile
      await updateProfile(profileImagePath: null);
    }
  }

  /// Check if profile picture exists
  Future<bool> hasProfilePicture() async {
    final profile = getProfile();
    if (profile.profileImagePath == null) return false;

    // On web, we can't check file existence
    if (kIsWeb) return false;

    final file = File(profile.profileImagePath!);
    return await file.exists();
  }

  // ========== Profile Import/Export Methods ==========

  /// Export version for compatibility checking
  static const int _exportVersion = 1;

  /// Export a single profile to JSON map (for backup)
  Map<String, dynamic> exportProfile(Profile profile) {
    return {
      'version': _exportVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'profile': profile.toJson(),
    };
  }

  /// Export all profiles to JSON map
  Map<String, dynamic> exportAllProfiles() {
    return {
      'version': _exportVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'profiles': _profiles.map((p) => p.toJson()).toList(),
      'activeProfileId': _activeProfileId,
    };
  }

  /// Export profiles to a file (opens save dialog)
  /// Returns the saved file path or null if cancelled/failed
  Future<String?> exportProfilesToFile({Profile? singleProfile}) async {
    if (kIsWeb) {
      LogService().log('Profile export to file not supported on web');
      return null;
    }

    try {
      final Map<String, dynamic> exportData;
      final String defaultFileName;

      if (singleProfile != null) {
        exportData = exportProfile(singleProfile);
        defaultFileName = 'geogram_profile_${singleProfile.callsign}.json';
      } else {
        exportData = exportAllProfiles();
        defaultFileName = 'geogram_profiles_backup.json';
      }

      final jsonString = const JsonEncoder.withIndent('  ').convert(exportData);

      // Open save dialog - bytes parameter required for Android SAF support
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Profiles',
        fileName: defaultFileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: Uint8List.fromList(utf8.encode(jsonString)),
      );

      if (result == null) {
        LogService().log('Profile export cancelled by user');
        return null;
      }

      LogService().log('Profiles exported to: $result');
      return result;
    } catch (e) {
      LogService().log('Error exporting profiles: $e');
      return null;
    }
  }

  /// Import profiles from a file (opens file picker)
  /// Returns a map with 'success', 'imported' count, and optional 'error' message
  Future<Map<String, dynamic>> importProfilesFromFile() async {
    if (kIsWeb) {
      return {
        'success': false,
        'error': 'Profile import not supported on web',
        'imported': 0,
      };
    }

    try {
      // Open file picker
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Import Profiles',
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        return {'success': false, 'error': 'cancelled', 'imported': 0};
      }

      final filePath = result.files.first.path;
      if (filePath == null) {
        return {
          'success': false,
          'error': 'Could not access file',
          'imported': 0,
        };
      }

      final file = File(filePath);
      final jsonString = await file.readAsString();

      return await importProfilesFromJson(jsonString);
    } catch (e) {
      LogService().log('Error importing profiles: $e');
      return {
        'success': false,
        'error': 'Error reading file: $e',
        'imported': 0,
      };
    }
  }

  /// Import profiles from JSON string
  Future<Map<String, dynamic>> importProfilesFromJson(String jsonString) async {
    try {
      final data = json.decode(jsonString) as Map<String, dynamic>;

      // Check version
      final version = data['version'] as int? ?? 0;
      if (version > _exportVersion) {
        return {
          'success': false,
          'error':
              'Export file is from a newer version. Please update the app.',
          'imported': 0,
        };
      }

      final List<Profile> profilesToImport = [];

      // Handle single profile export
      if (data.containsKey('profile')) {
        final profileData = data['profile'] as Map<String, dynamic>;
        profilesToImport.add(Profile.fromJson(profileData));
      }
      // Handle multiple profiles export
      else if (data.containsKey('profiles')) {
        final profilesList = data['profiles'] as List;
        for (final profileData in profilesList) {
          profilesToImport.add(
            Profile.fromJson(profileData as Map<String, dynamic>),
          );
        }
      } else {
        return {
          'success': false,
          'error': 'Invalid export file format',
          'imported': 0,
        };
      }

      if (profilesToImport.isEmpty) {
        return {
          'success': false,
          'error': 'No profiles found in file',
          'imported': 0,
        };
      }

      // Import profiles, checking for duplicates
      int importedCount = 0;
      int skippedCount = 0;
      final List<String> importedCallsigns = [];

      for (final importedProfile in profilesToImport) {
        // Check if profile with same callsign already exists
        final existingByCallsign = getProfileByCallsign(
          importedProfile.callsign,
        );
        // Check if profile with same npub already exists
        final existingByNpub = _profiles
            .where((p) => p.npub == importedProfile.npub)
            .firstOrNull;

        if (existingByCallsign != null || existingByNpub != null) {
          LogService().log(
            'Skipping duplicate profile: ${importedProfile.callsign}',
          );
          skippedCount++;
          continue;
        }

        // Generate a new ID to avoid conflicts
        final newProfile = Profile(
          type: importedProfile.type,
          callsign: importedProfile.callsign,
          nickname: importedProfile.nickname,
          description: importedProfile.description,
          npub: importedProfile.npub,
          nsec: importedProfile.nsec,
          useExtension: importedProfile.useExtension,
          preferredColor: importedProfile.preferredColor,
          latitude: importedProfile.latitude,
          longitude: importedProfile.longitude,
          locationName: importedProfile.locationName,
          createdAt: importedProfile.createdAt,
          isActive: false, // Start as inactive
          port: importedProfile.port,
          stationRole: importedProfile.stationRole,
          parentStationUrl: importedProfile.parentStationUrl,
          networkId: importedProfile.networkId,
          tileServerEnabled: importedProfile.tileServerEnabled,
          osmFallbackEnabled: importedProfile.osmFallbackEnabled,
          enableAprs: importedProfile.enableAprs,
        );

        _profiles.add(newProfile);
        importedCount++;
        importedCallsigns.add(newProfile.callsign);
        LogService().log('Imported profile: ${newProfile.callsign}');
      }

      if (importedCount > 0) {
        _saveAllProfiles();
      }

      return {
        'success': true,
        'imported': importedCount,
        'skipped': skippedCount,
        'callsigns': importedCallsigns,
      };
    } catch (e) {
      LogService().log('Error parsing import data: $e');
      return {
        'success': false,
        'error': 'Error parsing file: $e',
        'imported': 0,
      };
    }
  }
}
