/// Conference Call Page — active call UI shared by host and joiner (SFU topology).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/conference_service.dart';
import '../services/profile_service.dart';
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
  final FocusNode _screenShareFullscreenFocusNode = FocusNode();
  Timer? _screenShareFullscreenOverlayTimer;
  bool _isScreenShareFullscreen = false;
  bool _showScreenShareFullscreenOverlay = true;

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
      unawaited(_syncRemoteAudio());
      _queueScreenShareSync();
      if (mounted) setState(() {});
    });

    unawaited(_syncRemoteAudio());
    _queueScreenShareSync();
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
    _screenShareFullscreenOverlayTimer?.cancel();
    _screenShareFullscreenFocusNode.dispose();
    unawaited(_disposeAudioRenderers());
    unawaited(_disposeScreenRenderer());
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

  Future<void> _sendChatMessage(String content, String? filePath) async {
    await _conferenceService.sendChatMessage(content);
    if (!mounted) return;
    setState(() {});
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
      _closeScreenShareFullscreen();
      await _disposeScreenRenderer();
      return;
    }

    final stream = _conferenceService.activeScreenStream;
    if (stream == null) {
      _closeScreenShareFullscreen();
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

  void _openScreenShareFullscreen() {
    if (_screenRenderer == null) {
      return;
    }
    setState(() {
      _isScreenShareFullscreen = true;
    });
    _showScreenShareFullscreenControls();
  }

  void _closeScreenShareFullscreen() {
    if (!_isScreenShareFullscreen) {
      return;
    }
    _screenShareFullscreenOverlayTimer?.cancel();
    if (mounted) {
      setState(() {
        _isScreenShareFullscreen = false;
        _showScreenShareFullscreenOverlay = true;
      });
    } else {
      _isScreenShareFullscreen = false;
      _showScreenShareFullscreenOverlay = true;
    }
  }

  void _showScreenShareFullscreenControls() {
    if (!_isScreenShareFullscreen || !mounted) {
      return;
    }
    setState(() {
      _showScreenShareFullscreenOverlay = true;
    });
    _screenShareFullscreenOverlayTimer?.cancel();
    _screenShareFullscreenOverlayTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isScreenShareFullscreen) {
        setState(() {
          _showScreenShareFullscreenOverlay = false;
        });
      }
    });
  }

  KeyEventResult _handleScreenShareFullscreenKeyEvent(
    FocusNode node,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _closeScreenShareFullscreen();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
    final stationUrl = _conferenceService.stationMeetUrl;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
    final isViewingLocalScreenShare =
        activeScreenSharer != null &&
        activeScreenSharer.toUpperCase() == myCallsign.toUpperCase();
    final shareUrl = _shareUrl;
    final isShowingFullscreenScreenShare =
        _isScreenShareFullscreen &&
        _screenRenderer != null &&
        activeScreenSharer != null &&
        !isViewingLocalScreenShare;

    return PopScope(
      canPop: !_isScreenShareFullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isScreenShareFullscreen) {
          _closeScreenShareFullscreen();
        }
      },
      child: Scaffold(
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
        body: LayoutBuilder(
          builder: (context, constraints) {
            final screenPreviewHeight =
                activeScreenSharer == null || isViewingLocalScreenShare
                ? 0.0
                : math.min(
                    constraints.maxWidth * (9 / 16),
                    ((constraints.maxHeight - 150).clamp(40, 220)).toDouble(),
                  );
            final compactScreenPreview = screenPreviewHeight < 120;

            return Stack(
              children: [
                Column(
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
                                        color: theme
                                            .colorScheme
                                            .onPrimaryContainer,
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

                    if (activeScreenSharer != null &&
                        !isViewingLocalScreenShare)
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
                                    color: theme
                                        .colorScheme
                                        .surfaceContainerHighest,
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
                                      : (_isScreenShareFullscreen
                                            ? Center(
                                                child: Text(
                                                  'Screen share opened in full screen',
                                                  style: theme
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.copyWith(
                                                        color: theme
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                              )
                                            : RTCVideoView(_screenRenderer!)),
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
                                Tab(text: 'People (${participants.length})'),
                                Tab(
                                  text:
                                      'Chat (${_conferenceService.chatMessages.length})',
                                ),
                              ],
                            ),
                            Expanded(
                              child: TabBarView(
                                children: [
                                  participants.isEmpty
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
                                      : ListView.builder(
                                          padding: const EdgeInsets.all(8),
                                          itemCount: participants.length,
                                          itemBuilder: (context, index) {
                                            final p = participants[index];
                                            final isSelf =
                                                p.callsign == myCallsign;
                                            final isRelayPresenceOnly =
                                                !isHost &&
                                                !isSelf &&
                                                p.callsign !=
                                                    room?.hostCallsign;
                                            final statusLabel =
                                                isRelayPresenceOnly
                                                ? 'In room'
                                                : (p.isConnected
                                                      ? 'Connected'
                                                      : 'Connecting...');
                                            return _ParticipantTile(
                                              callsign: p.callsign,
                                              statusLabel: statusLabel,
                                              isConnected:
                                                  p.isConnected ||
                                                  isRelayPresenceOnly,
                                              isMuted: p.isMuted,
                                              isSpeaker: p.isSpeaker,
                                              hasPendingSpeakerRequest:
                                                  p.hasPendingSpeakerRequest,
                                              hasPendingScreenShareRequest: p
                                                  .hasPendingScreenShareRequest,
                                              isScreenSharing:
                                                  p.isScreenSharing,
                                              isHost:
                                                  p.callsign ==
                                                  room?.hostCallsign,
                                              isMe: isSelf,
                                              canManage:
                                                  isHost &&
                                                  p.callsign !=
                                                      room?.hostCallsign &&
                                                  !isSelf,
                                              onPromote: () =>
                                                  _promoteParticipant(
                                                    p.callsign,
                                                  ),
                                              onDemote: () =>
                                                  _demoteParticipant(
                                                    p.callsign,
                                                  ),
                                              onApproveScreenShare: () =>
                                                  _approveScreenShare(
                                                    p.callsign,
                                                  ),
                                            );
                                          },
                                        ),
                                  Column(
                                    children: [
                                      Expanded(
                                        child: MessageListWidget(
                                          messages:
                                              _conferenceService.chatMessages,
                                          isGroupChat: true,
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
                ),
                if (isShowingFullscreenScreenShare)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: const BoxDecoration(color: Colors.black),
                      child: Focus(
                        focusNode: _screenShareFullscreenFocusNode,
                        autofocus: true,
                        onKeyEvent: _handleScreenShareFullscreenKeyEvent,
                        child: MouseRegion(
                          onHover: (_) => _showScreenShareFullscreenControls(),
                          onEnter: (_) => _showScreenShareFullscreenControls(),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _showScreenShareFullscreenControls,
                            onPanDown: (_) =>
                                _showScreenShareFullscreenControls(),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Center(child: RTCVideoView(_screenRenderer!)),
                                if (_showScreenShareFullscreenOverlay)
                                  SafeArea(
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                    vertical: 10,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withValues(
                                                  alpha: 0.55,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(14),
                                              ),
                                              child: Text(
                                                '$activeScreenSharer is sharing a screen',
                                                style: theme
                                                    .textTheme
                                                    .titleSmall
                                                    ?.copyWith(
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          IconButton(
                                            icon: Container(
                                              padding: const EdgeInsets.all(10),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withValues(
                                                  alpha: 0.55,
                                                ),
                                                shape: BoxShape.circle,
                                              ),
                                              child: const Icon(
                                                Icons.fullscreen_exit,
                                                color: Colors.white,
                                              ),
                                            ),
                                            tooltip: 'Exit full screen',
                                            onPressed:
                                                _closeScreenShareFullscreen,
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
                    ),
                  ),
              ],
            );
          },
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
                  iconColor: isMuted
                      ? Colors.white
                      : theme.colorScheme.onSurface,
                  onPressed: _toggleMute,
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
                    onPressed: hasRequestedSpeaker
                        ? null
                        : _requestSpeakerAccess,
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
                ),
                _CallButton(
                  icon: Icons.call_end,
                  label: isHost ? 'End' : 'Leave',
                  color: const Color(0xFFD90429),
                  iconColor: Colors.white,
                  onPressed: _endCall,
                ),
              ],
            ),
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
  final VoidCallback? onPressed;

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
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
