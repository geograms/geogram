/// Conference Home Page — landing page for the standalone conference app.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/conference_service.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/profile_service.dart';
import '../util/app_type_theme.dart';
import 'conference_host_page.dart';
import 'conference_join_page.dart';
import 'conference_call_page.dart';

class ConferenceHomePage extends StatefulWidget {
  const ConferenceHomePage({super.key});

  @override
  State<ConferenceHomePage> createState() => _ConferenceHomePageState();
}

class _ConferenceHomePageState extends State<ConferenceHomePage> {
  final _conferenceService = ConferenceService();
  final _i18n = I18nService();
  StreamSubscription? _stateSub;
  ConferenceState _state = ConferenceState.idle;

  // Nearby meetings discovery
  List<Map<String, dynamic>> _nearbyMeetings = [];
  bool _scanning = false;
  Timer? _scanTimer;

  @override
  void initState() {
    super.initState();
    _state = _conferenceService.state;
    _stateSub = _conferenceService.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _scanForMeetings();
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

    await Future.wait(devices
        .where((d) =>
            d.isOnline &&
            d.url != null &&
            d.callsign.toUpperCase() != ownCallsign)
        .map((d) async {
      try {
        final resp = await http
            .get(Uri.parse('${d.url}/api/meet/active'))
            .timeout(const Duration(seconds: 3));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          data['device_nickname'] = d.nickname ?? d.name;
          data['device_url'] = d.url;
          results.add(data);
        }
      } catch (_) {}
    }));

    if (mounted) {
      setState(() {
        _nearbyMeetings = results;
        _scanning = false;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to join: $e')),
      );
    }
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
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Icon
                Container(
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
                    ),
                    icon: const Icon(Icons.add_call),
                    label: const Text(
                      'Host a Meeting',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
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
                    Icon(Icons.wifi, size: 18,
                        color: theme.colorScheme.onSurfaceVariant),
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
                  ...(_nearbyMeetings.map((m) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => _joinNearbyMeeting(m),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  Icon(Icons.mic,
                                      color: theme.colorScheme.primary),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          m['room_name'] as String? ??
                                              'Meeting',
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
                                                .colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    '${m['participant_count'] ?? 0}'
                                    '/${m['max_participants'] ?? 6}',
                                    style:
                                        theme.textTheme.labelMedium?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(Icons.arrow_forward_ios,
                                      size: 14,
                                      color:
                                          theme.colorScheme.onSurfaceVariant),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ))),

                // Return to call button (shown when active)
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
                      icon: const Icon(Icons.call_end),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
