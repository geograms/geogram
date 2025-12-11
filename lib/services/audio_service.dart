import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'log_service.dart';
import 'ogg_opus_writer.dart' hide OggOpusReader;

// Conditional imports for FFI-dependent code
import 'audio_native_stub.dart'
    if (dart.library.io) 'audio_native_ffi.dart';

// Conditional imports for platform-dependent code (File, Platform.isLinux)
import 'audio_platform_stub.dart'
    if (dart.library.io) 'audio_platform_io.dart';

/// Audio recording and playback service for voice messages.
///
/// Uses Opus/WebM format for optimal compression (~90 KB/min for speech).
/// Maximum recording duration: 30 seconds (~45 KB).
/// On Linux, uses ALSA directly via FFI (no external tools required).
class AudioService {
  static final AudioService _instance = AudioService._internal();
  factory AudioService() => _instance;
  AudioService._internal();

  final AudioRecorder _recorder = AudioRecorder();
  AudioPlayer? _player; // Lazy init - not available on Linux
  AlsaRecorder? _alsaRecorder;
  AlsaPlayer? _alsaPlayer;
  StreamSubscription? _alsaPositionSub;
  StreamSubscription? _alsaStateSub;

  // Playback state for Linux (when using ALSA)
  bool _alsaIsPlaying = false;
  Duration _alsaPosition = Duration.zero;
  Duration? _alsaDuration;

  // Recording state
  bool _isRecording = false;
  String? _currentRecordingPath;
  Timer? _durationTimer;
  Duration _recordingDuration = Duration.zero;

  // Stream controllers
  final _recordingDurationController = StreamController<Duration>.broadcast();
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();

  // Constants
  static const maxRecordingDuration = Duration(seconds: 30);
  static const sampleRate = 16000; // 16 kHz, optimal for speech
  static const bitRate = 12000; // 12 kbps, excellent compression for voice

  /// Stream of recording duration updates (every 100ms while recording)
  Stream<Duration> get recordingDurationStream => _recordingDurationController.stream;

  /// Stream of player state changes
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  /// Stream of playback position updates
  Stream<Duration> get positionStream => _positionController.stream;

  /// Current recording duration
  Duration get recordingDuration => _recordingDuration;

  /// Whether currently recording
  bool get isRecording => _isRecording;

  /// Whether currently playing
  bool get isPlaying => _alsaPlayer != null ? _alsaIsPlaying : (_player?.playing ?? false);

  /// Current playback position
  Duration get position => _alsaPlayer != null ? _alsaPosition : (_player?.position ?? Duration.zero);

  /// Total duration of loaded audio
  Duration? get duration => _alsaPlayer != null ? _alsaDuration : _player?.duration;

  /// Initialize the service and set up listeners
  Future<void> initialize() async {
    // On Linux, use ALSA for playback (just_audio has no Linux implementation)
    if (isLinuxPlatform) {
      LogService().log('AudioService initialized (Linux/ALSA mode)');
      return;
    }

    // Initialize just_audio for other platforms
    _player = AudioPlayer();

    // Forward player state changes
    _player!.playerStateStream.listen((state) {
      _playerStateController.add(state);
    });

    // Forward position updates
    _player!.positionStream.listen((position) {
      _positionController.add(position);
    });

    LogService().log('AudioService initialized');
  }

  /// Check if microphone permission is granted
  Future<bool> hasPermission() async {
    // On Linux with ALSA, permission is always granted (desktop)
    if (isLinuxPlatform && AlsaRecorder.isAvailable) {
      return true;
    }
    return await _recorder.hasPermission();
  }

  /// Last error message from recording attempt
  String? lastError;

  /// Start recording a voice message.
  /// Returns the output file path.
  Future<String?> startRecording() async {
    lastError = null;
    if (_isRecording) {
      LogService().log('AudioService: Already recording');
      return null;
    }

    try {
      // Generate output path
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:\-\.]'), '');

      // On Linux, use ALSA directly (no external tools required)
      if (isLinuxPlatform && AlsaRecorder.isAvailable) {
        return await _startAlsaRecording(tempDir.path, timestamp);
      }

      // Check permission for non-Linux platforms
      if (!await _recorder.hasPermission()) {
        LogService().log('AudioService: No microphone permission');
        return null;
      }

      // Choose encoder based on platform
      // - iOS: Use AAC/M4A
      // - Others: Use Opus/WebM for best compression
      String extension;
      AudioEncoder encoder;

      if (isIOSPlatform) {
        extension = 'm4a';
        encoder = AudioEncoder.aacLc;
      } else {
        extension = 'webm';
        encoder = AudioEncoder.opus;
      }

      _currentRecordingPath = '${tempDir.path}/voice_$timestamp.$extension';

      // Configure recording for speech optimization
      await _recorder.start(
        RecordConfig(
          encoder: encoder,
          sampleRate: sampleRate,
          bitRate: bitRate,
          numChannels: 1, // Mono for voice
        ),
        path: _currentRecordingPath!,
      );

      _isRecording = true;
      _recordingDuration = Duration.zero;

      // Start duration timer
      _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
        _recordingDuration += const Duration(milliseconds: 100);
        _recordingDurationController.add(_recordingDuration);

        // Auto-stop at max duration
        if (_recordingDuration >= maxRecordingDuration) {
          stopRecording();
        }
      });

      LogService().log('AudioService: Started recording to $_currentRecordingPath');
      return _currentRecordingPath;
    } catch (e, stackTrace) {
      lastError = e.toString();
      LogService().log('AudioService: Failed to start recording: $e');
      LogService().log('AudioService: Stack trace: $stackTrace');
      _isRecording = false;
      _currentRecordingPath = null;
      return null;
    }
  }

  /// Start recording using ALSA on Linux.
  Future<String?> _startAlsaRecording(String tempDir, String timestamp) async {
    try {
      _alsaRecorder = AlsaRecorder(sampleRate: sampleRate, channels: 1);
      _alsaRecorder!.initialize();

      _currentRecordingPath = '$tempDir/voice_$timestamp.wav';

      if (!await _alsaRecorder!.startRecording(_currentRecordingPath!)) {
        lastError = 'Failed to open audio device';
        LogService().log('AudioService: Failed to start ALSA recording');
        return null;
      }

      _isRecording = true;
      _recordingDuration = Duration.zero;

      // Start duration timer
      _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
        _recordingDuration += const Duration(milliseconds: 100);
        _recordingDurationController.add(_recordingDuration);

        // Auto-stop at max duration
        if (_recordingDuration >= maxRecordingDuration) {
          stopRecording();
        }
      });

      // Start background recording task
      _recordAlsaBackground();

      LogService().log('AudioService: Started ALSA recording to $_currentRecordingPath');
      return _currentRecordingPath;
    } catch (e, stackTrace) {
      lastError = e.toString();
      LogService().log('AudioService: Failed to start ALSA recording: $e');
      LogService().log('AudioService: Stack trace: $stackTrace');
      _isRecording = false;
      _currentRecordingPath = null;
      return null;
    }
  }

  // Buffer for ALSA recording samples
  List<int> _alsaSamples = [];

  /// Background task to continuously read from ALSA.
  Future<void> _recordAlsaBackground() async {
    _alsaSamples = [];
    final framesPerRead = sampleRate ~/ 10; // 100ms chunks

    while (_isRecording && _alsaRecorder != null && _alsaRecorder!.isRecording) {
      final frames = _alsaRecorder!.readFrames(framesPerRead);
      if (frames != null) {
        _alsaSamples.addAll(frames);
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Stop recording and return the file path.
  /// Returns null if not recording or if recording failed.
  /// On Linux, converts WAV to Opus/OGG using bundled libopus.
  Future<String?> stopRecording() async {
    if (!_isRecording) {
      return null;
    }

    _durationTimer?.cancel();
    _durationTimer = null;

    try {
      String? path;

      // Handle ALSA recording on Linux
      if (_alsaRecorder != null) {
        path = await _stopAlsaRecording();
      } else {
        path = await _recorder.stop();
      }

      _isRecording = false;

      LogService().log('AudioService: Stopped recording, duration: ${_recordingDuration.inSeconds}s');

      // Verify file exists and has content
      if (path != null) {
        final file = PlatformFile(path);
        if (await file.exists()) {
          final size = await file.length();
          LogService().log('AudioService: Recording saved, size: ${(size / 1024).toStringAsFixed(1)} KB');

          // On Linux, convert WAV to Opus/OGG
          if (isLinuxPlatform && path.endsWith('.wav')) {
            final oggPath = await _convertWavToOpus(path);
            if (oggPath != null) {
              // Delete the original WAV file
              await file.delete();
              return oggPath;
            }
            // If conversion failed, return WAV path as fallback
            LogService().log('AudioService: Opus conversion failed, using WAV');
          }

          return path;
        }
      }

      LogService().log('AudioService: Recording file not found');
      return null;
    } catch (e) {
      LogService().log('AudioService: Failed to stop recording: $e');
      _isRecording = false;
      return null;
    }
  }

  /// Stop ALSA recording and save to WAV file.
  Future<String?> _stopAlsaRecording() async {
    if (_alsaRecorder == null) return null;

    _alsaRecorder!.stopRecording();
    _isRecording = false;

    // Wait a bit for background task to finish
    await Future.delayed(const Duration(milliseconds: 100));

    if (_alsaSamples.isEmpty) {
      LogService().log('AudioService: No ALSA samples recorded');
      _alsaRecorder = null;
      return null;
    }

    // Write WAV file
    final wavData = _createWavFile(Int16List.fromList(_alsaSamples));
    final file = PlatformFile(_currentRecordingPath!);
    await file.writeAsBytes(wavData);

    LogService().log('AudioService: ALSA recording saved: ${_alsaSamples.length} samples, ${(wavData.length / 1024).toStringAsFixed(1)} KB');

    _alsaRecorder = null;
    _alsaSamples = [];
    return _currentRecordingPath;
  }

  /// Create a WAV file from PCM samples.
  Uint8List _createWavFile(Int16List samples) {
    final dataSize = samples.length * 2;
    final fileSize = 36 + dataSize;

    final buffer = ByteData(44 + dataSize);
    var offset = 0;

    // RIFF header
    buffer.setUint8(offset++, 0x52); // 'R'
    buffer.setUint8(offset++, 0x49); // 'I'
    buffer.setUint8(offset++, 0x46); // 'F'
    buffer.setUint8(offset++, 0x46); // 'F'
    buffer.setUint32(offset, fileSize, Endian.little);
    offset += 4;
    buffer.setUint8(offset++, 0x57); // 'W'
    buffer.setUint8(offset++, 0x41); // 'A'
    buffer.setUint8(offset++, 0x56); // 'V'
    buffer.setUint8(offset++, 0x45); // 'E'

    // fmt chunk
    buffer.setUint8(offset++, 0x66); // 'f'
    buffer.setUint8(offset++, 0x6D); // 'm'
    buffer.setUint8(offset++, 0x74); // 't'
    buffer.setUint8(offset++, 0x20); // ' '
    buffer.setUint32(offset, 16, Endian.little); // Chunk size
    offset += 4;
    buffer.setUint16(offset, 1, Endian.little); // Audio format (PCM)
    offset += 2;
    buffer.setUint16(offset, 1, Endian.little); // Channels (mono)
    offset += 2;
    buffer.setUint32(offset, sampleRate, Endian.little); // Sample rate
    offset += 4;
    buffer.setUint32(offset, sampleRate * 2, Endian.little); // Byte rate (mono, 16-bit)
    offset += 4;
    buffer.setUint16(offset, 2, Endian.little); // Block align (mono, 16-bit)
    offset += 2;
    buffer.setUint16(offset, 16, Endian.little); // Bits per sample
    offset += 2;

    // data chunk
    buffer.setUint8(offset++, 0x64); // 'd'
    buffer.setUint8(offset++, 0x61); // 'a'
    buffer.setUint8(offset++, 0x74); // 't'
    buffer.setUint8(offset++, 0x61); // 'a'
    buffer.setUint32(offset, dataSize, Endian.little);
    offset += 4;

    // PCM data
    for (var i = 0; i < samples.length; i++) {
      buffer.setInt16(offset, samples[i], Endian.little);
      offset += 2;
    }

    return buffer.buffer.asUint8List();
  }

  /// Convert a WAV file to Opus/OGG using bundled libopus.
  /// Returns the path to the OGG file, or null on failure.
  Future<String?> _convertWavToOpus(String wavPath) async {
    try {
      LogService().log('AudioService: Converting WAV to Opus...');

      // Read WAV file
      final (pcmSamples, wavSampleRate, wavChannels) = await WavReader.read(wavPath);

      // Create Opus encoder
      final encoder = OpusEncoder(
        sampleRate: wavSampleRate,
        channels: wavChannels,
        application: OPUS_APPLICATION_VOIP,
      );
      encoder.initialize();

      // Encode all samples
      final opusPackets = encoder.encodeAll(pcmSamples);
      encoder.dispose();

      if (opusPackets.isEmpty) {
        LogService().log('AudioService: No Opus packets generated');
        return null;
      }

      // Write to OGG file
      final oggPath = wavPath.replaceAll('.wav', '.ogg');
      final writer = OggOpusWriter(
        oggPath,
        sampleRate: wavSampleRate,
        channels: wavChannels,
        preSkip: 312, // Standard pre-skip for 16kHz
      );

      await writer.open();
      await writer.writeHeaders();

      // Samples per packet = sampleRate * frameSize(ms) / 1000
      // We use 20ms frames, so: 16000 * 20 / 1000 = 320 samples
      final samplesPerPacket = (wavSampleRate * 20) ~/ 1000;
      await writer.writePackets(opusPackets, samplesPerPacket);
      await writer.close();

      // Verify output
      final oggFile = PlatformFile(oggPath);
      if (await oggFile.exists()) {
        final oggSize = await oggFile.length();
        final wavSize = await PlatformFile(wavPath).length();
        final ratio = (oggSize / wavSize * 100).toStringAsFixed(1);
        LogService().log('AudioService: Opus conversion complete: ${(oggSize / 1024).toStringAsFixed(1)} KB ($ratio% of WAV)');
        return oggPath;
      }

      return null;
    } catch (e, stackTrace) {
      LogService().log('AudioService: Opus conversion error: $e');
      LogService().log('AudioService: Stack trace: $stackTrace');
      return null;
    }
  }

  /// Cancel recording and delete the file.
  Future<void> cancelRecording() async {
    if (!_isRecording) {
      return;
    }

    _durationTimer?.cancel();
    _durationTimer = null;

    try {
      // Handle ALSA recording on Linux
      if (_alsaRecorder != null) {
        _alsaRecorder!.stopRecording();
        _alsaRecorder = null;
        _alsaSamples = [];
      } else {
        await _recorder.stop();
      }
      _isRecording = false;

      // Delete the temporary file
      if (_currentRecordingPath != null) {
        final file = PlatformFile(_currentRecordingPath!);
        if (await file.exists()) {
          await file.delete();
        }
      }

      LogService().log('AudioService: Recording cancelled');
    } catch (e) {
      LogService().log('AudioService: Error cancelling recording: $e');
    }

    _currentRecordingPath = null;
    _recordingDuration = Duration.zero;
  }

  /// Load an audio file for playback.
  /// Returns the duration if successful, null otherwise.
  Future<Duration?> load(String filePath) async {
    try {
      // Stop any current playback
      await stop();

      // On Linux with local OGG files, use ALSA player
      if (isLinuxPlatform &&
          AlsaPlayer.isAvailable &&
          !filePath.startsWith('http') &&
          filePath.endsWith('.ogg')) {
        return await _loadAlsa(filePath);
      }

      Duration? duration;
      if (_player == null) {
        LogService().log('AudioService: just_audio not available on this platform');
        return null;
      }
      if (filePath.startsWith('http://') || filePath.startsWith('https://')) {
        duration = await _player!.setUrl(filePath);
      } else {
        duration = await _player!.setFilePath(filePath);
      }

      LogService().log('AudioService: Loaded ${filePath.split('/').last}, duration: ${duration?.inSeconds}s');
      return duration;
    } catch (e) {
      LogService().log('AudioService: Failed to load audio: $e');
      return null;
    }
  }

  /// Load OGG/Opus file for ALSA playback on Linux.
  Future<Duration?> _loadAlsa(String filePath) async {
    try {
      // Read and decode OGG/Opus file
      final (packets, sampleRate, channels, preSkip) =
          await OggOpusReader.read(filePath);

      if (packets.isEmpty) {
        LogService().log('AudioService: No audio packets in file');
        return null;
      }

      // Decode Opus to PCM
      final decoder = OpusDecoder(sampleRate: sampleRate, channels: channels);
      decoder.initialize();

      // Frame size for 20ms at given sample rate
      final frameSize = (sampleRate * 20) ~/ 1000;
      final pcmSamples = decoder.decodeAll(packets, frameSize);
      decoder.dispose();

      // Skip pre-skip samples
      final skipSamples = preSkip * channels;
      final samples = skipSamples < pcmSamples.length
          ? Int16List.fromList(pcmSamples.sublist(skipSamples))
          : pcmSamples;

      // Initialize ALSA player
      _alsaPlayer = AlsaPlayer();
      _alsaPlayer!.initialize();
      _alsaPlayer!.load(samples, sampleRate, channels);

      // Store duration
      _alsaDuration = _alsaPlayer!.duration;

      // Forward streams and update local state
      _alsaPositionSub = _alsaPlayer!.positionStream.listen((pos) {
        _alsaPosition = pos;
        _positionController.add(pos);
      });
      _alsaStateSub = _alsaPlayer!.stateStream.listen((state) {
        switch (state) {
          case AlsaPlayerState.playing:
            _alsaIsPlaying = true;
            _playerStateController.add(PlayerState(true, ProcessingState.ready));
            break;
          case AlsaPlayerState.paused:
            _alsaIsPlaying = false;
            _playerStateController.add(PlayerState(false, ProcessingState.ready));
            break;
          case AlsaPlayerState.completed:
            _alsaIsPlaying = false;
            _playerStateController.add(PlayerState(false, ProcessingState.completed));
            break;
          case AlsaPlayerState.stopped:
            _alsaIsPlaying = false;
            _playerStateController.add(PlayerState(false, ProcessingState.idle));
            break;
        }
      });

      final duration = _alsaDuration;
      LogService().log('AudioService: ALSA loaded ${filePath.split('/').last}, duration: ${duration?.inSeconds}s');
      return duration;
    } catch (e, stackTrace) {
      LogService().log('AudioService: Failed to load ALSA: $e');
      LogService().log('AudioService: Stack trace: $stackTrace');
      return null;
    }
  }

  /// Start or resume playback.
  Future<void> play() async {
    try {
      if (_alsaPlayer != null) {
        await _alsaPlayer!.play();
      } else if (_player != null) {
        await _player!.play();
      }
    } catch (e) {
      LogService().log('AudioService: Failed to play: $e');
    }
  }

  /// Pause playback.
  Future<void> pause() async {
    try {
      if (_alsaPlayer != null) {
        _alsaPlayer!.pause();
      } else if (_player != null) {
        await _player!.pause();
      }
    } catch (e) {
      LogService().log('AudioService: Failed to pause: $e');
    }
  }

  /// Stop playback and reset position.
  Future<void> stop() async {
    try {
      if (_alsaPlayer != null) {
        _alsaPlayer!.stop();
        _alsaPositionSub?.cancel();
        _alsaStateSub?.cancel();
        _alsaPlayer!.dispose();
        _alsaPlayer = null;
        _alsaIsPlaying = false;
        _alsaPosition = Duration.zero;
      } else if (_player != null) {
        await _player!.stop();
      }
    } catch (e) {
      LogService().log('AudioService: Failed to stop: $e');
    }
  }

  /// Seek to a specific position.
  Future<void> seek(Duration position) async {
    try {
      if (_alsaPlayer != null) {
        _alsaPlayer!.seek(position);
      } else if (_player != null) {
        await _player!.seek(position);
      }
    } catch (e) {
      LogService().log('AudioService: Failed to seek: $e');
    }
  }

  /// Get the duration of an audio file without loading it for playback.
  Future<int?> getFileDuration(String filePath) async {
    try {
      // On Linux with local OGG files, calculate from file
      if (isLinuxPlatform && !filePath.startsWith('http') && filePath.endsWith('.ogg')) {
        final (packets, sampleRate, _, _) = await OggOpusReader.read(filePath);
        // 20ms per packet
        final durationMs = packets.length * 20;
        return durationMs ~/ 1000;
      }

      // On Linux, just_audio is not available
      if (isLinuxPlatform) {
        LogService().log('AudioService: Cannot get duration - just_audio not available on Linux');
        return null;
      }

      final tempPlayer = AudioPlayer();
      Duration? duration;

      if (filePath.startsWith('http://') || filePath.startsWith('https://')) {
        duration = await tempPlayer.setUrl(filePath);
      } else {
        duration = await tempPlayer.setFilePath(filePath);
      }

      await tempPlayer.dispose();
      return duration?.inSeconds;
    } catch (e) {
      LogService().log('AudioService: Failed to get file duration: $e');
      return null;
    }
  }

  /// Clean up resources.
  Future<void> dispose() async {
    _durationTimer?.cancel();
    await _recorder.dispose();
    await _player?.dispose();
    _alsaPositionSub?.cancel();
    _alsaStateSub?.cancel();
    _alsaPlayer?.dispose();
    await _recordingDurationController.close();
    await _playerStateController.close();
    await _positionController.close();
  }
}

/// Player state enum matching just_audio's ProcessingState
enum VoicePlayerState {
  idle,
  loading,
  buffering,
  ready,
  completed,
}
