/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../bot/models/bot_message.dart';
import '../bot/services/bot_service.dart';
import '../services/config_service.dart';
import '../services/i18n_service.dart';
import '../widgets/music_player_widget.dart';
import '../widgets/music_progress_widget.dart';
import 'bot_settings_page.dart';

/// Bot chat page - main interface for talking to the AI assistant
class BotPage extends StatefulWidget {
  const BotPage({super.key});

  @override
  State<BotPage> createState() => _BotPageState();
}

class _BotPageState extends State<BotPage> {
  final BotService _botService = BotService();
  final I18nService _i18n = I18nService();
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();

  List<BotMessage> _messages = [];
  StreamSubscription<List<BotMessage>>? _messagesSubscription;
  bool _isInitialized = false;
  String? _selectedImagePath;

  // Command history for CLI-like navigation
  static const String _historyKey = 'bot_command_history';
  static const int _maxHistorySize = 50;
  final List<String> _commandHistory = [];
  int _historyIndex = -1;
  String _currentInput = '';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _messagesSubscription?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _botService.initialize();

    // Load command history from storage
    _loadCommandHistory();

    _messagesSubscription = _botService.messagesStream.listen((messages) {
      if (mounted) {
        setState(() {
          _messages = messages;
        });
        _scrollToBottom();
      }
    });

    setState(() {
      _messages = _botService.messages;
      _isInitialized = true;
    });

    // Scroll to bottom after initialization
    _scrollToBottom();
  }

  /// Load command history from persistent storage
  void _loadCommandHistory() {
    final history = ConfigService().get(_historyKey);
    if (history is List) {
      _commandHistory.clear();
      _commandHistory.addAll(history.cast<String>());
    }
  }

  /// Save command history to persistent storage
  void _saveCommandHistory() {
    // Keep only the last _maxHistorySize commands
    while (_commandHistory.length > _maxHistorySize) {
      _commandHistory.removeAt(0);
    }
    ConfigService().set(_historyKey, _commandHistory);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final content = _inputController.text.trim();
    final imagePath = _selectedImagePath;

    if (content.isEmpty && imagePath == null) return;

    // Add to command history (avoid duplicates of last command)
    if (content.isNotEmpty) {
      if (_commandHistory.isEmpty || _commandHistory.last != content) {
        _commandHistory.add(content);
        _saveCommandHistory();
      }
    }
    // Reset history navigation
    _historyIndex = -1;
    _currentInput = '';

    _inputController.clear();
    setState(() {
      _selectedImagePath = null;
    });
    await _botService.sendMessage(content, imagePath: imagePath);
    if (mounted) {
      setState(() {}); // Trigger rebuild when processing complete
    }
  }

  /// Handle keyboard events for command history navigation
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _navigateHistoryUp();
      return KeyEventResult.handled;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _navigateHistoryDown();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// Navigate to previous command in history
  void _navigateHistoryUp() {
    if (_commandHistory.isEmpty) return;

    if (_historyIndex == -1) {
      // Save current input before navigating
      _currentInput = _inputController.text;
      _historyIndex = _commandHistory.length - 1;
    } else if (_historyIndex > 0) {
      _historyIndex--;
    }

    _inputController.text = _commandHistory[_historyIndex];
    _inputController.selection = TextSelection.fromPosition(
      TextPosition(offset: _inputController.text.length),
    );
  }

  /// Navigate to next command in history
  void _navigateHistoryDown() {
    if (_historyIndex == -1) return;

    if (_historyIndex < _commandHistory.length - 1) {
      _historyIndex++;
      _inputController.text = _commandHistory[_historyIndex];
    } else {
      // Return to current input
      _historyIndex = -1;
      _inputController.text = _currentInput;
    }

    _inputController.selection = TextSelection.fromPosition(
      TextPosition(offset: _inputController.text.length),
    );
  }

  Future<void> _pickImage() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (image != null && mounted) {
        setState(() {
          _selectedImagePath = image.path;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking image: $e')),
        );
      }
    }
  }

  Future<void> _takePhoto() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (image != null && mounted) {
        setState(() {
          _selectedImagePath = image.path;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error taking photo: $e')),
        );
      }
    }
  }

  void _clearSelectedImage() {
    setState(() {
      _selectedImagePath = null;
    });
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const BotSettingsPage()),
    );
  }

  Future<void> _clearConversation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('bot_clear_conversation')),
        content: Text(_i18n.t('bot_clear_conversation_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _botService.clearConversation();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('bot')),
        actions: [
          if (_messages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: _i18n.t('bot_clear_conversation'),
              onPressed: _clearConversation,
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: _i18n.t('bot_settings'),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: _buildMessagesList(),
          ),
          // Input area
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildMessagesList() {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_messages.isEmpty) {
      return _buildEmptyState();
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        return _buildMessageBubble(message);
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('bot_greeting'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _i18n.t('bot_example_questions'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _buildSuggestionChip(_i18n.t('bot_example_nearby')),
                _buildSuggestionChip(_i18n.t('bot_example_events')),
                _buildSuggestionChip(_i18n.t('bot_example_distance')),
                _buildSuggestionChip('Where am I?'),
                _buildSuggestionChip('Play jazz music'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionChip(String text) {
    return ActionChip(
      label: Text(text),
      onPressed: () {
        _inputController.text = text;
        _sendMessage();
      },
    );
  }

  Widget _buildMessageBubble(BotMessage message) {
    final isUser = message.isUser;
    final colorScheme = Theme.of(context).colorScheme;

    if (message.isThinking) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8, right: 48),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _i18n.t('bot_thinking'),
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          bottom: 8,
          left: isUser ? 48 : 0,
          right: isUser ? 0 : 48,
        ),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser
              ? colorScheme.primaryContainer
              : message.error != null
                  ? colorScheme.errorContainer
                  : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.smart_toy,
                      size: 16,
                      color: message.error != null
                          ? colorScheme.error
                          : colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Bot',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: message.error != null
                            ? colorScheme.error
                            : colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            // Display image if present
            if (message.hasImage)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 250,
                      maxHeight: 200,
                    ),
                    child: Image.file(
                      File(message.imagePath!),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          width: 100,
                          height: 100,
                          color: colorScheme.errorContainer,
                          child: Icon(
                            Icons.broken_image,
                            color: colorScheme.onErrorContainer,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            if (message.content.isNotEmpty)
              SelectableText(
                message.content,
                style: TextStyle(
                  color: isUser
                      ? colorScheme.onPrimaryContainer
                      : message.error != null
                          ? colorScheme.onErrorContainer
                          : colorScheme.onSurface,
                ),
              ),
            // Display music player if track is available
            if (message.hasMusic)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: MusicPlayerWidget(
                  track: message.musicTrack!,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                ),
              ),
            // Display music generation progress if generating
            if (message.hasMusicGenerating)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: MusicProgressWidget(
                  stateStream: message.musicGenerationStream!,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  onComplete: (track) {
                    // Update the message with the completed track and save
                    _botService.updateMusicMessage(message.id, track);
                  },
                ),
              ),
            if (message.sources.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    Icon(
                      Icons.source_outlined,
                      size: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    ...message.sources.map((source) => Text(
                      source,
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    )),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant,
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Image preview (if selected)
            if (_selectedImagePath != null) _buildImagePreview(colorScheme),
            // Input row
            Row(
              children: [
                // Image picker button
                IconButton(
                  icon: const Icon(Icons.image_outlined),
                  onPressed: _botService.isProcessing ? null : _pickImage,
                  tooltip: _i18n.t('bot_attach_image'),
                ),
                // Camera button
                IconButton(
                  icon: const Icon(Icons.camera_alt_outlined),
                  onPressed: _botService.isProcessing ? null : _takePhoto,
                  tooltip: _i18n.t('bot_take_photo'),
                ),
                Expanded(
                  child: Focus(
                    onKeyEvent: _handleKeyEvent,
                    child: TextField(
                      controller: _inputController,
                      focusNode: _inputFocusNode,
                      decoration: InputDecoration(
                        hintText: _selectedImagePath != null
                            ? _i18n.t('bot_ask_about_image')
                            : _i18n.t('bot_ask_placeholder'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: colorScheme.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      enabled: !_botService.isProcessing,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: _botService.isProcessing
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.send),
                  onPressed: _botService.isProcessing ? null : _sendMessage,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImagePreview(ColorScheme colorScheme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(_selectedImagePath!),
              width: 60,
              height: 60,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: 60,
                  height: 60,
                  color: colorScheme.errorContainer,
                  child: Icon(
                    Icons.broken_image,
                    color: colorScheme.onErrorContainer,
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _i18n.t('bot_image_selected'),
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface,
                  ),
                ),
                Text(
                  _i18n.t('bot_image_hint'),
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: _clearSelectedImage,
            tooltip: _i18n.t('remove'),
          ),
        ],
      ),
    );
  }
}
