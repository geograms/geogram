/// Platform abstractions for native platforms (uses dart:io)

import 'dart:io';
import 'dart:typed_data';

import 'ogg_opus_writer.dart';
import 'opus_decoder.dart';
import 'alsa_player.dart';
import 'log_service.dart';

bool get isLinuxPlatform => Platform.isLinux;
bool get isIOSPlatform => Platform.isIOS;

/// Voice messages are only supported on Linux (ALSA FFI) and Android (record + just_audio)
/// Other platforms disabled until properly tested:
/// - iOS: record works but playback format (CAF) has issues
/// - macOS: needs testing
/// - Windows: needs just_audio_windows dependency
bool get isVoiceSupported => Platform.isLinux || Platform.isAndroid;

/// Decode OGG/Opus file and return PCM samples with metadata.
/// Returns (samples, sampleRate, channels) or null on error.
/// This is only available on native platforms (not web).
Future<(Int16List, int, int)?> decodeOggOpus(String filePath) async {
  try {
    // Read and decode OGG/Opus file
    final (packets, sampleRate, channels, preSkip, _) =
        await OggOpusReader.read(filePath);

    if (packets.isEmpty) {
      LogService().log('decodeOggOpus: No audio packets in file');
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

    return (samples, sampleRate, channels);
  } catch (e) {
    LogService().log('decodeOggOpus error: $e');
    return null;
  }
}

/// Create an ALSA player instance (only on native platforms).
AlsaPlayer createAlsaPlayer() => AlsaPlayer();

/// Wrapper around dart:io File
class PlatformFile {
  final File _file;
  PlatformFile(String path) : _file = File(path);

  Future<bool> exists() => _file.exists();
  Future<Uint8List> readAsBytes() => _file.readAsBytes();
  Future<void> writeAsBytes(List<int> bytes) => _file.writeAsBytes(bytes);
  Future<void> delete() async => _file.delete();
  Future<int> length() => _file.length();
  int lengthSync() => _file.lengthSync();
}
