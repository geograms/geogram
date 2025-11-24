/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:convert';
import 'package:path/path.dart' as path;
import '../models/collection.dart';
import '../models/chat_channel.dart';
import '../models/chat_message.dart';
import '../models/chat_settings.dart';
import '../services/chat_service.dart';
import '../services/profile_service.dart';
import '../widgets/channel_list_widget.dart';
import '../widgets/message_list_widget.dart';
import '../widgets/message_input_widget.dart';
import '../widgets/new_channel_dialog.dart';
import 'chat_settings_page.dart';

/// Page for browsing and interacting with a chat collection
class ChatBrowserPage extends StatefulWidget {
  final Collection collection;

  const ChatBrowserPage({
    Key? key,
    required this.collection,
  }) : super(key: key);

  @override
  State<ChatBrowserPage> createState() => _ChatBrowserPageState();
}

class _ChatBrowserPageState extends State<ChatBrowserPage> {
  final ChatService _chatService = ChatService();
  final ProfileService _profileService = ProfileService();

  List<ChatChannel> _channels = [];
  ChatChannel? _selectedChannel;
  List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initializeChat();
  }

  /// Initialize chat service and load data
  Future<void> _initializeChat() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Initialize chat service with collection path
      final storagePath = widget.collection.storagePath;
      if (storagePath == null) {
        throw Exception('Collection storage path is null');
      }

      // Pass current user's npub to initialize admin if needed
      final currentProfile = _profileService.getProfile();
      await _chatService.initializeCollection(
        storagePath,
        creatorNpub: currentProfile.npub,
      );

      // Load channels
      _channels = _chatService.channels;

      // Select main channel by default only in wide screen mode
      if (_channels.isNotEmpty && mounted) {
        final screenWidth = MediaQuery.of(context).size.width;
        final isWideScreen = screenWidth >= 600;

        if (isWideScreen) {
          await _selectChannel(_channels.first);
        }
      }

      setState(() {
        _isInitialized = true;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to initialize chat: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Select a channel and load its messages
  Future<void> _selectChannel(ChatChannel channel) async {
    setState(() {
      _selectedChannel = channel;
      _isLoading = true;
    });

    try {
      // Load messages for selected channel
      final messages = await _chatService.loadMessages(
        channel.id,
        limit: 100,
      );

      setState(() {
        _messages = messages;
      });
    } catch (e) {
      _showError('Failed to load messages: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Select a channel for mobile view (just sets it, layout handles display)
  Future<void> _selectChannelMobile(ChatChannel channel) async {
    await _selectChannel(channel);
  }

  /// Send a message
  Future<void> _sendMessage(String content, String? filePath) async {
    if (_selectedChannel == null) return;

    final currentProfile = _profileService.getProfile();
    if (currentProfile.callsign.isEmpty) {
      _showError('No active callsign. Please set up your profile first.');
      return;
    }

    try {
      // Load chat settings
      final settings = await _loadChatSettings();

      // Create message
      Map<String, String> metadata = {};

      // Handle file attachment
      String? attachedFileName;
      if (filePath != null) {
        attachedFileName = await _copyFileToChannel(filePath);
        if (attachedFileName != null) {
          metadata['file'] = attachedFileName;
        }
      }

      // Add signing if enabled
      if (settings.signMessages &&
          currentProfile.npub.isNotEmpty &&
          currentProfile.nsec.isNotEmpty) {
        // Add npub
        metadata['npub'] = currentProfile.npub;

        // TODO: Implement proper NOSTR signing using secp256k1
        // For now, add a placeholder signature
        // Real implementation should:
        // 1. Construct message text to sign (everything before signature)
        // 2. Hash the message using SHA-256
        // 3. Sign the hash with nsec using Schnorr signature on secp256k1
        // 4. Encode signature as hex
        metadata['signature'] = _generatePlaceholderSignature(
          content,
          metadata,
          currentProfile.nsec,
        );
      }

      // Create message object
      final message = ChatMessage.now(
        author: currentProfile.callsign,
        content: content,
        metadata: metadata.isNotEmpty ? metadata : null,
      );

      // Save message
      await _chatService.saveMessage(_selectedChannel!.id, message);

      // Add to local list (optimistic update)
      setState(() {
        _messages.add(message);
      });
    } catch (e) {
      _showError('Failed to send message: $e');
    }
  }

  /// Load chat settings
  Future<ChatSettings> _loadChatSettings() async {
    try {
      final storagePath = widget.collection.storagePath;
      if (storagePath == null) return ChatSettings();

      final settingsFile =
          File(path.join(storagePath, 'extra', 'settings.json'));
      if (!await settingsFile.exists()) {
        return ChatSettings();
      }

      final content = await settingsFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return ChatSettings.fromJson(json);
    } catch (e) {
      return ChatSettings();
    }
  }

  /// Generate placeholder signature
  /// TODO: Replace with proper NOSTR signing implementation
  String _generatePlaceholderSignature(
    String content,
    Map<String, String> metadata,
    String nsec,
  ) {
    // This is a placeholder. Real implementation needs:
    // - secp256k1 library for Schnorr signatures
    // - Proper message hashing (SHA-256)
    // - Signature encoding
    return 'PLACEHOLDER_SIGNATURE_${DateTime.now().millisecondsSinceEpoch}';
  }

  /// Copy file to channel's files folder
  Future<String?> _copyFileToChannel(String sourceFilePath) async {
    try {
      final sourceFile = File(sourceFilePath);
      if (!await sourceFile.exists()) {
        _showError('File not found');
        return null;
      }

      // Determine destination folder
      final storagePath = widget.collection.storagePath;
      if (storagePath == null) {
        _showError('Collection storage path is null');
        return null;
      }

      // For main channel, use year subfolder; for others, use channel folder directly
      String filesPath;
      if (_selectedChannel!.id == 'main') {
        final year = DateTime.now().year.toString();
        filesPath = path.join(storagePath, _selectedChannel!.folder, year, 'files');
      } else {
        filesPath = path.join(storagePath, _selectedChannel!.folder, 'files');
      }

      final filesDir = Directory(filesPath);

      // Create files directory if it doesn't exist
      if (!await filesDir.exists()) {
        await filesDir.create(recursive: true);
      }

      // Truncate filename if longer than 100 chars
      String fileName = path.basename(sourceFilePath);
      if (fileName.length > 100) {
        final ext = path.extension(fileName);
        final nameWithoutExt = path.basenameWithoutExtension(fileName);
        final maxNameLength = 100 - ext.length;
        fileName = nameWithoutExt.substring(0, maxNameLength) + ext;
      }

      final destPath = path.join(filesDir.path, fileName);
      var destFile = File(destPath);

      // Handle duplicate filenames
      int counter = 1;
      while (await destFile.exists()) {
        final nameWithoutExt = path.basenameWithoutExtension(fileName);
        final ext = path.extension(fileName);
        final newName = '${nameWithoutExt}_$counter$ext';
        destFile = File(path.join(filesDir.path, newName));
        counter++;
      }

      // Copy file
      await sourceFile.copy(destFile.path);

      return path.basename(destFile.path);
    } catch (e) {
      _showError('Failed to copy file: $e');
      return null;
    }
  }

  /// Check if user can delete a message
  bool _canDeleteMessage(ChatMessage message) {
    if (_selectedChannel == null) return false;

    final currentProfile = _profileService.getProfile();
    final userNpub = currentProfile.npub;

    // Check if user is admin or moderator
    return _chatService.security.canModerate(userNpub, _selectedChannel!.id);
  }

  /// Delete a message
  Future<void> _deleteMessage(ChatMessage message) async {
    if (_selectedChannel == null) return;

    try {
      final currentProfile = _profileService.getProfile();
      final userNpub = currentProfile.npub;

      await _chatService.deleteMessage(
        _selectedChannel!.id,
        message,
        userNpub,
      );

      // Remove from local list
      setState(() {
        _messages.removeWhere((msg) =>
            msg.timestamp == message.timestamp && msg.author == message.author);
      });

      _showSuccess('Message deleted');
    } catch (e) {
      _showError('Failed to delete message: $e');
    }
  }

  /// Open attached file
  Future<void> _openAttachedFile(ChatMessage message) async {
    if (!message.hasFile) return;

    try {
      final storagePath = widget.collection.storagePath;
      if (storagePath == null) {
        _showError('Collection storage path is null');
        return;
      }

      // Construct file path based on channel type
      String filePath;
      if (_selectedChannel!.id == 'main') {
        // For main channel, files are in year folders
        final year = message.dateTime.year.toString();
        filePath = path.join(
          storagePath,
          _selectedChannel!.folder,
          year,
          'files',
          message.attachedFile!,
        );
      } else {
        // For DM and group channels, files are in channel folder
        filePath = path.join(
          storagePath,
          _selectedChannel!.folder,
          'files',
          message.attachedFile!,
        );
      }

      final file = File(filePath);
      if (!await file.exists()) {
        _showError('File not found: ${message.attachedFile}');
        return;
      }

      // Open file with default application (using xdg-open on Linux)
      if (Platform.isLinux) {
        await Process.run('xdg-open', [filePath]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [filePath]);
      } else if (Platform.isWindows) {
        await Process.run('start', [filePath], runInShell: true);
      }
    } catch (e) {
      _showError('Failed to open file: $e');
    }
  }

  /// Show new channel dialog
  Future<void> _showNewChannelDialog() async {
    final result = await showDialog<ChatChannel>(
      context: context,
      builder: (context) => NewChannelDialog(
        existingChannelIds: _channels.map((ch) => ch.id).toList(),
        knownCallsigns: _chatService.participants.keys.toList(),
      ),
    );

    if (result != null) {
      try {
        setState(() {
          _isLoading = true;
        });

        // Create channel
        final channel = await _chatService.createChannel(result);

        // Refresh channels
        await _chatService.refreshChannels();

        setState(() {
          _channels = _chatService.channels;
        });

        // Select the new channel
        await _selectChannel(channel);

        _showSuccess('Channel created successfully');
      } catch (e) {
        _showError('Failed to create channel: $e');
      } finally {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Refresh current channel
  Future<void> _refreshChannel() async {
    if (_selectedChannel != null) {
      await _selectChannel(_selectedChannel!);
    }
  }

  /// Open settings page
  void _openSettings() {
    final storagePath = widget.collection.storagePath;
    if (storagePath == null) {
      _showError('Collection storage path is null');
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatSettingsPage(
          collectionPath: storagePath,
        ),
      ),
    ).then((_) {
      // Reload security settings when returning
      _chatService.refreshChannels();
      setState(() {});
    });
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final screenWidth = MediaQuery.of(context).size.width;
    final isWideScreen = screenWidth >= 600;

    return Scaffold(
      appBar: AppBar(
        leading: !isWideScreen && _selectedChannel != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  setState(() {
                    _selectedChannel = null;
                  });
                },
              )
            : null,
        title: LayoutBuilder(
          builder: (context, constraints) {
            // In narrow screen, show collection title when on channel list
            if (!isWideScreen && _selectedChannel == null) {
              return Text(widget.collection.title);
            }

            return Text(
              _selectedChannel?.name ?? widget.collection.title,
            );
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshChannel,
            tooltip: 'Refresh',
          ),
          if (_selectedChannel != null)
            IconButton(
              icon: const Icon(Icons.info_outline),
              onPressed: _showChannelInfo,
              tooltip: 'Channel info',
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
            tooltip: 'Settings',
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  /// Build main body
  Widget _buildBody(ThemeData theme) {
    if (!_isInitialized && _isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              _error!,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _initializeChat,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_channels.isEmpty) {
      return _buildEmptyState(theme);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Use two-panel layout for wide screens, single panel for narrow
        final isWideScreen = constraints.maxWidth >= 600;

        if (isWideScreen) {
          // Desktop/landscape: Two-panel layout
          return Row(
            children: [
              // Left sidebar - Channel list
              ChannelListWidget(
                channels: _channels,
                selectedChannelId: _selectedChannel?.id,
                onChannelSelect: _selectChannel,
                onNewChannel: _showNewChannelDialog,
              ),
              // Right panel - Messages and input
              Expanded(
                child: _selectedChannel == null
                    ? _buildNoChannelSelected(theme)
                    : Column(
                        children: [
                          // Message list
                          Expanded(
                            child: MessageListWidget(
                              messages: _messages,
                              isGroupChat: _selectedChannel!.isGroup,
                              isLoading: _isLoading,
                              onFileOpen: _openAttachedFile,
                              onMessageDelete: _deleteMessage,
                              canDeleteMessage: _canDeleteMessage,
                            ),
                          ),
                          // Message input
                          MessageInputWidget(
                            onSend: _sendMessage,
                            maxLength: _selectedChannel!.config?.maxSizeText ?? 500,
                            allowFiles:
                                _selectedChannel!.config?.fileUpload ?? true,
                          ),
                        ],
                      ),
              ),
            ],
          );
        } else {
          // Mobile/portrait: Single panel
          if (_selectedChannel == null) {
            // Show full-width channel list
            return _buildFullWidthChannelList(theme);
          } else {
            // Show chat messages (no duplicate header, using AppBar)
            return Column(
              children: [
                // Message list
                Expanded(
                  child: MessageListWidget(
                    messages: _messages,
                    isGroupChat: _selectedChannel!.isGroup,
                    isLoading: _isLoading,
                    onFileOpen: _openAttachedFile,
                    onMessageDelete: _deleteMessage,
                    canDeleteMessage: _canDeleteMessage,
                  ),
                ),
                // Message input
                MessageInputWidget(
                  onSend: _sendMessage,
                  maxLength: _selectedChannel!.config?.maxSizeText ?? 500,
                  allowFiles: _selectedChannel!.config?.fileUpload ?? true,
                ),
              ],
            );
          }
        }
      },
    );
  }

  /// Build full-width channel list for mobile view
  Widget _buildFullWidthChannelList(ThemeData theme) {
    // Sort channels: favorites first, then by last message time
    final sortedChannels = List<ChatChannel>.from(_channels);
    sortedChannels.sort((a, b) {
      // Favorites first
      if (a.isFavorite && !b.isFavorite) return -1;
      if (!a.isFavorite && b.isFavorite) return 1;

      // Main channel always at top (after favorites)
      if (a.isMain && !b.isMain) return -1;
      if (!a.isMain && b.isMain) return 1;

      // Then by last message time (newest first)
      if (a.lastMessageTime == null && b.lastMessageTime == null) return 0;
      if (a.lastMessageTime == null) return 1;
      if (b.lastMessageTime == null) return -1;
      return b.lastMessageTime!.compareTo(a.lastMessageTime!);
    });

    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant,
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.chat, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Channels',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _showNewChannelDialog,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ],
            ),
          ),
          // Channel list
          Expanded(
            child: ListView.builder(
              itemCount: sortedChannels.length,
              itemBuilder: (context, index) {
                final channel = sortedChannels[index];

                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: channel.isGroup
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.secondaryContainer,
                    child: Icon(
                      channel.isGroup ? Icons.group : Icons.person,
                      color: channel.isGroup
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSecondaryContainer,
                      size: 20,
                    ),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          channel.name,
                          style: TextStyle(
                            fontWeight: channel.isFavorite
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (channel.isFavorite)
                        Icon(
                          Icons.star,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                    ],
                  ),
                  subtitle: channel.description != null && channel.description!.isNotEmpty
                      ? Text(
                          channel.description!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : (channel.isGroup
                          ? const Text('Group chat')
                          : null),
                  onTap: () => _selectChannelMobile(channel),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Build empty state
  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 80,
            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
          ),
          const SizedBox(height: 24),
          Text(
            'No channels found',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Create a channel to start chatting',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _showNewChannelDialog,
            icon: const Icon(Icons.add),
            label: const Text('Create Channel'),
          ),
        ],
      ),
    );
  }

  /// Build no channel selected state
  Widget _buildNoChannelSelected(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Select a channel to start chatting',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Show channel information dialog
  void _showChannelInfo() {
    if (_selectedChannel == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_selectedChannel!.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildInfoRow('Type', _selectedChannel!.type.name),
              _buildInfoRow('ID', _selectedChannel!.id),
              if (_selectedChannel!.description != null)
                _buildInfoRow('Description', _selectedChannel!.description!),
              _buildInfoRow('Participants',
                  _selectedChannel!.participants.join(', ')),
              _buildInfoRow('Created',
                  _selectedChannel!.created.toString().substring(0, 16)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Build info row
  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: const TextStyle(fontSize: 12),
          ),
          const Divider(),
        ],
      ),
    );
  }
}
