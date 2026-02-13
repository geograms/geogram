/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Email Thread Page - Displays email conversation
 */

import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import '../models/email_message.dart';
import '../models/email_thread.dart';
import '../services/email_service.dart';
import '../services/profile_service.dart';
import 'email_compose_page.dart';
import 'photo_viewer_page.dart';

class _MessageDisplayParts {
  final String mainText;
  final String quotedText;

  const _MessageDisplayParts({
    required this.mainText,
    required this.quotedText,
  });
}

/// Email thread page showing conversation messages
class EmailThreadPage extends StatefulWidget {
  final EmailThread thread;

  /// Whether this is embedded in a larger layout (no AppBar)
  final bool embedded;

  const EmailThreadPage({Key? key, required this.thread, this.embedded = false})
    : super(key: key);

  @override
  State<EmailThreadPage> createState() => _EmailThreadPageState();
}

class _EmailThreadPageState extends State<EmailThreadPage> {
  final EmailService _emailService = EmailService();
  final ProfileService _profileService = ProfileService();
  final ScrollController _scrollController = ScrollController();
  final Set<String> _expandedQuotedMessageIds = <String>{};

  late EmailThread _thread;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _thread = widget.thread;
    _scheduleMarkThreadReadIfViewed();
  }

  @override
  void didUpdateWidget(EmailThreadPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.thread.threadId != oldWidget.thread.threadId) {
      _thread = widget.thread;
      _expandedQuotedMessageIds.clear();
      _scheduleMarkThreadReadIfViewed();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _reloadThread() async {
    if (_thread.folderPath == null) return;

    setState(() => _isLoading = true);

    final reloaded = await _emailService.loadThread(_thread.folderPath!);
    if (reloaded != null && mounted) {
      setState(() {
        _thread = reloaded;
        _isLoading = false;
      });
      _scheduleMarkThreadReadIfViewed();
    } else if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  void _scheduleMarkThreadReadIfViewed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_thread.status != EmailStatus.received || _thread.isRead) return;

      unawaited(_emailService.markThreadRead(_thread));
    });
  }

  Future<void> _reply() async {
    final result = await Navigator.of(context).push<EmailThread>(
      MaterialPageRoute(
        builder: (context) => EmailComposePage(replyTo: _thread),
      ),
    );

    if (result != null) {
      await _reloadThread();
    }
  }

  Future<void> _replyAll() async {
    final result = await Navigator.of(context).push<EmailThread>(
      MaterialPageRoute(
        builder: (context) =>
            EmailComposePage(replyTo: _thread, replyAll: true),
      ),
    );

    if (result != null) {
      await _reloadThread();
    }
  }

  Future<void> _forward() async {
    final result = await Navigator.of(context).push<EmailThread>(
      MaterialPageRoute(
        builder: (context) => EmailComposePage(forwardFrom: _thread),
      ),
    );

    if (result != null) {
      // Navigate back or show success
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return _buildContent();
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _thread.subject,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.reply),
            onPressed: _reply,
            tooltip: 'Reply',
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'reply_all':
                  _replyAll();
                  break;
                case 'forward':
                  _forward();
                  break;
                case 'mark_spam':
                  _emailService.markAsSpam(_thread);
                  Navigator.pop(context);
                  break;
                case 'delete':
                  _emailService.deleteThread(_thread);
                  Navigator.pop(context);
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'reply_all',
                child: ListTile(
                  leading: Icon(Icons.reply_all),
                  title: Text('Reply All'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'forward',
                child: ListTile(
                  leading: Icon(Icons.forward),
                  title: Text('Forward'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'mark_spam',
                child: ListTile(
                  leading: Icon(Icons.report),
                  title: Text('Mark as Spam'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete, color: Colors.red),
                  title: Text('Delete', style: TextStyle(color: Colors.red)),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildContent(),
      floatingActionButton: FloatingActionButton(
        onPressed: _reply,
        child: const Icon(Icons.reply),
        tooltip: 'Reply',
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverToBoxAdapter(child: _buildThreadHeader()),
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final message = _thread.messages[index];
                  final isFirst = index == 0;
                  final isLast = index == _thread.messages.length - 1;
                  return _buildMessageCard(message, isFirst, isLast);
                }, childCount: _thread.messages.length),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
            ],
          ),
        ),
        if (widget.embedded) _buildQuickReplyBar(),
      ],
    );
  }

  Widget _buildThreadHeader() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Material(
        color: theme.colorScheme.surface,
        elevation: 1,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _thread.subject,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _buildHeaderChip(
                    icon: Icons.mail_outline,
                    label: _statusLabel(_thread.status),
                    background: theme.colorScheme.primaryContainer,
                    foreground: theme.colorScheme.onPrimaryContainer,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _buildParticipantChip('From', _thread.from, Colors.blue),
                  for (final to in _thread.to)
                    _buildParticipantChip('To', to, Colors.green),
                  for (final cc in _thread.cc)
                    _buildParticipantChip('CC', cc, Colors.orange),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildHeaderChip(
                    icon: Icons.cloud_outlined,
                    label: _thread.station,
                    background: theme.colorScheme.secondaryContainer,
                    foreground: theme.colorScheme.onSecondaryContainer,
                  ),
                  _buildHeaderChip(
                    icon: Icons.forum_outlined,
                    label:
                        '${_thread.messageCount} message${_thread.messageCount == 1 ? '' : 's'}',
                    background: theme.colorScheme.surfaceVariant,
                    foreground: theme.colorScheme.onSurface,
                  ),
                  _buildHeaderChip(
                    icon: Icons.access_time,
                    label: _formatDateTime(_thread.createdDateTime),
                    background: theme.colorScheme.surfaceVariant,
                    foreground: theme.colorScheme.onSurface,
                  ),
                  if (_thread.labels.isNotEmpty)
                    ..._thread.labels.map(
                      (label) => _buildHeaderChip(
                        icon: Icons.label_outline,
                        label: label,
                        background: theme.colorScheme.tertiaryContainer,
                        foreground: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _reply,
                    icon: const Icon(Icons.reply),
                    label: const Text('Reply'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _replyAll,
                    icon: const Icon(Icons.reply_all),
                    label: const Text('Reply all'),
                  ),
                  TextButton.icon(
                    onPressed: _forward,
                    icon: const Icon(Icons.forward),
                    label: const Text('Forward'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildParticipantChip(String role, String email, Color color) {
    return Chip(
      avatar: CircleAvatar(
        backgroundColor: color,
        radius: 10,
        child: Text(
          role[0],
          style: const TextStyle(fontSize: 10, color: Colors.white),
        ),
      ),
      label: Text(email, style: const TextStyle(fontSize: 12)),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildHeaderChip({
    required IconData icon,
    required String label,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageCard(EmailMessage message, bool isFirst, bool isLast) {
    final profile = _profileService.getProfile();
    final isOwn = profile.callsign == message.author;

    final theme = Theme.of(context);
    final platform = theme.platform;
    final isDesktopPlatform =
        platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows;
    final isAndroidPlatform = platform == TargetPlatform.android;
    final bubbleColor = isOwn
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
        : theme.colorScheme.surface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: isOwn
                    ? theme.colorScheme.primary
                    : theme.colorScheme.secondary,
                child: Text(
                  message.author.isNotEmpty
                      ? message.author[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (!isLast)
                Container(
                  width: 2,
                  height: 26,
                  margin: const EdgeInsets.only(top: 4),
                  color: theme.colorScheme.outlineVariant,
                ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: isDesktopPlatform
                  ? (event) {
                      if (event.kind == PointerDeviceKind.mouse &&
                          (event.buttons & kSecondaryMouseButton) != 0) {
                        _showMessageActionMenuAt(message, event.position);
                      }
                    }
                  : null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: isAndroidPlatform
                    ? (details) => _showMessageActionMenuAt(
                        message,
                        details.globalPosition,
                      )
                    : null,
                child: Container(
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    message.author,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _formatDateTime(message.dateTime),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            _buildVerificationBadge(message),
                            PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert, size: 20),
                              onSelected: (value) =>
                                  _handleMessageAction(value, message),
                              itemBuilder: (context) =>
                                  _buildMessageActionMenuItems(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _buildMessageContent(message, theme),
                        if (message.hasFile || message.hasImage)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: _buildAttachments(message),
                          ),
                        if (message.isEdited)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Edited ${message.editedAt}',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[500],
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _messageDisplayKey(EmailMessage message) {
    return '${message.author}|${message.timestamp}|${message.content.hashCode}';
  }

  String _decodeQuotedPrintableLoose(String text) {
    final softLineBreakNormalized = text.replaceAll(RegExp(r'=\r?\n'), '');
    return softLineBreakNormalized.replaceAllMapped(
      RegExp(r'=([0-9A-Fa-f]{2})'),
      (match) {
        final value = int.tryParse(match.group(1)!, radix: 16);
        if (value == null) return match.group(0)!;
        return String.fromCharCode(value);
      },
    );
  }

  _MessageDisplayParts _splitMessageForDisplay(String rawContent) {
    final normalized = rawContent.replaceAll('\r\n', '\n').trimRight();
    if (normalized.isEmpty) {
      return const _MessageDisplayParts(mainText: '', quotedText: '');
    }

    final decoded = _decodeQuotedPrintableLoose(normalized);
    final lines = decoded.split('\n');

    var quotedIndex = -1;
    var signatureIndex = -1;

    for (var i = 0; i < lines.length; i++) {
      final rawLine = lines[i].trimRight();
      final line = rawLine.trimLeft();
      final dequoted = line.startsWith('>')
          ? line.replaceFirst(RegExp(r'^>\s*'), '')
          : line;

      if (signatureIndex < 0 &&
          dequoted.contains('Signature verification for NOSTR')) {
        signatureIndex = i;
      }
      if (quotedIndex < 0 &&
          RegExp(r'^On .+wrote:$', caseSensitive: false).hasMatch(dequoted)) {
        quotedIndex = i;
      }
      if (quotedIndex < 0 && line.startsWith('>')) {
        quotedIndex = i;
      }
    }

    var collapseIndex = quotedIndex;
    if (signatureIndex >= 0 &&
        (collapseIndex < 0 || signatureIndex < collapseIndex)) {
      collapseIndex = signatureIndex > 0 ? signatureIndex - 1 : signatureIndex;
    }

    if (collapseIndex < 0) {
      return _MessageDisplayParts(mainText: decoded.trim(), quotedText: '');
    }

    final mainText = lines.take(collapseIndex).join('\n').trimRight();
    final quotedText = lines.skip(collapseIndex).join('\n').trim();
    return _MessageDisplayParts(mainText: mainText, quotedText: quotedText);
  }

  Widget _buildMessageContent(EmailMessage message, ThemeData theme) {
    final parts = _splitMessageForDisplay(message.content);
    final messageKey = _messageDisplayKey(message);
    final isExpanded = _expandedQuotedMessageIds.contains(messageKey);
    final contentStyle = theme.textTheme.bodyMedium?.copyWith(
      height: 1.35,
      fontSize: 14,
    );

    final children = <Widget>[];
    if (parts.mainText.isNotEmpty) {
      children.add(SelectableText(parts.mainText, style: contentStyle));
    }
    if (parts.quotedText.isNotEmpty) {
      if (parts.mainText.isNotEmpty) {
        children.add(const SizedBox(height: 8));
      }
      children.add(
        TextButton.icon(
          onPressed: () {
            setState(() {
              if (isExpanded) {
                _expandedQuotedMessageIds.remove(messageKey);
              } else {
                _expandedQuotedMessageIds.add(messageKey);
              }
            });
          },
          icon: Icon(
            isExpanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
          ),
          label: Text(isExpanded ? 'Hide quoted text' : 'Show quoted text'),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: const Size(0, 0),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      );
      if (isExpanded) {
        children.add(
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              parts.quotedText,
              style: theme.textTheme.bodySmall?.copyWith(
                height: 1.3,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
    }

    if (children.isEmpty) {
      return SelectableText(message.content, style: contentStyle);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  List<PopupMenuEntry<String>> _buildMessageActionMenuItems() => const [
    PopupMenuItem(value: 'copy', child: Text('Copy')),
    PopupMenuItem(value: 'quote', child: Text('Quote')),
    PopupMenuDivider(),
    PopupMenuItem(
      value: 'delete',
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.delete_outline, color: Colors.red),
        title: Text('Delete message', style: TextStyle(color: Colors.red)),
      ),
    ),
  ];

  Future<void> _showMessageActionMenuAt(
    EmailMessage message,
    Offset globalPosition,
  ) async {
    final overlayContext = Overlay.maybeOf(context)?.context;
    if (overlayContext == null) return;
    final overlayBox = overlayContext.findRenderObject();
    if (overlayBox is! RenderBox) return;

    final selectedAction = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlayBox.size,
      ),
      items: _buildMessageActionMenuItems(),
    );

    if (selectedAction != null && mounted) {
      _handleMessageAction(selectedAction, message);
    }
  }

  Widget _buildVerificationBadge(EmailMessage message) {
    IconData icon;
    Color color;
    String tooltip;

    switch (message.verificationState) {
      case EmailVerificationState.verified:
        icon = Icons.verified;
        color = Colors.green;
        tooltip = 'Verified sender';
        break;
      case EmailVerificationState.pending:
        icon = Icons.pending;
        color = Colors.orange;
        tooltip = 'Verification pending';
        break;
      case EmailVerificationState.invalid:
        icon = Icons.error;
        color = Colors.red;
        tooltip = 'Invalid signature';
        break;
      case EmailVerificationState.mismatch:
        icon = Icons.warning;
        color = Colors.orange;
        tooltip = 'Sender mismatch';
        break;
      case EmailVerificationState.unverified:
      default:
        // No badge for unverified
        return const SizedBox.shrink();
    }

    return Tooltip(
      message: tooltip,
      child: Icon(icon, size: 20, color: color),
    );
  }

  Widget _buildAttachments(EmailMessage message) {
    // Collect all attachment filenames
    final attachments = <String>[];

    // Single file attachment
    if (message.hasFile && message.attachedFile != null) {
      attachments.add(message.attachedFile!);
    }
    // Single image attachment
    if (message.hasImage && message.attachedImage != null) {
      attachments.add(message.attachedImage!);
    }
    // Multiple files
    final filesStr = message.getMeta('files');
    if (filesStr != null && filesStr.isNotEmpty) {
      attachments.addAll(filesStr.split(','));
    }

    if (attachments.isEmpty) return const SizedBox.shrink();

    // Separate images from other files
    final imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'];
    final images = <String>[];
    final files = <String>[];

    for (final attachment in attachments) {
      final ext = p.extension(attachment).toLowerCase();
      if (imageExtensions.contains(ext)) {
        images.add(attachment);
      } else {
        files.add(attachment);
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.1),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Image thumbnails
          if (images.isNotEmpty) _buildImageAttachments(images),
          // File attachments
          if (files.isNotEmpty) _buildFileAttachments(files),
        ],
      ),
    );
  }

  Widget _buildImageAttachments(List<String> images) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: images.asMap().entries.map((entry) {
          final index = entry.key;
          final filename = entry.value;
          return _buildImageThumbnail(filename, images, index);
        }).toList(),
      ),
    );
  }

  Widget _buildImageThumbnail(
    String filename,
    List<String> allImageFilenames,
    int index,
  ) {
    if (kIsWeb) {
      return Container(
        width: 100,
        height: 100,
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.image, size: 40, color: Colors.grey),
      );
    }

    return FutureBuilder<Uint8List?>(
      future: _emailService.readAttachmentBytes(_thread, filename),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data == null) {
          return Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(8),
            ),
            child: snapshot.connectionState == ConnectionState.waiting
                ? const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : const Icon(Icons.broken_image, color: Colors.grey),
          );
        }

        return GestureDetector(
          onTap: () => _openImageViewer(allImageFilenames, index),
          child: Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey[300]!),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Image.memory(
                snapshot.data!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: Colors.grey[200],
                  child: const Icon(Icons.broken_image, color: Colors.grey),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openImageViewer(
    List<String> imageFilenames,
    int initialIndex,
  ) async {
    final paths = <String>[];
    for (final filename in imageFilenames) {
      final path = await _emailService.exportAttachmentToTemp(
        _thread,
        filename,
      );
      if (path != null) paths.add(path);
    }

    if (paths.isEmpty || !mounted) return;

    final adjustedIndex = initialIndex < paths.length ? initialIndex : 0;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PhotoViewerPage(imagePaths: paths, initialIndex: adjustedIndex),
      ),
    );
  }

  Widget _buildFileAttachments(List<String> files) {
    return Column(
      children: files.map((file) {
        final displayName = _getDisplayFileName(file);
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.insert_drive_file, size: 20),
          title: Text(
            displayName,
            style: const TextStyle(fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            icon: const Icon(Icons.open_in_new, size: 20),
            onPressed: () => _openFile(file),
            tooltip: 'Open',
          ),
        );
      }).toList(),
    );
  }

  /// Extract display name from hashed filename
  String _getDisplayFileName(String hashedName) {
    // Format: sha1hash_originalname.ext
    final underscoreIndex = hashedName.indexOf('_');
    if (underscoreIndex == 40) {
      return hashedName.substring(41);
    }
    return hashedName;
  }

  Future<void> _openFile(String filename) async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File opening not supported on web')),
      );
      return;
    }

    try {
      final path = await _emailService.exportAttachmentToTemp(
        _thread,
        filename,
      );
      if (path == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('File not found')));
        }
        return;
      }

      final uri = Uri.file(path);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No app found to open this file')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open file: $e')));
      }
    }
  }

  Widget _buildQuickReplyBar() {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: _reply,
            icon: const Icon(Icons.reply, size: 18),
            label: const Text('Reply'),
          ),
          OutlinedButton.icon(
            onPressed: _replyAll,
            icon: const Icon(Icons.reply_all, size: 18),
            label: const Text('Reply All'),
          ),
          OutlinedButton.icon(
            onPressed: _forward,
            icon: const Icon(Icons.forward, size: 18),
            label: const Text('Forward'),
          ),
        ],
      ),
    );
  }

  String _statusLabel(EmailStatus status) {
    switch (status) {
      case EmailStatus.draft:
        return 'Draft';
      case EmailStatus.pending:
        return 'Outbox';
      case EmailStatus.sent:
        return 'Sent';
      case EmailStatus.received:
        return 'Inbox';
      case EmailStatus.failed:
        return 'Failed';
      case EmailStatus.spam:
        return 'Spam';
      case EmailStatus.deleted:
        return 'Trash';
      case EmailStatus.archived:
        return 'Archived';
    }
  }

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    String date;
    if (diff.inDays == 0) {
      date = 'Today';
    } else if (diff.inDays == 1) {
      date = 'Yesterday';
    } else {
      date = '${dt.day}/${dt.month}/${dt.year}';
    }

    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return '$date at $time';
  }

  void _handleMessageAction(String action, EmailMessage message) {
    switch (action) {
      case 'copy':
        Clipboard.setData(ClipboardData(text: message.content));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
        break;
      case 'quote':
        // TODO: Open compose with quoted message
        break;
      case 'delete':
        _confirmDeleteMessage(message);
        break;
    }
  }

  Future<void> _confirmDeleteMessage(EmailMessage message) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this message?'),
        content: const Text('This message will be removed from the thread.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final threadRemoved = await _emailService.deleteMessage(_thread, message);
    if (!mounted) return;

    if (threadRemoved) {
      Navigator.pop(context);
      return;
    }

    await _reloadThread();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Message deleted')));
  }
}
