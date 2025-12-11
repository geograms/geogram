/*
 * Opus decoder via FFI for Linux.
 * Decodes Opus audio to PCM format using bundled libopus.
 */

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'log_service.dart';

// Opus error codes
const int OPUS_OK = 0;

/// Opaque decoder struct
final class OpusDecoderStruct extends Opaque {}

/// FFI function signatures
typedef OpusDecoderCreateNative = Pointer<OpusDecoderStruct> Function(
    Int32 fs, Int32 channels, Pointer<Int32> error);
typedef OpusDecoderCreate = Pointer<OpusDecoderStruct> Function(
    int fs, int channels, Pointer<Int32> error);

typedef OpusDecodeNative = Int32 Function(Pointer<OpusDecoderStruct> st,
    Pointer<Uint8> data, Int32 len, Pointer<Int16> pcm, Int32 frameSize, Int32 decodeFec);
typedef OpusDecode = int Function(Pointer<OpusDecoderStruct> st,
    Pointer<Uint8> data, int len, Pointer<Int16> pcm, int frameSize, int decodeFec);

typedef OpusDecoderDestroyNative = Void Function(Pointer<OpusDecoderStruct> st);
typedef OpusDecoderDestroy = void Function(Pointer<OpusDecoderStruct> st);

/// Opus decoder wrapper for Dart FFI.
/// Decodes Opus frames to 16-bit PCM audio.
class OpusDecoder {
  static DynamicLibrary? _lib;
  Pointer<OpusDecoderStruct>? _decoder;

  late OpusDecoderCreate _create;
  late OpusDecode _decode;
  late OpusDecoderDestroy _destroy;

  final int sampleRate;
  final int channels;

  bool _initialized = false;

  OpusDecoder({this.sampleRate = 16000, this.channels = 1});

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

    final paths = [
      'lib/libopus.so.0',
      'libopus.so.0',
      'libopus.so',
    ];

    for (final path in paths) {
      try {
        _lib = DynamicLibrary.open(path);
        LogService().log('OpusDecoder: Loaded library from $path');
        return;
      } catch (e) {
        continue;
      }
    }

    throw UnsupportedError('Could not load libopus');
  }

  /// Initialize the decoder.
  void initialize() {
    if (_initialized) return;

    _loadLibrary();

    _create = _lib!.lookupFunction<OpusDecoderCreateNative, OpusDecoderCreate>(
        'opus_decoder_create');
    _decode =
        _lib!.lookupFunction<OpusDecodeNative, OpusDecode>('opus_decode');
    _destroy =
        _lib!.lookupFunction<OpusDecoderDestroyNative, OpusDecoderDestroy>(
            'opus_decoder_destroy');

    final errorPtr = calloc<Int32>();
    _decoder = _create(sampleRate, channels, errorPtr);
    final error = errorPtr.value;
    calloc.free(errorPtr);

    if (error != OPUS_OK || _decoder == nullptr) {
      throw Exception('Failed to create Opus decoder: error $error');
    }

    _initialized = true;
    LogService().log('OpusDecoder: Initialized ($sampleRate Hz, $channels ch)');
  }

  /// Decode an Opus frame to PCM samples.
  /// [opusData]: Encoded Opus packet
  /// [frameSize]: Number of samples per channel to decode (e.g., 960 for 20ms at 48kHz, 320 for 20ms at 16kHz)
  /// Returns the decoded PCM samples, or null on error.
  Int16List? decodeFrame(Uint8List opusData, int frameSize) {
    if (!_initialized || _decoder == nullptr) {
      throw StateError('Decoder not initialized');
    }

    // Allocate input buffer
    final dataPtr = calloc<Uint8>(opusData.length);
    for (var i = 0; i < opusData.length; i++) {
      dataPtr[i] = opusData[i];
    }

    // Allocate output buffer
    final pcmPtr = calloc<Int16>(frameSize * channels);

    // Decode
    final samplesDecoded =
        _decode(_decoder!, dataPtr, opusData.length, pcmPtr, frameSize, 0);

    Int16List? result;
    if (samplesDecoded > 0) {
      result = Int16List(samplesDecoded * channels);
      for (var i = 0; i < samplesDecoded * channels; i++) {
        result[i] = pcmPtr[i];
      }
    } else {
      LogService().log('OpusDecoder: Decode error $samplesDecoded');
    }

    calloc.free(dataPtr);
    calloc.free(pcmPtr);

    return result;
  }

  /// Decode multiple Opus packets to PCM.
  Int16List decodeAll(List<Uint8List> packets, int frameSize) {
    if (!_initialized) {
      initialize();
    }

    final samples = <int>[];

    for (final packet in packets) {
      final decoded = decodeFrame(packet, frameSize);
      if (decoded != null) {
        samples.addAll(decoded);
      }
    }

    LogService().log('OpusDecoder: Decoded ${packets.length} packets, ${samples.length} samples');
    return Int16List.fromList(samples);
  }

  /// Release decoder resources.
  void dispose() {
    if (_decoder != null && _decoder != nullptr) {
      _destroy(_decoder!);
      _decoder = null;
    }
    _initialized = false;
  }
}
