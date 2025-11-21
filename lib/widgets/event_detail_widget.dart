/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import '../models/event.dart';
import '../models/event_link.dart';
import '../models/event_update.dart';
import '../models/event_registration.dart';
import '../services/i18n_service.dart';

/// Widget for displaying event detail with all v1.2 features
class EventDetailWidget extends StatelessWidget {
  final Event event;
  final String collectionPath;
  final String? currentCallsign;
  final String? currentUserNpub;
  final bool canEdit;
  final bool hasLiked;
  final VoidCallback? onLike;
  final VoidCallback? onRefresh;
  final VoidCallback? onEdit;
  final VoidCallback? onUploadFiles;
  final VoidCallback? onCreateUpdate;

  const EventDetailWidget({
    Key? key,
    required this.event,
    required this.collectionPath,
    this.currentCallsign,
    this.currentUserNpub,
    this.canEdit = false,
    this.hasLiked = false,
    this.onLike,
    this.onRefresh,
    this.onEdit,
    this.onUploadFiles,
    this.onCreateUpdate,
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
              IconButton(
                icon: Icon(
                  hasLiked ? Icons.favorite : Icons.favorite_border,
                  color: hasLiked ? theme.colorScheme.error : null,
                ),
                onPressed: onLike,
                tooltip: hasLiked ? i18n.t('unlike') : i18n.t('like'),
              ),
              // Edit/Settings button (if allowed)
              if (canEdit)
                IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: onEdit,
                  tooltip: i18n.t('event_settings'),
                ),
              // Refresh button
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: onRefresh,
                tooltip: i18n.t('refresh'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
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

          // Registration section
          if (event.hasRegistration) ...[
            _buildRegistration(context, theme, i18n),
            const SizedBox(height: 24),
          ],

          // Links section
          if (event.hasLinks) ...[
            _buildLinks(theme, i18n),
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

          // Engagement stats
          _buildEngagementStats(theme, i18n),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMetadata(ThemeData theme, I18nService i18n) {
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
                  : '${event.displayDate} ${event.displayTime}',
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

  Widget _buildFlyer(BuildContext context, ThemeData theme, I18nService i18n) {
    final year = event.id.substring(0, 4);
    final flyerPath = '$collectionPath/events/$year/${event.id}/${event.primaryFlyer}';

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
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(flyerPath),
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

  Widget _buildRegistration(BuildContext context, ThemeData theme, I18nService i18n) {
    final registration = event.registration!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          i18n.t('registration'),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            // Going
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.green.withOpacity(0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.green, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          i18n.t('going'),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${registration.goingCount} ${i18n.t('people')}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Interested
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.star_outline,
                          color: theme.colorScheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          i18n.t('interested'),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${registration.interestedCount} ${i18n.t('people')}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLinks(ThemeData theme, I18nService i18n) {
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
        ...event.links.map((link) => _buildLinkItem(link, theme, i18n)),
      ],
    );
  }

  Widget _buildLinkItem(EventLink link, ThemeData theme, I18nService i18n) {
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
                onPressed: () {
                  // TODO: Open link
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
  List<FileSystemEntity> _files = [];
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
    setState(() => _isLoading = true);

    try {
      final year = widget.event.id.substring(0, 4);
      final eventDir = Directory(
        '${widget.collectionPath}/events/$year/${widget.event.id}',
      );

      if (await eventDir.exists()) {
        final entities = await eventDir.list().toList();

        // Filter out directories and system files
        _files = entities.where((entity) {
          if (entity is! File) return false;

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

  Future<void> _openFile(FileSystemEntity file) async {
    final uri = Uri.file(file.path);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
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
            Text(
              i18n.t('event_files'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: _loadFiles,
              tooltip: i18n.t('refresh'),
            ),
            OutlinedButton.icon(
              onPressed: widget.onUploadFiles,
              icon: const Icon(Icons.add_photo_alternate, size: 18),
              label: Text(i18n.t('add_files')),
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
                onTap: () => _openFile(file),
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
                          child: isImage
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.file(
                                    File(file.path),
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
