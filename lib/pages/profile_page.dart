import 'dart:io' as io;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../models/profile.dart';
import '../services/profile_service.dart';
import '../services/log_service.dart';
import '../services/i18n_service.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final TextEditingController _nicknameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  Profile? _profile;
  bool _isLoading = true;
  String? _profileImagePath;

  // Color options - keys for translation
  final List<String> _colorOptions = [
    'red',
    'blue',
    'green',
    'yellow',
    'purple',
    'orange',
    'pink',
    'cyan',
  ];

  @override
  void initState() {
    super.initState();
    _i18n.languageNotifier.addListener(_onLanguageChanged);
    _loadProfile();
  }

  void _onLanguageChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _i18n.languageNotifier.removeListener(_onLanguageChanged);
    _saveProfile(showSnackbar: false);
    _nicknameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    setState(() => _isLoading = true);

    try {
      final profile = _profileService.getProfile();
      setState(() {
        _profile = profile;
        _nicknameController.text = profile.nickname;
        _descriptionController.text = profile.description;
        _profileImagePath = profile.profileImagePath;
        _isLoading = false;
      });
    } catch (e) {
      LogService().log('Error loading profile: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveProfile({bool showSnackbar = false}) async {
    if (_profile == null) return;

    try {
      final updatedProfile = _profile!.copyWith(
        nickname: _nicknameController.text,
        description: _descriptionController.text,
        profileImagePath: _profileImagePath,
      );

      await _profileService.saveProfile(updatedProfile);

      if (mounted && showSnackbar) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('profile_saved')),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      LogService().log('Error saving profile: $e');
      if (mounted && showSnackbar) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('error_saving_profile', params: [e.toString()])),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _pickProfileImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        dialogTitle: _i18n.t('select_profile_picture'),
      );

      if (result != null && result.files.isNotEmpty) {
        final filePath = result.files.first.path!;
        final savedPath = await _profileService.setProfilePicture(filePath);

        if (savedPath != null) {
          setState(() {
            _profileImagePath = savedPath;
          });

          LogService().log('Profile picture selected: $savedPath');
        }
      }
    } catch (e) {
      LogService().log('Error picking profile image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('error_selecting_image', params: [e.toString()])),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _removeProfileImage() async {
    await _profileService.removeProfilePicture();
    setState(() {
      _profileImagePath = null;
    });
  }

  void _copyToClipboard(String text, String label) {
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('field_is_empty'))),
      );
      return;
    }

    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_i18n.t('copied_to_clipboard', params: [label])),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _resetIdentity() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('reset_identity')),
        content: Text(_i18n.t('reset_identity_confirm')),
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
            child: Text(_i18n.t('yes_reset')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _profileService.regenerateIdentity();
      await _loadProfile();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('new_identity_generated')),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('profile_settings')),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Profile Information Section
                  Text(
                    _i18n.t('profile_information'),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),

                  // Profile picture and fields in a row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Profile Picture and Preferred Color on the left
                      SizedBox(
                        width: 160,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Profile Picture
                            Center(
                              child: GestureDetector(
                                onTap: _pickProfileImage,
                                child: Container(
                                  width: 100,
                                  height: 100,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                    image: (_profileImagePath != null && !kIsWeb)
                                        ? DecorationImage(
                                            image: FileImage(io.File(_profileImagePath!)),
                                            fit: BoxFit.cover,
                                          )
                                        : null,
                                  ),
                                  child: _profileImagePath == null
                                      ? Icon(
                                          Icons.person,
                                          size: 50,
                                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        )
                                      : null,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: _pickProfileImage,
                              icon: const Icon(Icons.upload, size: 16),
                              label: Text(
                                _profileImagePath == null ? _i18n.t('upload') : _i18n.t('change'),
                                style: const TextStyle(fontSize: 12),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                minimumSize: const Size(0, 0),
                              ),
                            ),
                            if (_profileImagePath != null) ...[
                              const SizedBox(height: 4),
                              Center(
                                child: IconButton(
                                  icon: const Icon(Icons.delete, size: 20),
                                  onPressed: _removeProfileImage,
                                  tooltip: _i18n.t('remove_picture'),
                                  color: Theme.of(context).colorScheme.error,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                ),
                              ),
                            ],

                            const SizedBox(height: 24),

                            // Preferred Color
                            Text(
                              _i18n.t('preferred_color'),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              value: _profile != null && _colorOptions.contains(_profile!.preferredColor.toLowerCase())
                                  ? _profile!.preferredColor.toLowerCase()
                                  : 'blue',
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                filled: true,
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              items: _colorOptions.map((color) {
                                return DropdownMenuItem(
                                  value: color,
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 20,
                                        height: 20,
                                        decoration: BoxDecoration(
                                          color: _getColorFromName(color),
                                          shape: BoxShape.circle,
                                          border: Border.all(color: Colors.grey),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _i18n.t(color),
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: (value) async {
                                if (value != null && _profile != null) {
                                  final updatedProfile = _profile!.copyWith(
                                    preferredColor: value.toLowerCase(),
                                  );
                                  await _profileService.saveProfile(updatedProfile);
                                  setState(() {
                                    _profile = updatedProfile;
                                  });
                                }
                              },
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 24),

                      // Form fields on the right
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Nickname Field
                            Text(
                              _i18n.t('nickname'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _nicknameController,
                              decoration: InputDecoration(
                                hintText: _i18n.t('enter_your_nickname'),
                                border: const OutlineInputBorder(),
                                filled: true,
                              ),
                              maxLength: 50,
                            ),

                            const SizedBox(height: 16),

                            // Description Field
                            Text(
                              _i18n.t('description'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _descriptionController,
                              decoration: InputDecoration(
                                hintText: _i18n.t('tell_about_yourself'),
                                border: const OutlineInputBorder(),
                                filled: true,
                              ),
                              maxLines: 4,
                              maxLength: 200,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 32),
                  const Divider(),
                  const SizedBox(height: 16),

                  // Identity Section
                  Text(
                    _i18n.t('nostr_identity'),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),

                  // Callsign (read-only)
                  Text(
                    _i18n.t('callsign'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline.withOpacity(0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _profile?.callsign ?? '',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy),
                          onPressed: () => _copyToClipboard(_profile?.callsign ?? '', _i18n.t('callsign')),
                          tooltip: _i18n.t('copy_callsign'),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // NPUB (read-only)
                  Text(
                    _i18n.t('nostr_public_key'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline.withOpacity(0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            _profile?.npub ?? '',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.copy),
                          onPressed: () => _copyToClipboard(_profile?.npub ?? '', _i18n.t('nostr_public_key')),
                          tooltip: _i18n.t('copy_to_clipboard'),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // NSEC (read-only, sensitive)
                  Text(
                    _i18n.t('nostr_private_key'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _i18n.t('keep_secret_warning'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.error.withOpacity(0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            _profile?.nsec ?? '',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.copy),
                          onPressed: () => _copyToClipboard(_profile?.nsec ?? '', _i18n.t('nostr_private_key')),
                          tooltip: _i18n.t('copy_to_clipboard'),
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Reset Identity Button
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _resetIdentity,
                      icon: const Icon(Icons.refresh),
                      label: Text(_i18n.t('reset_identity')),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                        side: BorderSide(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
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
}

extension StringExtension on String {
  String capitalize() {
    if (isEmpty) return this;
    return '${this[0].toUpperCase()}${substring(1)}';
  }
}
