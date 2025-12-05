/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Native platform implementation for file image operations
/// This file is only imported on non-web platforms

import 'dart:io';
import 'package:flutter/material.dart';

/// Get a FileImage provider from a file path
/// Returns null if file doesn't exist
ImageProvider? getFileImageProvider(String path) {
  try {
    final file = File(path);
    if (file.existsSync()) {
      return FileImage(file);
    }
  } catch (e) {
    // File operations failed
  }
  return null;
}

/// Check if a file exists at the given path
bool fileExists(String path) {
  try {
    return File(path).existsSync();
  } catch (e) {
    return false;
  }
}

/// Build an Image widget from a file path
/// Returns null if file doesn't exist
Widget? buildFileImage(String path, {double? width, double? height, BoxFit fit = BoxFit.cover}) {
  try {
    final file = File(path);
    if (file.existsSync()) {
      return Image.file(
        file,
        width: width,
        height: height,
        fit: fit,
      );
    }
  } catch (e) {
    // File operations failed
  }
  return null;
}
