/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Service to manage whisper native library downloads for F-Droid builds
 * where pre-built binaries cannot be bundled.
 */

import 'dart:ffi';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:whisper_flutter_new/whisper_flutter_new.dart';

import '../util/managed_http_client.dart';
import 'log_service.dart';
import 'storage_config.dart';

/// Manages the whisper native library for platforms where it may not be bundled
class WhisperLibraryService {
  static final WhisperLibraryService _instance =
      WhisperLibraryService._internal();
  factory WhisperLibraryService() => _instance;
  WhisperLibraryService._internal();

  String? _libraryPath;
  bool? _isBundled;

  /// Check if libwhisper.so is bundled with the app (normal builds)
  /// Returns false for F-Droid builds where it needs to be downloaded
  /// Returns false on Windows where whisper is not supported
  Future<bool> isLibraryBundled() async {
    if (_isBundled != null) return _isBundled!;

    // Whisper is not supported on Windows
    if (Platform.isWindows) {
      _isBundled = false;
      LogService().log('WhisperLibraryService: Not supported on Windows');
      return false;
    }

    if (!Platform.isAndroid) {
      _isBundled = true;
      return true;
    }

    try {
      // Try to load the bundled library
      DynamicLibrary.open('libwhisper.so');
      _isBundled = true;
      LogService().log('WhisperLibraryService: Library is bundled');
      return true;
    } catch (e) {
      _isBundled = false;
      LogService().log('WhisperLibraryService: Library not bundled, will need download');
      return false;
    }
  }

  /// Get the Android ABI for the current device
  String getDeviceAbi() {
    if (!Platform.isAndroid) {
      return 'unknown';
    }

    // Use Dart FFI's Abi to determine architecture
    final abi = Abi.current();

    switch (abi) {
      case Abi.androidArm64:
        return 'arm64-v8a';
      case Abi.androidArm:
        return 'armeabi-v7a';
      case Abi.androidX64:
        return 'x86_64';
      case Abi.androidIA32:
        return 'x86';
      default:
        // Fallback to arm64-v8a as most common
        return 'arm64-v8a';
    }
  }

  /// Get path where the library should be stored
  Future<String> _getLibraryDir() async {
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) {
      await storageConfig.init();
    }

    final abi = getDeviceAbi();
    final libDir = p.join(storageConfig.baseDir, 'lib', abi);

    final dir = Directory(libDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return libDir;
  }

  /// Get the full path to the library file
  Future<String> getLibraryPath() async {
    if (_libraryPath != null) return _libraryPath!;

    final libDir = await _getLibraryDir();
    _libraryPath = p.join(libDir, 'libwhisper.so');
    return _libraryPath!;
  }

  /// Check if the library has been downloaded
  Future<bool> isLibraryDownloaded() async {
    final path = await getLibraryPath();
    final file = File(path);
    return file.existsSync() && (await file.length()) > 0;
  }

  /// Check if whisper is available (either bundled or downloaded)
  Future<bool> isWhisperAvailable() async {
    if (await isLibraryBundled()) {
      return true;
    }
    return isLibraryDownloaded();
  }

  /// Download the whisper library from a station server
  /// Returns the path to the downloaded library on success
  Future<String> downloadLibrary({
    required String stationUrl,
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Library download only supported on Android');
    }

    final abi = getDeviceAbi();
    final downloadUrl = '$stationUrl/whisper/$abi/libwhisper.so';
    final destPath = await getLibraryPath();

    LogService().log('WhisperLibraryService: Downloading from $downloadUrl');

    return await withHttpClient((client) async {
      final request = http.Request('GET', Uri.parse(downloadUrl));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('Failed to download: HTTP ${response.statusCode}');
      }

      final totalBytes = response.contentLength ?? 0;
      var receivedBytes = 0;

      final file = File(destPath);
      final sink = file.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0 && onProgress != null) {
          onProgress(receivedBytes / totalBytes);
        }
      }

      await sink.close();

      LogService().log('WhisperLibraryService: Downloaded to $destPath');

      // Initialize whisper with the custom library path
      Whisper.setLibraryPath(destPath);

      return destPath;
    });
  }

  /// Initialize whisper with the downloaded library if not bundled
  /// Call this before using whisper features
  Future<void> ensureLibraryReady() async {
    if (await isLibraryBundled()) {
      return; // Bundled, nothing to do
    }

    if (await isLibraryDownloaded()) {
      final path = await getLibraryPath();
      Whisper.setLibraryPath(path);
      LogService().log('WhisperLibraryService: Using downloaded library at $path');
    }
    // If not downloaded, caller should handle prompting the user
  }
}
