/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/material.dart';
import '../models/profile.dart';
import '../services/profile_service.dart';

/// Widget for selecting and switching between multiple callsigns/profiles
/// Can be used in app bar, sidebar header, or settings
class CallsignSelectorWidget extends StatelessWidget {
  /// Callback when profile is switched
  final Function(Profile)? onProfileSwitch;

  /// Callback when new profile is requested
  final VoidCallback? onCreateNewProfile;

  /// Whether to show the create new profile option
  final bool showCreateOption;

  /// Whether to show in compact mode (just callsign chip)
  final bool compact;

  const CallsignSelectorWidget({
    Key? key,
    this.onProfileSwitch,
    this.onCreateNewProfile,
    this.showCreateOption = true,
    this.compact = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profileService = ProfileService();

    return ValueListenableBuilder<int>(
      valueListenable: profileService.profileNotifier,
      builder: (context, _, child) {
        final profiles = profileService.getAllProfiles();
        final activeProfile = profileService.getProfile();

        if (compact) {
          return _buildCompactSelector(context, theme, profiles, activeProfile);
        }

        return _buildFullSelector(context, theme, profiles, activeProfile);
      },
    );
  }

  /// Build compact selector (dropdown chip style)
  Widget _buildCompactSelector(
    BuildContext context,
    ThemeData theme,
    List<Profile> profiles,
    Profile activeProfile,
  ) {
    final hasMultiple = profiles.length > 1;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: hasMultiple ? () => _showProfilePicker(context, profiles, activeProfile) : null,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Callsign avatar
              _buildProfileAvatar(theme, activeProfile, size: 24),
              const SizedBox(width: 8),
              // Callsign text
              Text(
                activeProfile.callsign,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              // Dropdown indicator if multiple profiles
              if (hasMultiple) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_drop_down,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Build full selector (expandable list style)
  Widget _buildFullSelector(
    BuildContext context,
    ThemeData theme,
    List<Profile> profiles,
    Profile activeProfile,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Active profile header
        _buildActiveProfileTile(context, theme, activeProfile, profiles.length > 1),

        // Other profiles (if multiple)
        if (profiles.length > 1) ...[
          const SizedBox(height: 8),
          ...profiles
              .where((p) => p.id != activeProfile.id)
              .map((p) => _buildProfileTile(context, theme, p, false)),
        ],

        // Create new profile option
        if (showCreateOption) ...[
          const SizedBox(height: 8),
          _buildCreateProfileTile(context, theme),
        ],
      ],
    );
  }

  /// Build tile for active profile
  Widget _buildActiveProfileTile(
    BuildContext context,
    ThemeData theme,
    Profile profile,
    bool hasOthers,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          _buildProfileAvatar(theme, profile, isActive: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.callsign,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                if (profile.nickname.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    profile.nickname,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Active indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Active',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build tile for inactive profile
  Widget _buildProfileTile(
    BuildContext context,
    ThemeData theme,
    Profile profile,
    bool isActive,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () async {
          await ProfileService().switchToProfile(profile.id);
          onProfileSwitch?.call(profile);
        },
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              _buildProfileAvatar(theme, profile),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.callsign,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (profile.nickname.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        profile.nickname,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.swap_horiz,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build "Create new profile" tile
  Widget _buildCreateProfileTile(BuildContext context, ThemeData theme) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onCreateNewProfile ?? () => _showCreateProfileDialog(context),
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.3),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.add,
                  size: 20,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Add new callsign',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.secondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build profile avatar
  Widget _buildProfileAvatar(ThemeData theme, Profile profile, {bool isActive = false, double size = 36}) {
    // Check if profile has a custom image
    if (profile.profileImagePath != null && profile.profileImagePath!.isNotEmpty) {
      final imageFile = File(profile.profileImagePath!);
      if (imageFile.existsSync()) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.4),
            image: DecorationImage(
              image: FileImage(imageFile),
              fit: BoxFit.cover,
            ),
          ),
        );
      }
    }

    // Use default geogram icon when no profile image is set
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.4),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.4),
        child: Image.asset(
          'assets/default_profile.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  /// Get color based on profile's preferred color
  Color _getColorForProfile(Profile profile) {
    switch (profile.preferredColor.toLowerCase()) {
      case 'red':
        return Colors.red;
      case 'green':
        return Colors.green;
      case 'yellow':
        return Colors.amber;
      case 'purple':
        return Colors.purple;
      case 'orange':
        return Colors.orange;
      case 'pink':
        return Colors.pink;
      case 'cyan':
        return Colors.cyan;
      case 'blue':
      default:
        return Colors.blue;
    }
  }

  /// Show profile picker bottom sheet
  void _showProfilePicker(
    BuildContext context,
    List<Profile> profiles,
    Profile activeProfile,
  ) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle bar
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Title
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Switch Callsign',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Profile list
                ...profiles.map((profile) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _buildProfileTile(
                    context,
                    theme,
                    profile,
                    profile.id == activeProfile.id,
                  ),
                )),
                // Create new option
                if (showCreateOption) ...[
                  const SizedBox(height: 8),
                  _buildCreateProfileTile(context, theme),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Show create profile dialog
  void _showCreateProfileDialog(BuildContext context) {
    final theme = Theme.of(context);
    final nicknameController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create New Callsign'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'A new identity will be generated with a unique callsign.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nicknameController,
              decoration: const InputDecoration(
                labelText: 'Nickname (optional)',
                hintText: 'Enter a display name',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              final newProfile = await ProfileService().createNewProfile(
                nickname: nicknameController.text.trim().isNotEmpty
                    ? nicknameController.text.trim()
                    : null,
              );
              onProfileSwitch?.call(newProfile);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}

/// Compact callsign indicator for app bar
class CallsignIndicator extends StatelessWidget {
  final VoidCallback? onTap;

  const CallsignIndicator({Key? key, this.onTap}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profileService = ProfileService();

    return ValueListenableBuilder<int>(
      valueListenable: profileService.profileNotifier,
      builder: (context, _, __) {
        final profile = profileService.getProfile();
        final hasMultiple = profileService.hasMultipleProfiles;

        return Tooltip(
          message: hasMultiple
              ? 'Switch callsign (${profileService.profileCount} profiles)'
              : profile.callsign,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      profile.callsign,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (hasMultiple) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.unfold_more,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
