/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../models/event.dart';
import '../services/event_feedback_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../util/feedback_comment_utils.dart';
import '../util/feedback_folder_utils.dart';

class EventLikeButton extends StatefulWidget {
  final Event event;
  final String collectionPath;
  final bool compact;
  final bool showCount;
  final Future<void> Function()? onFeedbackUpdated;

  const EventLikeButton({
    super.key,
    required this.event,
    required this.collectionPath,
    this.compact = true,
    this.showCount = false,
    this.onFeedbackUpdated,
  });

  @override
  State<EventLikeButton> createState() => _EventLikeButtonState();
}

class _EventLikeButtonState extends State<EventLikeButton> {
  final EventFeedbackService _feedbackService = EventFeedbackService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();

  bool _isSubmitting = false;
  int _likeCount = 0;
  bool _hasLiked = false;
  String? _currentNpub;

  String? get _contentPath {
    if (widget.collectionPath.isEmpty) return null;
    final year = widget.event.id.substring(0, 4);
    return '${widget.collectionPath}/$year/${widget.event.id}';
  }

  @override
  void initState() {
    super.initState();
    _currentNpub = _profileService.getProfile().npub;
    _loadLikes();
  }

  @override
  void didUpdateWidget(covariant EventLikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.id != widget.event.id ||
        oldWidget.collectionPath != widget.collectionPath ||
        oldWidget.event.likeCount != widget.event.likeCount) {
      _currentNpub = _profileService.getProfile().npub;
      _loadLikes();
    }
  }

  Future<void> _loadLikes() async {
    final contentPath = _contentPath;
    if (contentPath == null || contentPath.isEmpty) {
      return;
    }

    try {
      final npubs = await FeedbackFolderUtils.readFeedbackFile(
        contentPath,
        FeedbackFolderUtils.feedbackTypeLikes,
      );

      final npub = _currentNpub;
      final hasLiked = npub != null && npub.isNotEmpty
          ? npubs.contains(npub)
          : false;

      if (!mounted) return;
      setState(() {
        _likeCount = npubs.length;
        _hasLiked = hasLiked;
      });
    } catch (e) {
      LogService().log('EventLikeButton: Error loading likes: $e');
    }
  }

  Future<void> _toggleLike() async {
    if (_isSubmitting) return;

    final contentPath = _contentPath;
    if (contentPath == null || contentPath.isEmpty) return;
    final isPublic = widget.event.visibility.toLowerCase() == 'public';

    final profile = _profileService.getProfile();
    if (profile.callsign.isEmpty) {
      _showMessage(_i18n.t('no_active_callsign'));
      return;
    }
    if (profile.npub.isEmpty) {
      _showMessage(_i18n.t('nostr_keys_required'));
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final event = await _feedbackService.buildLikeEvent(widget.event.id);
      if (event == null) {
        _showMessage(_i18n.t('nostr_keys_required'));
        return;
      }

      FeedbackToggleResult? stationResult;
      if (isPublic) {
        stationResult = await _feedbackService.toggleLikeOnStation(widget.event.id, event);
        if (!stationResult.success) {
          _showMessage(
            stationResult.error ?? _i18n.t('connection_failed'),
            isError: true,
          );
          return;
        }
      }

      bool? isActive = stationResult?.isActive;
      if (isActive == true) {
        await FeedbackFolderUtils.addFeedbackEvent(
          contentPath,
          FeedbackFolderUtils.feedbackTypeLikes,
          event,
        );
      } else if (isActive == false) {
        await FeedbackFolderUtils.removeFeedbackEvent(
          contentPath,
          FeedbackFolderUtils.feedbackTypeLikes,
          event.npub,
        );
      } else {
        isActive = await FeedbackFolderUtils.toggleFeedbackEvent(
          contentPath,
          FeedbackFolderUtils.feedbackTypeLikes,
          event,
        );
      }

      if (isActive == null) {
        _showMessage(_i18n.t('connection_failed'), isError: true);
        return;
      }

      final localCount = await FeedbackFolderUtils.getFeedbackCount(
        contentPath,
        FeedbackFolderUtils.feedbackTypeLikes,
      );
      final count = isPublic ? (stationResult?.count ?? localCount) : localCount;

      if (!mounted) return;
      setState(() {
        _hasLiked = isActive!;
        _likeCount = count;
      });

      _showMessage(isActive ? _i18n.t('like_added') : _i18n.t('like_removed'));
      await widget.onFeedbackUpdated?.call();
    } catch (e) {
      _showMessage('Failed to update like: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contentPath = _contentPath;
    if (contentPath == null || contentPath.isEmpty) {
      return const SizedBox.shrink();
    }

    final icon = Icon(
      _hasLiked ? Icons.favorite : Icons.favorite_border,
      color: _hasLiked ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
      size: widget.compact ? 20 : 22,
    );

    final button = IconButton(
      icon: icon,
      onPressed: _isSubmitting ? null : _toggleLike,
      tooltip: _hasLiked ? _i18n.t('unlike') : _i18n.t('like'),
      visualDensity: widget.compact ? VisualDensity.compact : VisualDensity.standard,
    );

    if (!widget.showCount) {
      return button;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        Text(
          _likeCount.toString(),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class EventFeedbackSection extends StatefulWidget {
  final Event event;
  final String collectionPath;
  final Future<void> Function()? onFeedbackUpdated;

  const EventFeedbackSection({
    super.key,
    required this.event,
    required this.collectionPath,
    this.onFeedbackUpdated,
  });

  @override
  State<EventFeedbackSection> createState() => _EventFeedbackSectionState();
}

class _EventFeedbackSectionState extends State<EventFeedbackSection> {
  final EventFeedbackService _feedbackService = EventFeedbackService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final TextEditingController _commentController = TextEditingController();

  bool _isLoading = false;
  bool _isSubmitting = false;
  List<FeedbackComment> _comments = [];

  String? get _contentPath {
    if (widget.collectionPath.isEmpty) return null;
    final year = widget.event.id.substring(0, 4);
    return '${widget.collectionPath}/$year/${widget.event.id}';
  }

  @override
  void initState() {
    super.initState();
    _loadComments();
  }

  @override
  void didUpdateWidget(covariant EventFeedbackSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.id != widget.event.id ||
        oldWidget.collectionPath != widget.collectionPath ||
        oldWidget.event.commentCount != widget.event.commentCount) {
      _loadComments();
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    final contentPath = _contentPath;
    if (contentPath == null || contentPath.isEmpty) {
      return;
    }

    setState(() => _isLoading = true);
    try {
      var comments = await FeedbackCommentUtils.loadComments(contentPath);
      if (comments.isEmpty && widget.event.comments.isNotEmpty) {
        comments = widget.event.comments.map((comment) {
          return FeedbackComment(
            id: '${comment.timestamp}_${comment.author}',
            author: comment.author,
            created: comment.timestamp,
            content: comment.content,
            npub: comment.npub,
            signature: comment.signature,
          );
        }).toList();
      }
      comments.sort((a, b) => _parseCommentDate(b.created).compareTo(_parseCommentDate(a.created)));

      if (!mounted) return;
      setState(() {
        _comments = comments;
      });
    } catch (e) {
      LogService().log('EventFeedbackSection: Error loading feedback: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  DateTime _parseCommentDate(String created) {
    final normalized = created.replaceAll('_', ':');
    return DateTime.tryParse(normalized) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> _addComment() async {
    if (_isSubmitting) return;
    final contentPath = _contentPath;
    if (contentPath == null || contentPath.isEmpty) return;
    final isPublic = widget.event.visibility.toLowerCase() == 'public';

    final content = _commentController.text.trim();
    if (content.isEmpty) return;

    final profile = _profileService.getProfile();
    if (profile.callsign.isEmpty) {
      _showMessage(_i18n.t('no_active_callsign'));
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final signature = await _feedbackService.signComment(widget.event.id, content);
      await FeedbackCommentUtils.writeComment(
        contentPath: contentPath,
        author: profile.callsign,
        content: content,
        npub: profile.npub.isNotEmpty ? profile.npub : null,
        signature: signature,
      );

      _commentController.clear();
      await _loadComments();
      _showMessage(_i18n.t('comment_added'));

      if (isPublic) {
        _feedbackService.commentOnStation(
          widget.event.id,
          profile.callsign,
          content,
          npub: profile.npub.isNotEmpty ? profile.npub : null,
          signature: signature,
        ).ignore();
      }

      await widget.onFeedbackUpdated?.call();
    } catch (e) {
      _showMessage('Failed to add comment: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contentPath = _contentPath;
    if (contentPath == null || contentPath.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isLoading) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        const SizedBox(height: 16),
        Text(
          _comments.isEmpty
              ? _i18n.t('comments')
              : '${_i18n.t('comments')} (${_comments.length})',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _commentController,
                decoration: InputDecoration(
                  hintText: _i18n.t('comment_hint'),
                  border: const OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.sentences,
                maxLines: 3,
                minLines: 1,
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _isSubmitting ? null : _addComment,
              icon: const Icon(Icons.send),
              tooltip: _i18n.t('add_comment'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_comments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _i18n.t('no_comments_yet'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          ..._comments.map((comment) => _buildCommentCard(comment, theme)),
      ],
    );
  }

  Widget _buildCommentCard(FeedbackComment comment, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              comment.author,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              comment.created.replaceAll('_', ':'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              comment.content,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
