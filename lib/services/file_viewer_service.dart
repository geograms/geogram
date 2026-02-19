/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';
import 'package:flutter/services.dart';
import 'debug_controller.dart';
import 'log_service.dart';

/// Service to handle external file VIEW intents from Android
/// Listens to the native MethodChannel and triggers navigation
/// to the appropriate viewer (PhotoViewerPage for images/videos,
/// DocumentViewerEditorPage for PDFs)
class FileViewerService {
  static final FileViewerService _instance = FileViewerService._internal();
  factory FileViewerService() => _instance;
  FileViewerService._internal();

  static const _channel = MethodChannel('dev.geogram/file_viewer');
  bool _initialized = false;

  /// File info from the launching intent (cold start), set by [checkLaunchIntent].
  static Map<String, String>? launchFile;

  /// Pull the launch intent file from the native side (call before runApp).
  /// Returns true if a file intent was detected.
  static Future<bool> checkLaunchIntent() async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod('getLaunchFile');
      if (result != null && result is Map) {
        launchFile = Map<String, String>.from(result);
        return true;
      }
    } catch (e) {
      // Channel not ready or no intent — not an error
    }
    return false;
  }

  /// Initialize the service and start listening for file events
  void initialize() {
    if (_initialized) return;
    if (!Platform.isAndroid) return;

    _channel.setMethodCallHandler(_handleMethodCall);
    _initialized = true;
    LogService().log('[FileViewer] FileViewerService initialized');
  }

  /// Handle method calls from native code
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onFileReceived') {
      final args = call.arguments as Map<dynamic, dynamic>;
      final path = args['path'] as String?;
      final mimeType = args['mimeType'] as String?;

      LogService().log('[FileViewer] File received: $path ($mimeType)');

      if (path != null) {
        // Trigger navigation via DebugController (has access to Navigator context)
        DebugController().triggerOpenExternalFile(path: path, mimeType: mimeType);
      }
    }
  }

  /// Dispose the service
  void dispose() {
    _channel.setMethodCallHandler(null);
    _initialized = false;
  }
}
