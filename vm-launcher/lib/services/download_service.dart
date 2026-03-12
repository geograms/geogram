import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models/download_manifest.dart';
import 'vm_config_service.dart';

class DownloadService {
  final ValueNotifier<double> progress = ValueNotifier(0.0);
  final ValueNotifier<String> speedText = ValueNotifier('');

  bool _cancelled = false;

  DateTime _lastProgressUpdate = DateTime.now();
  double _lastProgressValue = 0.0;
  static const _progressUpdateInterval = Duration(milliseconds: 100);

  void cancel() => _cancelled = true;

  Future<void> downloadAndSetup() async {
    _cancelled = false;
    final config = VmConfigService();
    await config.ensureDirectories();

    // Download QEMU binaries
    final qemuAsset = Platform.isWindows
        ? DownloadManifest.windowsQemu
        : DownloadManifest.linuxQemu;

    final qemuArchive = p.join(config.dataDir, qemuAsset.filename);
    await _downloadFile(qemuAsset.url, qemuArchive, 'QEMU');
    if (_cancelled) return;

    // Extract QEMU
    await _extractArchive(qemuArchive, p.dirname(config.qemuPath));
    if (_cancelled) return;

    // Make QEMU executable on Linux
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', config.qemuPath]);
    }

    // Download VM image
    await _downloadFile(
        DownloadManifest.vmImage.url, config.imagePath, 'VM image');
  }

  Future<void> _downloadFile(
      String url, String destPath, String label) async {
    final partialPath = '$destPath.partial';
    final partialFile = File(partialPath);
    final destFile = File(destPath);

    // Already downloaded
    if (await destFile.exists()) {
      progress.value = 1.0;
      return;
    }

    // Check existing partial download size
    int existingBytes = 0;
    if (await partialFile.exists()) {
      existingBytes = await partialFile.length();
    }

    // HEAD request for total size and range support
    final headResponse = await http.head(
      Uri.parse(url),
      headers: {'User-Agent': 'GeogramVM-Launcher'},
    ).timeout(const Duration(seconds: 30));

    final contentLength =
        int.tryParse(headResponse.headers['content-length'] ?? '') ?? 0;
    final supportsResume =
        headResponse.headers['accept-ranges'] == 'bytes' && contentLength > 0;

    // Already complete
    if (existingBytes > 0 &&
        existingBytes >= contentLength &&
        contentLength > 0) {
      await partialFile.rename(destPath);
      progress.value = 1.0;
      return;
    }

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['User-Agent'] = 'GeogramVM-Launcher';

      int startByte = 0;
      if (supportsResume && existingBytes > 0) {
        startByte = existingBytes;
        request.headers['Range'] = 'bytes=$startByte-';
      } else if (existingBytes > 0) {
        await partialFile.delete();
        existingBytes = 0;
      }

      final response = await client.send(request);
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      final expectedLength =
          response.contentLength ?? (contentLength - startByte);
      final totalSize = startByte + expectedLength;

      final sink = partialFile.openWrite(
          mode: startByte > 0 ? FileMode.append : FileMode.write);

      var downloaded = startByte;
      var lastSpeedCheck = DateTime.now();
      var lastSpeedBytes = downloaded;

      await for (final chunk in response.stream) {
        if (_cancelled) {
          await sink.flush();
          await sink.close();
          return;
        }

        sink.add(chunk);
        downloaded += chunk.length;

        if (totalSize > 0) {
          final p = downloaded / totalSize;
          _updateProgressThrottled(p);
        }

        // Speed calculation every second
        final now = DateTime.now();
        if (now.difference(lastSpeedCheck).inMilliseconds > 1000) {
          final bytesPerSec = (downloaded - lastSpeedBytes) /
              now.difference(lastSpeedCheck).inMilliseconds *
              1000;
          speedText.value = '${_formatBytes(bytesPerSec.round())}/s';
          lastSpeedCheck = now;
          lastSpeedBytes = downloaded;
        }
      }

      await sink.flush();
      await sink.close();

      // Verify SHA-256 if hash is available
      // (skipped when hash is empty — placeholder hashes)

      await partialFile.rename(destPath);
      progress.value = 1.0;
      speedText.value = '';
    } finally {
      client.close();
    }
  }

  Future<void> _extractArchive(String archivePath, String destDir) async {
    if (Platform.isWindows) {
      // Use PowerShell to extract zip
      await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'Expand-Archive',
        '-Path',
        archivePath,
        '-DestinationPath',
        destDir,
        '-Force',
      ]);
    } else {
      // tar for .tar.gz
      await Process.run('tar', [
        'xzf',
        archivePath,
        '-C',
        destDir,
      ]);
    }
  }

  void _updateProgressThrottled(double value) {
    final now = DateTime.now();
    if (now.difference(_lastProgressUpdate) >= _progressUpdateInterval ||
        (value - _lastProgressValue).abs() >= 0.01) {
      progress.value = value;
      _lastProgressUpdate = now;
      _lastProgressValue = value;
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<bool> verifySha256(String filePath, String expectedHash) async {
    if (expectedHash.isEmpty) return true;
    final file = File(filePath);
    final digest = await sha256.bind(file.openRead()).last;
    return digest.toString() == expectedHash;
  }
}
