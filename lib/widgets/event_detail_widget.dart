/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
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
  final String appPath;
  final String? currentCallsign;
  final String? currentUserNpub;
  final bool canEdit;
  final VoidCallback? onEdit;
  final VoidCallback? onUploadFiles;
  final VoidCallback? onCreateUpdate;
  final Future<void> Function()? onFeedbackUpdated;
  final void Function(String placePath)? onPlaceOpen;
  final void Function(List<String> contacts)? onContactsUpdated;
  final void Function(String callsign)? onContactOpen;
  final int filesRefreshKey;

  const EventDetailWidget({
    Key? key,
    required this.event,
    required this.appPath,
    this.currentCallsign,
    this.currentUserNpub,
    this.canEdit = false,
    this.onEdit,
    this.onUploadFiles,
    this.onCreateUpdate,
    this.onFeedbackUpdated,
    this.onPlaceOpen,
    this.onContactsUpdated,
    this.onContactOpen,
    this.filesRefreshKey = 0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();

    return Column(
      children: [
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

          // Event content (only if not empty)
          if (event.content.trim().isNotEmpty) ...[
            _buildContent(theme, i18n),
            const SizedBox(height: 24),
          ],

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

          // Contacts section - only show if has contacts or can add contacts
          if (event.hasContacts || (canEdit && onContactsUpdated != null)) ...[
            EventContactsSection(
              event: event,
              appPath: appPath,
              canEdit: canEdit,
              onContactsUpdated: onContactsUpdated,
              onContactTap: onContactOpen,
            ),
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
            appPath: appPath,
            onUploadFiles: onUploadFiles,
            refreshKey: filesRefreshKey,
          ),
          const SizedBox(height: 24),

          EventCommunityMediaSection(
            event: event,
            appPath: appPath,
            currentCallsign: currentCallsign,
            currentUserNpub: currentUserNpub,
          ),
          const SizedBox(height: 24),

          EventFeedbackSection(
            event: event,
            appPath: appPath,
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
        // Author (only if not empty)
        if (event.author.trim().isNotEmpty)
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
        // Location (clickable if linked to a place)
        if (event.hasPlaceReference && onPlaceOpen != null)
          InkWell(
            onTap: () => onPlaceOpen!(event.placePath!),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.place,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    event.locationName ?? event.location,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
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
    final flyerPaths = event.flyers
        .map((flyer) => '$appPath/$year/${event.id}/$flyer')
        .toList();

    return _SwipeableFlyer(flyerPaths: flyerPaths);
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
    return SelectableText(
      event.content,
      style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
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
      appPath: appPath,
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
  final String appPath;
  final String? currentCallsign;
  final String? currentUserNpub;
  final Future<void> Function()? onRegistrationUpdated;

  const EventRegistrationSection({
    Key? key,
    required this.event,
    required this.appPath,
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

    if (widget.appPath.isEmpty) {
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
    final isReadOnly = widget.appPath.isEmpty;

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
  final String appPath;
  final VoidCallback? onUploadFiles;
  final int refreshKey;

  const EventFilesSection({
    Key? key,
    required this.event,
    required this.appPath,
    this.onUploadFiles,
    this.refreshKey = 0,
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
    // Reload files if event changed or refresh requested
    if (oldWidget.event.id != widget.event.id ||
        oldWidget.refreshKey != widget.refreshKey) {
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
        '${widget.appPath}/$year/${widget.event.id}',
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

  bool _isVideoFile(String fileName) {
    final ext = path.extension(fileName).toLowerCase();
    return ['.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm'].contains(ext);
  }

  bool _isMediaFile(String fileName) {
    return _isImageFile(fileName) || _isVideoFile(fileName);
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

  void _openMediaViewer(BuildContext context, io.File file) {
    final mediaFiles = _files
        .where((entry) => _isMediaFile(path.basename(entry.path)))
        .toList();
    if (mediaFiles.isEmpty) return;

    final mediaPaths = mediaFiles.map((entry) => entry.path).toList();
    final initialIndex = mediaPaths.indexOf(file.path);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => PhotoViewerPage(
          imagePaths: mediaPaths,
          initialIndex: initialIndex >= 0 ? initialIndex : 0,
        ),
      ),
    );
  }

  void _handleFileTap(BuildContext context, io.File file) {
    if (_isMediaFile(path.basename(file.path))) {
      _openMediaViewer(context, file);
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
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 0.85,
            ),
            itemCount: _files.length,
            itemBuilder: (context, index) {
              final file = _files[index];
              final fileName = path.basename(file.path);
              final isImage = _isImageFile(fileName);
              final isVideo = _isVideoFile(fileName);

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
                                    width: double.infinity,
                                    height: double.infinity,
                                    errorBuilder: (context, error, stackTrace) {
                                      return Icon(
                                        Icons.broken_image,
                                        size: 48,
                                        color: theme.colorScheme.onSurfaceVariant,
                                      );
                                    },
                                  ),
                                )
                              : isVideo
                                  ? Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        Icon(
                                          Icons.video_file,
                                          size: 48,
                                          color: theme.colorScheme.primary,
                                        ),
                                        Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: BoxDecoration(
                                            color: Colors.black54,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            Icons.play_arrow,
                                            size: 24,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
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

/// Section for displaying and managing contacts associated with an event
class EventContactsSection extends StatefulWidget {
  final Event event;
  final String appPath;
  final bool canEdit;
  final void Function(List<String> contacts)? onContactsUpdated;
  final void Function(String callsign)? onContactTap;

  const EventContactsSection({
    Key? key,
    required this.event,
    required this.appPath,
    this.canEdit = false,
    this.onContactsUpdated,
    this.onContactTap,
  }) : super(key: key);

  @override
  State<EventContactsSection> createState() => _EventContactsSectionState();
}

class _EventContactsSectionState extends State<EventContactsSection> {
  final I18nService _i18n = I18nService();
  Map<String, _ContactInfo> _contactInfoMap = {};

  @override
  void initState() {
    super.initState();
    _loadContactInfo();
  }

  @override
  void didUpdateWidget(EventContactsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.contacts != widget.event.contacts) {
      _loadContactInfo();
    }
  }

  /// Load contact info directly from fast.json file
  Future<void> _loadContactInfo() async {
    if (widget.appPath.isEmpty || widget.event.contacts.isEmpty) return;

    final infoMap = <String, _ContactInfo>{};

    // Events appPath is like: devices/X1DPDX/events
    // Contacts are at: devices/X1DPDX/contacts/fast.json
    final devicePath = path.dirname(widget.appPath);
    final fastJsonPath = '$devicePath/contacts/fast.json';

    try {
      final file = io.File(fastJsonPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> jsonList = json.decode(content);

        // Build lookup map from callsign to contact info
        for (final item in jsonList) {
          final callsign = item['callsign'] as String?;
          if (callsign != null && widget.event.contacts.contains(callsign)) {
            final displayName = item['displayName'] as String? ?? callsign;
            final profilePic = item['profilePicture'] as String?;
            // fast.json has absolute filePath, use its directory for profile pics
            final filePath = item['filePath'] as String?;
            String? profilePicPath;
            if (profilePic != null && filePath != null) {
              final contactsDir = path.dirname(filePath);
              profilePicPath = '$contactsDir/media/$profilePic';
            }
            infoMap[callsign] = _ContactInfo(
              displayName: displayName,
              profilePicPath: profilePicPath,
            );
          }
        }
      }
    } catch (e) {
      // Silently fail - will just show callsigns
    }

    if (mounted) {
      setState(() {
        _contactInfoMap = infoMap;
      });
    }
  }

  String _getContactLabel(String callsign) {
    final info = _contactInfoMap[callsign];
    if (info != null && info.displayName.isNotEmpty && info.displayName != callsign) {
      return '${info.displayName} ($callsign)';
    }
    return callsign;
  }

  Widget? _buildContactAvatar(String callsign) {
    final info = _contactInfoMap[callsign];
    if (info?.profilePicPath != null) {
      final file = io.File(info!.profilePicPath!);
      if (file.existsSync()) {
        return CircleAvatar(
          radius: 12,
          backgroundImage: FileImage(file),
        );
      }
    }
    return null;
  }

  Future<void> _addContact() async {
    // Show a dialog to add a contact by callsign
    final callsign = await showDialog<String>(
      context: context,
      builder: (context) => _AddContactDialog(
        existingContacts: widget.event.contacts,
        i18n: _i18n,
      ),
    );

    if (callsign != null && callsign.isNotEmpty) {
      final updatedContacts = [...widget.event.contacts, callsign];
      widget.onContactsUpdated?.call(updatedContacts);
    }
  }

  Future<void> _removeContact(String callsign) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('remove_contact')),
        content: Text(_i18n.t('remove_contact_confirm', params: [callsign])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_i18n.t('remove')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final updatedContacts = widget.event.contacts.where((c) => c != callsign).toList();
      widget.onContactsUpdated?.call(updatedContacts);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isReadOnly = widget.appPath.isEmpty || !widget.canEdit;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _i18n.t('event_contacts'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (!isReadOnly && widget.onContactsUpdated != null)
              IconButton(
                icon: const Icon(Icons.person_add),
                onPressed: _addContact,
                tooltip: _i18n.t('add_contact'),
              ),
          ],
        ),
        const SizedBox(height: 12),

        if (widget.event.contacts.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.people_outline,
                  size: 24,
                  color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _i18n.t('no_event_contacts'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: widget.event.contacts.map((callsign) {
              final chip = Chip(
                avatar: _buildContactAvatar(callsign),
                label: Text(_getContactLabel(callsign)),
                deleteIcon: !isReadOnly && widget.onContactsUpdated != null
                    ? const Icon(Icons.close, size: 18)
                    : null,
                onDeleted: !isReadOnly && widget.onContactsUpdated != null
                    ? () => _removeContact(callsign)
                    : null,
              );
              if (widget.onContactTap != null) {
                return InkWell(
                  onTap: () => widget.onContactTap!(callsign),
                  borderRadius: BorderRadius.circular(16),
                  child: chip,
                );
              }
              return chip;
            }).toList(),
          ),
      ],
    );
  }
}

/// Dialog for adding a contact to an event
class _AddContactDialog extends StatefulWidget {
  final List<String> existingContacts;
  final I18nService i18n;

  const _AddContactDialog({
    required this.existingContacts,
    required this.i18n,
  });

  @override
  State<_AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<_AddContactDialog> {
  final _controller = TextEditingController();
  String? _error;

  void _submit() {
    final callsign = _controller.text.trim();
    if (callsign.isEmpty) {
      setState(() => _error = widget.i18n.t('callsign_required'));
      return;
    }
    if (widget.existingContacts.contains(callsign)) {
      setState(() => _error = widget.i18n.t('contact_already_added'));
      return;
    }
    Navigator.pop(context, callsign);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.i18n.t('add_contact')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: widget.i18n.t('callsign'),
              hintText: widget.i18n.t('enter_callsign'),
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.words,
            autofocus: true,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.i18n.t('cancel')),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.i18n.t('add')),
        ),
      ],
    );
  }
}

/// Helper class to store contact info for display
class _ContactInfo {
  final String displayName;
  final String? profilePicPath;

  _ContactInfo({
    required this.displayName,
    this.profilePicPath,
  });
}

/// Swipeable flyer/photo carousel for the event detail hero image.
class _SwipeableFlyer extends StatefulWidget {
  final List<String> flyerPaths;

  const _SwipeableFlyer({required this.flyerPaths});

  @override
  State<_SwipeableFlyer> createState() => _SwipeableFlyerState();
}

class _SwipeableFlyerState extends State<_SwipeableFlyer> {
  late final PageController _pageController;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paths = widget.flyerPaths;
    if (paths.isEmpty) return const SizedBox.shrink();

    if (kIsWeb) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 200,
          color: theme.colorScheme.surfaceVariant,
          child: Center(
            child: Text(I18nService().t('image_not_available_on_web')),
          ),
        ),
      );
    }

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 300,
            child: PageView.builder(
              controller: _pageController,
              itemCount: paths.length,
              onPageChanged: (index) {
                setState(() => _currentPage = index);
              },
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => PhotoViewerPage(
                          imagePaths: paths,
                          initialIndex: index,
                        ),
                      ),
                    );
                  },
                  child: Image.file(
                    io.File(paths[index]),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
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
                );
              },
            ),
          ),
        ),
        if (paths.length > 1) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              paths.length > 10 ? 0 : paths.length,
              (index) => Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: index == _currentPage
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                ),
              ),
            ),
          ),
          if (paths.length > 10)
            Text(
              '${_currentPage + 1} / ${paths.length}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ],
    );
  }
}
