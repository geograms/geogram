/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'dart:async';
import '../models/chat_message.dart';
import '../models/dm_conversation.dart';
import '../services/direct_message_service.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../util/event_bus.dart';
import '../widgets/message_list_widget.dart';
import '../widgets/message_input_widget.dart';

/// Page for 1:1 direct message conversation
class DMChatPage extends StatefulWidget {
  final String otherCallsign;

  const DMChatPage({
    Key? key,
    required this.otherCallsign,
  }) : super(key: key);

  @override
  State<DMChatPage> createState() => _DMChatPageState();
}

class _DMChatPageState extends State<DMChatPage> {
  final DirectMessageService _dmService = DirectMessageService();
  final DevicesService _devicesService = DevicesService();
  final I18nService _i18n = I18nService();

  List<ChatMessage> _messages = [];
  DMConversation? _conversation;
  bool _isLoading = true;
  bool _isSending = false;
  String? _error;

  // Event subscriptions
  EventSubscription<DirectMessageReceivedEvent>? _messageSubscription;
  EventSubscription<DirectMessageSyncEvent>? _syncSubscription;

  @override
  void initState() {
    super.initState();
    _initializeChat();
    _subscribeToEvents();
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _syncSubscription?.cancel();
    super.dispose();
  }

  void _subscribeToEvents() {
    // Listen for new messages
    _messageSubscription = EventBus().on<DirectMessageReceivedEvent>((event) {
      if (event.fromCallsign.toUpperCase() == widget.otherCallsign.toUpperCase() ||
          event.toCallsign.toUpperCase() == widget.otherCallsign.toUpperCase()) {
        // Reload messages when a relevant message is received
        _loadMessages();
      }
    });

    // Listen for sync completion
    _syncSubscription = EventBus().on<DirectMessageSyncEvent>((event) {
      if (event.otherCallsign.toUpperCase() == widget.otherCallsign.toUpperCase()) {
        if (event.success && event.newMessages > 0) {
          _loadMessages();
        }
      }
    });
  }

  Future<void> _initializeChat() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await _dmService.initialize();
      _conversation = await _dmService.getOrCreateConversation(widget.otherCallsign);

      // Mark as read
      await _dmService.markAsRead(widget.otherCallsign);

      await _loadMessages();
    } catch (e) {
      setState(() {
        _error = 'Failed to initialize chat: $e';
      });
    }

    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _loadMessages() async {
    try {
      final messages = await _dmService.loadMessages(widget.otherCallsign, limit: 200);
      if (mounted) {
        setState(() {
          _messages = messages;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load messages: $e';
        });
      }
    }
  }

  Future<void> _sendMessage(String content) async {
    if (content.trim().isEmpty) return;

    setState(() {
      _isSending = true;
    });

    try {
      await _dmService.sendMessage(widget.otherCallsign, content.trim());
      await _loadMessages();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send message: $e')),
        );
      }
    }

    if (mounted) {
      setState(() {
        _isSending = false;
      });
    }
  }

  Future<void> _syncMessages() async {
    final device = _devicesService.getDevice(widget.otherCallsign);
    if (device?.url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('device_not_reachable'))),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_i18n.t('syncing'))),
    );

    final result = await _dmService.syncWithDevice(
      widget.otherCallsign,
      deviceUrl: device!.url,
    );

    if (mounted) {
      if (result.success) {
        await _loadMessages();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Sync complete: ${result.messagesReceived} received, ${result.messagesSent} sent',
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync failed: ${result.error}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = _devicesService.getDevice(widget.otherCallsign);
    final isOnline = device?.isOnline ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            // Online indicator
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOnline ? Colors.green : Colors.grey,
              ),
            ),
            Text(widget.otherCallsign),
          ],
        ),
        actions: [
          // Sync button
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: _i18n.t('sync'),
            onPressed: _syncMessages,
          ),
          // Info button
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: _i18n.t('info'),
            onPressed: () => _showConversationInfo(),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _initializeChat,
              child: Text(_i18n.t('retry')),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Messages list
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Text(
                    _i18n.t('no_messages_yet'),
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                )
              : MessageListWidget(
                  messages: _messages,
                  isGroupChat: false, // 1:1 DM conversation
                ),
        ),
        // Message input
        if (!_isSending)
          MessageInputWidget(
            onSend: (content, filePath) => _sendMessage(content),
            allowFiles: false, // DMs don't support file attachments yet
          )
        else
          Container(
            padding: const EdgeInsets.all(16),
            child: const Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }

  void _showConversationInfo() {
    final device = _devicesService.getDevice(widget.otherCallsign);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Chat with ${widget.otherCallsign}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow('Status', device?.isOnline ?? false ? 'Online' : 'Offline'),
            if (_conversation != null) ...[
              const SizedBox(height: 8),
              _infoRow('Messages', '${_messages.length}'),
              _infoRow('Last activity', _conversation!.lastActivityText),
              _infoRow('Sync status', _conversation!.syncStatusText),
            ],
            if (device?.url != null) ...[
              const SizedBox(height: 8),
              _infoRow('URL', device!.url!),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_i18n.t('close')),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
