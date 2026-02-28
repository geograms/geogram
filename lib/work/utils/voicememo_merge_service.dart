/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';
import 'dart:typed_data';

import '../../services/log_service.dart';
import '../models/voicememo_content.dart';
import '../services/ndf_service.dart';

/// Service for merging voice memo clips
///
/// Merges audio clips by concatenating their audio data.
/// For OGG/Opus files, this requires decoding to PCM, concatenating,
/// and re-encoding to OGG/Opus.
///
/// Note: Full audio processing requires FFI bindings or external tools.
/// This implementation provides a basic approach using temporary files.
class VoiceMemoMergeService {
  final NdfService _ndfService;

  VoiceMemoMergeService({NdfService? ndfService})
      : _ndfService = ndfService ?? NdfService();

  /// Merge source clip into target clip
  ///
  /// The audio from [sourceClip] is appended to [targetClip].
  /// After merging:
  /// - [targetClip] has combined audio and updated duration
  /// - [targetClip].mergedFrom includes [sourceClip].id
  /// - [targetClip].transcription is cleared (needs re-transcription)
  /// - [sourceClip] should be deleted by the caller
  ///
  /// Returns the updated target clip, or null on failure.
  Future<VoiceMemoClip?> mergeClips({
    required String ndfFilePath,
    required VoiceMemoClip sourceClip,
    required VoiceMemoClip targetClip,
  }) async {
    try {
      // Read both audio files from the archive
      final sourceAudio = await _ndfService.readClipAudio(
        ndfFilePath,
        sourceClip.audioFile,
      );
      final targetAudio = await _ndfService.readClipAudio(
        ndfFilePath,
        targetClip.audioFile,
      );

      if (sourceAudio == null || targetAudio == null) {
        LogService().log('VoiceMemoMergeService: Could not read audio files');
        return null;
      }

      // Concatenate audio
      // Note: For proper OGG/Opus merging, we would need to:
      // 1. Decode both OGG files to PCM
      // 2. Concatenate PCM samples
      // 3. Re-encode to OGG/Opus
      //
      // For now, we use a simplified approach that works for Opus in OGG container
      // by stripping headers from the second file and concatenating.
      // A production implementation would use FFI bindings to opus/ogg libraries.
      final mergedAudio = await _concatenateOggOpus(targetAudio, sourceAudio);

      if (mergedAudio == null) {
        LogService().log('VoiceMemoMergeService: Audio concatenation failed');
        return null;
      }

      // Calculate new duration
      final newDurationMs = targetClip.durationMs + sourceClip.durationMs;

      // Update merged_from list
      final mergedFrom = List<String>.from(targetClip.mergedFrom ?? []);
      mergedFrom.add(sourceClip.id);

      // Create updated clip
      final updatedClip = targetClip.copyWith(
        durationMs: newDurationMs,
        mergedFrom: mergedFrom,
        transcription: null, // Clear transcription - needs re-transcription
      );

      // Save the merged audio (preserve original format from audioFile path)
      final ext = targetClip.audioFile.split('.').last;
      await _ndfService.saveClipAudio(
        ndfFilePath,
        targetClip.id,
        mergedAudio,
        extension: ext,
      );

      // Save the updated clip metadata
      await _ndfService.saveVoiceMemoClip(ndfFilePath, updatedClip);

      LogService().log(
        'VoiceMemoMergeService: Merged ${sourceClip.id} into ${targetClip.id}',
      );

      return updatedClip;
    } catch (e) {
      LogService().log('VoiceMemoMergeService: Error merging clips: $e');
      return null;
    }
  }

  /// Concatenate two OGG/Opus audio files
  ///
  /// This is a simplified implementation that may not work for all OGG files.
  /// For production use, consider using FFI bindings to libogg/libopus.
  Future<Uint8List?> _concatenateOggOpus(
    Uint8List firstFile,
    Uint8List secondFile,
  ) async {
    try {
      // For a proper implementation, we would:
      // 1. Parse OGG container structure
      // 2. Extract Opus packets from both files
      // 3. Rebuild OGG container with combined packets
      //
      // As a fallback, we attempt to use external ffmpeg if available
      if (await _isFFmpegAvailable()) {
        return _mergeWithFFmpeg(firstFile, secondFile);
      }

      // Without ffmpeg, we cannot properly concatenate Opus streams
      // Return null to indicate failure
      LogService().log(
        'VoiceMemoMergeService: FFmpeg not available for audio merge',
      );
      return null;
    } catch (e) {
      LogService().log('VoiceMemoMergeService: Concatenation error: $e');
      return null;
    }
  }

  /// Check if FFmpeg is available on the system
  Future<bool> _isFFmpegAvailable() async {
    try {
      final result = await Process.run('ffmpeg', ['-version']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  /// Merge audio files using FFmpeg
  Future<Uint8List?> _mergeWithFFmpeg(
    Uint8List firstFile,
    Uint8List secondFile,
  ) async {
    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    final firstPath = '${tempDir.path}/voicememo_merge_1_$timestamp.ogg';
    final secondPath = '${tempDir.path}/voicememo_merge_2_$timestamp.ogg';
    final listPath = '${tempDir.path}/voicememo_merge_list_$timestamp.txt';
    final outputPath = '${tempDir.path}/voicememo_merged_$timestamp.ogg';

    try {
      // Write temp files
      await File(firstPath).writeAsBytes(firstFile);
      await File(secondPath).writeAsBytes(secondFile);

      // Create concat file list
      await File(listPath).writeAsString(
        "file '$firstPath'\nfile '$secondPath'\n",
      );

      // Run ffmpeg concat
      final result = await Process.run('ffmpeg', [
        '-f', 'concat',
        '-safe', '0',
        '-i', listPath,
        '-c', 'copy', // Copy codec, no re-encoding
        '-y', // Overwrite output
        outputPath,
      ]);

      if (result.exitCode != 0) {
        LogService().log('VoiceMemoMergeService: FFmpeg failed: ${result.stderr}');
        return null;
      }

      // Read output
      final mergedBytes = await File(outputPath).readAsBytes();

      LogService().log(
        'VoiceMemoMergeService: FFmpeg merge successful, ${mergedBytes.length} bytes',
      );

      return mergedBytes;
    } finally {
      // Cleanup temp files
      await _safeDelete(firstPath);
      await _safeDelete(secondPath);
      await _safeDelete(listPath);
      await _safeDelete(outputPath);
    }
  }

  Future<void> _safeDelete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Ignore cleanup errors
    }
  }
}
