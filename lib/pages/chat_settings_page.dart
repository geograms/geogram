/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/chat_settings.dart';
import '../models/chat_security.dart';
import '../services/chat_service.dart';
import '../services/profile_service.dart';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:path/path.dart' as path;

/// Page for managing chat settings and moderators
class ChatSettingsPage extends StatefulWidget {
  final String collectionPath;

  const ChatSettingsPage({
    Key? key,
    required this.collectionPath,
  }) : super(key: key);

  @override
  State<ChatSettingsPage> createState() => _ChatSettingsPageState();
}

class _ChatSettingsPageState extends State<ChatSettingsPage> {
  final ChatService _chatService = ChatService();
  final ProfileService _profileService = ProfileService();

  ChatSettings _settings = ChatSettings();
  ChatSecurity _security = ChatSecurity();
  bool _isLoading = false;
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  /// Load settings and security
  Future<void> _loadSettings() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Load settings
      final settingsFile =
          File(path.join(widget.collectionPath, 'extra', 'settings.json'));
      if (await settingsFile.exists()) {
        final content = await settingsFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        _settings = ChatSettings.fromJson(json);
      }

      // Load security
      _security = _chatService.security;

      // Check if current user is admin
      final profile = _profileService.getProfile();
      _isAdmin = _security.isAdmin(profile.npub);
    } catch (e) {
      _showError('Failed to load settings: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Save settings
  Future<void> _saveSettings() async {
    try {
      final extraDir = Directory(path.join(widget.collectionPath, 'extra'));
      if (!await extraDir.exists()) {
        await extraDir.create(recursive: true);
      }

      final settingsFile =
          File(path.join(widget.collectionPath, 'extra', 'settings.json'));
      await settingsFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_settings.toJson()),
      );
    } catch (e) {
      _showError('Failed to save settings: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Chat Settings'),
        ),
        body: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Message signing section
          _buildSection(
            theme,
            'Message Signing',
            [
              SwitchListTile(
                title: const Text('Sign messages by default'),
                subtitle: const Text(
                  'Automatically sign all outgoing messages with your NOSTR key',
                ),
                value: _settings.signMessages,
                onChanged: (value) {
                  setState(() {
                    _settings = _settings.copyWith(signMessages: value);
                  });
                  _saveSettings();
                },
              ),
              if (_profileService.getProfile().npub.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Note: You need to set up your NOSTR keys in your profile to use message signing.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 24),

          // Security section (admin only)
          if (_isAdmin) ...[
            _buildSection(
              theme,
              'Security & Moderation',
              [
                ListTile(
                  title: const Text('Your Admin Status'),
                  subtitle: Text('npub: ${_security.adminNpub ?? "Not set"}'),
                  leading: const Icon(Icons.admin_panel_settings),
                ),
                const Divider(),
                ..._buildModeratorSections(theme),
              ],
            ),
          ] else ...[
            _buildSection(
              theme,
              'Moderation',
              [
                ListTile(
                  title: const Text('Moderators'),
                  subtitle: const Text(
                      'Only the chat administrator can manage moderators'),
                  leading: const Icon(Icons.shield),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Build moderator sections for each channel
  List<Widget> _buildModeratorSections(ThemeData theme) {
    List<Widget> widgets = [];

    // Main channel moderators
    widgets.add(
      ListTile(
        title: const Text('Main Channel Moderators'),
        trailing: IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => _addModerator('main'),
        ),
      ),
    );

    final mainMods = _security.getModerators('main');
    if (mainMods.isEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            'No moderators assigned',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    } else {
      for (var npub in mainMods) {
        widgets.add(
          ListTile(
            dense: true,
            leading: const Icon(Icons.person, size: 20),
            title: Text(
              npub,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete, size: 20),
              onPressed: () => _removeModerator('main', npub),
            ),
          ),
        );
      }
    }

    widgets.add(const Divider());

    // Group channels
    final channels = _chatService.channels
        .where((ch) => ch.isGroup && ch.id != 'main')
        .toList();

    for (var channel in channels) {
      widgets.add(
        ListTile(
          title: Text('${channel.name} Moderators'),
          trailing: IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _addModerator(channel.id),
          ),
        ),
      );

      final channelMods = _security.getModerators(channel.id);
      if (channelMods.isEmpty) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'No moderators assigned',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        );
      } else {
        for (var npub in channelMods) {
          widgets.add(
            ListTile(
              dense: true,
              leading: const Icon(Icons.person, size: 20),
              title: Text(
                npub,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete, size: 20),
                onPressed: () => _removeModerator(channel.id, npub),
              ),
            ),
          );
        }
      }

      widgets.add(const Divider());
    }

    return widgets;
  }

  /// Build a section
  Widget _buildSection(ThemeData theme, String title, List<Widget> children) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  /// Add moderator dialog
  Future<void> _addModerator(String channelId) async {
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Moderator'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'NOSTR public key (npub)',
            hintText: 'npub1...',
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      if (!result.startsWith('npub1')) {
        _showError('Invalid npub format');
        return;
      }

      try {
        _security.addModerator(channelId, result);
        await _chatService.saveSecurity(_security);
        setState(() {});
        _showSuccess('Moderator added');
      } catch (e) {
        _showError('Failed to add moderator: $e');
      }
    }
  }

  /// Remove moderator
  Future<void> _removeModerator(String channelId, String npub) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Moderator'),
        content: const Text('Are you sure you want to remove this moderator?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        _security.removeModerator(channelId, npub);
        await _chatService.saveSecurity(_security);
        setState(() {});
        _showSuccess('Moderator removed');
      } catch (e) {
        _showError('Failed to remove moderator: $e');
      }
    }
  }

  /// Show error message
  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  /// Show success message
  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
}
