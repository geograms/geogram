/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Web platform stub for file image operations
/// File-based images are not supported on web

import 'package:flutter/material.dart';

/// Get a FileImage provider from a file path
/// Always returns null on web
ImageProvider? getFileImageProvider(String path) {
  return null;
}

/// Check if a file exists at the given path
/// Always returns false on web
bool fileExists(String path) {
  return false;
}

/// Build an Image widget from a file path
/// Always returns null on web
Widget? buildFileImage(String path, {double? width, double? height, BoxFit fit = BoxFit.cover}) {
  return null;
}
