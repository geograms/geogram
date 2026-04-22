/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Browse + view events that live on another device. Uses the
 * generic /api/content/events surface — any device that serves the
 * endpoint (regular or station mode) shows up here without any
 * per-endpoint plumbing. Engagement (like / comment / view) goes
 * through the already-generic /api/feedback/event/{id}/… surface
 * via [RemoteEventActions].
 */

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../services/app_service.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/remote_content_client.dart';
import '../services/remote_contributor_actions.dart';
import '../services/remote_event_actions.dart';
import '../services/station_service.dart';
import '../widgets/file_folder_picker.dart';
import '../widgets/remote_content_image.dart';

class RemoteEventsBrowserPage extends StatefulWidget {
  final RemoteDevice device;

  const RemoteEventsBrowserPage({super.key, required this.device});

  @override
  State<RemoteEventsBrowserPage> createState() =>
      _RemoteEventsBrowserPageState();
}

class _RemoteEventsBrowserPageState extends State<RemoteEventsBrowserPage> {
  final I18nService _i18n = I18nService();

  List<Map<String, dynamic>> _events = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final r = await RemoteContent.list(
        remoteCallsign: widget.device.callsign,
        appType: 'events',
      );
      if (!mounted) return;
      if (!r.success) {
        setState(() {
          _error = r.error ?? 'Failed to load events';
          _isLoading = false;
        });
        return;
      }
      final items = (r.data?['items'] as List?) ?? const [];
      setState(() {
        _events = items
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
        _isLoading = false;
      });
    } catch (e) {
      LogService().log('RemoteEventsBrowserPage: load error: $e');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _openEvent(Map<String, dynamic> summary) async {
    final id = summary['id'] as String?;
    if (id == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _RemoteEventDetailPage(
        device: widget.device,
        eventId: id,
      ),
    ));
    // Refresh the list when returning — counts may have changed.
    _loadEvents();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.device.displayName} - Events'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadEvents,
            tooltip: _i18n.t('refresh'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError(theme)
              : _events.isEmpty
                  ? _buildEmpty(theme)
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _events.length,
                      itemBuilder: (context, i) =>
                          _buildEventCard(theme, _events[i]),
                    ),
    );
  }

  Widget _buildError(ThemeData theme) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline,
                size: 64, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(_i18n.t('error_loading_data'),
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadEvents,
              child: Text(_i18n.t('retry')),
            ),
          ],
        ),
      );

  Widget _buildEmpty(ThemeData theme) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.event_note_outlined,
                size: 64, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(_i18n.t('no_events'),
                style: theme.textTheme.titleMedium),
          ],
        ),
      );

  Widget _buildEventCard(ThemeData theme, Map<String, dynamic> ev) {
    final title = (ev['title'] as String?) ?? 'Untitled';
    final timestamp = (ev['timestamp'] as String?) ?? '';
    final visibility = (ev['visibility'] as String?) ?? 'public';
    final locationName =
        (ev['location_name'] as String?)?.trim() ?? '';
    final likeCount = (ev['like_count'] as num?)?.toInt() ?? 0;
    final commentCount = (ev['comment_count'] as num?)?.toInt() ?? 0;
    final viewCount = (ev['view_count'] as num?)?.toInt() ?? 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _openEvent(ev),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (visibility == 'request_access')
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Icon(Icons.lock_open_outlined,
                          size: 14,
                          color: theme.colorScheme.onTertiaryContainer),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (timestamp.isNotEmpty)
                Row(
                  children: [
                    Icon(Icons.schedule,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(timestamp,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )),
                  ],
                ),
              if (locationName.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.place_outlined,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(locationName,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          )),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  _statChip(theme, Icons.visibility, viewCount),
                  const SizedBox(width: 12),
                  _statChip(theme, Icons.thumb_up_outlined, likeCount),
                  const SizedBox(width: 12),
                  _statChip(theme, Icons.chat_bubble_outline, commentCount),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statChip(ThemeData theme, IconData icon, int count) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text('$count',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              )),
        ],
      );
}

// ─────────────────── detail page ───────────────────

class _RemoteEventDetailPage extends StatefulWidget {
  final RemoteDevice device;
  final String eventId;

  const _RemoteEventDetailPage({
    required this.device,
    required this.eventId,
  });

  @override
  State<_RemoteEventDetailPage> createState() =>
      _RemoteEventDetailPageState();
}

class _RemoteEventDetailPageState extends State<_RemoteEventDetailPage> {
  final I18nService _i18n = I18nService();
  final ProfileService _profileService = ProfileService();
  final TextEditingController _commentController = TextEditingController();

  Map<String, dynamic>? _event;
  bool _isLoading = true;
  bool _posting = false;
  bool _viewRecorded = false;
  bool _isUploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final r = await RemoteContent.get(
        remoteCallsign: widget.device.callsign,
        appType: 'events',
        itemId: widget.eventId,
      );
      if (!mounted) return;
      if (!r.success) {
        setState(() {
          _error = r.error ?? 'Failed to load event';
          _isLoading = false;
        });
        return;
      }
      setState(() {
        _event = r.data;
        _isLoading = false;
      });
      _recordView();
    } catch (e) {
      LogService().log('RemoteEventDetail: load error: $e');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _recordView() async {
    if (_viewRecorded) return;
    _viewRecorded = true;
    final r = await RemoteEventActions.recordView(
      remoteCallsign: widget.device.callsign,
      eventId: widget.eventId,
    );
    if (r.success && mounted) {
      final total = r.body?['total_views'];
      if (total is num && _event != null) {
        setState(() => _event!['view_count'] = total.toInt());
      }
    }
  }

  bool _requireKeys() {
    final profile = _profileService.getProfile();
    if (profile.npub.isEmpty || profile.nsec.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('NOSTR key required')),
      );
      return false;
    }
    return true;
  }

  Future<void> _toggleLike() async {
    if (_posting || !_requireKeys()) return;
    setState(() => _posting = true);
    try {
      final r = await RemoteEventActions.like(
        remoteCallsign: widget.device.callsign,
        eventId: widget.eventId,
        authorNpub: _event?['npub'] as String?,
      );
      if (!r.success) {
        _toast(r.error ?? 'Like failed');
      } else {
        await _load();
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  Future<void> _postComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty || _posting || !_requireKeys()) return;
    setState(() => _posting = true);
    try {
      final r = await RemoteEventActions.sendComment(
        remoteCallsign: widget.device.callsign,
        eventId: widget.eventId,
        content: text,
      );
      if (!r.success) {
        _toast(r.error ?? 'Comment rejected');
      } else {
        _commentController.clear();
        await _load();
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_event?['title'] as String? ?? _i18n.t('event') ?? 'Event'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: _i18n.t('refresh'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.error)),
                )
              : _event == null
                  ? const SizedBox.shrink()
                  : _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final ev = _event!;
    final title = (ev['title'] as String?) ?? '';
    final timestamp = (ev['timestamp'] as String?) ?? '';
    final location = (ev['location_name'] as String?)?.trim() ?? '';
    final content = (ev['content'] as String?)?.trim() ?? '';
    final visibility = (ev['visibility'] as String?) ?? 'public';
    final accessRequestRequired =
        ev['access_request_required'] == true;
    final likeCount = (ev['like_count'] as num?)?.toInt() ?? 0;
    final commentCount = (ev['comment_count'] as num?)?.toInt() ?? 0;
    final viewCount = (ev['view_count'] as num?)?.toInt() ?? 0;
    final comments = (ev['comments'] as List?) ?? const [];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(title,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (timestamp.isNotEmpty)
          Row(children: [
            Icon(Icons.schedule, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(timestamp,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )),
          ]),
        if (location.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.place_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Expanded(
              child: Text(location,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            ),
          ]),
        ],
        const SizedBox(height: 16),
        if (accessRequestRequired)
          _buildAccessRequestCard(theme, visibility)
        else ...[
          _buildPhotos(theme, ev),
          if (content.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(content, style: theme.textTheme.bodyMedium),
          ],
          const SizedBox(height: 16),
          _buildContributorsSection(theme, ev),
          const SizedBox(height: 12),
          _buildContributeButton(theme),
        ],
        const SizedBox(height: 16),
        _buildEngagementRow(theme, viewCount, likeCount, commentCount),
        const Divider(height: 32),
        Text('${_i18n.t('comments') ?? 'Comments'} (${comments.length})',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        _buildCommentCompose(theme),
        const SizedBox(height: 16),
        if (comments.isEmpty)
          Text(
            _i18n.t('no_comments_yet') ?? 'No comments yet.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          )
        else
          ...comments
              .whereType<Map<String, dynamic>>()
              .map((c) => _buildCommentCard(theme, c)),
      ],
    );
  }

  Widget _buildPhotos(ThemeData theme, Map<String, dynamic> ev) {
    final photos = (ev['photos'] as List? ?? ev['flyers'] as List?)
            ?.whereType<String>()
            .where((name) => name.trim().isNotEmpty)
            .toList() ??
        const <String>[];
    if (photos.isEmpty) return const SizedBox.shrink();
    // Gallery tiles use ?thumb=1 (~480 px JPEG) so the grid loads
    // fast. Tapping a tile opens a lightbox that fetches the full
    // resolution image. Bytes flow through ConnectionManager so
    // every transport (USB AOA / LAN / BLE / peer relay / …) works.
    if (photos.length == 1) {
      return InkWell(
        onTap: () => _openLightbox(photos, 0),
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: RemoteContentImage(
            remoteCallsign: widget.device.callsign,
            appType: 'events',
            itemId: widget.eventId,
            relativePath: photos.first,
            fit: BoxFit.cover,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
    return SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => InkWell(
          onTap: () => _openLightbox(photos, i),
          borderRadius: BorderRadius.circular(12),
          child: RemoteContentImage(
            remoteCallsign: widget.device.callsign,
            appType: 'events',
            itemId: widget.eventId,
            relativePath: photos[i],
            width: 280,
            height: 180,
            fit: BoxFit.cover,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  void _openLightbox(List<String> photos, int startIndex) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.95),
        pageBuilder: (_, __, ___) => _LightboxPage(
          remoteCallsign: widget.device.callsign,
          itemId: widget.eventId,
          photos: photos,
          startIndex: startIndex,
        ),
      ),
    );
  }

  /// "Contributed by" gallery — one card per approved contributor
  /// with their files. Source data comes from the event detail JSON
  /// served by EventContentProvider; pending contributors are not
  /// surfaced here (only the author sees them, in the editor).
  Widget _buildContributorsSection(ThemeData theme, Map<String, dynamic> ev) {
    final contributors = (ev['contributors'] as List?)
            ?.whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .where((m) =>
                m['callsign'] is String &&
                (m['files'] is List) &&
                (m['files'] as List).isNotEmpty)
            .toList() ??
        const <Map<String, dynamic>>[];
    if (contributors.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        for (final c in contributors) _buildContributorCard(theme, c),
      ],
    );
  }

  Widget _buildContributorCard(ThemeData theme, Map<String, dynamic> c) {
    final callsign = c['callsign'] as String;
    final files = (c['files'] as List).cast<String>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4),
            child: Text(
              _i18n.t('contributed_by').replaceAll('{0}', callsign),
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          SizedBox(
            height: 120,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: files.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => InkWell(
                onTap: () => _openLightbox(
                  files
                      .map((name) => 'contributors/$callsign/$name')
                      .toList(),
                  i,
                ),
                borderRadius: BorderRadius.circular(12),
                child: RemoteContentImage(
                  remoteCallsign: widget.device.callsign,
                  appType: 'events',
                  itemId: widget.eventId,
                  relativePath: 'contributors/$callsign/${files[i]}',
                  width: 160,
                  height: 120,
                  fit: BoxFit.cover,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Visitor-side upload button. Opens the file picker, then submits
  /// each file via [RemoteContributorActions.submitFile]. Progress +
  /// per-file failures are surfaced as SnackBars; on the first
  /// success we refresh the event detail so anything that landed in
  /// approved (because the contributor is already approved) shows
  /// up immediately.
  Widget _buildContributeButton(ThemeData theme) {
    // Vertical layout — title + help text get the full width on
    // narrow screens (mobile, USB-AOA tethered Android) and the
    // upload button sits underneath instead of squeezing the text.
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.primaryContainer.withOpacity(0.4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.add_a_photo_outlined,
                    color: theme.colorScheme.onPrimaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _i18n.t('contribute_media'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _i18n.t('contribute_media_help'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _isUploading ? null : _pickAndSubmitContributions,
              icon: _isUploading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child:
                          CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload),
              label: Text(_i18n.t('contribute_media')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndSubmitContributions() async {
    final paths = await FileFolderPicker.show(
      context,
      title: _i18n.t('contribute_media'),
      allowMultiSelect: true,
      allowedExtensions: {
        ...FileFolderPicker.imageExtensions,
        ...FileFolderPicker.videoExtensions,
      },
      profileStorage: AppService().profileStorage,
      initialGridView: true,
      initialDirectory: FileFolderPicker.defaultMediaDirectory(),
    );
    if (paths == null || paths.isEmpty) return;
    setState(() => _isUploading = true);
    int succeeded = 0;
    final failures = <String>[];
    try {
      for (final filePath in paths) {
        final filename = path.basename(filePath);
        final file = File(filePath);
        if (!await file.exists()) {
          failures.add(filename);
          continue;
        }
        if (!mounted) break;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 1),
            content: Text(
              _i18n.t('contributor_uploading').replaceAll('{0}', filename),
            ),
          ),
        );
        final bytes = await file.readAsBytes();
        final result = await RemoteContributorActions.submitFile(
          remoteCallsign: widget.device.callsign,
          eventId: widget.eventId,
          filename: filename,
          bytes: bytes,
        );
        if (result.success) {
          succeeded++;
        } else {
          failures.add('$filename (${result.error ?? 'failed'})');
        }
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
    if (!mounted) return;
    if (succeeded > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _i18n
                .t('contributor_upload_done')
                .replaceAll('{0}', '$succeeded'),
          ),
        ),
      );
      // Refresh in case any landed in approved (already-trusted contributor).
      await _load();
    }
    for (final f in failures) {
      if (!mounted) break;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Theme.of(context).colorScheme.error,
          content: Text(
            _i18n.t('contributor_upload_failed').replaceAll('{0}', f),
          ),
        ),
      );
    }
  }

  Widget _buildAccessRequestCard(ThemeData theme, String visibility) =>
      Card(
        color: theme.colorScheme.tertiaryContainer.withOpacity(0.3),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.lock_open_outlined,
                  color: theme.colorScheme.tertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Private event — the author must grant access to view details.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _buildEngagementRow(
      ThemeData theme, int views, int likes, int comments) {
    return Row(
      children: [
        _iconCount(theme, Icons.visibility, views, 'views'),
        const SizedBox(width: 16),
        InkWell(
          onTap: _posting ? null : _toggleLike,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 6, vertical: 4),
            child: _iconCount(theme, Icons.thumb_up, likes, 'likes'),
          ),
        ),
        const SizedBox(width: 16),
        _iconCount(theme, Icons.chat_bubble, comments, 'comments'),
      ],
    );
  }

  Widget _iconCount(
      ThemeData theme, IconData icon, int count, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          '$count $label',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildCommentCompose(ThemeData theme) {
    final profile = _profileService.getProfile();
    final hasKeys = profile.npub.isNotEmpty && profile.nsec.isNotEmpty;
    if (!hasKeys) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'NOSTR key required to comment',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _commentController,
            enabled: !_posting,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: _i18n.t('write_a_comment') ?? 'Write a comment…',
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
            ),
            onSubmitted: (_) => _postComment(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: _posting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send),
          onPressed: _posting ? null : _postComment,
          tooltip: _i18n.t('post_comment') ?? 'Post comment',
        ),
      ],
    );
  }

  Widget _buildCommentCard(ThemeData theme, Map<String, dynamic> c) {
    final author = (c['author'] as String?) ?? 'unknown';
    final timestamp = (c['timestamp'] as String?) ?? '';
    final content = (c['content'] as String?) ?? '';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.person,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(author,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  )),
              const SizedBox(width: 12),
              if (timestamp.isNotEmpty) ...[
                Icon(Icons.schedule,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(timestamp,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
              ],
            ]),
            const SizedBox(height: 8),
            Text(content, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  // Silence the linter about the unused StationService import on
  // platforms where the remote device already has a URL — the
  // constant reference keeps the import reachable without hard-coding
  // a dependency loop.
  // ignore: unused_element
  static final _stationService = StationService();
}

// ─────────────── lightbox ───────────────

class _LightboxPage extends StatefulWidget {
  final String remoteCallsign;
  final String itemId;
  final List<String> photos;
  final int startIndex;

  const _LightboxPage({
    required this.remoteCallsign,
    required this.itemId,
    required this.photos,
    required this.startIndex,
  });

  @override
  State<_LightboxPage> createState() => _LightboxPageState();
}

class _LightboxPageState extends State<_LightboxPage> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex;
    _controller = PageController(initialPage: _index);
    _prefetchAround(_index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Warm the cache with ±1 neighbours (and +2 when swiping forward)
  /// so the user doesn't stare at a spinner every time they flip.
  void _prefetchAround(int current) {
    final n = widget.photos.length;
    if (n < 2) return;
    for (final offset in const [1, -1, 2]) {
      final i = (current + offset + n) % n;
      RemoteContentImage.prefetch(
        remoteCallsign: widget.remoteCallsign,
        appType: 'events',
        itemId: widget.itemId,
        relativePath: widget.photos[i],
        thumbnail: false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          children: [
            // Full-resolution viewer with swipe navigation.
            PageView.builder(
              controller: _controller,
              itemCount: widget.photos.length,
              onPageChanged: (i) {
                setState(() => _index = i);
                _prefetchAround(i);
              },
              itemBuilder: (_, i) => Center(
                child: InteractiveViewer(
                  maxScale: 4,
                  child: RemoteContentImage(
                    remoteCallsign: widget.remoteCallsign,
                    appType: 'events',
                    itemId: widget.itemId,
                    relativePath: widget.photos[i],
                    thumbnail: false,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            // Counter + close button overlay.
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  if (widget.photos.length > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${_index + 1} / ${widget.photos.length}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
