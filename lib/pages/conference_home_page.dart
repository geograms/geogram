/// Conference Home Page — landing page for the standalone conference app.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../util/managed_http_client.dart';
import '../models/conference_archive_entry.dart';
import '../models/conference_schedule_entry.dart';
import '../services/conference_archive_service.dart';
import '../services/conference_schedule_service.dart';
import '../services/conference_service.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/profile_service.dart';
import '../util/app_type_theme.dart';
import 'conference_archive_detail_page.dart';
import 'conference_host_page.dart';
import 'conference_join_page.dart';
import 'conference_call_page.dart';

class ConferenceHomePage extends StatefulWidget {
  const ConferenceHomePage({super.key});

  @override
  State<ConferenceHomePage> createState() => _ConferenceHomePageState();
}

class _ConferenceHomePageState extends State<ConferenceHomePage> {
  final _archiveService = ConferenceArchiveService();
  final _scheduleService = ConferenceScheduleService();
  final _conferenceService = ConferenceService();
  final _i18n = I18nService();
  StreamSubscription? _stateSub;
  ConferenceState _state = ConferenceState.idle;

  // Nearby meetings discovery
  List<Map<String, dynamic>> _nearbyMeetings = [];
  bool _scanning = false;
  Timer? _scanTimer;
  final ManagedHttpClient _scanClient = ManagedHttpClient();
  List<ConferenceArchiveEntry> _historyEntries =
      const <ConferenceArchiveEntry>[];
  List<ConferenceScheduleEntry> _scheduledEntries =
      const <ConferenceScheduleEntry>[];
  bool _scheduleLoading = true;
  String? _scheduleError;
  bool _historyLoading = true;
  String? _historyError;
  List<String> _allTags = const <String>[];
  String? _selectedTag;

  @override
  void initState() {
    super.initState();
    _state = _conferenceService.state;
    _stateSub = _conferenceService.stateStream.listen((s) {
      if (!mounted) {
        return;
      }
      setState(() => _state = s);
      if (s == ConferenceState.idle) {
        unawaited(_loadSchedules());
        unawaited(_loadHistory());
      }
    });
    _scanForMeetings();
    _loadSchedules();
    _loadHistory();
    _scanTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _scanForMeetings(),
    );
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _scanTimer?.cancel();
    _scanClient.close();
    super.dispose();
  }

  Future<void> _scanForMeetings() async {
    if (_scanning) return;

    setState(() => _scanning = true);

    final devices = DevicesService().getAllDevices();
    final ownCallsign = ProfileService().getProfile().callsign.toUpperCase();
    final results = <Map<String, dynamic>>[];

    // Filter to devices with HTTP(S) URLs (skip wss:// station-only devices)
    final candidates = devices
        .where(
          (d) =>
              d.url != null &&
              d.url!.startsWith('http') &&
              d.callsign.toUpperCase() != ownCallsign,
        )
        .toList();

    debugPrint(
      'MEET_SCAN: ${devices.length} total devices, '
      '${candidates.length} candidates (own=$ownCallsign)',
    );
    for (final d in candidates) {
      debugPrint('MEET_SCAN:   ${d.callsign} url=${d.url}');
    }

    await Future.wait(
      candidates.map((d) async {
        try {
          final url = '${d.url}/api/meet/active';
          debugPrint('MEET_SCAN: Checking $url');
          final resp = await _scanClient
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 3));
          debugPrint('MEET_SCAN:   ${d.callsign} -> ${resp.statusCode}');
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body) as Map<String, dynamic>;
            data['device_nickname'] = d.nickname ?? d.name;
            data['device_url'] = d.url;
            results.add(data);
          }
        } catch (e) {
          debugPrint('MEET_SCAN:   ${d.callsign} -> ERROR: $e');
        }
      }),
    );

    if (mounted) {
      setState(() {
        _nearbyMeetings = results;
        _scanning = false;
      });
    }
  }

  Future<void> _loadHistory() async {
    if (mounted) {
      setState(() {
        _historyLoading = true;
        _historyError = null;
      });
    }
    try {
      final entries = await _archiveService.listArchives();
      final tags = <String>{};
      for (final entry in entries) {
        tags.addAll(entry.tags);
      }
      final sortedTags = tags.toList()..sort();
      if (!mounted) {
        return;
      }
      setState(() {
        _historyEntries = entries;
        _allTags = sortedTags;
        _historyLoading = false;
        _historyError = null;
        // Clear filter if selected tag no longer exists
        if (_selectedTag != null && !tags.contains(_selectedTag)) {
          _selectedTag = null;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _historyLoading = false;
        _historyError = '$error';
      });
    }
  }

  Future<void> _loadSchedules() async {
    if (mounted) {
      setState(() {
        _scheduleLoading = true;
        _scheduleError = null;
      });
    }
    try {
      final entries = await _scheduleService.listSchedules(
        includeCompleted: false,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _scheduledEntries = entries;
        _scheduleLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _scheduleLoading = false;
        _scheduleError = '$error';
      });
    }
  }

  void _joinNearbyMeeting(Map<String, dynamic> meeting) async {
    final roomId = meeting['room_id'] as String?;
    if (roomId == null) return;

    try {
      await _conferenceService.discoverAndJoin(roomId);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ConferenceCallPage()),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to join: $e')));
    }
  }

  Future<void> _openArchive(ConferenceArchiveEntry entry) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ConferenceArchiveDetailPage(entry: entry),
      ),
    );
    if (!mounted) {
      return;
    }
    await _loadHistory();
  }

  Future<void> _deleteArchive(ConferenceArchiveEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete meeting?'),
        content: Text(
          'This will permanently delete the archive for "${entry.roomName}", '
          'including chat history, files, and recordings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _archiveService.deleteArchive(entry);
      if (!mounted) return;
      await _loadHistory();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
    }
  }

  Future<void> _editTags(ConferenceArchiveEntry entry) async {
    final controller = TextEditingController();
    final currentTags = List<String>.from(entry.tags);
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
                        final tag =
                            controller.text.trim().toLowerCase();
                        if (tag.isNotEmpty && !currentTags.contains(tag)) {
                          setDialogState(() => currentTags.add(tag));
                          controller.clear();
                        }
                      },
                    ),
                  ],
                ),
                if (_allTags.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Existing tags:',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _allTags
                        .where((tag) => !currentTags.contains(tag))
                        .map(
                          (tag) => ActionChip(
                            label: Text(tag),
                            onPressed: () => setDialogState(
                              () => currentTags.add(tag),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
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
      await _archiveService.updateTags(entry, result);
      if (!mounted) return;
      await _loadHistory();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to update tags: $e')));
    }
  }

  Future<void> _startScheduledMeeting(ConferenceScheduleEntry entry) async {
    try {
      await _conferenceService.startScheduledConference(entry.roomId);
      if (!mounted) return;
      await _loadSchedules();
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ConferenceCallPage()),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to start: $e')));
    }
  }

  Future<void> _copyScheduleLink(ConferenceScheduleEntry entry) async {
    final url = entry.stationMeetUrl;
    if (url == null || url.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No station link available yet')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  String _formatScheduleDate(DateTime value) {
    final local = value.toLocal();
    final day =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    final time =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    return '$day $time';
  }

  String _formatHistoryDate(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(local.year, local.month, local.day);
    final diff = today.difference(date).inDays;

    String dayLabel;
    if (diff == 0) {
      dayLabel = 'Today';
    } else if (diff == 1) {
      dayLabel = 'Yesterday';
    } else {
      dayLabel =
          '${local.year.toString().padLeft(4, '0')}-'
          '${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}';
    }
    final time =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    return '$dayLabel $time';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_i18n.t('app_type_conference')),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.mic), text: 'Meetings'),
              Tab(icon: Icon(Icons.history), text: 'History'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: _buildMeetingsTab(theme),
              ),
            ),
            _buildHistoryTab(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildMeetingsTab(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final gradient = getAppTypeGradient('conference', isDark);

    return RefreshIndicator(
      onRefresh: () async {
        await _scanForMeetings();
        await _loadSchedules();
      },
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // Icon
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              gradient: gradient,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mic, size: 40, color: Colors.white),
          ),
          const SizedBox(height: 32),

          // Host button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ConferenceHostPage(),
                ),
              ).then((_) => _loadSchedules()),
              icon: const Icon(Icons.add_call),
              label: const Text(
                'Host a Meeting',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Join button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ConferenceJoinPage(),
                ),
              ),
              icon: const Icon(Icons.call),
              label: const Text(
                'Join a Meeting',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

          if (_state == ConferenceState.active) ...[
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ConferenceCallPage(),
                  ),
                ),
                icon: const Icon(Icons.call),
                label: const Text(
                  'Return to Call',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],

          // Scheduled meetings section
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.event,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                'Scheduled Meetings',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (_scheduleLoading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  padding: EdgeInsets.zero,
                  onPressed: _loadSchedules,
                  tooltip: 'Refresh schedules',
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_scheduleError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _scheduleError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            )
          else if (!_scheduleLoading && _scheduledEntries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No scheduled meetings yet',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ..._scheduledEntries.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              entry.isActive
                                  ? Icons.podcasts
                                  : Icons.schedule,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.roomName,
                                    style: theme.textTheme.bodyLarge
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    entry.scheduledAt == null
                                        ? 'Start when host decides'
                                        : 'Scheduled for ${_formatScheduleDate(entry.scheduledAt!)}',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                  ),
                                  if (entry.stationMeetUrl != null &&
                                      entry.stationMeetUrl!.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      entry.stationMeetUrl!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: entry.stationMeetUrl == null ||
                                      entry.stationMeetUrl!.isEmpty
                                  ? null
                                  : () => _copyScheduleLink(entry),
                              icon: const Icon(Icons.link),
                              label: const Text('Copy link'),
                            ),
                            FilledButton.icon(
                              onPressed: entry.isActive
                                  ? (_conferenceService.state ==
                                              ConferenceState.active &&
                                          _conferenceService.room?.roomId ==
                                              entry.roomId
                                      ? () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  const ConferenceCallPage(),
                                            ),
                                          )
                                      : null)
                                  : () => _startScheduledMeeting(entry),
                              icon: Icon(
                                entry.isActive
                                    ? Icons.call
                                    : Icons.play_arrow,
                              ),
                              label: Text(
                                entry.isActive
                                    ? 'Open active meeting'
                                    : 'Start now',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Nearby meetings section
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.wifi,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                'Nearby Meetings',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: 32,
                height: 32,
                child: _scanning
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        icon: const Icon(Icons.refresh, size: 18),
                        padding: EdgeInsets.zero,
                        onPressed: _scanForMeetings,
                        tooltip: 'Refresh',
                      ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_nearbyMeetings.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No meetings found nearby',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ...(_nearbyMeetings.map(
              (m) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _joinNearbyMeeting(m),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(
                            Icons.mic,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(
                                  m['room_name'] as String? ?? 'Meeting',
                                  style: theme.textTheme.bodyLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${m['host_callsign'] ?? ''}'
                                  ' (${m['device_nickname'] ?? ''})',
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(
                                        color: theme
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.mic,
                                    size: 12,
                                    color: theme
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    '${m['speaker_count'] ?? 0}'
                                    '/${m['max_speakers'] ?? 6}',
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.people,
                                    size: 12,
                                    color: theme
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    '${m['participant_count'] ?? 0}',
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.arrow_forward_ios,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            )),
        ],
      ),
    );
  }

  Widget _buildHistoryTab(ThemeData theme) {
    if (_historyLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_historyError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _historyError!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      );
    }
    if (_historyEntries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No archived meetings yet',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    final filtered = _selectedTag == null
        ? _historyEntries
        : _historyEntries
              .where((e) => e.tags.contains(_selectedTag))
              .toList();

    return Row(
      children: [
        // Tag sidebar
        if (_allTags.isNotEmpty)
          SizedBox(
            width: 120,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(
                    color: theme.dividerColor,
                    width: 0.5,
                  ),
                ),
              ),
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(
                      left: 8,
                      bottom: 8,
                    ),
                    child: Text(
                      'Tags',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _TagChip(
                    label: 'All',
                    selected: _selectedTag == null,
                    onTap: () => setState(() => _selectedTag = null),
                    theme: theme,
                  ),
                  ..._allTags.map(
                    (tag) => _TagChip(
                      label: tag,
                      selected: _selectedTag == tag,
                      onTap: () => setState(
                        () => _selectedTag =
                            _selectedTag == tag ? null : tag,
                      ),
                      theme: theme,
                    ),
                  ),
                ],
              ),
            ),
          ),
        // Meeting list
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadHistory,
            child: filtered.isEmpty
                ? ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Center(
                          child: Text(
                            'No meetings with tag "$_selectedTag"',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final entry = filtered[index];
                      return _buildHistoryCard(theme, entry);
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildHistoryCard(ThemeData theme, ConferenceArchiveEntry entry) {
    final roleLabel = entry.hostedByMe ? 'Host' : 'Participant';
    final roleColor = entry.hostedByMe
        ? theme.colorScheme.primary
        : theme.colorScheme.tertiary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openArchive(entry),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  entry.hostedByMe ? Icons.podcasts : Icons.headphones,
                  color: roleColor,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              entry.roomName,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: roleColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              roleLabel,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: roleColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.hostedByMe
                            ? 'Hosted by you'
                            : 'Hosted by ${entry.hostCallsign}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            _formatHistoryDate(entry.updatedAt),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 12),
                          if (entry.messageCount > 0) ...[
                            Icon(
                              Icons.chat_bubble_outline,
                              size: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${entry.messageCount}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          if (entry.fileCount > 0) ...[
                            Icon(
                              Icons.attach_file,
                              size: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${entry.fileCount}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          if (entry.recordingCount > 0) ...[
                            Icon(
                              Icons.videocam_outlined,
                              size: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${entry.recordingCount}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (entry.tags.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: entry.tags
                              .map(
                                (tag) => Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    tag,
                                    style:
                                        theme.textTheme.labelSmall?.copyWith(
                                      color: theme
                                          .colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.label_outline,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      tooltip: 'Edit tags',
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: () => _editTags(entry),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      tooltip: 'Delete archive',
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: () => _deleteArchive(entry),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final ThemeData theme;

  const _TagChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected
            ? theme.colorScheme.primaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 6,
            ),
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: selected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}
