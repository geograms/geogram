/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/chat_message.dart';
import '../services/profile_service.dart';
import '../services/devices_service.dart';
import 'voice_player_widget.dart';

/// Widget for displaying a single chat message bubble
class MessageBubbleWidget extends StatelessWidget {
  final ChatMessage message;
  final bool isGroupChat;
  final VoidCallback? onFileOpen;
  final VoidCallback? onLocationView;
  final VoidCallback? onDelete;
  final bool canDelete;
  /// Path to the voice file (for voice messages)
  final String? voiceFilePath;
  /// Callback to request download of voice file from remote
  final Future<String?> Function()? onVoiceDownloadRequested;

  const MessageBubbleWidget({
    Key? key,
    required this.message,
    this.isGroupChat = true,
    this.onFileOpen,
    this.onLocationView,
    this.onDelete,
    this.canDelete = false,
    this.voiceFilePath,
    this.onVoiceDownloadRequested,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profileService = ProfileService();
    final currentProfile = profileService.getProfile();
    final currentCallsign = currentProfile.callsign;

    // Compare case-insensitively for callsigns, or by npub if available
    final isOwnMessage = message.author.toUpperCase() == currentCallsign.toUpperCase() ||
        (message.npub != null &&
         message.npub!.isNotEmpty &&
         currentProfile.npub.isNotEmpty &&
         message.npub == currentProfile.npub);

    // Get sender's preferred color from cached device status
    final Color bubbleColor;
    final Color textColor;
    if (isOwnMessage) {
      bubbleColor = theme.colorScheme.primaryContainer;
      textColor = theme.colorScheme.onPrimaryContainer;
    } else {
      final device = DevicesService().getDevice(message.author);
      bubbleColor = _getBubbleColor(device?.preferredColor, theme);
      textColor = _getTextColor(device?.preferredColor, theme);
    }

    return Align(
      alignment: isOwnMessage ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        child: Column(
          crossAxisAlignment:
              isOwnMessage ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // Author name (only for group chats and other people's messages)
            if (isGroupChat && !isOwnMessage)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 4),
                child: Text(
                  message.author,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            // Message bubble
            InkWell(
              onLongPress: () => _showMessageOptions(context),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Voice message player (takes priority over text content)
                    if (message.hasVoice)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: VoicePlayerWidget(
                          filePath: voiceFilePath ?? '',
                          durationSeconds: message.voiceDuration,
                          isLocal: voiceFilePath != null,
                          onDownloadRequested: onVoiceDownloadRequested,
                        ),
                      )
                    // Text message content
                    else if (message.content.isNotEmpty)
                      SelectableText(
                        message.content,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: textColor,
                        ),
                      ),
                    // Metadata chips (file, location, poll - but NOT signature)
                    if (message.hasFile || message.hasLocation || message.isPoll)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildMetadataChips(context, theme, isOwnMessage),
                      ),
                    // Timestamp, signature icon, and options
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            message.displayTime,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: textColor.withOpacity(0.7),
                              fontSize: 11,
                            ),
                          ),
                          // Verified indicator (signature verified by server)
                          if (message.isVerified) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.verified,
                                    size: 11,
                                    color: Colors.green.shade700,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    'verified',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.green.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ]
                          // Failed verification (has signature but verification failed - possible spoofing)
                          else if (message.isSigned) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.warning,
                                    size: 11,
                                    color: Colors.red.shade700,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    'unverified',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.red.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          // Options menu button (moderator only, not for own messages)
                          if (canDelete && onDelete != null && !isOwnMessage) ...[
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: () => _showMessageOptions(context),
                              child: Icon(
                                Icons.more_horiz,
                                size: 16,
                                color: theme.colorScheme.onSurfaceVariant
                                        .withOpacity(0.6),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build metadata chips (file, location, etc.)
  Widget _buildMetadataChips(
      BuildContext context, ThemeData theme, bool isOwnMessage) {
    List<Widget> chips = [];

    // File attachment chip
    if (message.hasFile) {
      chips.add(
        ActionChip(
          avatar: Icon(
            Icons.attach_file,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          label: Text(
            message.attachedFile ?? 'File',
            style: theme.textTheme.bodySmall,
          ),
          onPressed: onFileOpen,
          backgroundColor: theme.colorScheme.surface,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    // Location chip
    if (message.hasLocation) {
      chips.add(
        ActionChip(
          avatar: Icon(
            Icons.location_on,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          label: Text(
            '${message.latitude?.toStringAsFixed(4)}, ${message.longitude?.toStringAsFixed(4)}',
            style: theme.textTheme.bodySmall,
          ),
          onPressed: onLocationView,
          backgroundColor: theme.colorScheme.surface,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    // Poll chip
    if (message.isPoll) {
      chips.add(
        Chip(
          avatar: Icon(
            Icons.poll,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          label: Text(
            'Poll',
            style: theme.textTheme.bodySmall,
          ),
          backgroundColor: theme.colorScheme.surface,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    // Note: Signature indicator is now shown as a small icon next to timestamp

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: chips,
    );
  }

  /// Show message options (copy, etc.)
  void _showMessageOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy message'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: message.content));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Message copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Message info'),
              onTap: () {
                Navigator.pop(context);
                _showMessageInfo(context);
              },
            ),
            if (canDelete && onDelete != null)
              ListTile(
                leading: Icon(
                  Icons.delete,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Delete message',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDelete(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Confirm deletion
  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Message'),
        content: const Text('Are you sure you want to delete this message? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              if (onDelete != null) {
                onDelete!();
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// Show detailed message information
  void _showMessageInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Message Information'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildInfoRow('Author', message.author),
              _buildInfoRow('Timestamp', message.timestamp),
              if (message.npub != null)
                _buildInfoRow('npub', message.npub!),
              if (message.hasFile)
                _buildInfoRow('File', message.attachedFile!),
              if (message.hasLocation)
                _buildInfoRow('Location',
                    '${message.latitude}, ${message.longitude}'),
              if (message.isSigned) ...[
                _buildInfoRow('Signature', message.signature!),
                _buildInfoRow('Verified', message.isVerified ? 'Yes' : 'No'),
              ],
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

  /// Build info row for dialog
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

  /// Convert color name to Material Color with appropriate shade for bubble background
  Color _getBubbleColor(String? colorName, ThemeData theme) {
    if (colorName == null || colorName.isEmpty) {
      return theme.colorScheme.surfaceVariant;
    }

    final MaterialColor baseColor;
    switch (colorName.toLowerCase()) {
      case 'red':
        baseColor = Colors.red;
        break;
      case 'green':
        baseColor = Colors.green;
        break;
      case 'yellow':
        baseColor = Colors.amber;
        break;
      case 'purple':
        baseColor = Colors.purple;
        break;
      case 'orange':
        baseColor = Colors.orange;
        break;
      case 'pink':
        baseColor = Colors.pink;
        break;
      case 'cyan':
        baseColor = Colors.cyan;
        break;
      case 'blue':
        baseColor = Colors.blue;
        break;
      default:
        return theme.colorScheme.surfaceVariant;
    }

    // Use shade100 for a subtle bubble background
    return baseColor.shade100;
  }

  /// Get high-contrast text color for bubble based on preferred color
  Color _getTextColor(String? colorName, ThemeData theme) {
    if (colorName == null || colorName.isEmpty) {
      return theme.colorScheme.onSurfaceVariant;
    }

    // Use shade900 (very dark) for high contrast on shade100 backgrounds
    switch (colorName.toLowerCase()) {
      case 'red':
        return Colors.red.shade900;
      case 'green':
        return Colors.green.shade900;
      case 'yellow':
        return Colors.amber.shade900;
      case 'purple':
        return Colors.purple.shade900;
      case 'orange':
        return Colors.orange.shade900;
      case 'pink':
        return Colors.pink.shade900;
      case 'cyan':
        return Colors.cyan.shade900;
      case 'blue':
        return Colors.blue.shade900;
      default:
        return theme.colorScheme.onSurfaceVariant;
    }
  }
}
