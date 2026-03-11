/// Conference Join Page — join an audio conference via link, room ID, or QR scan.
///
/// Defaults to listener role (no mic prompt). Option to join as speaker.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/conference_service.dart';
import 'conference_call_page.dart';

class ConferenceJoinPage extends StatefulWidget {
  /// Pre-filled link or room ID (e.g. from deep link or event).
  final String? initialLink;

  const ConferenceJoinPage({super.key, this.initialLink});

  @override
  State<ConferenceJoinPage> createState() => _ConferenceJoinPageState();
}

class _ConferenceJoinPageState extends State<ConferenceJoinPage> {
  late final TextEditingController _linkController;
  final _conferenceService = ConferenceService();
  bool _joining = false;
  String? _error;
  ConferenceParticipantRole _joinRole = ConferenceParticipantRole.listener;

  @override
  void initState() {
    super.initState();
    _linkController = TextEditingController(text: widget.initialLink ?? '');
  }

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final input = _linkController.text.trim();
    if (input.isEmpty) return;

    setState(() {
      _joining = true;
      _error = null;
    });

    try {
      if (input.startsWith('ws://') || input.startsWith('wss://')) {
        await _conferenceService.joinLan(input, participantRole: _joinRole);
      } else if (input.contains('://')) {
        final uri = Uri.parse(input);
        final segments = uri.pathSegments;

        if (segments.length >= 2 && segments[segments.length - 2] == 'meet') {
          await _joinFromMeetUrl(uri);
        } else {
          throw ArgumentError('Unrecognized URL format: $input');
        }
      } else if (input.contains('@')) {
        await _conferenceService.discoverAndJoin(input, participantRole: _joinRole);
      } else {
        await _conferenceService.joinStation(input, participantRole: _joinRole);
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ConferenceCallPage()),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e is StateError
          ? e.message
          : e.toString();
      setState(() {
        _joining = false;
        _error = msg;
      });
    }
  }

  Future<void> _joinFromMeetUrl(Uri meetUri) async {
    final activeUri = meetUri.resolve('active');
    try {
      final response = await http
          .get(activeUri)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final roomId = data['room_id'] as String?;
        final signalingMode = data['signaling_mode'] as String? ?? 'lan';
        final stationMeetUrl = data['station_meet_url'] as String?;
        int? signalingPort;
        final signalingPortValue = data['signaling_port'];
        if (signalingPortValue is int) {
          signalingPort = signalingPortValue;
        } else if (signalingPortValue is String) {
          signalingPort = int.tryParse(signalingPortValue);
        }

        if (signalingMode == ConferenceSignalingMode.station.name) {
          if (stationMeetUrl != null && stationMeetUrl.isNotEmpty) {
            await _conferenceService.joinStationMeetUrl(
              Uri.parse(stationMeetUrl),
              participantRole: _joinRole,
            );
            return;
          }
          if (roomId != null && roomId.isNotEmpty) {
            await _conferenceService.joinStation(
              roomId,
              participantRole: _joinRole,
            );
            return;
          }
        } else if (signalingPort != null) {
          final wsScheme = meetUri.scheme == 'https' ? 'wss' : 'ws';
          final wsUrl = Uri(
            scheme: wsScheme,
            host: meetUri.host,
            port: signalingPort,
            path: '/meet/ws',
          ).toString();
          await _conferenceService.joinLan(
            wsUrl,
            participantRole: _joinRole,
          );
          return;
        }
      }
    } catch (_) {}

    final wsScheme = meetUri.scheme == 'https' ? 'wss' : 'ws';
    final wsUrl = Uri(
      scheme: wsScheme,
      host: meetUri.host,
      port: meetUri.hasPort ? meetUri.port : null,
      path: '/meet/ws',
    ).toString();
    await _conferenceService.joinLan(wsUrl, participantRole: _joinRole);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Join Meeting'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.group, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Join an audio meeting',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Enter a meeting link or room ID.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _linkController,
              decoration: const InputDecoration(
                labelText: 'Link or Room ID',
                hintText: 'http://192.168.1.5:8080/meet/ABCD',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
              keyboardType: TextInputType.url,
              enabled: !_joining,
            ),
            const SizedBox(height: 16),
            // Role selection
            SegmentedButton<ConferenceParticipantRole>(
              segments: const [
                ButtonSegment(
                  value: ConferenceParticipantRole.listener,
                  label: Text('Listen'),
                  icon: Icon(Icons.headphones),
                ),
                ButtonSegment(
                  value: ConferenceParticipantRole.speaker,
                  label: Text('Speak'),
                  icon: Icon(Icons.mic),
                ),
              ],
              selected: {_joinRole},
              onSelectionChanged: _joining
                  ? null
                  : (s) => setState(() => _joinRole = s.first),
            ),
            const SizedBox(height: 4),
            Text(
              _joinRole == ConferenceParticipantRole.listener
                  ? 'No microphone needed'
                  : 'Microphone will be requested',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
            ],
            FilledButton.icon(
              onPressed: _joining ? null : _join,
              icon: _joining
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.call),
              label: Text(_joining ? 'Joining...' : 'Join'),
            ),
          ],
        ),
      ),
    );
  }
}
