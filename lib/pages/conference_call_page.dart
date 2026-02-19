/// Conference Call Page — active call UI shared by host and joiner.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/conference_service.dart';
import '../services/profile_service.dart';

class ConferenceCallPage extends StatefulWidget {
  const ConferenceCallPage({super.key});

  @override
  State<ConferenceCallPage> createState() => _ConferenceCallPageState();
}

class _ConferenceCallPageState extends State<ConferenceCallPage> {
  final _conferenceService = ConferenceService();
  StreamSubscription? _stateSubscription;
  StreamSubscription? _eventSubscription;
  List<String> _lanUrls = [];

  @override
  void initState() {
    super.initState();

    _stateSubscription = _conferenceService.stateStream.listen((state) {
      if (!mounted) return;
      if (state == ConferenceState.idle) {
        Navigator.pop(context);
        return;
      }
      setState(() {});
    });

    _eventSubscription = _conferenceService.events.listen((_) {
      if (mounted) setState(() {});
    });

    _loadLanUrls();
  }

  Future<void> _loadLanUrls() async {
    if (_conferenceService.role == ConferenceRole.host &&
        _conferenceService.room?.signalingMode == ConferenceSignalingMode.lan) {
      _lanUrls = await _conferenceService.getLanUrls();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _eventSubscription?.cancel();
    super.dispose();
  }

  Future<void> _endCall() async {
    await _conferenceService.endConference();
    if (mounted) Navigator.pop(context);
  }

  void _toggleMute() {
    _conferenceService.toggleMute();
    setState(() {});
  }

  void _showShareSheet() {
    final room = _conferenceService.room;
    if (room == null) return;

    final shareUrl = _lanUrls.isNotEmpty ? _lanUrls.first : room.roomId;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Share Conference',
              style: Theme.of(ctx).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            if (_lanUrls.isNotEmpty) ...[
              SizedBox(
                width: 200,
                height: 200,
                child: QrImageView(
                  data: _lanUrls.first,
                  version: QrVersions.auto,
                  size: 200,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _lanUrls.first,
                style: Theme.of(ctx).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ] else ...[
              Text(
                'Room ID: ${room.roomId}',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: shareUrl));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Link copied')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy Link'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final room = _conferenceService.room;
    final isHost = _conferenceService.role == ConferenceRole.host;
    final isMuted = _conferenceService.isLocalMuted;
    final participants = room?.participants.values.toList() ?? [];

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(room?.roomName ?? 'Conference'),
        automaticallyImplyLeading: false,
        actions: [
          if (isHost)
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: _showShareSheet,
              tooltip: 'Share link',
            ),
        ],
      ),
      body: Column(
        children: [
          // Room info
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(
                  room?.signalingMode == ConferenceSignalingMode.lan
                      ? Icons.wifi
                      : Icons.cloud,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  room?.signalingMode == ConferenceSignalingMode.lan
                      ? 'LAN mode'
                      : 'Station mode',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  '${participants.length} participant${participants.length != 1 ? 's' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Participant list
          Expanded(
            child: participants.isEmpty
                ? Center(
                    child: Text(
                      'Waiting for participants...',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: participants.length,
                    itemBuilder: (context, index) {
                      final p = participants[index];
                      return _ParticipantTile(
                        callsign: p.callsign,
                        isConnected: p.isConnected,
                        isMuted: p.isMuted,
                        isHost: p.callsign == room?.hostCallsign,
                        isMe: p.callsign == ProfileService().getProfile().callsign,
                      );
                    },
                  ),
          ),
        ],
      ),

      // Bottom controls
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Mute button
              _CallButton(
                icon: isMuted ? Icons.mic_off : Icons.mic,
                label: isMuted ? 'Unmute' : 'Mute',
                color: isMuted ? theme.colorScheme.error : theme.colorScheme.surfaceContainerHighest,
                iconColor: isMuted ? Colors.white : theme.colorScheme.onSurface,
                onPressed: _toggleMute,
              ),

              // End call
              _CallButton(
                icon: Icons.call_end,
                label: isHost ? 'End' : 'Leave',
                color: theme.colorScheme.error,
                iconColor: Colors.white,
                onPressed: _endCall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  final String callsign;
  final bool isConnected;
  final bool isMuted;
  final bool isHost;
  final bool isMe;

  const _ParticipantTile({
    required this.callsign,
    required this.isConnected,
    required this.isMuted,
    required this.isHost,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isConnected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          child: Icon(
            isConnected ? Icons.person : Icons.person_outline,
            color: isConnected
                ? theme.colorScheme.onPrimaryContainer
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        title: Text(
          callsign + (isMe ? ' (You)' : '') + (isHost ? ' (Host)' : ''),
          style: theme.textTheme.bodyLarge,
        ),
        subtitle: Text(
          isConnected ? 'Connected' : 'Connecting...',
          style: TextStyle(
            color: isConnected ? Colors.green : Colors.orange,
            fontSize: 12,
          ),
        ),
        trailing: isMuted
            ? Icon(Icons.mic_off, color: theme.colorScheme.error, size: 20)
            : null,
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color iconColor;
  final VoidCallback onPressed;

  const _CallButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.iconColor,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          heroTag: label,
          onPressed: onPressed,
          backgroundColor: color,
          child: Icon(icon, color: iconColor),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
