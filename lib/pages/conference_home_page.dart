/// Conference Home Page — landing page for the standalone conference app.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

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
  List<ConferenceArchiveEntry> _historyEntries =
      const <ConferenceArchiveEntry>[];
  List<ConferenceScheduleEntry> _scheduledEntries =
      const <ConferenceScheduleEntry>[];
  bool _scheduleLoading = true;
  String? _scheduleError;
  bool _historyLoading = true;
  String? _historyError;

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
          final resp = await http
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
      if (!mounted) {
        return;
      }
      setState(() {
        _historyEntries = entries;
        _historyLoading = false;
        _historyError = null;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final gradient = getAppTypeGradient('conference', isDark);

    return Scaffold(
      appBar: AppBar(title: Text(_i18n.t('app_type_conference'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: RefreshIndicator(
            onRefresh: () async {
              await _scanForMeetings();
              await _loadSchedules();
              await _loadHistory();
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
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.history,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Recent Meetings',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    if (_historyLoading)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 18),
                        padding: EdgeInsets.zero,
                        onPressed: _loadHistory,
                        tooltip: 'Refresh history',
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_historyError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _historyError!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  )
                else if (!_historyLoading && _historyEntries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No archived meetings yet',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  ..._historyEntries.map(
                    (entry) => Padding(
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
                                  entry.hostedByMe
                                      ? Icons.podcasts
                                      : Icons.headphones,
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
                                        entry.hostedByMe
                                            ? 'Hosted by you'
                                            : 'Hosted by ${entry.hostCallsign}',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        entry.updatedAt.toLocal().toString(),
                                        style: theme.textTheme.labelSmall
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
                                    Text(
                                      '${entry.messageCount} chat',
                                      style: theme.textTheme.labelSmall,
                                    ),
                                    Text(
                                      '${entry.fileCount} files',
                                      style: theme.textTheme.labelSmall,
                                    ),
                                    Text(
                                      '${entry.recordingCount} rec',
                                      style: theme.textTheme.labelSmall,
                                    ),
                                  ],
                                ),
                                const SizedBox(width: 8),
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
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
