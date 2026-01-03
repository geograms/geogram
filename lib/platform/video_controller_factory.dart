/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:video_player/video_player.dart';

/// Creates a VideoPlayerController from a file path (non-web platforms).
VideoPlayerController? createVideoController(String videoPath) {
  return VideoPlayerController.file(File(videoPath));
}
