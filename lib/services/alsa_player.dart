/*
 * ALSA audio player via FFI for Linux.
 * Plays PCM audio directly using libasound, no external tools required.
 */

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'log_service.dart';

// ALSA constants
const int SND_PCM_STREAM_PLAYBACK = 0;
const int SND_PCM_ACCESS_RW_INTERLEAVED = 3;
const int SND_PCM_FORMAT_S16_LE = 2;

/// Opaque ALSA PCM handle
final class SndPcmT extends Opaque {}

/// Opaque ALSA hardware params handle
final class SndPcmHwParamsT extends Opaque {}

// FFI function signatures
typedef SndPcmOpenNative = Int32 Function(
    Pointer<Pointer<SndPcmT>> pcm, Pointer<Utf8> name, Int32 stream, Int32 mode);
typedef SndPcmOpen = int Function(
    Pointer<Pointer<SndPcmT>> pcm, Pointer<Utf8> name, int stream, int mode);

typedef SndPcmCloseNative = Int32 Function(Pointer<SndPcmT> pcm);
typedef SndPcmClose = int Function(Pointer<SndPcmT> pcm);

typedef SndPcmHwParamsMallocNative = Int32 Function(Pointer<Pointer<SndPcmHwParamsT>> ptr);
typedef SndPcmHwParamsMalloc = int Function(Pointer<Pointer<SndPcmHwParamsT>> ptr);

typedef SndPcmHwParamsFreeNative = Void Function(Pointer<SndPcmHwParamsT> ptr);
typedef SndPcmHwParamsFree = void Function(Pointer<SndPcmHwParamsT> ptr);

typedef SndPcmHwParamsAnyNative = Int32 Function(
    Pointer<SndPcmT> pcm, Pointer<SndPcmHwParamsT> params);
typedef SndPcmHwParamsAny = int Function(
    Pointer<SndPcmT> pcm, Pointer<SndPcmHwParamsT> params);

typedef SndPcmHwParamsSetAccessNative = Int32 Function(
    Pointer<SndPcmT> pcm, Pointer<SndPcmHwParamsT> params, Int32 access);
typedef SndPcmHwParamsSetAccess = int Function(
    Pointer<SndPcmT> pcm, Pointer<SndPcmHwParamsT> params, int access);

typedef SndPcmHwParamsSetFormatNative = Int32 Function(
    Pointer<SndPcmT> pcm, Pointer<SndPcmHwParamsT> params, Int32 format);
typedef SndPcmHwParamsSetFormat = int Function(
    Pointer<SndPcmT> pcm, Pointer<SndPcmHwParamsT> params, int format);

typedef SndPcmHwParamsSetRateNearNative = Int32 Function(Pointer<SndPcmT> pcm,
    Pointer<SndPcmHwParamsT> params, Pointer<Uint32> rate, Pointer<Int32> dir);
typedef SndPcmHwParamsSetRateNear = int Function(Pointer<SndPcmT> pcm,
    Pointer<SndPcmHwParamsT> params, Pointer<Uint32> rate, Pointer<Int32> dir);

typedef SndPcmHwParamsSetChannelsNative = Int32 Function(
    Pointer<SndPcmT> pcm, Pointer<SndPcmHwParamsT> params, Uint32 channels);
typedef SndPcmHwParamsSetChannels = int Function(
    Pointer<SndPcmT> pcm, Pointer<SndPcmHwParamsT> params, int channels);

typedef SndPcmHwParamsNative = Int32 Function(
    Pointer<SndPcmT> pcm, Pointer<SndPcmHwParamsT> params);
typedef SndPcmHwParams = int Function(
    Pointer<SndPcmT> pcm, Pointer<SndPcmHwParamsT> params);

typedef SndPcmPrepareNative = Int32 Function(Pointer<SndPcmT> pcm);
typedef SndPcmPrepare = int Function(Pointer<SndPcmT> pcm);

typedef SndPcmWriteiNative = Int64 Function(
    Pointer<SndPcmT> pcm, Pointer<Void> buffer, Uint64 frames);
typedef SndPcmWritei = int Function(
    Pointer<SndPcmT> pcm, Pointer<Void> buffer, int frames);

typedef SndPcmDropNative = Int32 Function(Pointer<SndPcmT> pcm);
typedef SndPcmDrop = int Function(Pointer<SndPcmT> pcm);

typedef SndPcmDrainNative = Int32 Function(Pointer<SndPcmT> pcm);
typedef SndPcmDrain = int Function(Pointer<SndPcmT> pcm);

typedef SndStrErrorNative = Pointer<Utf8> Function(Int32 errnum);
typedef SndStrError = Pointer<Utf8> Function(int errnum);

/// ALSA-based audio player for Linux.
/// Plays PCM audio directly via libasound, no external tools needed.
class AlsaPlayer {
  static DynamicLibrary? _lib;
  Pointer<SndPcmT>? _pcm;
  bool _isPlaying = false;
  bool _isPaused = false;
  bool _stopRequested = false;

  late SndPcmOpen _sndPcmOpen;
  late SndPcmClose _sndPcmClose;
  late SndPcmHwParamsMalloc _sndPcmHwParamsMalloc;
  late SndPcmHwParamsFree _sndPcmHwParamsFree;
  late SndPcmHwParamsAny _sndPcmHwParamsAny;
  late SndPcmHwParamsSetAccess _sndPcmHwParamsSetAccess;
  late SndPcmHwParamsSetFormat _sndPcmHwParamsSetFormat;
  late SndPcmHwParamsSetRateNear _sndPcmHwParamsSetRateNear;
  late SndPcmHwParamsSetChannels _sndPcmHwParamsSetChannels;
  late SndPcmHwParams _sndPcmHwParams;
  late SndPcmPrepare _sndPcmPrepare;
  late SndPcmWritei _sndPcmWritei;
  late SndPcmDrop _sndPcmDrop;
  late SndPcmDrain _sndPcmDrain;
  late SndStrError _sndStrError;

  int _sampleRate = 16000;
  int _channels = 1;
  Int16List? _samples;
  int _position = 0;

  // Stream controllers for state updates
  final _positionController = StreamController<Duration>.broadcast();
  final _stateController = StreamController<AlsaPlayerState>.broadcast();

  Stream<Duration> get positionStream => _positionController.stream;
  Stream<AlsaPlayerState> get stateStream => _stateController.stream;

  AlsaPlayer();

  /// Check if ALSA is available on this system.
  static bool get isAvailable {
    if (!Platform.isLinux) return false;
    try {
      _loadLibrary();
      return true;
    } catch (e) {
      return false;
    }
  }

  static void _loadLibrary() {
    if (_lib != null) return;

    final paths = ['libasound.so.2', 'libasound.so'];
    for (final path in paths) {
      try {
        _lib = DynamicLibrary.open(path);
        LogService().log('AlsaPlayer: Loaded $path');
        return;
      } catch (e) {
        continue;
      }
    }
    throw UnsupportedError('Could not load libasound');
  }

  /// Initialize ALSA functions.
  void initialize() {
    _loadLibrary();

    _sndPcmOpen = _lib!.lookupFunction<SndPcmOpenNative, SndPcmOpen>('snd_pcm_open');
    _sndPcmClose = _lib!.lookupFunction<SndPcmCloseNative, SndPcmClose>('snd_pcm_close');
    _sndPcmHwParamsMalloc = _lib!.lookupFunction<SndPcmHwParamsMallocNative, SndPcmHwParamsMalloc>('snd_pcm_hw_params_malloc');
    _sndPcmHwParamsFree = _lib!.lookupFunction<SndPcmHwParamsFreeNative, SndPcmHwParamsFree>('snd_pcm_hw_params_free');
    _sndPcmHwParamsAny = _lib!.lookupFunction<SndPcmHwParamsAnyNative, SndPcmHwParamsAny>('snd_pcm_hw_params_any');
    _sndPcmHwParamsSetAccess = _lib!.lookupFunction<SndPcmHwParamsSetAccessNative, SndPcmHwParamsSetAccess>('snd_pcm_hw_params_set_access');
    _sndPcmHwParamsSetFormat = _lib!.lookupFunction<SndPcmHwParamsSetFormatNative, SndPcmHwParamsSetFormat>('snd_pcm_hw_params_set_format');
    _sndPcmHwParamsSetRateNear = _lib!.lookupFunction<SndPcmHwParamsSetRateNearNative, SndPcmHwParamsSetRateNear>('snd_pcm_hw_params_set_rate_near');
    _sndPcmHwParamsSetChannels = _lib!.lookupFunction<SndPcmHwParamsSetChannelsNative, SndPcmHwParamsSetChannels>('snd_pcm_hw_params_set_channels');
    _sndPcmHwParams = _lib!.lookupFunction<SndPcmHwParamsNative, SndPcmHwParams>('snd_pcm_hw_params');
    _sndPcmPrepare = _lib!.lookupFunction<SndPcmPrepareNative, SndPcmPrepare>('snd_pcm_prepare');
    _sndPcmWritei = _lib!.lookupFunction<SndPcmWriteiNative, SndPcmWritei>('snd_pcm_writei');
    _sndPcmDrop = _lib!.lookupFunction<SndPcmDropNative, SndPcmDrop>('snd_pcm_drop');
    _sndPcmDrain = _lib!.lookupFunction<SndPcmDrainNative, SndPcmDrain>('snd_pcm_drain');
    _sndStrError = _lib!.lookupFunction<SndStrErrorNative, SndStrError>('snd_strerror');

    LogService().log('AlsaPlayer: Initialized');
  }

  String _getError(int code) {
    final ptr = _sndStrError(code);
    return ptr.toDartString();
  }

  /// Load PCM samples for playback.
  void load(Int16List samples, int sampleRate, int channels) {
    _samples = samples;
    _sampleRate = sampleRate;
    _channels = channels;
    _position = 0;
    LogService().log('AlsaPlayer: Loaded ${samples.length} samples at $sampleRate Hz');
  }

  /// Get total duration of loaded audio.
  Duration? get duration {
    if (_samples == null) return null;
    final totalFrames = _samples!.length ~/ _channels;
    return Duration(milliseconds: (totalFrames * 1000) ~/ _sampleRate);
  }

  /// Get current playback position.
  Duration get position {
    final frames = _position ~/ _channels;
    return Duration(milliseconds: (frames * 1000) ~/ _sampleRate);
  }

  bool get isPlaying => _isPlaying && !_isPaused;
  bool get isPaused => _isPaused;

  /// Open ALSA playback device.
  bool _openDevice() {
    final pcmPtr = calloc<Pointer<SndPcmT>>();
    final deviceName = 'default'.toNativeUtf8();

    var err = _sndPcmOpen(pcmPtr, deviceName, SND_PCM_STREAM_PLAYBACK, 0);
    calloc.free(deviceName);

    if (err < 0) {
      calloc.free(pcmPtr);
      LogService().log('AlsaPlayer: Failed to open device: ${_getError(err)}');
      return false;
    }

    _pcm = pcmPtr.value;
    calloc.free(pcmPtr);

    // Configure hardware params
    final hwParamsPtr = calloc<Pointer<SndPcmHwParamsT>>();
    err = _sndPcmHwParamsMalloc(hwParamsPtr);
    if (err < 0) {
      _sndPcmClose(_pcm!);
      _pcm = null;
      calloc.free(hwParamsPtr);
      return false;
    }

    final hwParams = hwParamsPtr.value;
    calloc.free(hwParamsPtr);

    _sndPcmHwParamsAny(_pcm!, hwParams);
    _sndPcmHwParamsSetAccess(_pcm!, hwParams, SND_PCM_ACCESS_RW_INTERLEAVED);
    _sndPcmHwParamsSetFormat(_pcm!, hwParams, SND_PCM_FORMAT_S16_LE);

    final ratePtr = calloc<Uint32>();
    final dirPtr = calloc<Int32>();
    ratePtr.value = _sampleRate;
    _sndPcmHwParamsSetRateNear(_pcm!, hwParams, ratePtr, dirPtr);
    calloc.free(ratePtr);
    calloc.free(dirPtr);

    _sndPcmHwParamsSetChannels(_pcm!, hwParams, _channels);

    err = _sndPcmHwParams(_pcm!, hwParams);
    _sndPcmHwParamsFree(hwParams);

    if (err < 0) {
      _sndPcmClose(_pcm!);
      _pcm = null;
      LogService().log('AlsaPlayer: Failed to set hw params: ${_getError(err)}');
      return false;
    }

    _sndPcmPrepare(_pcm!);
    return true;
  }

  /// Close ALSA device.
  void _closeDevice() {
    if (_pcm != null) {
      _sndPcmDrop(_pcm!);
      _sndPcmClose(_pcm!);
      _pcm = null;
    }
  }

  /// Start or resume playback.
  Future<void> play() async {
    if (_samples == null) {
      LogService().log('AlsaPlayer: No samples loaded');
      return;
    }

    if (_isPaused) {
      _isPaused = false;
      _stateController.add(AlsaPlayerState.playing);
      return;
    }

    if (_isPlaying) return;

    _isPlaying = true;
    _stopRequested = false;
    _stateController.add(AlsaPlayerState.playing);

    // Start playback in background
    _playbackLoop();
  }

  /// Background playback loop.
  Future<void> _playbackLoop() async {
    if (!_openDevice()) {
      _isPlaying = false;
      _stateController.add(AlsaPlayerState.stopped);
      return;
    }

    final framesPerWrite = _sampleRate ~/ 20; // 50ms chunks
    final samplesPerWrite = framesPerWrite * _channels;

    while (_isPlaying && !_stopRequested && _position < _samples!.length) {
      if (_isPaused) {
        await Future.delayed(const Duration(milliseconds: 50));
        continue;
      }

      final remaining = _samples!.length - _position;
      final toWrite = remaining < samplesPerWrite ? remaining : samplesPerWrite;
      final frames = toWrite ~/ _channels;

      // Allocate and copy samples
      final buffer = calloc<Int16>(toWrite);
      for (var i = 0; i < toWrite; i++) {
        buffer[i] = _samples![_position + i];
      }

      // Write to ALSA
      final written = _sndPcmWritei(_pcm!, buffer.cast<Void>(), frames);
      calloc.free(buffer);

      if (written < 0) {
        LogService().log('AlsaPlayer: Write error: ${_getError(written)}');
        break;
      }

      _position += written * _channels;
      _positionController.add(position);

      // Small delay to prevent tight loop
      await Future.delayed(const Duration(milliseconds: 10));
    }

    // Drain remaining audio
    if (_pcm != null && !_stopRequested) {
      _sndPcmDrain(_pcm!);
    }

    _closeDevice();
    _isPlaying = false;

    if (_position >= _samples!.length) {
      _position = 0;
      _stateController.add(AlsaPlayerState.completed);
    } else {
      _stateController.add(AlsaPlayerState.stopped);
    }
  }

  /// Pause playback.
  void pause() {
    if (_isPlaying && !_isPaused) {
      _isPaused = true;
      _stateController.add(AlsaPlayerState.paused);
    }
  }

  /// Stop playback.
  void stop() {
    _stopRequested = true;
    _isPaused = false;
    _position = 0;
    _stateController.add(AlsaPlayerState.stopped);
  }

  /// Seek to position.
  void seek(Duration position) {
    final frames = (position.inMilliseconds * _sampleRate) ~/ 1000;
    _position = (frames * _channels).clamp(0, _samples?.length ?? 0);
    _positionController.add(this.position);
  }

  /// Release resources.
  void dispose() {
    stop();
    _closeDevice();
    _positionController.close();
    _stateController.close();
  }
}

enum AlsaPlayerState {
  stopped,
  playing,
  paused,
  completed,
}
