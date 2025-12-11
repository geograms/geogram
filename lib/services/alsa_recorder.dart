/*
 * ALSA audio recorder via FFI for Linux.
 * Records PCM audio directly using libasound, no external tools required.
 */

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'log_service.dart';

// ALSA constants
const int SND_PCM_STREAM_CAPTURE = 1;
const int SND_PCM_ACCESS_RW_INTERLEAVED = 3;
const int SND_PCM_FORMAT_S16_LE = 2; // Signed 16-bit little-endian

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

typedef SndPcmHwParamsSetRateNearNative = Int32 Function(
    Pointer<SndPcmT> pcm, Pointer<SndPcmHwParamsT> params, Pointer<Uint32> rate, Pointer<Int32> dir);
typedef SndPcmHwParamsSetRateNear = int Function(
    Pointer<SndPcmT> pcm, Pointer<SndPcmHwParamsT> params, Pointer<Uint32> rate, Pointer<Int32> dir);

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

typedef SndPcmReadiNative = Int64 Function(
    Pointer<SndPcmT> pcm, Pointer<Void> buffer, Uint64 frames);
typedef SndPcmReadi = int Function(
    Pointer<SndPcmT> pcm, Pointer<Void> buffer, int frames);

typedef SndPcmDropNative = Int32 Function(Pointer<SndPcmT> pcm);
typedef SndPcmDrop = int Function(Pointer<SndPcmT> pcm);

typedef SndStrErrorNative = Pointer<Utf8> Function(Int32 errnum);
typedef SndStrError = Pointer<Utf8> Function(int errnum);

/// ALSA-based audio recorder for Linux.
/// Records directly via libasound, no external tools needed.
class AlsaRecorder {
  static DynamicLibrary? _lib;
  Pointer<SndPcmT>? _pcm;
  bool _isRecording = false;

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
  late SndPcmReadi _sndPcmReadi;
  late SndPcmDrop _sndPcmDrop;
  late SndStrError _sndStrError;

  final int sampleRate;
  final int channels;

  AlsaRecorder({this.sampleRate = 16000, this.channels = 1});

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
        LogService().log('AlsaRecorder: Loaded $path');
        return;
      } catch (e) {
        continue;
      }
    }
    throw UnsupportedError('Could not load libasound');
  }

  /// Initialize ALSA and open the capture device.
  void initialize() {
    _loadLibrary();

    // Look up functions
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
    _sndPcmReadi = _lib!.lookupFunction<SndPcmReadiNative, SndPcmReadi>('snd_pcm_readi');
    _sndPcmDrop = _lib!.lookupFunction<SndPcmDropNative, SndPcmDrop>('snd_pcm_drop');
    _sndStrError = _lib!.lookupFunction<SndStrErrorNative, SndStrError>('snd_strerror');

    LogService().log('AlsaRecorder: Initialized');
  }

  String _getError(int code) {
    final ptr = _sndStrError(code);
    return ptr.toDartString();
  }

  /// Start recording to a WAV file.
  Future<bool> startRecording(String outputPath) async {
    if (_isRecording) return false;

    // Open default capture device
    final pcmPtr = calloc<Pointer<SndPcmT>>();
    final deviceName = 'default'.toNativeUtf8();

    var err = _sndPcmOpen(pcmPtr, deviceName, SND_PCM_STREAM_CAPTURE, 0);
    calloc.free(deviceName);

    if (err < 0) {
      calloc.free(pcmPtr);
      LogService().log('AlsaRecorder: Failed to open device: ${_getError(err)}');
      return false;
    }

    _pcm = pcmPtr.value;
    calloc.free(pcmPtr);

    // Allocate hw params
    final hwParamsPtr = calloc<Pointer<SndPcmHwParamsT>>();
    err = _sndPcmHwParamsMalloc(hwParamsPtr);
    if (err < 0) {
      _sndPcmClose(_pcm!);
      _pcm = null;
      calloc.free(hwParamsPtr);
      LogService().log('AlsaRecorder: Failed to allocate hw params: ${_getError(err)}');
      return false;
    }

    final hwParams = hwParamsPtr.value;
    calloc.free(hwParamsPtr);

    // Fill with defaults
    err = _sndPcmHwParamsAny(_pcm!, hwParams);
    if (err < 0) {
      _sndPcmHwParamsFree(hwParams);
      _sndPcmClose(_pcm!);
      _pcm = null;
      LogService().log('AlsaRecorder: Failed to get hw params: ${_getError(err)}');
      return false;
    }

    // Set access type
    err = _sndPcmHwParamsSetAccess(_pcm!, hwParams, SND_PCM_ACCESS_RW_INTERLEAVED);
    if (err < 0) {
      _sndPcmHwParamsFree(hwParams);
      _sndPcmClose(_pcm!);
      _pcm = null;
      LogService().log('AlsaRecorder: Failed to set access: ${_getError(err)}');
      return false;
    }

    // Set format (16-bit signed little-endian)
    err = _sndPcmHwParamsSetFormat(_pcm!, hwParams, SND_PCM_FORMAT_S16_LE);
    if (err < 0) {
      _sndPcmHwParamsFree(hwParams);
      _sndPcmClose(_pcm!);
      _pcm = null;
      LogService().log('AlsaRecorder: Failed to set format: ${_getError(err)}');
      return false;
    }

    // Set sample rate
    final ratePtr = calloc<Uint32>();
    final dirPtr = calloc<Int32>();
    ratePtr.value = sampleRate;
    dirPtr.value = 0;
    err = _sndPcmHwParamsSetRateNear(_pcm!, hwParams, ratePtr, dirPtr);
    final actualRate = ratePtr.value;
    calloc.free(ratePtr);
    calloc.free(dirPtr);

    if (err < 0) {
      _sndPcmHwParamsFree(hwParams);
      _sndPcmClose(_pcm!);
      _pcm = null;
      LogService().log('AlsaRecorder: Failed to set rate: ${_getError(err)}');
      return false;
    }

    LogService().log('AlsaRecorder: Actual sample rate: $actualRate');

    // Set channels
    err = _sndPcmHwParamsSetChannels(_pcm!, hwParams, channels);
    if (err < 0) {
      _sndPcmHwParamsFree(hwParams);
      _sndPcmClose(_pcm!);
      _pcm = null;
      LogService().log('AlsaRecorder: Failed to set channels: ${_getError(err)}');
      return false;
    }

    // Apply hw params
    err = _sndPcmHwParams(_pcm!, hwParams);
    _sndPcmHwParamsFree(hwParams);

    if (err < 0) {
      _sndPcmClose(_pcm!);
      _pcm = null;
      LogService().log('AlsaRecorder: Failed to apply hw params: ${_getError(err)}');
      return false;
    }

    // Prepare device
    err = _sndPcmPrepare(_pcm!);
    if (err < 0) {
      _sndPcmClose(_pcm!);
      _pcm = null;
      LogService().log('AlsaRecorder: Failed to prepare device: ${_getError(err)}');
      return false;
    }

    _isRecording = true;
    LogService().log('AlsaRecorder: Started recording to $outputPath');
    return true;
  }

  /// Read PCM frames from the capture device.
  /// Returns null if not recording.
  Int16List? readFrames(int numFrames) {
    if (!_isRecording || _pcm == null) return null;

    final bytesPerFrame = channels * 2; // 16-bit = 2 bytes
    final bufferSize = numFrames * bytesPerFrame;
    final buffer = calloc<Int16>(numFrames * channels);

    final framesRead = _sndPcmReadi(_pcm!, buffer.cast<Void>(), numFrames);

    if (framesRead < 0) {
      calloc.free(buffer);
      LogService().log('AlsaRecorder: Read error: ${_getError(framesRead)}');
      return null;
    }

    // Copy to Dart list
    final result = Int16List(framesRead * channels);
    for (var i = 0; i < framesRead * channels; i++) {
      result[i] = buffer[i];
    }

    calloc.free(buffer);
    return result;
  }

  /// Stop recording and close the device.
  void stopRecording() {
    if (_pcm != null) {
      _sndPcmDrop(_pcm!);
      _sndPcmClose(_pcm!);
      _pcm = null;
    }
    _isRecording = false;
    LogService().log('AlsaRecorder: Stopped recording');
  }

  bool get isRecording => _isRecording;

  /// Record audio and save directly to WAV file.
  /// [durationSeconds] - Maximum recording duration
  /// [outputPath] - Path to save the WAV file
  /// [onProgress] - Callback for recording progress (seconds elapsed)
  /// [shouldStop] - Callback to check if recording should stop early
  Future<String?> recordToWav(
    String outputPath,
    int durationSeconds, {
    void Function(double seconds)? onProgress,
    bool Function()? shouldStop,
  }) async {
    if (!await startRecording(outputPath)) {
      return null;
    }

    final samples = <int>[];
    final framesPerRead = sampleRate ~/ 10; // Read 100ms at a time
    final totalFrames = sampleRate * durationSeconds;
    var framesRecorded = 0;

    while (framesRecorded < totalFrames && _isRecording) {
      if (shouldStop?.call() ?? false) break;

      final frames = readFrames(framesPerRead);
      if (frames == null) break;

      samples.addAll(frames);
      framesRecorded += frames.length ~/ channels;

      onProgress?.call(framesRecorded / sampleRate);

      // Small delay to prevent tight loop
      await Future.delayed(const Duration(milliseconds: 10));
    }

    stopRecording();

    if (samples.isEmpty) {
      LogService().log('AlsaRecorder: No samples recorded');
      return null;
    }

    // Write WAV file
    final wavData = _createWavFile(Int16List.fromList(samples));
    final file = File(outputPath);
    await file.writeAsBytes(wavData);

    LogService().log('AlsaRecorder: Saved ${samples.length} samples to $outputPath');
    return outputPath;
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
    buffer.setUint16(offset, channels, Endian.little); // Channels
    offset += 2;
    buffer.setUint32(offset, sampleRate, Endian.little); // Sample rate
    offset += 4;
    buffer.setUint32(offset, sampleRate * channels * 2, Endian.little); // Byte rate
    offset += 4;
    buffer.setUint16(offset, channels * 2, Endian.little); // Block align
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
}
