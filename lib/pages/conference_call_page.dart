/// Conference Call Page — active call UI shared by host and joiner (SFU topology).
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
  List<String> _meetUrls = [];

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

    _loadMeetUrls();
  }

  Future<void> _loadMeetUrls() async {
    if (_conferenceService.role == ConferenceRole.host &&
        _conferenceService.room?.signalingMode == ConferenceSignalingMode.lan) {
      final urls = await _conferenceService.getMeetUrls();
      if (mounted) setState(() => _meetUrls = urls);
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

  String? get _shareUrl {
    if (_meetUrls.isNotEmpty) return _meetUrls.first;
    return _conferenceService.stationMeetUrl;
  }

  void _copyShareUrl() {
    final url = _shareUrl;
    if (url == null) return;
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link copied')),
    );
  }

  Future<void> _promoteParticipant(String callsign) async {
    try {
      await _conferenceService.promoteToSpeaker(callsign);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  Future<void> _demoteParticipant(String callsign) async {
    try {
      await _conferenceService.demoteToListener(callsign);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  void _showShareSheet() {
    final room = _conferenceService.room;
    if (room == null) return;

    final primaryUrl = _shareUrl;
    final stationUrl = _conferenceService.stationMeetUrl;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Share Meeting',
              style: Theme.of(ctx).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),

            if (primaryUrl != null) ...[
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
                      _meetUrls.isNotEmpty ? 'Join link' : 'Station link',
                      style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                        color: Theme.of(ctx).colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      primaryUrl,
                      style: Theme.of(ctx).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(ctx).colorScheme.onPrimaryContainer,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              SizedBox(
                width: 180,
                height: 180,
                child: QrImageView(
                  data: primaryUrl,
                  version: QrVersions.auto,
                  size: 180,
                ),
              ),
              const SizedBox(height: 16),

              FilledButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: primaryUrl));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link copied')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy Link'),
              ),
            ],

            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              'Room ID',
              style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: room.roomId));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Room ID copied')),
                );
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    room.roomId,
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontFamily: 'monospace',
                      letterSpacing: 1,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.copy, size: 14,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                ],
              ),
            ),

            if (_meetUrls.length > 1) ...[
              const SizedBox(height: 12),
              Text(
                'Other LAN addresses',
                style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              for (final url in _meetUrls.skip(1))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: url));
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Copied: $url')),
                      );
                    },
                    child: Row(
                      children: [
                        Icon(Icons.wifi, size: 14,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            url,
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

            if (_meetUrls.isNotEmpty && stationUrl != null) ...[
              const SizedBox(height: 12),
              Text(
                'Station link',
                style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: stationUrl));
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Copied: $stationUrl')),
                  );
                },
                child: Row(
                  children: [
                    Icon(Icons.cloud, size: 14,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        stationUrl,
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
    final shareUrl = _shareUrl;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(room?.roomName ?? 'Meeting'),
        automaticallyImplyLeading: false,
        actions: [
          if (isHost)
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: _showShareSheet,
              tooltip: 'Share meeting',
            ),
        ],
      ),
      body: Column(
        children: [
          // Room info bar
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
                if (room != null)
                  Expanded(
                    child: InkWell(
                      onTap: _copyShareUrl,
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
                            Flexible(
                              child: Text(
                                shareUrl ?? room.roomId,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.copy, size: 12,
                                color: theme.colorScheme.onPrimaryContainer),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                // Speaker/listener count
                Icon(Icons.mic, size: 14,
                    color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 2),
                Text(
                  '${room?.speakerCount ?? 0}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.headphones, size: 14,
                    color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 2),
                Text(
                  '${room?.listenerCount ?? 0}',
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
                        isSpeaker: p.isSpeaker,
                        isHost: p.callsign == room?.hostCallsign,
                        isMe: p.callsign ==
                            ProfileService().getProfile().callsign,
                        canManage: isHost &&
                            p.callsign != room?.hostCallsign &&
                            p.callsign != ProfileService().getProfile().callsign,
                        onPromote: () => _promoteParticipant(p.callsign),
                        onDemote: () => _demoteParticipant(p.callsign),
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
  final bool isSpeaker;
  final bool isHost;
  final bool isMe;
  final bool canManage;
  final VoidCallback? onPromote;
  final VoidCallback? onDemote;

  const _ParticipantTile({
    required this.callsign,
    required this.isConnected,
    required this.isMuted,
    required this.isSpeaker,
    required this.isHost,
    required this.isMe,
    this.canManage = false,
    this.onPromote,
    this.onDemote,
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
            isSpeaker ? Icons.mic : Icons.headphones,
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
          '${isConnected ? 'Connected' : 'Connecting...'} - ${isSpeaker ? 'Speaker' : 'Listener'}',
          style: TextStyle(
            color: isConnected ? Colors.green : Colors.orange,
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMuted)
              Icon(Icons.mic_off, color: theme.colorScheme.error, size: 20),
            if (canManage) ...[
              const SizedBox(width: 4),
              if (isSpeaker)
                IconButton(
                  icon: const Icon(Icons.mic_off, size: 20),
                  onPressed: onDemote,
                  tooltip: 'Demote to listener',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                )
              else
                IconButton(
                  icon: const Icon(Icons.mic, size: 20),
                  onPressed: onPromote,
                  tooltip: 'Promote to speaker',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
            ],
          ],
        ),
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
