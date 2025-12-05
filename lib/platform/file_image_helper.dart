/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Platform-aware file image helper
/// Provides FileImage support on native platforms while gracefully handling web

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

// Conditionally import dart:io only on non-web platforms
import 'file_image_native.dart' if (dart.library.html) 'file_image_web.dart' as file_helper;

/// Get a FileImage provider from a file path
/// Returns null on web or if file doesn't exist
ImageProvider? getFileImageProvider(String path) {
  if (kIsWeb) return null;
  return file_helper.getFileImageProvider(path);
}

/// Check if a file exists at the given path
/// Returns false on web
bool fileExists(String path) {
  if (kIsWeb) return false;
  return file_helper.fileExists(path);
}

/// Build an Image widget from a file path
/// Returns null on web or if file doesn't exist
Widget? buildFileImage(String path, {double? width, double? height, BoxFit fit = BoxFit.cover}) {
  if (kIsWeb) return null;
  return file_helper.buildFileImage(path, width: width, height: height, fit: fit);
}
