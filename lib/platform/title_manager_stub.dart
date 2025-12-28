import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import 'title_manager_interface.dart';

final TitleManager titleManager = DesktopTitleManager();

class DesktopTitleManager implements TitleManager {
  String? _cachedTitle;

  @override
  Future<String> getTitle() async {
    if (!_isDesktopPlatform()) {
      return _cachedTitle ?? 'Geogram';
    }
    try {
      final title = await windowManager.getTitle();
      _cachedTitle = title;
      return title;
    } catch (_) {
      return _cachedTitle ?? 'Geogram';
    }
  }

  @override
  Future<void> setTitle(String title) async {
    _cachedTitle = title;
    if (!_isDesktopPlatform()) return;
    try {
      await windowManager.setTitle(title);
    } catch (_) {
      // Ignore title updates on unsupported platforms.
    }
  }

  @override
  Future<bool> isFocused() async {
    if (!_isDesktopPlatform()) return true;
    try {
      return await windowManager.isFocused();
    } catch (_) {
      return true;
    }
  }

  bool _isDesktopPlatform() {
    return defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }
}
