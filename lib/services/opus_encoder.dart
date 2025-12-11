/*
 * Opus encoder via FFI for Linux.
 * Encodes PCM audio to Opus format using bundled libopus.
 */

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'log_service.dart';

// Opus application types
const int OPUS_APPLICATION_VOIP = 2048;
const int OPUS_APPLICATION_AUDIO = 2049;
const int OPUS_APPLICATION_RESTRICTED_LOWDELAY = 2051;

// Opus error codes
const int OPUS_OK = 0;
const int OPUS_BAD_ARG = -1;
const int OPUS_BUFFER_TOO_SMALL = -2;
const int OPUS_INTERNAL_ERROR = -3;
const int OPUS_INVALID_PACKET = -4;
const int OPUS_UNIMPLEMENTED = -5;
const int OPUS_INVALID_STATE = -6;
const int OPUS_ALLOC_FAIL = -7;

// Opus encoder control requests
const int OPUS_SET_BITRATE_REQUEST = 4002;
const int OPUS_SET_VBR_REQUEST = 4006;
const int OPUS_SET_COMPLEXITY_REQUEST = 4010;

/// Opaque encoder struct
final class OpusEncoderStruct extends Opaque {}

/// FFI function signatures
typedef OpusEncoderCreateNative = Pointer<OpusEncoderStruct> Function(
  Int32 fs, Int32 channels, Int32 application, Pointer<Int32> error);
typedef OpusEncoderCreate = Pointer<OpusEncoderStruct> Function(
  int fs, int channels, int application, Pointer<Int32> error);

typedef OpusEncodeNative = Int32 Function(
  Pointer<OpusEncoderStruct> st, Pointer<Int16> pcm, Int32 frameSize,
  Pointer<Uint8> data, Int32 maxDataBytes);
typedef OpusEncode = int Function(
  Pointer<OpusEncoderStruct> st, Pointer<Int16> pcm, int frameSize,
  Pointer<Uint8> data, int maxDataBytes);

typedef OpusEncoderDestroyNative = Void Function(Pointer<OpusEncoderStruct> st);
typedef OpusEncoderDestroy = void Function(Pointer<OpusEncoderStruct> st);

typedef OpusEncoderCtlNative = Int32 Function(
  Pointer<OpusEncoderStruct> st, Int32 request, Int32 value);
typedef OpusEncoderCtl = int Function(
  Pointer<OpusEncoderStruct> st, int request, int value);

/// Opus encoder wrapper for Dart FFI.
/// Encodes 16-bit PCM audio to Opus frames.
class OpusEncoder {
  static DynamicLibrary? _lib;
  Pointer<OpusEncoderStruct>? _encoder;

  late OpusEncoderCreate _create;
  late OpusEncode _encode;
  late OpusEncoderDestroy _destroy;
  late OpusEncoderCtl _ctl;

  final int sampleRate;
  final int channels;
  final int application;

  bool _initialized = false;

  /// Create an Opus encoder.
  /// [sampleRate]: 8000, 12000, 16000, 24000, or 48000 Hz
  /// [channels]: 1 (mono) or 2 (stereo)
  /// [application]: OPUS_APPLICATION_VOIP, OPUS_APPLICATION_AUDIO, etc.
  OpusEncoder({
    this.sampleRate = 16000,
    this.channels = 1,
    this.application = OPUS_APPLICATION_VOIP,
  });

  /// Check if libopus is available on this platform.
  static bool get isAvailable {
    if (!Platform.isLinux) return false;
    try {
      _loadLibrary();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Load the bundled libopus library.
  static void _loadLibrary() {
    if (_lib != null) return;

    // Try to load from bundle directory first, then system
    final paths = [
      // Bundled with app (relative to executable)
      'lib/libopus.so.0',
      'libopus.so.0',
      // System library fallback
      'libopus.so',
      'libopus.so.0',
    ];

    for (final path in paths) {
      try {
        _lib = DynamicLibrary.open(path);
        LogService().log('OpusEncoder: Loaded library from $path');
        return;
      } catch (e) {
        continue;
      }
    }

    throw UnsupportedError('Could not load libopus. Make sure it is bundled with the app.');
  }

  /// Initialize the encoder.
  void initialize() {
    if (_initialized) return;

    _loadLibrary();

    // Look up functions
    _create = _lib!.lookupFunction<OpusEncoderCreateNative, OpusEncoderCreate>(
      'opus_encoder_create');
    _encode = _lib!.lookupFunction<OpusEncodeNative, OpusEncode>(
      'opus_encode');
    _destroy = _lib!.lookupFunction<OpusEncoderDestroyNative, OpusEncoderDestroy>(
      'opus_encoder_destroy');
    _ctl = _lib!.lookupFunction<OpusEncoderCtlNative, OpusEncoderCtl>(
      'opus_encoder_ctl');

    // Create encoder
    final errorPtr = calloc<Int32>();
    _encoder = _create(sampleRate, channels, application, errorPtr);
    final error = errorPtr.value;
    calloc.free(errorPtr);

    if (error != OPUS_OK || _encoder == nullptr) {
      throw Exception('Failed to create Opus encoder: error $error');
    }

    // Configure encoder for voice
    _ctl(_encoder!, OPUS_SET_BITRATE_REQUEST, 12000); // 12 kbps
    _ctl(_encoder!, OPUS_SET_VBR_REQUEST, 1); // Variable bitrate
    _ctl(_encoder!, OPUS_SET_COMPLEXITY_REQUEST, 5); // Medium complexity

    _initialized = true;
    LogService().log('OpusEncoder: Initialized ($sampleRate Hz, $channels ch)');
  }

  /// Encode PCM samples to an Opus frame.
  /// [pcmData]: 16-bit signed PCM samples
  /// [frameSize]: Number of samples per channel (must be 2.5, 5, 10, 20, 40, or 60 ms worth)
  /// Returns the encoded Opus packet, or null on error.
  Uint8List? encodeFrame(Int16List pcmData, int frameSize) {
    if (!_initialized || _encoder == nullptr) {
      throw StateError('Encoder not initialized');
    }

    // Allocate input buffer
    final pcmPtr = calloc<Int16>(pcmData.length);
    for (var i = 0; i < pcmData.length; i++) {
      pcmPtr[i] = pcmData[i];
    }

    // Allocate output buffer (max Opus packet size is 1275 bytes per frame)
    const maxPacketSize = 4000;
    final outputPtr = calloc<Uint8>(maxPacketSize);

    // Encode
    final encodedBytes = _encode(_encoder!, pcmPtr, frameSize, outputPtr, maxPacketSize);

    Uint8List? result;
    if (encodedBytes > 0) {
      result = Uint8List(encodedBytes);
      for (var i = 0; i < encodedBytes; i++) {
        result[i] = outputPtr[i];
      }
    } else {
      LogService().log('OpusEncoder: Encode error $encodedBytes');
    }

    // Free buffers
    calloc.free(pcmPtr);
    calloc.free(outputPtr);

    return result;
  }

  /// Encode an entire PCM buffer to Opus frames.
  /// [pcmData]: 16-bit signed PCM samples
  /// Returns a list of encoded Opus packets.
  List<Uint8List> encodeAll(Int16List pcmData) {
    if (!_initialized) {
      initialize();
    }

    final frames = <Uint8List>[];

    // Use 20ms frames (recommended for VOIP)
    // 16000 Hz * 0.020s = 320 samples per frame (mono)
    final samplesPerFrame = (sampleRate * 20) ~/ 1000;
    final totalSamples = pcmData.length ~/ channels;

    var offset = 0;
    while (offset + samplesPerFrame * channels <= pcmData.length) {
      final framePcm = Int16List(samplesPerFrame * channels);
      for (var i = 0; i < samplesPerFrame * channels; i++) {
        framePcm[i] = pcmData[offset + i];
      }

      final encoded = encodeFrame(framePcm, samplesPerFrame);
      if (encoded != null) {
        frames.add(encoded);
      }

      offset += samplesPerFrame * channels;
    }

    LogService().log('OpusEncoder: Encoded ${frames.length} frames from $totalSamples samples');
    return frames;
  }

  /// Release encoder resources.
  void dispose() {
    if (_encoder != null && _encoder != nullptr) {
      _destroy(_encoder!);
      _encoder = null;
    }
    _initialized = false;
  }
}
