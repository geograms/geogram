/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/profile.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import 'profile_page.dart';
import 'relay_dashboard_page.dart';

/// Page for managing multiple profiles
class ProfileManagementPage extends StatefulWidget {
  const ProfileManagementPage({super.key});

  @override
  State<ProfileManagementPage> createState() => _ProfileManagementPageState();
}

class _ProfileManagementPageState extends State<ProfileManagementPage> {
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();

  List<Profile> _profiles = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _profileService.profileNotifier.addListener(_onProfileChanged);
    _loadProfiles();
  }

  @override
  void dispose() {
    _profileService.profileNotifier.removeListener(_onProfileChanged);
    super.dispose();
  }

  void _onProfileChanged() {
    _loadProfiles();
  }

  void _loadProfiles() {
    setState(() {
      _profiles = _profileService.getAllProfiles();
      _isLoading = false;
    });
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

  Widget _buildProfileAvatar(Profile profile, {double size = 48}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _getColorFromName(profile.preferredColor),
      ),
      child: Center(
        child: Text(
          profile.callsign.isNotEmpty ? profile.callsign.substring(0, 2) : '??',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: size * 0.35,
          ),
        ),
      ),
    );
  }

  Future<void> _createNewProfile() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const _CreateProfileDialog(),
    );

    if (result != null) {
      final useExtension = result['useExtension'] as bool? ?? false;
      final type = result['type'] as ProfileType;
      final nickname = result['nickname'] as String?;

      try {
        if (useExtension) {
          // Create profile using NIP-07 extension
          final profile = await _profileService.createProfileWithExtension(
            nickname: nickname,
          );
          if (profile == null) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_i18n.t('extension_login_failed')),
                  backgroundColor: Colors.red,
                ),
              );
            }
            return;
          }
        } else {
          // Create profile with generated keys
          await _profileService.createNewProfile(
            nickname: nickname,
            type: type,
          );
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_i18n.t('profile_created')),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        LogService().log('Error creating profile: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error creating profile: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _deleteProfile(Profile profile) async {
    if (_profiles.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('cannot_delete_last_profile')),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_profile')),
        content: Text(_i18n.t('delete_profile_confirm',
            params: [profile.callsign])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await _profileService.deleteProfile(profile.id);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('profile_deleted')),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  Future<void> _switchToProfile(Profile profile) async {
    await _profileService.switchToProfile(profile.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('switched_to_profile', params: [profile.callsign])),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _editProfile(Profile profile) {
    // Switch to the profile first, then open edit page
    _profileService.switchToProfile(profile.id).then((_) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const ProfilePage()),
      );
    });
  }

  void _openRelayDashboard(Profile profile) {
    // Switch to the profile first, then open relay dashboard
    _profileService.switchToProfile(profile.id).then((_) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const RelayDashboardPage()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('manage_profiles')),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _createNewProfile,
            tooltip: _i18n.t('create_profile'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _profiles.isEmpty
              ? _buildEmptyState()
              : _buildProfileList(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNewProfile,
        icon: const Icon(Icons.add),
        label: Text(_i18n.t('new_profile')),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.person_outline,
            size: 80,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            _i18n.t('no_profiles'),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            _i18n.t('create_profile_hint'),
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileList() {
    final activeProfile = _profileService.getProfile();

    // Sort profiles: active first, then relays, then clients
    final sortedProfiles = List<Profile>.from(_profiles)
      ..sort((a, b) {
        if (a.id == activeProfile.id) return -1;
        if (b.id == activeProfile.id) return 1;
        if (a.isRelay && !b.isRelay) return -1;
        if (!a.isRelay && b.isRelay) return 1;
        return a.callsign.compareTo(b.callsign);
      });

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sortedProfiles.length,
      itemBuilder: (context, index) {
        final profile = sortedProfiles[index];
        final isActive = profile.id == activeProfile.id;

        return Card(
          elevation: isActive ? 4 : 1,
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: isActive
                ? BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : BorderSide.none,
          ),
          child: InkWell(
            onTap: isActive ? null : () => _switchToProfile(profile),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _buildProfileAvatar(profile),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  profile.callsign,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                                const SizedBox(width: 8),
                                _buildProfileTypeBadge(profile),
                                if (isActive) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primaryContainer,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      _i18n.t('selected'),
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (profile.nickname.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                profile.nickname,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                            const SizedBox(height: 4),
                            Text(
                              'Created: ${_formatDate(profile.createdAt)}',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Colors.grey[600],
                                  ),
                            ),
                          ],
                        ),
                      ),
                      // Activate/Deactivate toggle
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: profile.isActive,
                            onChanged: (value) {
                              _profileService.toggleProfileActive(profile.id);
                            },
                            activeColor: Colors.green,
                          ),
                          Text(
                            profile.isActive
                                ? _i18n.t('running')
                                : _i18n.t('stopped'),
                            style: TextStyle(
                              fontSize: 10,
                              color: profile.isActive
                                  ? Colors.green
                                  : Colors.grey[600],
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        onSelected: (value) {
                          switch (value) {
                            case 'edit':
                              _editProfile(profile);
                              break;
                            case 'relay':
                              _openRelayDashboard(profile);
                              break;
                            case 'switch':
                              _switchToProfile(profile);
                              break;
                            case 'activate':
                              _profileService.activateProfile(profile.id);
                              break;
                            case 'deactivate':
                              _profileService.deactivateProfile(profile.id);
                              break;
                            case 'copy':
                              _copyCallsign(profile);
                              break;
                            case 'delete':
                              _deleteProfile(profile);
                              break;
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Row(
                              children: [
                                const Icon(Icons.edit),
                                const SizedBox(width: 8),
                                Text(_i18n.t('edit_profile')),
                              ],
                            ),
                          ),
                          if (profile.isRelay)
                            PopupMenuItem(
                              value: 'relay',
                              child: Row(
                                children: [
                                  const Icon(Icons.cell_tower),
                                  const SizedBox(width: 8),
                                  Text(_i18n.t('relay_dashboard')),
                                ],
                              ),
                            ),
                          if (!isActive)
                            PopupMenuItem(
                              value: 'switch',
                              child: Row(
                                children: [
                                  const Icon(Icons.swap_horiz),
                                  const SizedBox(width: 8),
                                  Text(_i18n.t('switch_to_profile')),
                                ],
                              ),
                            ),
                          const PopupMenuDivider(),
                          if (!profile.isActive)
                            PopupMenuItem(
                              value: 'activate',
                              child: Row(
                                children: [
                                  const Icon(Icons.play_arrow, color: Colors.green),
                                  const SizedBox(width: 8),
                                  Text(_i18n.t('activate_profile')),
                                ],
                              ),
                            )
                          else
                            PopupMenuItem(
                              value: 'deactivate',
                              child: Row(
                                children: [
                                  Icon(Icons.stop, color: Colors.grey[600]),
                                  const SizedBox(width: 8),
                                  Text(_i18n.t('deactivate_profile')),
                                ],
                              ),
                            ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'copy',
                            child: Row(
                              children: [
                                const Icon(Icons.copy),
                                const SizedBox(width: 8),
                                Text(_i18n.t('copy_callsign')),
                              ],
                            ),
                          ),
                          if (_profiles.length > 1) ...[
                            const PopupMenuDivider(),
                            PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  const Icon(Icons.delete, color: Colors.red),
                                  const SizedBox(width: 8),
                                  Text(
                                    _i18n.t('delete'),
                                    style: const TextStyle(color: Colors.red),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                  if (profile.isRelay) ...[
                    const SizedBox(height: 12),
                    const Divider(),
                    const SizedBox(height: 8),
                    _buildRelayQuickActions(profile, isActive),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildProfileTypeBadge(Profile profile) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: profile.isRelay
            ? Colors.orange.withOpacity(0.2)
            : Colors.blue.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        profile.isRelay ? 'RELAY' : 'CLIENT',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: profile.isRelay ? Colors.orange : Colors.blue,
        ),
      ),
    );
  }

  Widget _buildRelayQuickActions(Profile profile, bool isActive) {
    return Row(
      children: [
        Icon(
          Icons.cell_tower,
          size: 16,
          color: Colors.orange[700],
        ),
        const SizedBox(width: 8),
        Text(
          _i18n.t('relay_profile'),
          style: TextStyle(
            fontSize: 12,
            color: Colors.orange[700],
            fontWeight: FontWeight.w500,
          ),
        ),
        const Spacer(),
        if (profile.port != null)
          Text(
            'Port: ${profile.port}',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
        const SizedBox(width: 16),
        OutlinedButton.icon(
          onPressed: () => _openRelayDashboard(profile),
          icon: const Icon(Icons.dashboard, size: 16),
          label: Text(_i18n.t('dashboard')),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            textStyle: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  void _copyCallsign(Profile profile) {
    Clipboard.setData(ClipboardData(text: profile.callsign));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_i18n.t('copied_to_clipboard', params: [profile.callsign])),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

/// Dialog for creating a new profile
class _CreateProfileDialog extends StatefulWidget {
  const _CreateProfileDialog();

  @override
  State<_CreateProfileDialog> createState() => _CreateProfileDialogState();
}

class _CreateProfileDialogState extends State<_CreateProfileDialog> {
  final I18nService _i18n = I18nService();
  final ProfileService _profileService = ProfileService();
  final TextEditingController _nicknameController = TextEditingController();
  ProfileType _selectedType = ProfileType.client;
  bool _useExtension = false;
  bool _extensionAvailable = false;
  bool _checkingExtension = true;

  @override
  void initState() {
    super.initState();
    _checkExtensionAvailability();
  }

  Future<void> _checkExtensionAvailability() async {
    if (kIsWeb) {
      final available = await _profileService.isExtensionAvailable();
      if (mounted) {
        setState(() {
          _extensionAvailable = available;
          _checkingExtension = false;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _extensionAvailable = false;
          _checkingExtension = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_i18n.t('create_profile')),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // NIP-07 Extension option (web only)
            if (kIsWeb) ...[
              _buildExtensionOption(),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 16),
            ],
            // Profile type selection (only show if not using extension)
            if (!_useExtension) ...[
              Text(
                _i18n.t('profile_type'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _buildTypeOption(
                      type: ProfileType.client,
                      icon: Icons.person,
                      title: _i18n.t('client'),
                      description: _i18n.t('client_description'),
                      color: Colors.blue,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildTypeOption(
                      type: ProfileType.relay,
                      icon: Icons.cell_tower,
                      title: _i18n.t('relay'),
                      description: _i18n.t('relay_description'),
                      color: Colors.orange,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
            Text(
              _i18n.t('nickname_optional'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nicknameController,
              decoration: InputDecoration(
                hintText: _i18n.t('enter_nickname'),
                border: const OutlineInputBorder(),
              ),
              maxLength: 50,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_i18n.t('cancel')),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context, {
              'type': _selectedType,
              'useExtension': _useExtension,
              'nickname': _nicknameController.text.trim().isEmpty
                  ? null
                  : _nicknameController.text.trim(),
            });
          },
          child: Text(_i18n.t('create')),
        ),
      ],
    );
  }

  Widget _buildExtensionOption() {
    final isSelected = _useExtension;

    return InkWell(
      onTap: _extensionAvailable
          ? () => setState(() {
                _useExtension = !_useExtension;
              })
          : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected
                ? Colors.purple
                : _extensionAvailable
                    ? Colors.grey[300]!
                    : Colors.grey[200]!,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: isSelected
              ? Colors.purple.withOpacity(0.1)
              : _extensionAvailable
                  ? null
                  : Colors.grey[100],
        ),
        child: Row(
          children: [
            Icon(
              Icons.extension,
              size: 40,
              color: _extensionAvailable
                  ? (isSelected ? Colors.purple : Colors.grey[600])
                  : Colors.grey[400],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        _i18n.t('login_with_extension'),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _extensionAvailable
                              ? (isSelected ? Colors.purple : null)
                              : Colors.grey[500],
                        ),
                      ),
                      if (_checkingExtension) ...[
                        const SizedBox(width: 8),
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ] else if (_extensionAvailable) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _i18n.t('available'),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _extensionAvailable
                        ? _i18n.t('extension_login_description')
                        : _i18n.t('extension_not_available'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            if (_extensionAvailable)
              Checkbox(
                value: _useExtension,
                onChanged: (value) {
                  setState(() {
                    _useExtension = value ?? false;
                  });
                },
                activeColor: Colors.purple,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeOption({
    required ProfileType type,
    required IconData icon,
    required String title,
    required String description,
    required Color color,
  }) {
    final isSelected = _selectedType == type && !_useExtension;

    return InkWell(
      onTap: _useExtension
          ? null
          : () => setState(() => _selectedType = type),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected
                ? color
                : _useExtension
                    ? Colors.grey[200]!
                    : Colors.grey[300]!,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: isSelected
              ? color.withOpacity(0.1)
              : _useExtension
                  ? Colors.grey[100]
                  : null,
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 32,
              color: _useExtension
                  ? Colors.grey[400]
                  : (isSelected ? color : Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: _useExtension ? Colors.grey[400] : (isSelected ? color : null),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: _useExtension ? Colors.grey[400] : Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
