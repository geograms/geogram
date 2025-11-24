/// Stub file for window_manager on web platform
/// This provides minimal stubs to allow compilation on web

import 'package:flutter/material.dart';

/// Stub for windowManager global instance
final windowManager = WindowManagerStub();

/// Stub implementation of WindowManager for web
class WindowManagerStub {
  Future<void> ensureInitialized() async {}

  Future<void> waitUntilReadyToShow(
    WindowOptions? options,
    Future<void> Function()? callback,
  ) async {
    // No-op on web
    if (callback != null) {
      await callback();
    }
  }

  Future<void> show() async {}
  Future<void> hide() async {}
  Future<void> focus() async {}
  Future<void> blur() async {}
  Future<void> close() async {}
  Future<void> minimize() async {}
  Future<void> maximize() async {}
  Future<void> restore() async {}

  Future<void> setSize(Size size) async {}
  Future<void> setPosition(Offset position) async {}
  Future<void> setTitle(String title) async {}
  Future<void> setFullScreen(bool isFullScreen) async {}
  Future<void> setAlwaysOnTop(bool isAlwaysOnTop) async {}
  Future<void> setPreventClose(bool isPreventClose) async {}
  Future<void> setSkipTaskbar(bool isSkipTaskbar) async {}

  Future<Size> getSize() async => const Size(800, 600);
  Future<Offset> getPosition() async => Offset.zero;
  Future<bool> isFullScreen() async => false;
  Future<bool> isMaximized() async => false;
  Future<bool> isMinimized() async => false;
  Future<bool> isVisible() async => true;
  Future<bool> isFocused() async => true;
}

/// Stub for WindowOptions
class WindowOptions {
  final Size? size;
  final bool? center;
  final Color? backgroundColor;
  final bool? skipTaskbar;
  final TitleBarStyle? titleBarStyle;
  final bool? alwaysOnTop;
  final bool? fullScreen;
  final String? title;

  const WindowOptions({
    this.size,
    this.center,
    this.backgroundColor,
    this.skipTaskbar,
    this.titleBarStyle,
    this.alwaysOnTop,
    this.fullScreen,
    this.title,
  });
}

/// Stub for TitleBarStyle enum
enum TitleBarStyle {
  normal,
  hidden,
}
