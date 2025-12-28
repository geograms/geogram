/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'package:flutter/foundation.dart';
import '../platform/title_manager.dart';
import '../services/log_service.dart';
import '../services/notification_service.dart';
import '../services/profile_service.dart';
import '../util/event_bus.dart';

/// Provides lightweight attention on desktop/web for new messages.
class MessageAttentionService {
  static final MessageAttentionService _instance = MessageAttentionService._internal();
  factory MessageAttentionService() => _instance;
  MessageAttentionService._internal();

  final TitleManager _titleManager = getTitleManager();
  EventSubscription<ChatMessageEvent>? _chatSubscription;
  EventSubscription<DirectMessageReceivedEvent>? _dmSubscription;
  Timer? _resetTimer;
  String _baseTitle = 'Geogram';
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    if (!_shouldEnableAttention()) {
      _initialized = true;
      return;
    }

    _baseTitle = await _titleManager.getTitle();
    if (_baseTitle.trim().isEmpty) {
      _baseTitle = 'Geogram';
    }

    _chatSubscription = EventBus().on<ChatMessageEvent>(_handleChatMessage);
    _dmSubscription = EventBus().on<DirectMessageReceivedEvent>(_handleDirectMessage);
    _initialized = true;
    LogService().log('MessageAttentionService initialized');
  }

  bool _shouldEnableAttention() {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  Future<void> _handleChatMessage(ChatMessageEvent event) async {
    if (!_initialized) return;
    if (!_shouldNotify(event.callsign)) return;
    await _signalAttention('New message');
  }

  Future<void> _handleDirectMessage(DirectMessageReceivedEvent event) async {
    if (!_initialized) return;
    if (event.fromSync) return;
    if (!_shouldNotify(event.fromCallsign)) return;
    await _signalAttention('New message');
  }

  bool _shouldNotify(String fromCallsign) {
    final settings = NotificationService().getSettings();
    if (!settings.enableNotifications || !settings.notifyNewMessages) {
      return false;
    }

    final myCallsign = ProfileService().getProfile().callsign;
    if (myCallsign.isEmpty || fromCallsign == myCallsign) {
      return false;
    }

    return true;
  }

  Future<void> _signalAttention(String label) async {
    final focused = await _titleManager.isFocused();
    if (focused) return;

    final title = '• $label - $_baseTitle';
    await _titleManager.setTitle(title);

    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 6), () {
      _titleManager.setTitle(_baseTitle);
    });
  }

  void dispose() {
    _chatSubscription?.cancel();
    _dmSubscription?.cancel();
    _resetTimer?.cancel();
  }
}
