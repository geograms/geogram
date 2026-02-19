/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart';

import '../../services/log_service.dart';
import '../models/music_models.dart';
import 'music_audio_handler.dart';
import 'music_storage_service.dart';

/// Playback state
enum MusicPlaybackState {
  stopped,
  loading,
  playing,
  paused,
  completed,
  error,
}

/// Service for music playback using media_kit
class MusicPlaybackService {
  final MusicStorageService storage;
  final LogService _log = LogService();

  Player? _player;
  MusicLibrary? _library;
  MusicAudioHandler? _audioHandler;

  PlaybackQueue _queue = PlaybackQueue();
  PlayHistory _history = PlayHistory();
  MusicTrack? _currentTrack;

  // Playback state tracking
  MusicPlaybackState _state = MusicPlaybackState.stopped;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;

  // Track play start for history
  DateTime? _playStartTime;
  Duration _playStartPosition = Duration.zero;

  // Stream controllers
  final _stateController = StreamController<MusicPlaybackState>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _trackController = StreamController<MusicTrack?>.broadcast();
  final _queueController = StreamController<PlaybackQueue>.broadcast();
  final _volumeController = StreamController<double>.broadcast();

  MusicPlaybackService({required this.storage});

  // === Getters ===

  MusicPlaybackState get state => _state;
  Duration get position => _position;
  Duration get duration => _duration;
  double get volume => _volume;
  MusicTrack? get currentTrack => _currentTrack;
  PlaybackQueue get queue => _queue;
  PlayHistory get history => _history;
  bool get isPlaying => _state == MusicPlaybackState.playing;
  bool get hasNext => _queue.hasNext;
  bool get hasPrevious => _queue.hasPrevious;

  // === Streams ===

  Stream<MusicPlaybackState> get stateStream => _stateController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration> get durationStream => _durationController.stream;
  Stream<MusicTrack?> get trackStream => _trackController.stream;
  Stream<PlaybackQueue> get queueStream => _queueController.stream;
  Stream<double> get volumeStream => _volumeController.stream;

  /// Initialize the playback service
  Future<void> initialize(MusicLibrary library) async {
    _library = library;

    // Initialize media_kit
    MediaKit.ensureInitialized();
    _player = Player();

    // Set up player listeners
    _player!.stream.position.listen((pos) {
      _position = pos;
      _positionController.add(pos);
    });

    _player!.stream.duration.listen((dur) {
      _duration = dur;
      _durationController.add(dur);
    });

    _player!.stream.playing.listen((playing) {
      if (playing) {
        _updateState(MusicPlaybackState.playing);
      } else if (_state == MusicPlaybackState.playing) {
        _updateState(MusicPlaybackState.paused);
      }
    });

    _player!.stream.completed.listen((completed) {
      if (completed) {
        _onTrackCompleted();
      }
    });

    _player!.stream.error.listen((error) {
      _log.log('MusicPlaybackService: Player error: $error');
      _updateState(MusicPlaybackState.error);
    });

    // Load saved queue and history
    _queue = await storage.loadQueue();
    _history = await storage.loadHistory();

    // Restore last playing track position
    if (_queue.isNotEmpty && _queue.currentTrackId != null) {
      final track = _library?.getTrack(_queue.currentTrackId!);
      if (track != null) {
        _currentTrack = track;
        _trackController.add(track);
        // Don't auto-play, just restore state
      }
    }

    // Initialize Android media session (notification + lock screen controls)
    if (Platform.isAndroid) {
      try {
        _audioHandler = await AudioService.init(
          builder: () => MusicAudioHandler(this, _library!),
          config: const AudioServiceConfig(
            androidNotificationChannelId: 'com.geogram.music',
            androidNotificationChannelName: 'Music',
            androidNotificationOngoing: true,
            androidStopForegroundOnPause: true,
          ),
        );
        _log.log('MusicPlaybackService: AudioService initialized');
      } catch (e) {
        _log.log('MusicPlaybackService: AudioService init failed: $e');
      }
    }

    _log.log('MusicPlaybackService: Initialized');
  }

  void _updateState(MusicPlaybackState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  /// Play a track by ID
  Future<void> playTrack(String trackId) async {
    final track = _library?.getTrack(trackId);
    if (track == null) {
      _log.log('MusicPlaybackService: Track not found: $trackId');
      return;
    }

    await _playTrack(track);
  }

  /// Play a track directly
  Future<void> _playTrack(MusicTrack track) async {
    if (_player == null) return;

    try {
      _updateState(MusicPlaybackState.loading);

      // Record play start
      _playStartTime = DateTime.now();
      _playStartPosition = Duration.zero;

      // Check file exists
      final file = File(track.filePath);
      if (!await file.exists()) {
        _log.log('MusicPlaybackService: File not found: ${track.filePath}');
        _updateState(MusicPlaybackState.error);
        return;
      }

      // Update current track
      _currentTrack = track;
      _trackController.add(track);

      // Update queue if not already at this track
      if (_queue.currentTrackId != track.id) {
        // Find track in queue or add it
        final index = _queue.trackIds.indexOf(track.id);
        if (index >= 0) {
          _queue = _queue.copyWith(
            currentIndex: index,
            updatedAt: DateTime.now(),
          );
        } else {
          // Insert at current position
          final newTracks = List<String>.from(_queue.trackIds);
          final insertIndex = _queue.currentIndex + 1;
          newTracks.insert(insertIndex.clamp(0, newTracks.length), track.id);
          _queue = _queue.copyWith(
            trackIds: newTracks,
            currentIndex: insertIndex.clamp(0, newTracks.length - 1),
            updatedAt: DateTime.now(),
          );
        }
        _queueController.add(_queue);
        await storage.saveQueue(_queue);
      }

      // Open and play
      await _player!.open(Media(track.filePath));
      await _player!.play();

      _log.log('MusicPlaybackService: Playing ${track.title}');
    } catch (e) {
      _log.log('MusicPlaybackService: Error playing track: $e');
      _updateState(MusicPlaybackState.error);
    }
  }

  /// Play an album
  Future<void> playAlbum(String albumId, {int startIndex = 0}) async {
    if (_library == null) return;

    final tracks = _library!.getAlbumTracks(albumId);
    if (tracks.isEmpty) return;

    // Set up queue with album tracks
    _queue = PlaybackQueue(
      trackIds: tracks.map((t) => t.id).toList(),
      currentIndex: startIndex.clamp(0, tracks.length - 1),
      updatedAt: DateTime.now(),
    );
    _queueController.add(_queue);
    await storage.saveQueue(_queue);

    // Play first track
    await _playTrack(tracks[startIndex.clamp(0, tracks.length - 1)]);
  }

  /// Play a list of tracks
  Future<void> playTracks(List<MusicTrack> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) return;

    // Set up queue
    _queue = PlaybackQueue(
      trackIds: tracks.map((t) => t.id).toList(),
      currentIndex: startIndex.clamp(0, tracks.length - 1),
      updatedAt: DateTime.now(),
    );
    _queueController.add(_queue);
    await storage.saveQueue(_queue);

    // Play first track
    await _playTrack(tracks[startIndex.clamp(0, tracks.length - 1)]);
  }

  /// Add track to queue
  Future<void> addToQueue(String trackId) async {
    final newTracks = List<String>.from(_queue.trackIds);
    newTracks.add(trackId);

    _queue = _queue.copyWith(
      trackIds: newTracks,
      updatedAt: DateTime.now(),
    );
    _queueController.add(_queue);
    await storage.saveQueue(_queue);
  }

  /// Clear the queue
  Future<void> clearQueue() async {
    await stop();
    _queue = PlaybackQueue();
    _queueController.add(_queue);
    await storage.saveQueue(_queue);
  }

  /// Resume playback
  Future<void> play() async {
    if (_player == null) return;

    if (_state == MusicPlaybackState.paused) {
      await _player!.play();
      _playStartTime = DateTime.now();
      _playStartPosition = _position;
    } else if (_currentTrack != null) {
      await _playTrack(_currentTrack!);
    } else if (_queue.isNotEmpty && _queue.currentTrackId != null) {
      final track = _library?.getTrack(_queue.currentTrackId!);
      if (track != null) {
        await _playTrack(track);
      }
    }
  }

  /// Pause playback
  Future<void> pause() async {
    if (_player == null) return;
    await _player!.pause();
    _recordPlayEvent(completed: false);
  }

  /// Stop playback
  Future<void> stop() async {
    if (_player == null) return;

    _recordPlayEvent(completed: false);

    await _player!.stop();
    _position = Duration.zero;
    _positionController.add(_position);
    _updateState(MusicPlaybackState.stopped);
  }

  /// Seek to position
  Future<void> seek(Duration position) async {
    if (_player == null) return;
    await _player!.seek(position);
  }

  /// Skip to next track
  Future<void> next() async {
    if (_queue.isEmpty || _library == null) return;

    _recordPlayEvent(completed: false);

    final nextIndex = _queue.getNextIndex();
    if (nextIndex == _queue.currentIndex && _queue.repeat == RepeatMode.off) {
      // At end of queue with no repeat
      await stop();
      return;
    }

    _queue = _queue.copyWith(
      currentIndex: nextIndex,
      positionSeconds: 0,
      updatedAt: DateTime.now(),
    );
    _queueController.add(_queue);
    await storage.saveQueue(_queue);

    final trackId = _queue.currentTrackId;
    if (trackId != null) {
      final track = _library!.getTrack(trackId);
      if (track != null) {
        await _playTrack(track);
      }
    }
  }

  /// Skip to previous track
  Future<void> previous() async {
    if (_queue.isEmpty || _library == null) return;

    // If more than 3 seconds into track, restart it instead
    if (_position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }

    _recordPlayEvent(completed: false);

    final prevIndex = _queue.getPreviousIndex();
    _queue = _queue.copyWith(
      currentIndex: prevIndex,
      positionSeconds: 0,
      updatedAt: DateTime.now(),
    );
    _queueController.add(_queue);
    await storage.saveQueue(_queue);

    final trackId = _queue.currentTrackId;
    if (trackId != null) {
      final track = _library!.getTrack(trackId);
      if (track != null) {
        await _playTrack(track);
      }
    }
  }

  /// Toggle shuffle
  Future<void> toggleShuffle() async {
    if (_queue.shuffle) {
      _queue = _queue.unshuffled();
    } else {
      _queue = _queue.shuffled();
    }
    _queueController.add(_queue);
    await storage.saveQueue(_queue);
  }

  /// Cycle repeat mode
  Future<void> cycleRepeat() async {
    _queue = _queue.cycleRepeat();
    _queueController.add(_queue);
    await storage.saveQueue(_queue);
  }

  /// Set volume (0.0 to 1.0)
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    _volumeController.add(_volume);
    if (_player != null) {
      await _player!.setVolume(_volume * 100);
    }
  }

  /// Handle track completion
  void _onTrackCompleted() {
    _recordPlayEvent(completed: true);

    if (_queue.repeat == RepeatMode.one) {
      // Repeat current track
      seek(Duration.zero);
      play();
    } else {
      // Move to next track
      next();
    }
  }

  /// Record play event to history
  void _recordPlayEvent({required bool completed}) {
    if (_currentTrack == null || _playStartTime == null) return;

    final playedDuration = _position - _playStartPosition;
    final playedSeconds = playedDuration.inSeconds;

    // Only record if played more than a few seconds
    if (playedSeconds < 5) return;

    final event = PlayEvent(
      trackId: _currentTrack!.id,
      albumId: _currentTrack!.albumId,
      artistId: _currentTrack!.artistId,
      playedAt: _playStartTime!,
      durationPlayedSeconds: playedSeconds,
      completed: completed,
    );

    _history = _history.recordPlay(event);
    storage.saveHistory(_history);

    _playStartTime = null;
  }

  /// Save current position to queue
  Future<void> savePosition() async {
    if (_queue.isEmpty) return;

    _queue = _queue.copyWith(
      positionSeconds: _position.inSeconds.toDouble(),
      updatedAt: DateTime.now(),
    );
    await storage.saveQueue(_queue);
  }

  /// Dispose resources
  Future<void> dispose() async {
    await savePosition();
    _recordPlayEvent(completed: false);

    await _audioHandler?.stop();
    await _audioHandler?.dispose();
    _audioHandler = null;

    await _player?.dispose();
    _player = null;

    await _stateController.close();
    await _positionController.close();
    await _durationController.close();
    await _trackController.close();
    await _queueController.close();
    await _volumeController.close();
  }
}
