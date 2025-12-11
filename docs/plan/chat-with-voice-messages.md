# Voice Messages for 1:1 Direct Messages

**Version**: 1.0
**Created**: 2025-12-11
**Status**: Planning

## Overview

Add voice message support to 1:1 direct messages (DMs). Voice messages are recorded audio clips that can be sent and played back within conversations. This follows the existing file attachment pattern used in chat channels.

## Requirements

### Functional Requirements
1. Record voice messages with tap-to-record UI
2. Preview recording before sending
3. Send voice message as part of DM conversation
4. Play voice messages inline with audio controls
5. Show recording duration/playback progress
6. Support all platforms: Web, Android, iOS, Linux, macOS, Windows

### Non-Functional Requirements
1. **Bandwidth efficiency**: Some connections use Bluetooth (~2 Mbps max)
2. **Cross-platform codec**: Must play on all browsers and native platforms
3. **Small file size**: Target < 50 KB for 30-second voice message
4. **Low latency**: Recording should start immediately
5. **Download-before-play**: Show download indicator, only enable playback when file is fully downloaded
6. **No autoplay**: User must tap to play

## Audio Format Selection

### Recommended: Opus in WebM Container (`.webm`)

| Criteria | Opus/WebM | AAC/M4A | MP3 |
|----------|-----------|---------|-----|
| Browser Support | All modern | Safari only native | All |
| Compression | **Best** (~6-12 kbps for voice) | Good (~32 kbps) | Poor (~64 kbps) |
| Quality at low bitrate | **Excellent** | Good | Poor |
| Flutter support | `just_audio` | `just_audio` | `just_audio` |
| Native recording | `record` package | `record` package | `record` package |
| 1-min file size | **~50-90 KB** | ~240 KB | ~480 KB |

**Rationale**: Opus codec is specifically designed for speech, provides excellent compression at low bitrates, and is supported by all modern browsers. WebM container is well-supported on web platforms.

### Fallback: AAC/M4A (`.m4a`)

For platforms where WebM recording isn't available, use AAC in M4A container as fallback.

### Encoding Settings

```
Format: Opus/WebM
Sample Rate: 16000 Hz (speech-optimized)
Channels: Mono
Bitrate: 12000 bps (12 kbps)
```

**Result**: ~90 KB per minute, excellent voice quality

## Storage Strategy

### Directory Structure

Following the existing chat format specification, voice messages are stored as files:

```
~/.local/share/geogram/dm/{OTHER_CALLSIGN}/
├── messages.txt          # DM conversation file
└── files/                # Attached files including voice
    ├── voice_20251211_143025.webm
    └── voice_20251211_144512.webm
```

### Filename Convention

```
voice_{YYYYMMDD}_{HHMMSS}.webm
```

Example: `voice_20251211_143025.webm` (December 11, 2025, 14:30:25)

### Message Metadata

Extend existing metadata pattern with `voice` field:

```
> 2025-12-11 14:30_25 -- X1ABCD
--> voice: voice_20251211_143025.webm
--> duration: 12
```

**Fields**:
- `voice`: Filename of voice recording
- `duration`: Duration in seconds (for UI display without decoding)

## Implementation Plan

### Phase 1: Dependencies & Audio Service

**Add to `pubspec.yaml`:**
```yaml
dependencies:
  record: ^5.1.0        # Cross-platform audio recording
  just_audio: ^0.9.36   # Cross-platform audio playback
```

**Create:** `lib/services/audio_service.dart`

```dart
class AudioService {
  static final AudioService _instance = AudioService._internal();
  factory AudioService() => _instance;

  // Recording
  Future<void> startRecording(String outputPath);
  Future<String?> stopRecording();  // Returns file path
  Future<void> cancelRecording();
  Stream<Duration> get recordingDuration;
  bool get isRecording;

  // Playback
  Future<void> play(String filePath);
  Future<void> pause();
  Future<void> stop();
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<PlayerState> get playerState;
}
```

### Phase 2: Chat Message Model Extension

**File:** `lib/models/chat_message.dart`

Add voice message helpers (following existing `hasFile` pattern):

```dart
/// Check if message is a voice message
bool get hasVoice => hasMeta('voice');

/// Get voice filename
String? get voiceFile => getMeta('voice');

/// Get voice duration in seconds
int? get voiceDuration {
  final dur = getMeta('duration');
  return dur != null ? int.tryParse(dur) : null;
}
```

### Phase 3: Voice Recording Widget

**Create:** `lib/widgets/voice_recorder_widget.dart`

Inline recording widget that replaces message input when recording:

```
┌─────────────────────────────────────────────────────────┐
│  [Cancel]    ●  0:12    ═══════════════════   [Send]   │
└─────────────────────────────────────────────────────────┘
```

**States**:
1. **Idle**: Hidden (message input shown instead)
2. **Recording**: Red dot, timer (max 30s), cancel/send buttons
3. **Preview**: Play button, progress bar, cancel/send buttons (no waveform)

### Phase 4: Voice Playback Widget

**Create:** `lib/widgets/voice_player_widget.dart`

Inline player widget for displaying voice messages in chat:

```
┌─────────────────────────────────────────────┐
│  [▶]  0:05 / 0:12  ═══●════════════════    │
└─────────────────────────────────────────────┘
```

**States**:
1. **Downloading**: Download indicator (spinner/progress), disabled play button
2. **Ready**: Play button enabled, shows total duration
3. **Playing**: Pause button, current position / total duration, seekable progress bar
4. **Paused**: Play button, current position / total duration

**Features**:
- Download indicator when fetching from remote device
- Play button disabled until download complete (no streaming)
- Play/pause toggle
- Current position / total duration
- Seekable progress bar
- Auto-stop when complete
- No autoplay

### Phase 5: DM Chat Page Integration

**File:** `lib/pages/dm_chat_page.dart`

1. Enable file attachments: `allowFiles: true`
2. Add voice record button to message input area
3. Handle voice message in `_sendMessage()`
4. Display voice messages using `VoicePlayerWidget`

**UI Flow**:
```
Normal Input:
┌───────────────────────────────────────────────────────┐
│  [🎤]  Type a message...                      [Send]  │
└───────────────────────────────────────────────────────┘

Recording (after tap 🎤):
┌───────────────────────────────────────────────────────┐
│  [✕]     ●  0:08     ══════════════════       [✓]    │
└───────────────────────────────────────────────────────┘
```

### Phase 6: Direct Message Service Updates

**File:** `lib/services/direct_message_service.dart`

1. Copy voice files to DM `files/` folder (like chat attachments)
2. Include `voice` and `duration` in message metadata
3. Handle voice file sync between devices

### Phase 7: Message Bubble Widget Updates

**File:** `lib/widgets/message_bubble_widget.dart`

Display voice messages with inline player:

```dart
if (message.hasVoice) {
  children.add(
    VoicePlayerWidget(
      filePath: _getVoiceFilePath(message),
      duration: message.voiceDuration,
    ),
  );
}
```

## Files to Create

| File | Purpose |
|------|---------|
| `lib/services/audio_service.dart` | Recording and playback service |
| `lib/widgets/voice_recorder_widget.dart` | Recording UI component |
| `lib/widgets/voice_player_widget.dart` | Playback UI component |

## Files to Modify

| File | Changes |
|------|---------|
| `pubspec.yaml` | Add `record` and `just_audio` packages |
| `lib/models/chat_message.dart` | Add `hasVoice`, `voiceFile`, `voiceDuration` |
| `lib/pages/dm_chat_page.dart` | Enable voice recording, add record button |
| `lib/services/direct_message_service.dart` | Handle voice file storage |
| `lib/widgets/message_bubble_widget.dart` | Display voice player for voice messages |
| `lib/widgets/message_input_widget.dart` | Add microphone button |
| `docs/apps/chat-format-specification.md` | Document voice metadata fields |

## Bandwidth Optimization

### Strategies
1. **Opus codec at 12 kbps**: ~90 KB/minute (vs 480 KB for MP3)
2. **16 kHz sample rate**: Optimal for speech, not music
3. **Mono channel**: Voice doesn't need stereo
4. **Maximum recording limit**: 30 seconds (~45 KB max)

### Bluetooth Considerations
- BLE: ~2 Mbps theoretical, ~200 KB/s practical
- 45 KB voice message (30s): ~0.25 seconds transfer time
- Well within acceptable limits even on slow connections

## Platform-Specific Notes

### Web
- Use `MediaRecorder` API with `audio/webm;codecs=opus`
- Playback via `<audio>` element or Web Audio API

### Android
- `record` package uses MediaRecorder
- May need RECORD_AUDIO permission

### iOS
- `record` package uses AVAudioRecorder
- May need microphone permission in Info.plist

### Desktop (Linux/macOS/Windows)
- `record` package uses native APIs
- No special permissions needed

## Security Considerations

1. **Permissions**: Request microphone permission before recording
2. **Storage**: Voice files stored locally, synced like other messages
3. **No cloud storage**: Files only on user devices
4. **Signature support**: Voice messages can be NOSTR-signed like text

## Testing Plan

1. **Unit tests**: AudioService recording/playback
2. **Widget tests**: VoiceRecorderWidget states and transitions
3. **Integration tests**: Full send/receive flow on Android devices
4. **Cross-platform**: Test on web, Android, iOS, desktop

## Implementation Order

1. Add dependencies (`record`, `just_audio`)
2. Create `AudioService` with basic record/play
3. Create `VoicePlayerWidget` (playback first - simpler)
4. Create `VoiceRecorderWidget`
5. Update `ChatMessage` model
6. Update `DirectMessageService` for file handling
7. Integrate into `dm_chat_page.dart`
8. Update `message_bubble_widget.dart`
9. Update documentation
10. Test on all platforms

## Success Criteria

- [ ] Record voice message up to 30 seconds
- [ ] Preview before sending
- [ ] Send via DM with < 50 KB for 30 seconds
- [ ] Receive with download indicator
- [ ] Play only after fully downloaded (no streaming)
- [ ] No autoplay
- [ ] Works on: Web, Android, iOS, Linux, macOS, Windows
- [ ] Playback controls: play/pause, seek, progress
- [ ] Duration shown before playing
- [ ] Graceful handling of microphone permission denial

## Decisions Made

1. **No autoplay**: User must tap to play
2. **No waveform visualization**: Keep UI simple for v1
3. **Maximum recording**: 30 seconds
4. **Download-before-play**: Show download indicator, only enable playback when complete
5. **Transcription**: Future feature, not in v1

---

*This plan follows the existing file attachment pattern from chat-format-specification.md*
