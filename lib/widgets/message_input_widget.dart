/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import '../services/i18n_service.dart';
import '../models/chat_message.dart';
import '../platform/file_image_helper.dart' as file_helper;

/// Widget for composing and sending chat messages
class MessageInputWidget extends StatefulWidget {
  final Function(String content, String? filePath) onSend;
  final int maxLength;
  final bool allowFiles;
  /// Optional callback for mic button (voice recording)
  final VoidCallback? onMicPressed;
  final ChatMessage? quotedMessage;
  final VoidCallback? onClearQuote;

  const MessageInputWidget({
    Key? key,
    required this.onSend,
    this.maxLength = 500,
    this.allowFiles = true,
    this.onMicPressed,
    this.quotedMessage,
    this.onClearQuote,
  }) : super(key: key);

  @override
  State<MessageInputWidget> createState() => _MessageInputWidgetState();
}

class _MessageInputWidgetState extends State<MessageInputWidget> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final FocusNode _keyboardListenerFocusNode = FocusNode();
  final I18nService _i18n = I18nService();
  String? _selectedFilePath;
  String? _selectedFileName;
  bool _isSending = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _keyboardListenerFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Quote preview (if replying)
          if (widget.quotedMessage != null) _buildQuotePreview(theme),
          // File preview (if file selected)
          if (_selectedFilePath != null) _buildFilePreview(theme),
          // Input row - WhatsApp/Telegram style layout
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Attachment button (combines image + file into popup menu)
                if (widget.allowFiles)
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.add,
                      color: _isSending ? theme.disabledColor : theme.colorScheme.onSurfaceVariant,
                    ),
                    enabled: !_isSending,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                    tooltip: _i18n.t('attach'),
                    onSelected: (value) {
                      if (value == 'image') {
                        _pickImage();
                      } else if (value == 'file') {
                        _pickFile();
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'image',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.image_outlined, color: theme.colorScheme.primary),
                            const SizedBox(width: 12),
                            Text(_i18n.t('attach_image')),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'file',
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.attach_file, color: theme.colorScheme.primary),
                            const SizedBox(width: 12),
                            Text(_i18n.t('attach_file')),
                          ],
                        ),
                      ),
                    ],
                  ),
                const SizedBox(width: 4),
                // Text input field - takes most of the space
                Expanded(
                  child: KeyboardListener(
                    focusNode: _keyboardListenerFocusNode,
                    onKeyEvent: (event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.enter &&
                          !HardwareKeyboard.instance.isShiftPressed) {
                        _handleSend();
                      }
                    },
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      enabled: !_isSending,
                      maxLines: 6,
                      minLines: 1,
                      maxLength: widget.maxLength,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: _i18n.t('type_a_message'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        counterText: '',
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerHighest,
                        isDense: true,
                      ),
                      onSubmitted: (_) => _handleSend(),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // Mic button (optional, for voice recording)
                if (widget.onMicPressed != null)
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: IconButton(
                      icon: const Icon(Icons.mic, size: 22),
                      onPressed: _isSending ? null : widget.onMicPressed,
                      tooltip: 'Record voice message',
                      color: theme.colorScheme.primary,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                // Send button - circular filled button
                SizedBox(
                  width: 44,
                  height: 44,
                  child: Material(
                    color: theme.colorScheme.primary,
                    shape: const CircleBorder(),
                    child: InkWell(
                      onTap: _isSending ? null : _handleSend,
                      customBorder: const CircleBorder(),
                      child: Center(
                        child: _isSending
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: theme.colorScheme.onPrimary,
                                ),
                              )
                            : Icon(
                                Icons.send,
                                size: 20,
                                color: theme.colorScheme.onPrimary,
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build file preview widget
  Widget _buildFilePreview(ThemeData theme) {
    final isImage = _isImageFile(_selectedFilePath!);
    final imageWidget = isImage
        ? file_helper.buildFileImage(
            _selectedFilePath!,
            width: 48,
            height: 48,
            fit: BoxFit.cover,
          )
        : null;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (imageWidget != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: imageWidget,
            )
          else
            Icon(
              Icons.insert_drive_file,
              color: theme.colorScheme.primary,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _selectedFileName ?? 'File',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _getFileSize(_selectedFilePath!),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: _clearFile,
            tooltip: _i18n.t('remove_file'),
            iconSize: 20,
          ),
        ],
      ),
    );
  }

  /// Build quote preview widget
  Widget _buildQuotePreview(ThemeData theme) {
    final quoted = widget.quotedMessage!;
    final excerpt = quoted.content.isNotEmpty
        ? quoted.content
        : _i18n.t('message');
    final preview = excerpt.length > 120 ? '${excerpt.substring(0, 120)}...' : excerpt;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  quoted.author,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (widget.onClearQuote != null)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: widget.onClearQuote,
              tooltip: _i18n.t('remove_quote'),
              iconSize: 18,
            ),
        ],
      ),
    );
  }

  /// Maximum file size: 10 MB
  static const int _maxFileSize = 10 * 1024 * 1024;

  /// Pick a file to attach
  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();

      if (result != null && result.files.single.path != null) {
        // Check file size
        final file = File(result.files.single.path!);
        final fileSize = await file.length();
        if (fileSize > _maxFileSize) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(_i18n.t('file_too_large', params: ['10 MB'])),
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
            );
          }
          return;
        }

        setState(() {
          _selectedFilePath = result.files.single.path;
          _selectedFileName = result.files.single.name;
        });

        // Auto-focus text field after selecting file
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _focusNode.requestFocus();
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('error_picking_file', params: ['$e'])),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  /// Pick an image to attach
  Future<void> _pickImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
      );

      if (result != null && result.files.single.path != null) {
        // Check file size
        final file = File(result.files.single.path!);
        final fileSize = await file.length();
        if (fileSize > _maxFileSize) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(_i18n.t('file_too_large', params: ['10 MB'])),
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
            );
          }
          return;
        }

        setState(() {
          _selectedFilePath = result.files.single.path;
          _selectedFileName = result.files.single.name;
        });

        // Auto-focus text field after selecting image
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _focusNode.requestFocus();
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('error_picking_file', params: ['$e'])),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  bool _isImageFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  /// Clear selected file
  void _clearFile() {
    setState(() {
      _selectedFilePath = null;
      _selectedFileName = null;
    });
  }

  /// Handle send button press
  Future<void> _handleSend() async {
    if (_isSending) return; // Guard against double-send (Enter key + onSubmitted)
    final content = _controller.text.trim();

    // Check if there's content or a file
    if (content.isEmpty && _selectedFilePath == null) {
      return;
    }

    // Check max length
    if (content.length > widget.maxLength) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              _i18n.t('message_too_long', params: ['${widget.maxLength}'])),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    setState(() {
      _isSending = true;
    });

    try {
      // Call the onSend callback
      await widget.onSend(content, _selectedFilePath);

      // Clear input on success
      _controller.clear();
      _clearFile();

      // Request focus after the frame to ensure it persists through rebuilds
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('failed_to_send_message', params: ['$e'])),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  /// Get human-readable file size
  String _getFileSize(String filePath) {
    try {
      final file = File(filePath);
      final bytes = file.lengthSync();

      if (bytes < 1024) {
        return '$bytes B';
      } else if (bytes < 1024 * 1024) {
        return '${(bytes / 1024).toStringAsFixed(1)} KB';
      } else if (bytes < 1024 * 1024 * 1024) {
        return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
      } else {
        return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
      }
    } catch (e) {
      return _i18n.t('unknown_size');
    }
  }
}
