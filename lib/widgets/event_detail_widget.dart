/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' as io;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import '../models/event.dart';
import '../models/event_link.dart';
import '../models/event_update.dart';
import '../models/event_registration.dart';
import '../services/event_service.dart';
import '../services/i18n_service.dart';
import 'event_feedback_section.dart';
import 'event_community_media_section.dart';
import '../pages/photo_viewer_page.dart';

/// Widget for displaying event detail with all v1.2 features
class EventDetailWidget extends StatelessWidget {
  final Event event;
  final String collectionPath;
  final String? currentCallsign;
  final String? currentUserNpub;
  final bool canEdit;
  final VoidCallback? onEdit;
  final VoidCallback? onUploadFiles;
  final VoidCallback? onCreateUpdate;
  final Future<void> Function()? onFeedbackUpdated;

  const EventDetailWidget({
    Key? key,
    required this.event,
    required this.collectionPath,
    this.currentCallsign,
    this.currentUserNpub,
    this.canEdit = false,
    this.onEdit,
    this.onUploadFiles,
    this.onCreateUpdate,
    this.onFeedbackUpdated,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();

    return Column(
      children: [
        // Action toolbar with title
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              // Event title
              Expanded(
                child: Text(
                  event.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Like button
              EventLikeButton(
                event: event,
                collectionPath: collectionPath,
                compact: true,
                showCount: false,
                onFeedbackUpdated: onFeedbackUpdated,
              ),
              // Edit/Settings button (if allowed)
              if (canEdit)
                IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: onEdit,
                  tooltip: i18n.t('event_settings'),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
          // Event metadata (author, date, location, visibility)
          _buildMetadata(theme, i18n),
          const SizedBox(height: 16),

          // Flyer display
          if (event.hasFlyer) ...[
            const SizedBox(height: 16),
            _buildFlyer(context, theme, i18n),
          ],

          // Trailer
          if (event.hasTrailer) ...[
            const SizedBox(height: 16),
            _buildTrailer(theme, i18n),
          ],

          // Divider and spacing based on whether we have media
          if (event.hasFlyer || event.hasTrailer) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 16),
          ] else
            const SizedBox(height: 16),

          // Event content
          _buildContent(theme, i18n),
          const SizedBox(height: 24),

          // Agenda
          if (event.agenda != null && event.agenda!.isNotEmpty) ...[
            _buildAgenda(theme, i18n),
            const SizedBox(height: 24),
          ],

          // Registration section
          if (event.hasRegistration) ...[
            _buildRegistration(context, theme, i18n),
            const SizedBox(height: 24),
          ],

          // Links section
          if (event.hasLinks) ...[
            _buildLinks(context, theme, i18n),
            const SizedBox(height: 24),
          ],

          // Updates section
          if (event.hasUpdates) ...[
            _buildUpdates(theme, i18n),
            const SizedBox(height: 24),
          ],

          // Files & Photos section
          EventFilesSection(
            event: event,
            collectionPath: collectionPath,
            onUploadFiles: onUploadFiles,
          ),
          const SizedBox(height: 24),

          EventCommunityMediaSection(
            event: event,
            collectionPath: collectionPath,
            currentCallsign: currentCallsign,
            currentUserNpub: currentUserNpub,
          ),
          const SizedBox(height: 24),

          EventFeedbackSection(
            event: event,
            collectionPath: collectionPath,
            onFeedbackUpdated: onFeedbackUpdated,
          ),
          const SizedBox(height: 24),

          // Engagement stats
          _buildEngagementStats(theme, i18n),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMetadata(ThemeData theme, I18nService i18n) {
    final relativeLabel = _relativeDaysLabel(i18n);

    // Get visibility icon and label
    IconData visibilityIcon;
    String visibilityLabel;
    switch (event.visibility) {
      case 'private':
        visibilityIcon = Icons.lock;
        visibilityLabel = i18n.t('private');
        break;
      case 'group':
        visibilityIcon = Icons.group;
        visibilityLabel = i18n.t('group');
        break;
      default:
        visibilityIcon = Icons.public;
        visibilityLabel = i18n.t('public');
    }

    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        // Author
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              event.author,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        // Date
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_today,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              event.isMultiDay
                  ? '${event.startDate} - ${event.endDate}'
                  : event.displayDateTime,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (relativeLabel != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.timelapse,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                relativeLabel,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        // Location
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              event.isOnline ? Icons.language : Icons.place,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              event.locationName ?? event.location,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        // Visibility
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              visibilityIcon,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              visibilityLabel,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String? _relativeDaysLabel(I18nService i18n) {
    DateTime? startDate;
    if (event.isMultiDay && event.startDate != null) {
      try {
        startDate = DateTime.parse(event.startDate!);
      } catch (e) {
        startDate = null;
      }
    } else {
      final dt = event.dateTime;
      startDate = DateTime(dt.year, dt.month, dt.day);
    }

    if (startDate == null) return null;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diffDays = startDate.difference(today).inDays;

    if (diffDays < -90) {
      return null;
    }
    if (diffDays == 0) {
      return i18n.t('today');
    }
    if (diffDays > 0) {
      return i18n.t('in_days', params: [diffDays.toString()]);
    }
    return i18n.t('days_ago_long', params: [diffDays.abs().toString()]);
  }

  Widget _buildFlyer(BuildContext context, ThemeData theme, I18nService i18n) {
    final year = event.id.substring(0, 4);
    final flyerPath = '$collectionPath/$year/${event.id}/${event.primaryFlyer}';
    final flyerPaths = event.flyers
        .map((flyer) => '$collectionPath/$year/${event.id}/$flyer')
        .toList();
    final canOpen = !kIsWeb && flyerPaths.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          i18n.t('flyer'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: canOpen
              ? () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => PhotoViewerPage(
                        imagePaths: flyerPaths,
                        initialIndex: 0,
                      ),
                    ),
                  );
                }
              : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: kIsWeb
                ? Container(
                    height: 200,
                    color: theme.colorScheme.surfaceVariant,
                    child: Center(
                      child: Text(i18n.t('image_not_available_on_web')),
                    ),
                  )
                : Image.file(
                    io.File(flyerPath),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        height: 200,
                        color: theme.colorScheme.surfaceVariant,
                        child: Center(
                          child: Icon(
                            Icons.broken_image,
                            size: 48,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildTrailer(ThemeData theme, I18nService i18n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          i18n.t('trailer'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                Icons.play_circle_outline,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  event.trailer ?? '',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContent(ThemeData theme, I18nService i18n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          i18n.t('description'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        SelectableText(
          event.content,
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
        ),
      ],
    );
  }

  Widget _buildAgenda(ThemeData theme, I18nService i18n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          i18n.t('agenda'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        SelectableText(
          event.agenda ?? '',
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
        ),
      ],
    );
  }

  Widget _buildRegistration(BuildContext context, ThemeData theme, I18nService i18n) {
    return EventRegistrationSection(
      event: event,
      collectionPath: collectionPath,
      currentCallsign: currentCallsign,
      currentUserNpub: currentUserNpub,
      onRegistrationUpdated: onFeedbackUpdated,
    );
  }

  Widget _buildLinks(BuildContext context, ThemeData theme, I18nService i18n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          i18n.t('links'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        ...event.links.map((link) => _buildLinkItem(context, link, theme, i18n)),
      ],
    );
  }

  Widget _buildLinkItem(BuildContext context, EventLink link, ThemeData theme, I18nService i18n) {
    IconData icon;
    switch (link.linkType) {
      case LinkType.zoom:
      case LinkType.googleMeet:
      case LinkType.teams:
        icon = Icons.video_call;
        break;
      case LinkType.instagram:
      case LinkType.twitter:
      case LinkType.facebook:
        icon = Icons.share;
        break;
      case LinkType.youtube:
        icon = Icons.play_circle_outline;
        break;
      case LinkType.github:
        icon = Icons.code;
        break;
      default:
        icon = Icons.link;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      link.description,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      link.url,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.open_in_new, size: 18),
                onPressed: () async {
                  final uri = Uri.tryParse(link.url);
                  if (uri == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(i18n.t('invalid_url', params: [link.url]))),
                    );
                    return;
                  }
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(i18n.t('could_not_open_url', params: [link.url]))),
                    );
                  }
                },
                tooltip: i18n.t('open_link'),
              ),
            ],
          ),
          if (link.password != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.lock, size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  '${i18n.t('password')}: ${link.password}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ],
          if (link.note != null) ...[
            const SizedBox(height: 8),
            Text(
              link.note!,
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUpdates(ThemeData theme, I18nService i18n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              i18n.t('updates'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            if (canEdit)
              OutlinedButton.icon(
                onPressed: onCreateUpdate,
                icon: const Icon(Icons.add, size: 18),
                label: Text(i18n.t('new_update')),
              ),
          ],
        ),
        const SizedBox(height: 12),
        ...event.updates.map((update) => _buildUpdateItem(update, theme, i18n)),
      ],
    );
  }

  Widget _buildUpdateItem(EventUpdate update, ThemeData theme, I18nService i18n) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            update.title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                Icons.person_outline,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                update.author,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                Icons.access_time,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                '${update.displayDate} ${update.displayTime}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            update.content,
            style: theme.textTheme.bodyMedium,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          if (update.likeCount > 0 || update.commentCount > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (update.likeCount > 0) ...[
                  Icon(Icons.favorite, size: 14, color: theme.colorScheme.error),
                  const SizedBox(width: 4),
                  Text(
                    '${update.likeCount}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(width: 12),
                ],
                if (update.commentCount > 0) ...[
                  Icon(Icons.comment_outlined, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    '${update.commentCount}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEngagementStats(ThemeData theme, I18nService i18n) {
    return Row(
      children: [
        Icon(Icons.favorite, size: 20, color: theme.colorScheme.error),
        const SizedBox(width: 6),
        Text(
          '${event.likeCount} ${i18n.t('likes')}',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(width: 20),
        Icon(Icons.comment_outlined, size: 20),
        const SizedBox(width: 6),
        Text(
          '${event.commentCount} ${i18n.t('comments_plural')}',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

}

class EventRegistrationSection extends StatefulWidget {
  final Event event;
  final String collectionPath;
  final String? currentCallsign;
  final String? currentUserNpub;
  final Future<void> Function()? onRegistrationUpdated;

  const EventRegistrationSection({
    Key? key,
    required this.event,
    required this.collectionPath,
    this.currentCallsign,
    this.currentUserNpub,
    this.onRegistrationUpdated,
  }) : super(key: key);

  @override
  State<EventRegistrationSection> createState() => _EventRegistrationSectionState();
}

class _EventRegistrationSectionState extends State<EventRegistrationSection> {
  final EventService _eventService = EventService();
  final I18nService _i18n = I18nService();
  bool _isSubmitting = false;
  late EventRegistration _registration;

  @override
  void initState() {
    super.initState();
    _registration = widget.event.registration ?? EventRegistration();
  }

  @override
  void didUpdateWidget(covariant EventRegistrationSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.id != widget.event.id ||
        oldWidget.event.registration?.totalCount != widget.event.registration?.totalCount) {
      _registration = widget.event.registration ?? EventRegistration();
    }
  }

  Future<void> _toggleRegistration(RegistrationType type) async {
    if (_isSubmitting) return;

    if (widget.collectionPath.isEmpty) {
      _showMessage(_i18n.t('connection_failed'), isError: true);
      return;
    }

    final callsign = widget.currentCallsign ?? '';
    final npub = widget.currentUserNpub ?? '';
    if (callsign.isEmpty) {
      _showMessage(_i18n.t('no_active_callsign'));
      return;
    }
    if (npub.isEmpty) {
      _showMessage(_i18n.t('nostr_keys_required'));
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final currentType = _registration.getRegistrationType(callsign);
      bool success;
      if (currentType == type) {
        success = await _eventService.unregister(
          eventId: widget.event.id,
          callsign: callsign,
        );
      } else {
        success = await _eventService.register(
          eventId: widget.event.id,
          callsign: callsign,
          npub: npub,
          type: type,
        );
      }

      if (!success) {
        _showMessage(_i18n.t('error'), isError: true);
        return;
      }

      final updated = await _eventService.loadEvent(widget.event.id);
      if (updated != null) {
        setState(() {
          _registration = updated.registration ?? EventRegistration();
        });
      }

      await widget.onRegistrationUpdated?.call();
    } catch (e) {
      _showMessage('Failed to update registration: $e', isError: true);
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
    final callsign = widget.currentCallsign ?? '';
    final isGoing = callsign.isNotEmpty && _registration.isGoing(callsign);
    final isInterested = callsign.isNotEmpty && _registration.isInterested(callsign);
    final isReadOnly = widget.collectionPath.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _i18n.t('registration'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildRegistrationCard(
                theme: theme,
                label: _i18n.t('going'),
                count: _registration.goingCount,
                icon: Icons.check_circle,
                accent: Colors.green,
                isActive: isGoing,
                isReadOnly: isReadOnly,
                onPressed: () => _toggleRegistration(RegistrationType.going),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildRegistrationCard(
                theme: theme,
                label: _i18n.t('interested'),
                count: _registration.interestedCount,
                icon: Icons.star_outline,
                accent: theme.colorScheme.primary,
                isActive: isInterested,
                isReadOnly: isReadOnly,
                onPressed: () => _toggleRegistration(RegistrationType.interested),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRegistrationCard({
    required ThemeData theme,
    required String label,
    required int count,
    required IconData icon,
    required Color accent,
    required bool isActive,
    required bool isReadOnly,
    required VoidCallback onPressed,
  }) {
    final borderColor = accent.withOpacity(0.3);
    final backgroundColor = accent.withOpacity(isActive ? 0.2 : 0.08);

    final button = isActive
        ? FilledButton.icon(
            onPressed: _isSubmitting ? null : onPressed,
            icon: const Icon(Icons.check, size: 16),
            label: Text(label),
          )
        : OutlinedButton.icon(
            onPressed: _isSubmitting ? null : onPressed,
            icon: Icon(icon, size: 16),
            label: Text(label),
          );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: borderColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accent, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$count ${_i18n.t('people')}',
            style: theme.textTheme.bodyMedium,
          ),
          if (!isReadOnly) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: button,
            ),
          ],
        ],
      ),
    );
  }
}

/// Stateful widget for displaying and managing event files
class EventFilesSection extends StatefulWidget {
  final Event event;
  final String collectionPath;
  final VoidCallback? onUploadFiles;

  const EventFilesSection({
    Key? key,
    required this.event,
    required this.collectionPath,
    this.onUploadFiles,
  }) : super(key: key);

  @override
  State<EventFilesSection> createState() => _EventFilesSectionState();
}

class _EventFilesSectionState extends State<EventFilesSection> {
  List<io.File> _files = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  @override
  void didUpdateWidget(EventFilesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload files if event changed
    if (oldWidget.event.id != widget.event.id) {
      _loadFiles();
    }
  }

  Future<void> _loadFiles() async {
    // File system operations not supported on web
    if (kIsWeb) {
      setState(() => _isLoading = false);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final year = widget.event.id.substring(0, 4);
      final eventDir = io.Directory(
        '${widget.collectionPath}/$year/${widget.event.id}',
      );

      if (await eventDir.exists()) {
        final entities = await eventDir.list().toList();

        // Filter out directories and system files
        _files = entities.whereType<io.File>().where((entity) {
          final fileName = path.basename(entity.path);
          // Exclude system files
          if (fileName == 'event.txt') return false;
          if (fileName.startsWith('.')) return false;

          return true;
        }).toList();

        // Sort by name
        _files.sort((a, b) => path.basename(a.path).compareTo(path.basename(b.path)));
      }
    } catch (e) {
      print('Error loading files: $e');
    }

    setState(() => _isLoading = false);
  }

  bool _isImageFile(String fileName) {
    final ext = path.extension(fileName).toLowerCase();
    return ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'].contains(ext);
  }

  IconData _getFileIcon(String fileName) {
    final ext = path.extension(fileName).toLowerCase();

    if (_isImageFile(fileName)) return Icons.image;
    if (['.pdf'].contains(ext)) return Icons.picture_as_pdf;
    if (['.doc', '.docx', '.txt', '.md'].contains(ext)) return Icons.description;
    if (['.mp4', '.avi', '.mov', '.mkv'].contains(ext)) return Icons.video_file;
    if (['.mp3', '.wav', '.ogg', '.m4a'].contains(ext)) return Icons.audio_file;
    if (['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) return Icons.folder_zip;

    return Icons.insert_drive_file;
  }

  Future<void> _openFile(io.File file) async {
    if (kIsWeb) return;
    final uri = Uri.file(file.path);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  void _openImageViewer(BuildContext context, io.File file) {
    final imageFiles = _files
        .where((entry) => _isImageFile(path.basename(entry.path)))
        .toList();
    if (imageFiles.isEmpty) return;

    final imagePaths = imageFiles.map((entry) => entry.path).toList();
    final initialIndex = imagePaths.indexOf(file.path);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => PhotoViewerPage(
          imagePaths: imagePaths,
          initialIndex: initialIndex >= 0 ? initialIndex : 0,
        ),
      ),
    );
  }

  void _handleFileTap(BuildContext context, io.File file) {
    if (_isImageFile(path.basename(file.path))) {
      _openImageViewer(context, file);
      return;
    }

    _openFile(file);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                i18n.t('event_files'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: _loadFiles,
              tooltip: i18n.t('refresh'),
            ),
            IconButton(
              icon: const Icon(Icons.add_photo_alternate),
              onPressed: widget.onUploadFiles,
              tooltip: i18n.t('add_files'),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Files grid
        if (_isLoading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          )
        else if (_files.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.folder_open,
                  size: 32,
                  color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    i18n.t('no_files_yet'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1,
            ),
            itemCount: _files.length,
            itemBuilder: (context, index) {
              final file = _files[index];
              final fileName = path.basename(file.path);
              final isImage = _isImageFile(fileName);

              return InkWell(
                onTap: () => _handleFileTap(context, file),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Thumbnail or icon
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: (isImage && !kIsWeb)
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.file(
                                    io.File(file.path),
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      return Icon(
                                        Icons.broken_image,
                                        size: 48,
                                        color: theme.colorScheme.onSurfaceVariant,
                                      );
                                    },
                                  ),
                                )
                              : Icon(
                                  _getFileIcon(fileName),
                                  size: 48,
                                  color: theme.colorScheme.primary,
                                ),
                        ),
                      ),
                      // File name
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceVariant,
                          borderRadius: const BorderRadius.only(
                            bottomLeft: Radius.circular(8),
                            bottomRight: Radius.circular(8),
                          ),
                        ),
                        child: Text(
                          fileName,
                          style: theme.textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
