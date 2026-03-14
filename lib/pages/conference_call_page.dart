/// Conference Call Page — active call UI shared by host and joiner (SFU topology).
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/conference_archive_entry.dart';
import '../services/alsa_recorder.dart';
import '../services/conference_archive_service.dart';
import '../services/conference_service.dart';
import '../services/profile_service.dart';
import '../widgets/audio_level_bar.dart';
import 'conference_archive_detail_page.dart';
import 'conference_home_page.dart';
import '../widgets/message_input_widget.dart';
import '../widgets/message_list_widget.dart';

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
  final Map<String, RTCVideoRenderer> _audioRenderers = {};
  RTCVideoRenderer? _screenRenderer;
  Future<void> _screenSyncQueue = Future<void>.value();
  String? _screenRendererStreamId;
  bool _isExitingToHome = false;
  bool _isWaitingForApproval = false;
  double _audioLevel = 0.0;
  Timer? _audioLevelTimer;
  AlsaRecorder? _alsaMonitor;
  ConferenceArchiveEntry? _lastArchiveEntry;

  @override
  void initState() {
    super.initState();

    _stateSubscription = _conferenceService.stateStream.listen((state) {
      if (!mounted) return;
      // Capture archive entry while conference is still active
      _lastArchiveEntry = _conferenceService.archiveEntry ?? _lastArchiveEntry;
      if (state == ConferenceState.idle) {
        _navigateToArchiveOrHome();
        return;
      }
      if (state == ConferenceState.active) {
        _isWaitingForApproval = false;
      }
      setState(() {});
    });

    _eventSubscription = _conferenceService.events.listen((event) {
      unawaited(_syncRemoteAudio());
      _queueScreenShareSync();

      if (event.type == 'kicked' && mounted) {
        final data = event.data as Map<String, dynamic>?;
        final reason = data?['reason'] as String?;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              reason != null && reason.isNotEmpty
                  ? 'You have been removed from the meeting: $reason'
                  : 'You have been removed from the meeting',
            ),
          ),
        );
      } else if (event.type == 'join_pending' && mounted) {
        setState(() => _isWaitingForApproval = true);
      } else if (event.type == 'password_required' && mounted) {
        _showPasswordDialog();
      } else if (event.type == 'banned' && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You are banned from this meeting')),
        );
      }

      if (mounted) setState(() {});
    });

    unawaited(_syncRemoteAudio());
    _queueScreenShareSync();
    _loadMeetUrls();

    unawaited(_startAudioMonitor());
  }

  Future<void> _startAudioMonitor() async {
    if (Platform.isLinux && AlsaRecorder.isAvailable) {
      try {
        _alsaMonitor = AlsaRecorder(sampleRate: 8000, channels: 1);
        _alsaMonitor!.initialize();
        final ok = await _alsaMonitor!.startRecording('monitor');
        if (!ok) {
          _alsaMonitor = null;
        }
      } catch (e) {
        _alsaMonitor = null;
      }
    }

    _audioLevelTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) {
        if (!mounted) return;
        _pollAudioLevel();
      },
    );
  }

  void _pollAudioLevel() {
    // Show zero when muted
    if (_conferenceService.isLocalMuted) {
      if (_audioLevel != 0.0 && mounted) setState(() => _audioLevel = 0.0);
      // Still drain ALSA buffer so it doesn't accumulate
      _alsaMonitor?.readFrames(1600);
      return;
    }

    if (_alsaMonitor != null && _alsaMonitor!.isRecording) {
      // Read 200ms worth of frames at 8kHz = 1600 frames
      final frames = _alsaMonitor!.readFrames(1600);
      if (frames != null && frames.isNotEmpty) {
        double sumSquares = 0;
        for (final sample in frames) {
          sumSquares += sample * sample;
        }
        final rms = sumSquares / frames.length;
        final normalized = (rms / (32767 * 32767)).clamp(0.0, 1.0);
        final amplitude = (normalized * 10).clamp(0.0, 1.0);
        if (mounted) setState(() => _audioLevel = amplitude);
      }
      return;
    }

    // Fallback: try WebRTC stats (works on Android/iOS with peers)
    _pollAudioLevelFromStats();
  }

  Future<void> _pollAudioLevelFromStats() async {
    double maxLevel = 0.0;
    final pcs = _conferenceService.peerConnections;
    for (final pc in pcs) {
      try {
        final stats = await pc.getStats();
        for (final report in stats) {
          final level = report.values['audioLevel'];
          if (level is num && level > maxLevel) maxLevel = level.toDouble();
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _audioLevel = maxLevel);
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
    _audioLevelTimer?.cancel();
    _alsaMonitor?.stopRecording();
    _stateSubscription?.cancel();
    _eventSubscription?.cancel();
    unawaited(_disposeAudioRenderers());
    unawaited(_disposeScreenRenderer());
    super.dispose();
  }

  Future<void> _endCall() async {
    _lastArchiveEntry = _conferenceService.archiveEntry ?? _lastArchiveEntry;
    await _conferenceService.endConference();
    if (!mounted) return;
    await _navigateToArchiveOrHome();
  }

  Future<void> _navigateToArchiveOrHome() async {
    if (!mounted || _isExitingToHome) return;
    final entry = _lastArchiveEntry;
    if (entry != null) {
      try {
        final refreshed =
            await ConferenceArchiveService().refreshArchive(entry);
        if (!mounted) return;
        _isExitingToHome = true;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ConferenceArchiveDetailPage(entry: refreshed),
          ),
        );
        return;
      } catch (_) {}
    }
    _returnToConferenceHome();
  }

  void _toggleMute() {
    _conferenceService.toggleMute();
    setState(() {});
  }

  String? get _shareUrl {
    return _conferenceService.shareableStationMeetUrl ??
        (_meetUrls.isNotEmpty ? _meetUrls.first : null);
  }

  void _copyShareUrl() {
    final url = _shareUrl;
    if (url == null) return;
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  Future<void> _promoteParticipant(String callsign) async {
    try {
      await _conferenceService.promoteToSpeaker(callsign);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _demoteParticipant(String callsign) async {
    try {
      await _conferenceService.demoteToListener(callsign);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _requestSpeakerAccess() async {
    try {
      await _conferenceService.requestToSpeak();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _requestScreenShare() async {
    try {
      await _conferenceService.requestToShareScreen();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _approveScreenShare(String callsign) async {
    try {
      await _conferenceService.approveScreenShare(callsign);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _toggleScreenShare() async {
    try {
      if (_conferenceService.isLocalScreenSharing) {
        await _conferenceService.stopScreenShare();
      } else {
        await _conferenceService.startScreenShare();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _toggleRecording() async {
    try {
      if (_conferenceService.isRecording) {
        await _conferenceService.stopRecording();
      } else {
        await _conferenceService.startRecording();
      }
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _sendChatMessage(String content, String? filePath) async {
    await _conferenceService.sendChatMessage(content);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _kickParticipant(String callsign, {bool ban = false}) async {
    try {
      await _conferenceService.kickParticipant(callsign, ban: ban);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  void _showPasswordDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Meeting Password Required'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Password',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _conferenceService.endConference();
            },
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              // TODO: retry join with password — requires storing join params
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  void _showHostSettingsSheet() {
    final room = _conferenceService.room;
    if (room == null) return;

    var approvalRequired = room.approvalRequired;
    final passwordController = TextEditingController(
      text: room.password ?? '',
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            24, 24, 24,
            MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Meeting Settings',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Meeting password',
                  hintText: 'Leave empty for open access',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('Require approval to join'),
                subtitle: const Text(
                  'New participants wait until you approve',
                ),
                value: approvalRequired,
                onChanged: (v) => setSheetState(
                  () => approvalRequired = v,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  final pw = passwordController.text.trim();
                  _conferenceService.updateModerationSettings(
                    approvalRequired: approvalRequired,
                    password: pw.isEmpty ? null : pw,
                    clearPassword: pw.isEmpty,
                  );
                  Navigator.pop(ctx);
                },
                child: const Text('Apply'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPeopleList(
    ThemeData theme,
    ConferenceRoom? room,
    List<ConferenceParticipant> participants,
    bool isHost,
    String myCallsign,
  ) {
    final pendingRequests = room?.pendingJoinRequests ?? {};
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        // Waiting room section (host only)
        if (isHost && pendingRequests.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Text(
              'Waiting Room (${pendingRequests.length})',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final callsign in pendingRequests.keys)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.tertiaryContainer,
                  child: Icon(
                    Icons.front_hand,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
                title: Text(callsign),
                subtitle: Text(
                  'Waiting for approval',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.check_circle,
                        color: theme.colorScheme.primary,
                      ),
                      onPressed: () =>
                          _conferenceService.approveJoinRequest(callsign),
                      tooltip: 'Approve',
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.cancel,
                        color: theme.colorScheme.error,
                      ),
                      onPressed: () =>
                          _conferenceService.denyJoinRequest(callsign),
                      tooltip: 'Deny',
                    ),
                  ],
                ),
              ),
            ),
          const Divider(),
        ],
        // Participant list
        for (final p in participants) ...[
          () {
            final isSelf = p.callsign == myCallsign;
            final isRelayPresenceOnly =
                !isHost && !isSelf && p.callsign != room?.hostCallsign;
            final statusLabel = isRelayPresenceOnly
                ? 'In room'
                : (p.isConnected ? 'Connected' : 'Connecting...');
            return _ParticipantTile(
              callsign: p.callsign,
              statusLabel: statusLabel,
              isConnected: p.isConnected || isRelayPresenceOnly,
              isMuted: p.isMuted,
              isSpeaker: p.isSpeaker,
              hasPendingSpeakerRequest: p.hasPendingSpeakerRequest,
              hasPendingScreenShareRequest: p.hasPendingScreenShareRequest,
              isScreenSharing: p.isScreenSharing,
              isHost: p.callsign == room?.hostCallsign,
              isMe: isSelf,
              canManage:
                  isHost && p.callsign != room?.hostCallsign && !isSelf,
              onPromote: () => _promoteParticipant(p.callsign),
              onDemote: () => _demoteParticipant(p.callsign),
              onApproveScreenShare: () => _approveScreenShare(p.callsign),
              onKick: () => _kickParticipant(p.callsign),
              onBan: () => _kickParticipant(p.callsign, ban: true),
            );
          }(),
        ],
      ],
    );
  }

  Future<void> _syncRemoteAudio() async {
    final activeStreams = _conferenceService.remoteAudioStreams;
    final activeIds = activeStreams.map((stream) => stream.id).toSet();

    for (final stream in activeStreams) {
      await _attachRemoteStream(stream);
    }

    final staleIds = _audioRenderers.keys
        .where((streamId) => !activeIds.contains(streamId))
        .toList();
    for (final streamId in staleIds) {
      final renderer = _audioRenderers.remove(streamId);
      if (renderer == null) continue;
      renderer.srcObject = null;
      await renderer.dispose();
    }
  }

  Future<void> _attachRemoteStream(MediaStream stream) async {
    var renderer = _audioRenderers[stream.id];
    if (renderer == null) {
      renderer = RTCVideoRenderer();
      await renderer.initialize();
      _audioRenderers[stream.id] = renderer;
    }
    renderer.srcObject = stream;
  }

  Future<void> _disposeAudioRenderers() async {
    for (final renderer in _audioRenderers.values) {
      renderer.srcObject = null;
      await renderer.dispose();
    }
    _audioRenderers.clear();
  }

  Future<void> _syncScreenShare() async {
    final myCallsign = ProfileService().getProfile().callsign;
    final activeSharer = _conferenceService.activeScreenSharer;
    if (activeSharer != null &&
        activeSharer.toUpperCase() == myCallsign.toUpperCase()) {
      await _disposeScreenRenderer();
      return;
    }

    final stream = _conferenceService.activeScreenStream;
    if (stream == null) {
      await _disposeScreenRenderer();
      return;
    }

    var renderer = _screenRenderer;
    if (renderer == null) {
      renderer = RTCVideoRenderer();
      await renderer.initialize();
      _screenRenderer = renderer;
    }

    if (_screenRendererStreamId == stream.id &&
        renderer.srcObject?.id == stream.id) {
      return;
    }

    renderer.srcObject = null;
    renderer.srcObject = stream;
    _screenRendererStreamId = stream.id;
  }

  Future<void> _disposeScreenRenderer() async {
    final renderer = _screenRenderer;
    _screenRenderer = null;
    _screenRendererStreamId = null;
    if (renderer == null) {
      return;
    }
    renderer.srcObject = null;
    await renderer.dispose();
  }

  Future<void> _openScreenShareFullscreen() async {
    final stream = _conferenceService.activeScreenStream;
    final activeSharer = _conferenceService.activeScreenSharer;
    if (stream == null || activeSharer == null) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ConferenceScreenShareViewerPage(
          stream: stream,
          sharerCallsign: activeSharer,
        ),
      ),
    );
  }

  void _queueScreenShareSync() {
    _screenSyncQueue = _screenSyncQueue
        .catchError((Object error, StackTrace stackTrace) {})
        .then((_) => _syncScreenShare());
  }

  void _showShareSheet() {
    final room = _conferenceService.room;
    if (room == null) return;

    final primaryUrl = _shareUrl;
    final stationUrl = _conferenceService.shareableStationMeetUrl;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Share Meeting', style: Theme.of(ctx).textTheme.titleLarge),
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
                      primaryUrl == stationUrl ? 'Station link' : 'Join link',
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
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Link copied')));
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
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Room ID copied')));
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
                  Icon(
                    Icons.copy,
                    size: 14,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
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
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('Copied: $url')));
                    },
                    child: Row(
                      children: [
                        Icon(
                          Icons.wifi,
                          size: 14,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
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
                        Icon(
                          Icons.copy,
                          size: 14,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
            ],

            if (_meetUrls.isNotEmpty &&
                stationUrl != null &&
                stationUrl != primaryUrl) ...[
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
                    Icon(
                      Icons.cloud,
                      size: 14,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
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
                    Icon(
                      Icons.copy,
                      size: 14,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
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

  void _returnToConferenceHome() {
    if (!mounted || _isExitingToHome) {
      return;
    }
    _isExitingToHome = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ConferenceHomePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final room = _conferenceService.room;
    final isHost = _conferenceService.role == ConferenceRole.host;
    final isMuted = _conferenceService.isLocalMuted;
    final participants = room?.participants.values.toList() ?? [];
    final myCallsign = ProfileService().getProfile().callsign;
    final me = room?.participants[myCallsign];
    final canRequestSpeaker = !isHost && me != null && !me.isSpeaker;
    final hasRequestedSpeaker = me?.hasPendingSpeakerRequest ?? false;
    final hasRequestedScreenShare = me?.hasPendingScreenShareRequest ?? false;
    final activeScreenSharer = room?.activeScreenSharerCallsign;
    final isLocalScreenSharing = _conferenceService.isLocalScreenSharing;
    final isRecording = _conferenceService.isRecording;
    final isViewingLocalScreenShare =
        activeScreenSharer != null &&
        activeScreenSharer.toUpperCase() == myCallsign.toUpperCase();
    final shareUrl = _shareUrl;
    final compactControls =
        mediaQuery.orientation == Orientation.landscape ||
        mediaQuery.size.height < 520;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(room?.roomName ?? 'Meeting'),
        automaticallyImplyLeading: false,
        actions: [
          if (isHost)
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _showHostSettingsSheet,
              tooltip: 'Meeting settings',
            ),
          if (isHost)
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: _showShareSheet,
              tooltip: 'Share meeting',
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isCompactLayout = constraints.maxHeight < 520;
          final showInlineScreenPreview =
              activeScreenSharer != null &&
              !isViewingLocalScreenShare &&
              !isCompactLayout;
          final showScreenPreviewBanner =
              activeScreenSharer != null &&
              !isViewingLocalScreenShare &&
              isCompactLayout;
          final screenPreviewHeight = !showInlineScreenPreview
              ? 0.0
              : math.min(
                  constraints.maxWidth * (9 / 16),
                  ((constraints.maxHeight - 260).clamp(32, 170)).toDouble(),
                );
          final compactScreenPreview = screenPreviewHeight < 120;

          return Column(
            children: [
              // Room info bar
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
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
                              horizontal: 8,
                              vertical: 3,
                            ),
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
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: theme
                                              .colorScheme
                                              .onPrimaryContainer,
                                        ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.copy,
                                  size: 12,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(width: 8),
                    // Speaker/listener count
                    Icon(
                      Icons.mic,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '${room?.speakerCount ?? 0}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.headphones,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '${room?.listenerCount ?? 0}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (isRecording) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.error,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'REC',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const Divider(height: 1),

              if (isViewingLocalScreenShare)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.screen_share,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'You are sharing your screen',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              if (showScreenPreviewBanner)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$activeScreenSharer is sharing a screen',
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.fullscreen),
                        tooltip: 'Open full screen',
                        onPressed: _screenRenderer == null
                            ? null
                            : _openScreenShareFullscreen,
                      ),
                    ],
                  ),
                ),

              if (showInlineScreenPreview)
                Container(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    compactScreenPreview ? 10 : 16,
                    16,
                    8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              activeScreenSharer == myCallsign
                                  ? 'You are sharing your screen'
                                  : '$activeScreenSharer is sharing a screen',
                              style: compactScreenPreview
                                  ? theme.textTheme.titleSmall
                                  : theme.textTheme.titleMedium,
                            ),
                          ),
                          if (_screenRenderer != null)
                            IconButton(
                              icon: const Icon(Icons.fullscreen),
                              tooltip: 'Open full screen',
                              onPressed: _openScreenShareFullscreen,
                            ),
                        ],
                      ),
                      SizedBox(height: compactScreenPreview ? 6 : 8),
                      SizedBox(
                        width: double.infinity,
                        height: screenPreviewHeight,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                            ),
                            child: _screenRenderer == null
                                ? Center(
                                    child: Text(
                                      'Connecting screen share...',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  )
                                : RTCVideoView(_screenRenderer!),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              Expanded(
                child: DefaultTabController(
                  length: 2,
                  child: Column(
                    children: [
                      TabBar(
                        tabs: [
                          Tab(text: 'People (${participants.length}${isHost && (room?.pendingJoinRequests.isNotEmpty ?? false) ? '+${room!.pendingJoinRequests.length}' : ''})'),
                          Tab(
                            text:
                                'Chat (${_conferenceService.chatMessages.length})',
                          ),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            _isWaitingForApproval
                                ? Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const CircularProgressIndicator(),
                                        const SizedBox(height: 16),
                                        Text(
                                          'Waiting for host approval...',
                                          style: theme.textTheme.bodyLarge
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  )
                                : participants.isEmpty
                                ? Center(
                                    child: Text(
                                      'Waiting for participants...',
                                      style: theme.textTheme.bodyLarge
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  )
                                : _buildPeopleList(
                                    theme, room, participants,
                                    isHost, myCallsign,
                                  ),
                            Column(
                              children: [
                                Expanded(
                                  child: MessageListWidget(
                                    messages: _conferenceService.chatMessages,
                                    isGroupChat: true,
                                    canDeleteMessage: isHost
                                        ? (_) => true
                                        : null,
                                    onMessageDelete: isHost
                                        ? (msg) {
                                            final confId = msg.getMeta(
                                              'conference_id',
                                            );
                                            if (confId != null) {
                                              _conferenceService
                                                  .deleteChatMessage(confId);
                                            }
                                          }
                                        : null,
                                  ),
                                ),
                                MessageInputWidget(
                                  onSend: _sendChatMessage,
                                  allowFiles: false,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),

      // Bottom controls
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: EdgeInsets.all(compactControls ? 10 : 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AudioLevelBar(amplitude: _audioLevel),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.spaceEvenly,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: compactControls ? 12 : 18,
                runSpacing: compactControls ? 8 : 12,
                children: [
              _CallButton(
                icon: isMuted ? Icons.mic_off : Icons.mic,
                label: isMuted ? 'Unmute' : 'Mute',
                color: isMuted
                    ? theme.colorScheme.error
                    : theme.colorScheme.surfaceContainerHighest,
                iconColor: isMuted ? Colors.white : theme.colorScheme.onSurface,
                onPressed: _toggleMute,
                compact: compactControls,
              ),
              if (canRequestSpeaker)
                _CallButton(
                  icon: hasRequestedSpeaker
                      ? Icons.pan_tool_alt
                      : Icons.record_voice_over,
                  label: hasRequestedSpeaker ? 'Requested' : 'Request Mic',
                  color: hasRequestedSpeaker
                      ? theme.colorScheme.primary
                      : theme.colorScheme.secondaryContainer,
                  iconColor: hasRequestedSpeaker
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSecondaryContainer,
                  onPressed: hasRequestedSpeaker ? null : _requestSpeakerAccess,
                  compact: compactControls,
                ),
              _CallButton(
                icon: isLocalScreenSharing
                    ? Icons.stop_screen_share
                    : (isHost ? Icons.screen_share : Icons.present_to_all),
                label: isLocalScreenSharing
                    ? 'Stop Screen'
                    : (isHost ? 'Share Screen' : 'Ask Screen'),
                color: isLocalScreenSharing
                    ? theme.colorScheme.primary
                    : (hasRequestedScreenShare
                          ? theme.colorScheme.primary
                          : theme.colorScheme.tertiaryContainer),
                iconColor: isLocalScreenSharing || hasRequestedScreenShare
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onTertiaryContainer,
                onPressed: isLocalScreenSharing
                    ? _toggleScreenShare
                    : (isHost
                          ? (activeScreenSharer == null
                                ? _toggleScreenShare
                                : null)
                          : (hasRequestedScreenShare ||
                                    (activeScreenSharer != null &&
                                        activeScreenSharer != myCallsign)
                                ? null
                                : _requestScreenShare)),
                compact: compactControls,
              ),
              _CallButton(
                icon: isRecording
                    ? Icons.stop_circle
                    : Icons.fiber_manual_record,
                label: isRecording ? 'Stop Rec' : 'Record',
                color: isRecording
                    ? theme.colorScheme.error
                    : theme.colorScheme.secondaryContainer,
                iconColor: isRecording
                    ? Colors.white
                    : theme.colorScheme.onSecondaryContainer,
                onPressed: _toggleRecording,
                compact: compactControls,
              ),
              _CallButton(
                icon: Icons.call_end,
                label: isHost ? 'End' : 'Leave',
                color: const Color(0xFFD90429),
                iconColor: Colors.white,
                onPressed: _endCall,
                compact: compactControls,
              ),
            ],
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
  final String statusLabel;
  final bool isConnected;
  final bool isMuted;
  final bool isSpeaker;
  final bool hasPendingSpeakerRequest;
  final bool hasPendingScreenShareRequest;
  final bool isScreenSharing;
  final bool isHost;
  final bool isMe;
  final bool canManage;
  final VoidCallback? onPromote;
  final VoidCallback? onDemote;
  final VoidCallback? onApproveScreenShare;
  final VoidCallback? onKick;
  final VoidCallback? onBan;

  const _ParticipantTile({
    required this.callsign,
    required this.statusLabel,
    required this.isConnected,
    required this.isMuted,
    required this.isSpeaker,
    this.hasPendingSpeakerRequest = false,
    this.hasPendingScreenShareRequest = false,
    this.isScreenSharing = false,
    required this.isHost,
    required this.isMe,
    this.canManage = false,
    this.onPromote,
    this.onDemote,
    this.onApproveScreenShare,
    this.onKick,
    this.onBan,
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
          '$statusLabel - ${isSpeaker ? 'Speaker' : (hasPendingSpeakerRequest ? 'Listener, mic requested' : 'Listener')}${isScreenSharing ? ', sharing screen' : (hasPendingScreenShareRequest ? ', screen requested' : '')}',
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
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                )
              else
                IconButton(
                  icon: Icon(
                    hasPendingSpeakerRequest ? Icons.pan_tool_alt : Icons.mic,
                    size: 20,
                    color: hasPendingSpeakerRequest
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  onPressed: onPromote,
                  tooltip: hasPendingSpeakerRequest
                      ? 'Approve speaker request'
                      : 'Promote to speaker',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                ),
              if (hasPendingScreenShareRequest)
                IconButton(
                  icon: Icon(
                    Icons.present_to_all,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  onPressed: onApproveScreenShare,
                  tooltip: 'Approve screen sharing',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                ),
              if (!isHost)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  onSelected: (value) {
                    if (value == 'kick') onKick?.call();
                    if (value == 'ban') onBan?.call();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'kick',
                      child: ListTile(
                        leading: Icon(Icons.person_remove),
                        title: Text('Kick'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'ban',
                      child: ListTile(
                        leading: Icon(Icons.block),
                        title: Text('Kick & Ban'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConferenceScreenShareViewerPage extends StatefulWidget {
  final MediaStream stream;
  final String sharerCallsign;

  const _ConferenceScreenShareViewerPage({
    required this.stream,
    required this.sharerCallsign,
  });

  @override
  State<_ConferenceScreenShareViewerPage> createState() =>
      _ConferenceScreenShareViewerPageState();
}

class _ConferenceScreenShareViewerPageState
    extends State<_ConferenceScreenShareViewerPage> {
  RTCVideoRenderer? _renderer;
  final FocusNode _focusNode = FocusNode();
  final TransformationController _transformationController =
      TransformationController();
  Timer? _overlayTimer;
  bool _showOverlay = true;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeRenderer());
    _showOverlayTemporarily();
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    _focusNode.dispose();
    _transformationController.dispose();
    unawaited(_disposeRenderer());
    super.dispose();
  }

  Future<void> _initializeRenderer() async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = widget.stream;
    if (!mounted) {
      renderer.srcObject = null;
      await renderer.dispose();
      return;
    }
    setState(() {
      _renderer = renderer;
    });
  }

  Future<void> _disposeRenderer() async {
    final renderer = _renderer;
    _renderer = null;
    if (renderer == null) {
      return;
    }
    renderer.srcObject = null;
    await renderer.dispose();
  }

  void _showOverlayTemporarily() {
    if (!mounted) {
      return;
    }
    setState(() {
      _showOverlay = true;
    });
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _showOverlay = false;
        });
      }
    });
  }

  void _closeViewer() {
    Navigator.of(context).maybePop();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _closeViewer();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: MouseRegion(
          onHover: (_) => _showOverlayTemporarily(),
          onEnter: (_) => _showOverlayTemporarily(),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _showOverlayTemporarily(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_renderer == null)
                  Center(
                    child: Text(
                      'Connecting screen share...',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                  )
                else
                  InteractiveViewer(
                    transformationController: _transformationController,
                    minScale: 1,
                    maxScale: 4,
                    panEnabled: true,
                    scaleEnabled: true,
                    trackpadScrollCausesScale: true,
                    onInteractionStart: (_) => _showOverlayTemporarily(),
                    onInteractionUpdate: (_) => _showOverlayTemporarily(),
                    child: SizedBox.expand(
                      child: Center(child: RTCVideoView(_renderer!)),
                    ),
                  ),
                if (_showOverlay)
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                '${widget.sharerCallsign} is sharing a screen',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          IconButton(
                            icon: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.fullscreen_exit,
                                color: Colors.white,
                              ),
                            ),
                            tooltip: 'Exit full screen',
                            onPressed: _closeViewer,
                          ),
                        ],
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

class _CallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color iconColor;
  final VoidCallback? onPressed;
  final bool compact;

  const _CallButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.iconColor,
    required this.onPressed,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (compact)
          FloatingActionButton.small(
            heroTag: label,
            onPressed: onPressed,
            backgroundColor: color,
            child: Icon(icon, color: iconColor, size: 20),
          )
        else
          FloatingActionButton(
            heroTag: label,
            onPressed: onPressed,
            backgroundColor: color,
            child: Icon(icon, color: iconColor),
          ),
        SizedBox(height: compact ? 4 : 6),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontSize: compact ? 11 : null,
          ),
        ),
      ],
    );
  }
}
