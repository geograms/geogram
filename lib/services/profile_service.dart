import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../models/profile.dart';
import '../services/log_service.dart';
import '../services/config_service.dart';
import '../util/nostr_key_generator.dart';

/// Service for managing user profile
class ProfileService {
  static final ProfileService _instance = ProfileService._internal();
  factory ProfileService() => _instance;
  ProfileService._internal();

  Profile? _profile;
  bool _initialized = false;

  /// Notifier for profile changes
  final ValueNotifier<int> profileNotifier = ValueNotifier<int>(0);

  /// Initialize profile service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await _loadProfile();
      _initialized = true;
      LogService().log('ProfileService initialized');
    } catch (e) {
      LogService().log('Error initializing ProfileService: $e');
    }
  }

  /// Load profile from config
  Future<void> _loadProfile() async {
    final config = ConfigService().getAll();

    if (config.containsKey('profile')) {
      final profileData = config['profile'] as Map<String, dynamic>;
      _profile = Profile.fromJson(profileData);

      // Auto-generate identity if missing
      if (_profile!.npub.isEmpty || _profile!.nsec.isEmpty) {
        await _generateIdentity();
      } else if (_profile!.callsign.isEmpty) {
        // Derive callsign from existing npub if missing
        try {
          _profile!.callsign = NostrKeyGenerator.deriveCallsign(_profile!.npub);
          await saveProfile(_profile!);
        } catch (e) {
          // If derivation fails, generate new identity
          await _generateIdentity();
        }
      }

      LogService().log('Profile loaded from config');
    } else {
      // Create default profile with identity
      _profile = Profile();
      await _generateIdentity();
      LogService().log('Created default profile with new identity');
    }
  }

  /// Generate new NOSTR identity (npub/nsec/callsign)
  Future<void> _generateIdentity() async {
    final keys = NostrKeyGenerator.generateKeyPair();
    _profile!.npub = keys.npub;
    _profile!.nsec = keys.nsec;
    _profile!.callsign = keys.callsign;

    // Set random preferred color if not set
    if (_profile!.preferredColor.isEmpty) {
      final colors = ['red', 'blue', 'green', 'yellow', 'purple', 'orange', 'pink', 'cyan'];
      _profile!.preferredColor = colors[Random().nextInt(colors.length)];
    }

    await saveProfile(_profile!);
    LogService().log('Generated new identity: ${_profile!.callsign}');
  }

  /// Save profile to config
  Future<void> saveProfile(Profile profile) async {
    _profile = profile;
    await ConfigService().set('profile', profile.toJson());
    profileNotifier.value++; // Notify listeners
    LogService().log('Profile saved to config');
  }

  /// Get current profile
  Profile getProfile() {
    if (!_initialized) {
      throw Exception('ProfileService not initialized');
    }
    return _profile ?? Profile();
  }

  /// Update profile fields
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

  /// Generate new identity (reset keys)
  Future<void> regenerateIdentity() async {
    await _generateIdentity();
  }

  /// Set profile picture from file
  Future<String?> setProfilePicture(String sourcePath) async {
    try {
      final file = File(sourcePath);
      if (!await file.exists()) {
        LogService().log('Profile picture file not found: $sourcePath');
        return null;
      }

      // Get app data directory
      final appDir = await getApplicationDocumentsDirectory();
      final geogramDir = Directory(path.join(appDir.path, 'geogram'));
      if (!await geogramDir.exists()) {
        await geogramDir.create(recursive: true);
      }

      // Copy file to app directory with consistent name
      final extension = path.extension(sourcePath);
      final destPath = path.join(geogramDir.path, 'profile_picture$extension');
      final destFile = File(destPath);

      await file.copy(destPath);
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
      try {
        final file = File(profile.profileImagePath!);
        if (await file.exists()) {
          await file.delete();
          LogService().log('Profile picture deleted');
        }
      } catch (e) {
        LogService().log('Error deleting profile picture: $e');
      }

      // Update profile
      await updateProfile(profileImagePath: null);
    }
  }

  /// Check if profile picture exists
  Future<bool> hasProfilePicture() async {
    final profile = getProfile();
    if (profile.profileImagePath == null) return false;

    final file = File(profile.profileImagePath!);
    return await file.exists();
  }
}
