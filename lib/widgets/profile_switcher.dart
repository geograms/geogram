/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';
import 'package:flutter/material.dart';
import '../models/profile.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../pages/profile_management_page.dart';

/// Profile switcher widget for the AppBar
/// Shows current profile and allows switching between profiles
class ProfileSwitcher extends StatefulWidget {
  const ProfileSwitcher({super.key});

  @override
  State<ProfileSwitcher> createState() => _ProfileSwitcherState();
}

class _ProfileSwitcherState extends State<ProfileSwitcher> {
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();

  @override
  void initState() {
    super.initState();
    _profileService.profileNotifier.addListener(_onProfileChanged);
  }

  @override
  void dispose() {
    _profileService.profileNotifier.removeListener(_onProfileChanged);
    super.dispose();
  }

  void _onProfileChanged() {
    if (mounted) setState(() {});
  }

  Color _getColorFromName(String colorName) {
    switch (colorName.toLowerCase()) {
      case 'red':
        return Colors.red;
      case 'blue':
        return Colors.blue;
      case 'green':
        return Colors.green;
      case 'yellow':
        return Colors.yellow;
      case 'purple':
        return Colors.purple;
      case 'orange':
        return Colors.orange;
      case 'pink':
        return Colors.pink;
      case 'cyan':
        return Colors.cyan;
      default:
        return Colors.blue;
    }
  }

  Widget _buildProfileAvatar(Profile profile, {double size = 32}) {
    // Check if profile has a custom image
    if (profile.profileImagePath != null && profile.profileImagePath!.isNotEmpty) {
      final imageFile = File(profile.profileImagePath!);
      if (imageFile.existsSync()) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withOpacity(0.5),
              width: 2,
            ),
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
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withOpacity(0.5),
          width: 2,
        ),
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/default_profile.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  void _showProfileMenu(BuildContext context) {
    final profiles = _profileService.getAllProfiles();
    final activeProfile = _profileService.getProfile();
    final RenderBox button = context.findRenderObject() as RenderBox;
    final RenderBox overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero),
            ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    showMenu<String>(
      context: context,
      position: position,
      items: [
        // Current profiles
        ...profiles.map((profile) {
          final isActive = profile.id == activeProfile.id;
          return PopupMenuItem<String>(
            value: profile.id,
            child: Row(
              children: [
                _buildProfileAvatar(profile, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Text(
                            profile.nickname.isNotEmpty
                                ? profile.nickname
                                : profile.callsign,
                            style: TextStyle(
                              fontWeight:
                                  isActive ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          const SizedBox(width: 4),
                          if (profile.isRelay)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.orange.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'RELAY',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.orange,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (profile.nickname.isNotEmpty)
                        Text(
                          profile.callsign,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.6),
                          ),
                        ),
                    ],
                  ),
                ),
                if (isActive)
                  Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                    size: 20,
                  ),
              ],
            ),
          );
        }),
        const PopupMenuDivider(),
        // Manage profiles option
        PopupMenuItem<String>(
          value: '_manage',
          child: Row(
            children: [
              Icon(
                Icons.manage_accounts,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Text(_i18n.t('manage_profiles')),
            ],
          ),
        ),
      ],
    ).then((value) async {
      if (value == null) return;

      if (value == '_manage') {
        // Open profile management page
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const ProfileManagementPage(),
            ),
          );
        }
      } else {
        // Switch to selected profile
        await _profileService.switchToProfile(value);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profileService.getProfile();

    return InkWell(
      onTap: () => _showProfileMenu(context),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProfileAvatar(profile),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      profile.nickname.isNotEmpty
                          ? profile.nickname
                          : (profile.callsign.isNotEmpty
                              ? profile.callsign
                              : 'No Profile'),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    if (profile.isRelay) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'RELAY',
                          style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (profile.nickname.isNotEmpty)
                  Text(
                    profile.callsign,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withOpacity(0.7),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.arrow_drop_down,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
            ),
          ],
        ),
      ),
    );
  }
}
