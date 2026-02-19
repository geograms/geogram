/// Conference Join Page — join an audio conference via link, room ID, or QR scan.
library;

import 'dart:async';

import 'package:flutter/material.dart';

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
        // Direct WebSocket URL (LAN mode)
        await _conferenceService.joinLan(input);
      } else if (input.contains('://')) {
        // HTTP(S) URL — parse meet URL format
        final uri = Uri.parse(input);
        final segments = uri.pathSegments;

        if (segments.length == 2 && segments[0] == 'meet') {
          // LAN: http://ip:port/meet/XXXX → derive WS URL
          final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
          final wsUrl = '$wsScheme://${uri.host}:${uri.port}/conference/ws';
          await _conferenceService.joinLan(wsUrl);
        } else if (segments.length == 3 && segments[1] == 'meet') {
          // Station: http://station/CALLSIGN/meet/XXXX
          final callsign = segments[0];
          final code = segments[2];
          final roomId = '$code@$callsign';
          await _conferenceService.discoverAndJoin(roomId);
        } else {
          // Legacy: http://ip:port/conference/web → derive WS URL
          final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
          final wsUrl = '$wsScheme://${uri.host}:${uri.port}/conference/ws';
          await _conferenceService.joinLan(wsUrl);
        }
      } else if (input.contains('@')) {
        // Room ID with @callsign — use discovery
        await _conferenceService.discoverAndJoin(input);
      } else {
        // Assume room ID — join via station
        await _conferenceService.joinStation(input);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Join Conference'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.group, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Join an audio conference',
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Enter a conference link or room ID.',
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
