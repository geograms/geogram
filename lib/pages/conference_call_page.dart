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
  List<String> _lanWsUrls = [];
  List<String> _lanWebUrls = [];

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
      final wsUrls = await _conferenceService.getLanWsUrls();
      final webUrls = await _conferenceService.getLanUrls();
      if (mounted) {
        setState(() {
          _lanWsUrls = wsUrls;
          _lanWebUrls = webUrls;
        });
      }
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

  void _copyRoomId() {
    final roomId = _conferenceService.room?.roomId;
    if (roomId == null) return;
    Clipboard.setData(ClipboardData(text: roomId));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Room ID copied')),
    );
  }

  void _showShareSheet() {
    final room = _conferenceService.room;
    if (room == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Share Conference',
              style: Theme.of(ctx).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),

            // Room ID — always shown, prominently
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(
                    'Room ID',
                    style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                      color: Theme.of(ctx).colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    room.roomId,
                    style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      color: Theme.of(ctx).colorScheme.onPrimaryContainer,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // QR code — encodes the room ID
            SizedBox(
              width: 180,
              height: 180,
              child: QrImageView(
                data: room.roomId,
                version: QrVersions.auto,
                size: 180,
              ),
            ),
            const SizedBox(height: 16),

            // Copy Room ID button
            FilledButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: room.roomId));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Room ID copied')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy Room ID'),
            ),

            // LAN WebSocket URL for direct join (secondary info)
            if (_lanWsUrls.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                'Direct LAN join',
                style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              for (final wsUrl in _lanWsUrls)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: wsUrl));
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Copied: $wsUrl')),
                      );
                    },
                    child: Row(
                      children: [
                        Icon(Icons.wifi, size: 14,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            wsUrl,
                            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Icon(Icons.copy, size: 14,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
            ],

            // Web browser URL (tertiary info)
            if (_lanWebUrls.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Browser join',
                style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _lanWebUrls.first));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Copied: ${_lanWebUrls.first}')),
                  );
                },
                child: Row(
                  children: [
                    Icon(Icons.language, size: 14,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _lanWebUrls.first,
                        style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Icon(Icons.copy, size: 14,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
            ],

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
              tooltip: 'Share conference',
            ),
        ],
      ),
      body: Column(
        children: [
          // Room info bar — shows room ID (tappable to copy), mode, participants
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
                const SizedBox(width: 6),
                Text(
                  room?.signalingMode == ConferenceSignalingMode.lan
                      ? 'LAN'
                      : 'Station',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                // Room ID — tappable to copy
                if (room != null)
                  InkWell(
                    onTap: _copyRoomId,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            room.roomId,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onPrimaryContainer,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.copy, size: 12,
                              color: theme.colorScheme.onPrimaryContainer),
                        ],
                      ),
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
                        isMe: p.callsign ==
                            ProfileService().getProfile().callsign,
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
                color: isMuted
                    ? theme.colorScheme.error
                    : theme.colorScheme.surfaceContainerHighest,
                iconColor:
                    isMuted ? Colors.white : theme.colorScheme.onSurface,
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
