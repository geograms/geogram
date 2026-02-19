/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../models/music_library.dart';
import '../models/music_track.dart';
import 'music_playback_service.dart';

/// Bridges audio_service (Android media session / notification) to MusicPlaybackService.
class MusicAudioHandler extends BaseAudioHandler with SeekHandler {
  final MusicPlaybackService _playback;
  final MusicLibrary _library;
  final List<StreamSubscription> _subs = [];

  MusicAudioHandler(this._playback, this._library) {
    _listenToPlayback();
  }

  void _listenToPlayback() {
    // Track changes → update mediaItem
    _subs.add(_playback.trackStream.listen(_onTrackChanged));

    // State changes → update playbackState
    _subs.add(_playback.stateStream.listen((_) => _updatePlaybackState()));

    // Position changes → update playbackState
    _subs.add(_playback.positionStream.listen((_) => _updatePlaybackState()));

    // Duration changes → update mediaItem duration
    _subs.add(_playback.durationStream.listen((_) {
      if (_playback.currentTrack != null) {
        _onTrackChanged(_playback.currentTrack);
      }
    }));

    // Emit initial state
    _updatePlaybackState();
  }

  void _onTrackChanged(MusicTrack? track) {
    if (track == null) {
      mediaItem.add(null);
      return;
    }

    Uri? artUri;
    if (track.albumId != null) {
      final album = _library.getAlbum(track.albumId!);
      if (album?.artwork != null) {
        artUri = Uri.file(album!.artwork!);
      }
    }

    mediaItem.add(MediaItem(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album ?? '',
      duration: _playback.duration > Duration.zero
          ? _playback.duration
          : Duration(seconds: track.durationSeconds),
      artUri: artUri,
    ));
  }

  void _updatePlaybackState() {
    final controls = <MediaControl>[
      MediaControl.skipToPrevious,
      if (_playback.isPlaying) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
      MediaControl.stop,
    ];

    final systemActions = {
      MediaAction.seek,
      MediaAction.seekForward,
      MediaAction.seekBackward,
    };

    AudioProcessingState processingState;
    bool playing;

    switch (_playback.state) {
      case MusicPlaybackState.playing:
        processingState = AudioProcessingState.ready;
        playing = true;
        break;
      case MusicPlaybackState.paused:
        processingState = AudioProcessingState.ready;
        playing = false;
        break;
      case MusicPlaybackState.loading:
        processingState = AudioProcessingState.loading;
        playing = false;
        break;
      case MusicPlaybackState.error:
        processingState = AudioProcessingState.error;
        playing = false;
        break;
      case MusicPlaybackState.stopped:
      case MusicPlaybackState.completed:
        processingState = AudioProcessingState.idle;
        playing = false;
        break;
    }

    playbackState.add(PlaybackState(
      controls: controls,
      systemActions: systemActions,
      processingState: processingState,
      playing: playing,
      updatePosition: _playback.position,
      updateTime: DateTime.now(),
    ));
  }

  // === Control callbacks (from notification / lock screen) ===

  @override
  Future<void> play() => _playback.play();

  @override
  Future<void> pause() => _playback.pause();

  @override
  Future<void> stop() async {
    await _playback.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _playback.seek(position);

  @override
  Future<void> skipToNext() => _playback.next();

  @override
  Future<void> skipToPrevious() => _playback.previous();

  /// Clean up subscriptions
  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }
}
