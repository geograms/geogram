# Conference Format Specification

**Version**: 1.0
**Last Updated**: 2026-02-19
**Status**: Active

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [File Organization](#file-organization)
- [Signaling Modes](#signaling-modes)
- [Signaling Messages](#signaling-messages)
- [Peer Connection Management](#peer-connection-management)
- [Web Client](#web-client)
- [Debug API](#debug-api)
- [Integration Points](#integration-points)
- [Complete Examples](#complete-examples)
- [Implementation Reference](#implementation-reference)
- [Validation Rules](#validation-rules)
- [Best Practices](#best-practices)
- [Security Considerations](#security-considerations)
- [Related Documentation](#related-documentation)
- [Change Log](#change-log)

## Overview

This document specifies the P2P audio conferencing system in the Geogram platform. The conference feature enables real-time audio communication between participants using a mesh topology with WebRTC, supporting both LAN mode (for local networks without internet) and Station mode (for distributed internet-based communication).

### Key Features

- **Mesh Topology**: All participants connect directly to each other (max 6 participants)
- **Dual Signaling Modes**:
  - LAN mode: Host runs HTTP+WS signaling server for local network joins
  - Station mode: Existing WebSocket infrastructure relays signaling messages
- **P2P Audio Only**: Media flows directly between participants, not through servers
- **Web Browser Support**: LAN mode serves HTML client for browser-based joining
- **Automatic Mode Detection**: System chooses LAN or Station mode based on connectivity
- **QR Code Sharing**: LAN mode generates shareable QR codes and URLs
- **Mute Control**: Participants can toggle audio on/off
- **Event Integration**: Conference button shown in online events (isOnline=true)

## Architecture

### Network Topology

```
LAN Mode:
┌─────────────────────────────────────────────┐
│         Local Network (LAN)                  │
├─────────────────────────────────────────────┤
│                                               │
│  Host (runs signaling server)                │
│  ├─ HTTP+WS server on random port           │
│  ├─ Serves web client HTML                  │
│  ├─ Relays WebRTC offers/answers/ICE        │
│  └─ Direct P2P audio with participants      │
│                                               │
│  Participant A ◄─────► Host ◄─────► Participant B
│       ▲                                ▲
│       └──────► Participant C ◄─────────┘
│                                               │
└─────────────────────────────────────────────┘

Station Mode:
┌──────────────┐
│   Station    │
│  (Signaling) │
└──────┬───────┘
       │ WebSocket
       │
   ┌───┴─────────────────────────────┐
   │                                   │
Host/Participant A         Participant B
(Direct P2P Audio)         (Direct P2P Audio)
```

### Components

1. **ConferenceService** - Orchestration, mode selection, room management
2. **ConferenceSignalingServer** - HTTP+WS server (LAN mode only)
3. **ConferencePeerManager** - WebRTC peer connections, audio management
4. **ConferenceMixin** - Station-side signaling relay (shared mixin)
5. **Web Client** - HTML page served in LAN mode for browser joining

## File Organization

| File | Purpose |
|------|---------|
| `lib/server/mixins/conference_mixin.dart` | Station-side conference signaling relay (shared mixin) |
| `lib/services/conference_signaling_server.dart` | Host-side HTTP+WS signaling server (LAN mode) |
| `lib/services/conference_peer_manager.dart` | Audio WebRTC peer connections (mesh) |
| `lib/services/conference_service.dart` | Orchestration service (mode selection, room management) |
| `lib/pages/conference_host_page.dart` | Host UI (create/manage conference) |
| `lib/pages/conference_join_page.dart` | Join UI (enter URL or room ID) |
| `lib/pages/conference_call_page.dart` | Active call UI (audio controls, participants) |
| `assets/conference/index.html` | Minimal web client for browsers (LAN mode only) |

## Signaling Modes

### LAN Mode

**Activation**: When host is not connected to a station

**Process**:
1. Host creates conference
2. ConferenceService detects no station connection
3. ConferenceSignalingServer starts on random port (>= 10000)
4. System generates:
   - Share URL: `http://{local-ip}:{port}/?room={roomId}`
   - QR code encoding the URL
   - 6-character join code for manual entry
5. Web server serves `assets/conference/index.html` with room parameters

**Participants**:
1. Scan QR code or enter URL in browser
2. Browser JavaScript connects to host's signaling server via WebSocket
3. Browser exchanges WebRTC offer/answer/ICE candidates with host
4. Audio flows directly P2P between browser and host

**Advantages**:
- Works without internet
- No external server required
- Minimal latency
- Private to local network

**Limitations**:
- Participants must be on same local network
- Host must stay active to accept new joins
- Browser participants only (no mobile app in LAN mode)

### Station Mode

**Activation**: When host is connected to a station

**Process**:
1. Host creates conference while connected to station
2. ConferenceService detects station connection
3. Sends conference creation message to station via existing WebSocket
4. Station creates room and stores in conference state
5. Host remains connected to station via WebSocket for signaling relay

**Participants**:
1. Participant enters room ID or clicks shared link
2. Client connects to station
3. Client sends join request through station WebSocket
4. Host receives join notification from station
5. Participants exchange WebRTC signaling through station
6. Audio flows directly P2P between participants

**Advantages**:
- Works over internet
- Distributed access
- Participants don't need to be on same network
- Scalable to different networks

**Limitations**:
- Requires station connection
- Slightly higher latency (signaling relay overhead)
- Station operator can see participant list (no audio)

## Signaling Messages

### LAN Mode (WebSocket between Browser and Host)

#### Client to Host

**Join Message**:
```json
{
  "type": "join",
  "roomId": "room-abc123",
  "callsign": "PARTICIPANT1",
  "offer": "webrtc-offer-sdp-string"
}
```

**ICE Candidate Message**:
```json
{
  "type": "ice-candidate",
  "roomId": "room-abc123",
  "callsign": "PARTICIPANT1",
  "candidate": "ice-candidate-object"
}
```

**Mute/Unmute**:
```json
{
  "type": "mute",
  "roomId": "room-abc123",
  "muted": true
}
```

#### Host to Client

**Join Response**:
```json
{
  "type": "join-response",
  "success": true,
  "peerId": "peer-xyz789",
  "participants": [
    {"callsign": "HOST", "peerId": "host-peer"},
    {"callsign": "PARTICIPANT1", "peerId": "peer-001"}
  ]
}
```

**Answer Message**:
```json
{
  "type": "answer",
  "peerId": "peer-001",
  "answer": "webrtc-answer-sdp-string"
}
```

**ICE Candidate Message**:
```json
{
  "type": "ice-candidate",
  "peerId": "peer-001",
  "candidate": "ice-candidate-object"
}
```

**Participant Joined**:
```json
{
  "type": "participant-joined",
  "callsign": "PARTICIPANT2",
  "peerId": "peer-002"
}
```

**Participant Left**:
```json
{
  "type": "participant-left",
  "peerId": "peer-002"
}
```

### Station Mode (WebSocket through Station)

Messages use the same structure but are relayed through the station API endpoints.

**Station API Endpoints**:

```
POST /api/conference/create
{
  "roomId": string,
  "title": string
}

POST /api/conference/{roomId}/join
{
  "callsign": string,
  "offer": string
}

POST /api/conference/{roomId}/answer
{
  "peerId": string,
  "answer": string
}

POST /api/conference/{roomId}/ice-candidate
{
  "peerId": string,
  "candidate": object
}

POST /api/conference/{roomId}/leave
{
  "peerId": string
}

GET /api/conference/{roomId}/participants
→ Returns list of current participants
```

## Peer Connection Management

### WebRTC Configuration

**Audio-Optimized Settings** (`WebRTCConfig.forConference()`):

```dart
WebRTCConfig(
  audioOnly: true,
  audioConstraints: {
    'echoCancellation': true,
    'noiseSuppression': true,
    'autoGainControl': true,
  },
  iceServers: [
    // STUN servers for NAT traversal
    IceServer(
      urls: ['stun:stun.l.google.com:19302'],
    ),
    // TURN server for relay (if needed)
    IceServer(
      urls: ['turn:turn.example.com:3478'],
      username: 'user',
      credential: 'pass',
    ),
  ],
)
```

### Peer Manager State

**Managed Peers**:
```dart
class ConferencePeerManager {
  Map<String, RTCPeerConnection> peers = {};      // peerId → connection
  Map<String, MediaStream> remoteStreams = {};    // peerId → stream
  LocalMediaStream? localStream;                   // User's own audio
  bool isMuted = false;
}
```

### Connection Lifecycle

1. **Establish**: WebRTC offer/answer exchange
2. **ICE Gathering**: Candidate collection and exchange
3. **Connected**: ICE connection established
4. **Failed**: Connection attempt failed, retry or close
5. **Closed**: Connection explicitly closed

### Audio Track Management

- **Local Audio**: Capture from microphone, enabled/disabled by mute state
- **Remote Audio**: Receive audio from each peer, mix in audio element or send to audio output
- **Constraints**: Echo cancellation, noise suppression, auto gain control enabled
- **Sampling**: 16 kHz (speech-optimized)

## Web Client

### HTML Client Structure

**File**: `assets/conference/index.html`

**Features**:
- Room join interface (enter callsign, room ID, or use URL parameters)
- Real-time participant list
- Audio level indicators
- Mute/unmute toggle button
- Leave conference button
- Status messages

**URL Parameters**:
```
?room=room-abc123        # Conference room ID
&callsign=PARTICIPANT1   # User's callsign (optional)
&host=192.168.1.100      # Host IP (for discovery)
&port=12345              # Host port
```

**JavaScript Responsibilities**:
- Create WebRTC peer connections
- Manage local media stream
- Handle signaling messages (WebSocket)
- Update UI with participant list and audio status
- Handle audio playback

### Browser Compatibility

Requires WebRTC support:
- Chrome/Chromium 23+
- Firefox 22+
- Safari 12.1+
- Edge 15+

## Debug API

The debug API provides endpoints to test conference functionality without manual UI interaction.

### Endpoints

#### Create Conference

```
POST /debug/conference_host
{
  "title": "Test Conference",
  "mode": "auto"  // "auto", "lan", or "station"
}

Response:
{
  "roomId": "room-abc123",
  "mode": "lan",
  "signalingUrl": "ws://192.168.1.100:12345",
  "shareUrl": "http://192.168.1.100:12345/?room=room-abc123",
  "qrCode": "data:image/png;base64,..."
}
```

#### Join Conference

```
POST /debug/conference_join
{
  "roomId": "room-abc123",
  "callsign": "PARTICIPANT1",
  "method": "url"  // "url" or "roomId"
}

Response:
{
  "success": true,
  "peerId": "peer-xyz789",
  "participants": [
    {"callsign": "HOST", "muted": false},
    {"callsign": "PARTICIPANT1", "muted": false}
  ]
}
```

#### Get Conference Status

```
GET /debug/conference_status

Response:
{
  "roomId": "room-abc123",
  "participants": [
    {
      "callsign": "HOST",
      "peerId": "host-peer",
      "muted": false,
      "audioLevel": 0.45,
      "connectedAt": "2026-02-19T10:30:00Z"
    },
    {
      "callsign": "PARTICIPANT1",
      "peerId": "peer-001",
      "muted": false,
      "audioLevel": 0.32,
      "connectedAt": "2026-02-19T10:31:15Z"
    }
  ],
  "duration": 95,
  "maxParticipants": 6
}
```

#### Toggle Mute

```
POST /debug/conference_mute
{
  "roomId": "room-abc123",
  "muted": true
}

Response:
{
  "success": true,
  "muted": true
}
```

#### Leave/End Conference

```
POST /debug/conference_end
{
  "roomId": "room-abc123"
}

Response:
{
  "success": true,
  "duration": 245,
  "participantCount": 3
}
```

## Integration Points

### Event Detail Page

**Trigger**: Event with `isOnline: true` shows conference button

**Behavior**:
1. User clicks "Start Conference" button
2. `ConferenceHostPage` opens
3. Conference created with event title
4. URL/QR code generated for sharing
5. Participants can join via shared link

**Button Placement**:
- Prominent position in event header
- Icon: microphone or phone symbol
- Text: "Start/Join Conference"
- Only shown for online events

### ConferenceMixin Integration

**Added to both station servers**:
- `lib/cli/pure_station.dart` (CLI station)
- `lib/station.dart` (Desktop station)

**Provides**:
- Conference room creation and management
- Signaling message relay
- Participant tracking
- Room cleanup on disconnect

**Usage**:
```dart
class StationServer extends ... with ConferenceMixin {
  // Inherits conference methods
}

// In message handler:
if (message.type == 'conference_join') {
  await handleConferenceJoin(message);
}
```

### WebRTC Configuration

**Configuration** provided by `WebRTCConfig.forConference()`:
- Audio-only constraints
- Echo cancellation and noise suppression enabled
- Sampling rate optimized for voice
- STUN/TURN server configuration

**Usage**:
```dart
final config = WebRTCConfig.forConference();
final peerConnection = await createPeerConnection(config.rtcConfig);
```

## Complete Examples

### Example 1: LAN Mode Conference

```
1. Host launches desktop app on 192.168.1.100
2. User clicks "Start Conference"
3. ConferenceService detects no station connection → LAN mode
4. ConferenceSignalingServer starts on port 12345
5. URL generated: http://192.168.1.100:12345/?room=room-abc123
6. QR code displayed to user

7. Participant A scans QR code on same network
8. Browser connects to ws://192.168.1.100:12345
9. JavaScript sends: { type: "join", roomId: "room-abc123", callsign: "ALPHA1", offer: ... }
10. Host receives join, creates RTCPeerConnection for ALPHA1
11. Host sends answer back to participant
12. ICE candidates exchanged
13. Audio connection established
14. Both can hear each other (direct P2P)

15. Participant B joins same way
16. Host creates new peer connection for BETA2
17. Participant A's browser also creates peer connection to BETA2
18. All three connected in mesh: Host ↔ A, Host ↔ B, A ↔ B
```

### Example 2: Station Mode Conference

```
1. User opens desktop app connected to station
2. Clicks "Start Conference"
3. ConferenceService detects station connection → Station mode
4. Sends: POST /api/conference/create { roomId: "room-xyz789", title: "Team Meeting" }
5. Station creates room
6. User sees room ID: xyz789
7. Shares room ID or link: geogram://conference/xyz789

8. Participant A clicks link or enters room ID
9. Desktop app connects to station WebSocket
10. Sends: POST /api/conference/xyz789/join { callsign: "ALPHA1", offer: ... }
11. Station relays message to Host
12. Host creates RTCPeerConnection for ALPHA1
13. Host sends answer through station
14. Station relays answer to Participant A
15. ICE candidates exchanged through station relay
16. Audio connection established (direct P2P)

17. Participant B joins same way
18. Station maintains participant list
19. All participants connected in mesh
```

### Example 3: Web Browser Join (LAN Mode)

```
HTML (assets/conference/index.html):

<!DOCTYPE html>
<html>
<head>
  <title>Geogram Conference</title>
</head>
<body>
  <div id="status">Connecting...</div>
  <div id="participants">
    <h3>Participants:</h3>
    <ul id="participant-list"></ul>
  </div>

  <audio id="remote-audio" autoplay playsinline></audio>

  <div id="controls">
    <input type="text" id="callsign" placeholder="Your callsign">
    <button id="mute-btn">Mute</button>
    <button id="leave-btn">Leave</button>
  </div>

  <script src="conference-client.js"></script>
</body>
</html>

JavaScript (conference-client.js):

const params = new URLSearchParams(window.location.search);
const roomId = params.get('room');
const signalingUrl = params.get('signalingUrl');

let ws = new WebSocket(signalingUrl);
let peerConnections = {};
let localStream = null;

ws.onmessage = (event) => {
  const message = JSON.parse(event.data);

  if (message.type === 'join-response') {
    updateParticipantList(message.participants);
  } else if (message.type === 'answer') {
    peerConnections[message.peerId].setRemoteDescription(
      new RTCSessionDescription(message.answer)
    );
  } else if (message.type === 'ice-candidate') {
    peerConnections[message.peerId].addIceCandidate(message.candidate);
  }
};

async function joinConference() {
  localStream = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: true }
  });

  const peerConnection = new RTCPeerConnection({
    iceServers: [{ urls: ['stun:stun.l.google.com:19302'] }]
  });

  localStream.getTracks().forEach(track => {
    peerConnection.addTrack(track, localStream);
  });

  peerConnection.ontrack = (event) => {
    document.getElementById('remote-audio').srcObject = event.streams[0];
  };

  peerConnection.onicecandidate = (event) => {
    if (event.candidate) {
      ws.send(JSON.stringify({
        type: 'ice-candidate',
        roomId: roomId,
        candidate: event.candidate
      }));
    }
  };

  const offer = await peerConnection.createOffer();
  await peerConnection.setLocalDescription(offer);

  ws.send(JSON.stringify({
    type: 'join',
    roomId: roomId,
    callsign: document.getElementById('callsign').value,
    offer: offer
  }));

  peerConnections['host'] = peerConnection;
}

document.getElementById('leave-btn').addEventListener('click', () => {
  ws.close();
  localStream.getTracks().forEach(track => track.stop());
  window.close();
});
```

## Implementation Reference

### ConferenceService (Orchestration)

```dart
class ConferenceService {
  late ConferenceSignalingServer? _lanServer;
  late ConferencePeerManager _peerManager;
  String? _currentRoomId;
  ConferenceMode _mode = ConferenceMode.auto;

  // Start hosting a conference
  Future<ConferenceInfo> hostConference({
    required String title,
    ConferenceMode mode = ConferenceMode.auto,
  }) async {
    // Detect mode: LAN if no station, otherwise Station
    bool hasStation = await _isStationConnected();
    _mode = mode == ConferenceMode.auto
      ? (hasStation ? ConferenceMode.station : ConferenceMode.lan)
      : mode;

    if (_mode == ConferenceMode.lan) {
      return _hostLAN(title);
    } else {
      return _hostStation(title);
    }
  }

  Future<ConferenceInfo> _hostLAN(String title) async {
    _lanServer = ConferenceSignalingServer();
    final port = await _lanServer!.start();
    final localIp = await _getLocalIp();

    final roomId = _generateRoomId();
    final shareUrl = 'http://$localIp:$port/?room=$roomId';
    final qrCode = _generateQrCode(shareUrl);

    _currentRoomId = roomId;
    return ConferenceInfo(
      roomId: roomId,
      mode: ConferenceMode.lan,
      shareUrl: shareUrl,
      qrCode: qrCode,
    );
  }

  Future<ConferenceInfo> _hostStation(String title) async {
    // Call station API to create conference room
    final response = await _station.api.post(
      '/api/conference/create',
      body: { 'roomId': _generateRoomId(), 'title': title },
    );

    _currentRoomId = response['roomId'];
    return ConferenceInfo(
      roomId: _currentRoomId!,
      mode: ConferenceMode.station,
      stationUrl: _station.url,
    );
  }

  // Leave/end conference
  Future<void> endConference() async {
    if (_mode == ConferenceMode.lan) {
      await _lanServer?.stop();
    } else {
      await _station.api.post(
        '/api/conference/$_currentRoomId/leave',
        body: {},
      );
    }

    await _peerManager.closeAllConnections();
    _currentRoomId = null;
  }

  // Mute/unmute
  void setMuted(bool muted) {
    _peerManager.isMuted = muted;
    _peerManager.updateLocalAudioTracks();
  }
}
```

### ConferencePeerManager (WebRTC Peers)

```dart
class ConferencePeerManager {
  Map<String, RTCPeerConnection> peers = {};
  Map<String, MediaStream> remoteStreams = {};
  LocalMediaStream? localStream;
  bool isMuted = false;

  Future<void> addPeer({
    required String peerId,
    required RTCSessionDescription offer,
    required Function(RTCSessionDescription) onAnswer,
  }) async {
    final peerConnection = await _createPeerConnection();

    // Add local audio tracks
    localStream ??= await _captureLocalAudio();
    localStream!.getTracks().forEach((track) {
      peerConnection.addTrack(track, localStream!);
    });

    // Handle remote audio
    peerConnection.onTrack = (event) {
      remoteStreams[peerId] = event.streams.first;
      _handleRemoteAudio(peerId, event.streams.first);
    };

    // Set remote offer
    await peerConnection.setRemoteDescription(offer);

    // Create and send answer
    final answer = await peerConnection.createAnswer();
    await peerConnection.setLocalDescription(answer);
    onAnswer(answer);

    peers[peerId] = peerConnection;
  }

  void updateLocalAudioTracks() {
    // Enable/disable all local audio tracks based on isMuted
    localStream?.getTracks().forEach((track) {
      if (track.kind == 'audio') {
        track.enabled = !isMuted;
      }
    });
  }

  Future<void> closeAllConnections() async {
    for (final conn in peers.values) {
      await conn.close();
    }
    peers.clear();

    localStream?.getTracks().forEach((track) => track.stop());
    localStream = null;

    remoteStreams.clear();
  }

  Future<MediaStream> _captureLocalAudio() async {
    return await navigator.mediaDevices.getUserMedia(
      constraints: {
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        }
      },
    );
  }

  Future<RTCPeerConnection> _createPeerConnection() async {
    return await createPeerConnection({
      'iceServers': [
        {'urls': ['stun:stun.l.google.com:19302']},
      ],
    });
  }
}
```

### ConferenceSignalingServer (LAN Mode)

```dart
class ConferenceSignalingServer {
  late HttpServer _httpServer;
  late WebSocketChannel Function(WebSocket) _handleWebSocket;
  Map<String, WebSocketChannel> _clients = {};

  Future<int> start() async {
    _httpServer = await HttpServer.bind('0.0.0.0', 0);
    _httpServer.listen((request) {
      if (request.uri.path == '/' && request.uri.queryParameters['room'] != null) {
        // Serve HTML client
        _serveConferenceClient(request);
      } else if (WebSocketTransformer.isUpgradeRequest(request)) {
        // Upgrade to WebSocket
        _handleWebSocketConnection(request);
      }
    });

    return _httpServer.port;
  }

  void _handleWebSocketConnection(HttpRequest request) {
    WebSocketTransformer.upgrade(request).then((WebSocket webSocket) {
      final roomId = request.uri.queryParameters['room'];
      _clients[roomId] = webSocket.toWebSocketChannel();

      webSocket.listen((message) {
        _handleSignalingMessage(roomId, message);
      });
    });
  }

  void _handleSignalingMessage(String roomId, dynamic message) {
    final data = jsonDecode(message);

    if (data['type'] == 'join') {
      // Relay to host
      _relayToHost(roomId, data);
    } else if (data['type'] == 'ice-candidate') {
      // Relay ICE candidate
      _relayToHost(roomId, data);
    } else if (data['type'] == 'mute') {
      // Relay mute status
      _broadcastToRoom(roomId, data);
    }
  }

  void _relayToHost(String roomId, Map<String, dynamic> message) {
    // Host receives all signaling messages
    // In LAN mode, host is the peer manager
  }

  void _broadcastToRoom(String roomId, Map<String, dynamic> message) {
    // Broadcast to all clients in room
  }

  Future<void> stop() async {
    await _httpServer.close();
  }

  void _serveConferenceClient(HttpRequest request) {
    // Serve assets/conference/index.html with query parameters
  }
}
```

## Validation Rules

### Conference Creation

- Room ID must be unique (non-empty string)
- Conference title required
- Mode must be valid: "auto", "lan", or "station"
- Host must have working audio device (if LAN mode)
- Host must be connected to station (if Station mode explicitly requested)

### Participant Join

- Callsign must be non-empty
- Callsign must be unique within conference (same person joining twice is allowed, but shown as one participant)
- WebRTC offer must be valid SDP
- Room ID must exist and be active
- Max 6 participants per conference (enforced by closing oldest connection if exceeded)

### Signaling Messages

- All signaling messages must have valid JSON
- Required fields: `type`, `roomId` (or `peerId` for answer/ICE)
- `type` must be one of: join, answer, ice-candidate, mute, leave, participant-joined, participant-left
- Offer/answer/ICE candidates must be valid WebRTC objects
- Mute field must be boolean

### Audio Constraints

- Audio sampling rate: 16 kHz (speech optimized)
- Echo cancellation: enabled
- Noise suppression: enabled
- Auto gain control: enabled
- Mono (1 channel) sufficient, stereo (2 channel) acceptable

## Best Practices

### For Host

1. **Stable Connection**: Ensure stable internet (Station mode) or LAN (LAN mode)
2. **Audio Quality**: Use headphones to prevent echo
3. **Timing**: Start conference a few seconds before expected join time
4. **Sharing**: Clearly communicate join URL or QR code
5. **Participant Limit**: Be aware of 6-participant maximum (mesh topology limit)

### For Participants

1. **Audio Testing**: Test audio before joining (check microphone works)
2. **Mute When Listening**: Reduce echo and background noise
3. **Network Quality**: Use 5GHz WiFi or wired connection for best quality
4. **Room Setup**: Minimize background noise (close windows, etc.)
5. **Proximity**: Sit reasonably close to microphone

### For Developers

1. **Error Handling**: Gracefully handle connection failures and timeouts
2. **Cleanup**: Always close peer connections when participant leaves
3. **Resource Management**: Stop audio tracks when muted to save bandwidth
4. **Logging**: Log signaling messages for debugging (but not audio content)
5. **Testing**: Test with various network conditions (good, moderate, poor)

### For System Administrators

1. **STUN/TURN Servers**: Configure appropriate servers for NAT traversal
2. **Firewall**: Allow WebRTC ports (UDP range, typically 10000-20000)
3. **Bandwidth**: Monitor bandwidth usage during conferences
4. **Limits**: Set reasonable limits on concurrent conferences per user/device
5. **Monitoring**: Track conference creation and join failures

## Security Considerations

### Audio Privacy

- **P2P Encryption**: Audio is encrypted in transit between peers (SRTP)
- **Server Relay**: Station never receives audio data (signaling only)
- **No Recording**: System does not record audio by default
- **User Consent**: All participants aware conference is active

### Authorization

- **Open Access**: LAN mode accessible to anyone on local network with URL/QR
- **Station Auth**: Station mode inherits station authentication
- **No Passwords**: Conferences do not have passwords (rely on URL secrecy)
- **Callsign Trust**: Callsigns are self-reported (not cryptographically verified)

### DoS Prevention

- **Rate Limiting**: Limit conference creation per user/device
- **Resource Limits**: Max 6 participants per conference
- **Timeout**: Conferences expire if no activity for extended period
- **Port Binding**: LAN mode uses random high ports to avoid conflicts

### Network Security

- **STUN/TURN Security**: Use STUN/TURN over TLS (stun/turn over TCP or secure protocols)
- **Credential Rotation**: Rotate TURN credentials regularly
- **Certificate Pinning**: Consider certificate pinning for station connections
- **TLS**: All station connections use TLS encryption

## Related Documentation

- [WebRTC Integration](../webrtc.md) - WebRTC peer connection configuration
- [Station API](../station/api.md) - Station signaling relay endpoints
- [Events Format Specification](events-format-specification.md) - Integration with online events
- [Chat Format Specification](chat-format-specification.md) - Similar real-time communication pattern

## Change Log

### Version 1.0 (2026-02-19)

- Initial specification
- LAN mode (local network conferencing)
- Station mode (internet-based conferencing)
- Mesh topology (all participants connected to each other)
- WebRTC audio-only peer connections
- HTTP+WS signaling server for LAN mode
- ConferenceMixin for station-side signaling relay
- Web browser client for LAN mode joining
- QR code and URL sharing for LAN mode
- Mute/unmute control
- Max 6 participants per conference
- Event integration (conference button for online events)
- Debug API endpoints for testing

---

*This specification is part of the Geogram project.*
*License: Apache-2.0*
