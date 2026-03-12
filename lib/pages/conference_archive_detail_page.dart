library;

import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../models/conference_archive_entry.dart';
import '../services/conference_archive_service.dart';
import '../services/file_launcher_service.dart';
import '../widgets/message_list_widget.dart';

class ConferenceArchiveDetailPage extends StatefulWidget {
  final ConferenceArchiveEntry entry;

  const ConferenceArchiveDetailPage({super.key, required this.entry});

  @override
  State<ConferenceArchiveDetailPage> createState() =>
      _ConferenceArchiveDetailPageState();
}

class _ConferenceArchiveDetailPageState
    extends State<ConferenceArchiveDetailPage> {
  final _archiveService = ConferenceArchiveService();
  final _fileLauncher = FileLauncherService();

  ConferenceArchiveEntry? _entry;
  List<ChatMessage> _messages = const <ChatMessage>[];
  bool _loading = true;
  bool _openingAsset = false;
  String? _error;

  ConferenceArchiveEntry get _currentEntry => _entry ?? widget.entry;

  @override
  void initState() {
    super.initState();
    _loadArchive();
  }

  Future<void> _loadArchive() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final refreshed = await _archiveService.refreshArchive(_currentEntry);
      final messages = await _archiveService.loadMessages(refreshed);
      if (!mounted) {
        return;
      }
      setState(() {
        _entry = refreshed;
        _messages = messages;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _openAsset(ConferenceArchiveAsset asset) async {
    if (_openingAsset) {
      return;
    }

    setState(() => _openingAsset = true);
    try {
      final path = await _archiveService.exportArchiveFileToTemporaryPath(
        _currentEntry,
        asset.relativePath,
      );
      if (!mounted) {
        return;
      }
      if (path == null) {
        throw StateError('Unable to export ${asset.name}');
      }
      final opened = await _fileLauncher.openFile(path);
      if (!mounted) {
        return;
      }
      if (!opened) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Unable to open ${asset.name}')));
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to open ${asset.name}: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _openingAsset = false);
      }
    }
  }

  Future<void> _editTags() async {
    final controller = TextEditingController();
    final currentTags = List<String>.from(_currentEntry.tags);
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit tags'),
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (currentTags.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: currentTags
                        .map(
                          (tag) => InputChip(
                            label: Text(tag),
                            onDeleted: () => setDialogState(
                              () => currentTags.remove(tag),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                if (currentTags.isNotEmpty) const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          hintText: 'Add a tag',
                          isDense: true,
                        ),
                        onSubmitted: (value) {
                          final tag = value.trim().toLowerCase();
                          if (tag.isNotEmpty && !currentTags.contains(tag)) {
                            setDialogState(() => currentTags.add(tag));
                            controller.clear();
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () {
                        final tag = controller.text.trim().toLowerCase();
                        if (tag.isNotEmpty && !currentTags.contains(tag)) {
                          setDialogState(() => currentTags.add(tag));
                          controller.clear();
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(currentTags),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      final updated = await _archiveService.updateTags(_currentEntry, result);
      if (!mounted) return;
      setState(() => _entry = updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to update tags: $e')));
    }
  }

  Widget _buildSummaryTab(ThemeData theme) {
    final entry = _currentEntry;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _InfoCard(
          title: 'Tags',
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ...entry.tags.map(
                  (tag) => Chip(
                    label: Text(tag),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                ActionChip(
                  avatar: const Icon(Icons.edit, size: 16),
                  label: Text(
                    entry.tags.isEmpty ? 'Add tags' : 'Edit',
                  ),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  onPressed: _editTags,
                ),
              ],
            ),
          ],
        ),
        _InfoCard(
          title: 'Meeting',
          children: [
            _InfoRow(label: 'Name', value: entry.roomName),
            _InfoRow(
              label: 'Role',
              value: entry.hostedByMe ? 'Hosted by you' : 'Participated',
            ),
            _InfoRow(
              label: 'Host',
              value: entry.hostCallsign.isEmpty
                  ? 'Unknown'
                  : entry.hostCallsign,
            ),
            _InfoRow(label: 'Started', value: _formatDateTime(entry.startedAt)),
            _InfoRow(
              label: 'Ended',
              value: entry.endedAt == null
                  ? 'In progress'
                  : _formatDateTime(entry.endedAt!),
            ),
            _InfoRow(label: 'Mode', value: entry.signalingMode.toUpperCase()),
          ],
        ),
        _InfoCard(
          title: 'Participants',
          children: [
            _InfoRow(
              label: 'Participants',
              value: entry.participants.isEmpty
                  ? 'None'
                  : entry.participants.join(', '),
            ),
            _InfoRow(
              label: 'Speakers',
              value: entry.speakers.isEmpty
                  ? 'None'
                  : entry.speakers.join(', '),
            ),
            _InfoRow(
              label: 'Screen Share',
              value: entry.activeScreenSharer ?? 'None',
            ),
          ],
        ),
        _InfoCard(
          title: 'Archive',
          children: [
            _InfoRow(label: 'Messages', value: '${entry.messageCount}'),
            _InfoRow(label: 'Files', value: '${entry.fileCount}'),
            _InfoRow(label: 'Recordings', value: '${entry.recordingCount}'),
            _InfoRow(label: 'Archive', value: entry.relativePath),
            if (entry.stationMeetUrl != null &&
                entry.stationMeetUrl!.isNotEmpty)
              _InfoRow(label: 'Meeting URL', value: entry.stationMeetUrl!),
            if (entry.meetUrls.isNotEmpty)
              _InfoRow(label: 'URLs', value: entry.meetUrls.join('\n')),
          ],
        ),
      ],
    );
  }

  Widget _buildChatTab(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.error,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return MessageListWidget(messages: _messages, isGroupChat: true);
  }

  Widget _buildAssetsTab(ThemeData theme) {
    final entry = _currentEntry;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _AssetSection(
          title: 'Recordings',
          icon: Icons.fiber_manual_record,
          assets: entry.recordings,
          emptyLabel: 'No recordings archived for this meeting',
          openingDisabled: _openingAsset,
          onOpenAsset: _openAsset,
        ),
        const SizedBox(height: 16),
        _AssetSection(
          title: 'Files',
          icon: Icons.attach_file,
          assets: entry.files,
          emptyLabel: 'No files archived for this meeting',
          openingDisabled: _openingAsset,
          onOpenAsset: _openAsset,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = _currentEntry;

    return Scaffold(
      appBar: AppBar(
        title: Text(entry.roomName),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh archive',
            onPressed: _loadArchive,
          ),
        ],
      ),
      body: DefaultTabController(
        length: 3,
        child: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: 'Summary'),
                Tab(text: 'Chat'),
                Tab(text: 'Archive'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _buildSummaryTab(theme),
                  _buildChatTab(theme),
                  _buildAssetsTab(theme),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssetSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<ConferenceArchiveAsset> assets;
  final String emptyLabel;
  final bool openingDisabled;
  final Future<void> Function(ConferenceArchiveAsset asset) onOpenAsset;

  const _AssetSection({
    required this.title,
    required this.icon,
    required this.assets,
    required this.emptyLabel,
    required this.openingDisabled,
    required this.onOpenAsset,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (assets.isEmpty)
              Text(
                emptyLabel,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              ...assets.map(
                (asset) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.insert_drive_file,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(asset.name),
                  subtitle: Text(_formatAssetSubtitle(asset)),
                  trailing: IconButton(
                    icon: const Icon(Icons.open_in_new),
                    tooltip: 'Open file',
                    onPressed: openingDisabled
                        ? null
                        : () => onOpenAsset(asset),
                  ),
                  onTap: openingDisabled ? null : () => onOpenAsset(asset),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _InfoCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

String _formatAssetSubtitle(ConferenceArchiveAsset asset) {
  final parts = <String>[];
  if (asset.size != null) {
    parts.add(_formatFileSize(asset.size!));
  }
  if (asset.modifiedAt != null) {
    parts.add(_formatDateTime(asset.modifiedAt!));
  }
  return parts.isEmpty ? asset.relativePath : parts.join(' • ');
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  final year = local.year.toString().padLeft(4, '0');
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute';
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
