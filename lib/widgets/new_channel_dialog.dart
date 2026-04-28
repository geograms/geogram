/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/chat_channel.dart';
import '../models/distributed_chat.dart';
import '../util/group_utils.dart';

enum _GroupConversationMode { standard, decentralized }

enum _NewChannelMode { create, joinByInvite }

/// Full-screen page for creating a new chat channel (DM or group)
class NewChannelDialog extends StatefulWidget {
  final List<String> existingChannelIds;
  final List<String> knownCallsigns;

  const NewChannelDialog({
    Key? key,
    required this.existingChannelIds,
    this.knownCallsigns = const [],
  }) : super(key: key);

  @override
  State<NewChannelDialog> createState() => _NewChannelDialogState();
}

class _NewChannelDialogState extends State<NewChannelDialog> {
  final _formKey = GlobalKey<FormState>();
  _NewChannelMode _mode = _NewChannelMode.create;
  ChatChannelType _channelType = ChatChannelType.group;
  _GroupConversationMode _groupMode = _GroupConversationMode.standard;
  bool _dailyFiles = false;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _callsignController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _iconController = TextEditingController();
  final TextEditingController _inviteLinkController = TextEditingController();
  final List<String> _selectedParticipants = [];
  bool _isCreating = false;

  @override
  void dispose() {
    _nameController.dispose();
    _callsignController.dispose();
    _descriptionController.dispose();
    _iconController.dispose();
    _inviteLinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final ctaLabel = _mode == _NewChannelMode.joinByInvite ? 'Join' : 'Create';

    return Scaffold(
      appBar: AppBar(
        title: Text('New Channel'),
        leading: IconButton(
          icon: Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _isCreating ? null : _handleCreate,
              child: _isCreating
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(ctaLabel),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Mode', style: theme.textTheme.titleSmall),
              SizedBox(height: 8),
              SegmentedButton<_NewChannelMode>(
                segments: const [
                  ButtonSegment(
                    value: _NewChannelMode.create,
                    label: Text('Create'),
                    icon: Icon(Icons.add),
                  ),
                  ButtonSegment(
                    value: _NewChannelMode.joinByInvite,
                    label: Text('Join via invite'),
                    icon: Icon(Icons.link),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              SizedBox(height: 24),

              if (_mode == _NewChannelMode.joinByInvite) ...[
                TextFormField(
                  controller: _inviteLinkController,
                  decoration: InputDecoration(
                    labelText: 'Invite link',
                    hintText: 'geogram://dchat?payload=...',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.link),
                  ),
                  minLines: 3,
                  maxLines: 5,
                  autofocus: true,
                  validator: (value) {
                    final raw = value?.trim() ?? '';
                    if (raw.isEmpty) return 'Paste an invite link';
                    try {
                      DistributedChatInvite.decode(raw);
                    } catch (_) {
                      return 'Invite link is not valid';
                    }
                    return null;
                  },
                ),
                SizedBox(height: 12),
                Text(
                  'Paste a one-time invite link from a private group host. Joining is auto-approved if the link is still valid.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ] else ...[
                // Channel type selector
                Text('Channel Type', style: theme.textTheme.titleSmall),
                SizedBox(height: 8),
                SegmentedButton<ChatChannelType>(
                  segments: const [
                    ButtonSegment(
                      value: ChatChannelType.group,
                      label: Text('Group'),
                      icon: Icon(Icons.group),
                    ),
                    ButtonSegment(
                      value: ChatChannelType.direct,
                      label: Text('Direct Message'),
                      icon: Icon(Icons.person),
                    ),
                  ],
                  selected: {_channelType},
                  onSelectionChanged: (s) =>
                      setState(() => _channelType = s.first),
                ),
                SizedBox(height: 24),

              // Direct message fields
              if (_channelType == ChatChannelType.direct) ...[
                TextFormField(
                  controller: _callsignController,
                  decoration: InputDecoration(
                    labelText: 'Callsign',
                    hintText: 'Enter callsign (e.g., CR7BBQ)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person),
                  ),
                  textCapitalization: TextCapitalization.characters,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter a callsign';
                    }
                    final callsign = value.trim().toUpperCase();
                    if (widget.existingChannelIds.contains(callsign)) {
                      return 'Channel already exists';
                    }
                    return null;
                  },
                ),
              ],

              // Group fields
              if (_channelType == ChatChannelType.group) ...[
                TextFormField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: 'Group Name',
                    hintText: 'Enter group name',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.group),
                  ),
                  autofocus: true,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter a group name';
                    }
                    return null;
                  },
                ),
                SizedBox(height: 16),
                TextFormField(
                  controller: _descriptionController,
                  decoration: InputDecoration(
                    labelText: 'Description (optional)',
                    hintText: 'What is this group about?',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.description),
                  ),
                  maxLines: 2,
                ),
                SizedBox(height: 24),
                TextFormField(
                  controller: _iconController,
                  decoration: InputDecoration(
                    labelText: 'Icon (optional)',
                    hintText: 'Emoji or short symbol, e.g. 🛰️',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.emoji_emotions_outlined),
                  ),
                  maxLength: 8,
                ),
                SizedBox(height: 8),

                Text('Hosting', style: theme.textTheme.titleSmall),
                SizedBox(height: 8),
                SegmentedButton<_GroupConversationMode>(
                  segments: const [
                    ButtonSegment(
                      value: _GroupConversationMode.standard,
                      label: Text('Centralized'),
                      icon: Icon(Icons.storage),
                    ),
                    ButtonSegment(
                      value: _GroupConversationMode.decentralized,
                      label: Text('Decentralized'),
                      icon: Icon(Icons.hub),
                    ),
                  ],
                  selected: {_groupMode},
                  onSelectionChanged: (selection) {
                    setState(() {
                      _groupMode = selection.first;
                    });
                  },
                ),
                SizedBox(height: 16),

                if (_groupMode == _GroupConversationMode.standard) ...[
                  Text('Message Storage', style: theme.textTheme.titleSmall),
                  SizedBox(height: 8),
                  RadioListTile<bool>(
                    title: Text('Single file'),
                    subtitle: Text(
                      'All messages in one file. Simpler, good for small groups with low activity.',
                      style: theme.textTheme.bodySmall,
                    ),
                    value: false,
                    groupValue: _dailyFiles,
                    onChanged: (v) => setState(() => _dailyFiles = v!),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  RadioListTile<bool>(
                    title: Text('Daily files'),
                    subtitle: Text(
                      'One file per day. Better for very active rooms with many participants.',
                      style: theme.textTheme.bodySmall,
                    ),
                    value: true,
                    groupValue: _dailyFiles,
                    onChanged: (v) => setState(() => _dailyFiles = v!),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  SizedBox(height: 24),
                  Text('Participants', style: theme.textTheme.titleSmall),
                  SizedBox(height: 8),
                  if (widget.knownCallsigns.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: widget.knownCallsigns.map((callsign) {
                        final isSelected = _selectedParticipants.contains(
                          callsign,
                        );
                        return FilterChip(
                          label: Text(callsign),
                          selected: isSelected,
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                _selectedParticipants.add(callsign);
                              } else {
                                _selectedParticipants.remove(callsign);
                              }
                            });
                          },
                        );
                      }).toList(),
                    )
                  else
                    Text(
                      'No known participants yet. They will appear here once devices connect.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                ] else
                  Text(
                    'Members will join later through invite links and moderator approval. Conversation topics are created inside the room after it is created.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
              ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleCreate() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isCreating = true);

    try {
      if (_mode == _NewChannelMode.joinByInvite) {
        final invite = DistributedChatInvite.decode(
          _inviteLinkController.text.trim(),
        );
        if (mounted) Navigator.pop(context, invite);
        return;
      }

      ChatChannel channel;

      if (_channelType == ChatChannelType.direct) {
        final callsign = _callsignController.text.trim().toUpperCase();
        channel = ChatChannel.direct(callsign: callsign);
      } else {
        final name = _nameController.text.trim();
        final description = _descriptionController.text.trim();
        final icon = _iconController.text.trim();
        final id = GroupUtils.sanitizeGroupName(name);

        if (widget.existingChannelIds.contains(id)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('A group with this name already exists'),
                backgroundColor: Colors.red,
              ),
            );
          }
          setState(() => _isCreating = false);
          return;
        }

        if (_groupMode == _GroupConversationMode.decentralized) {
          channel = ChatChannel(
            id: id,
            type: ChatChannelType.group,
            name: name,
            folder: 'dchat/$id',
            participants: const [],
            description: description.isNotEmpty ? description : null,
            created: DateTime.now(),
            config: ChatChannelConfig(
              id: id,
              name: name,
              description: description.isNotEmpty ? description : null,
              visibility: 'RESTRICTED',
              fileUpload: false,
              dailyFiles: true,
              distributionMode: 'distributed',
              joinPolicy: 'approval_required',
              icon: icon.isNotEmpty ? icon : null,
            ),
          );
        } else {
          channel = ChatChannel.group(
            id: id,
            name: name,
            participants: _selectedParticipants,
            description: description.isNotEmpty ? description : null,
          );

          if (channel.config != null) {
            channel = channel.copyWith(
              config: channel.config!.copyWith(
                dailyFiles: _dailyFiles,
                icon: icon.isNotEmpty ? icon : null,
              ),
            );
          }
        }
      }

      if (mounted) Navigator.pop(context, channel);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }
}
