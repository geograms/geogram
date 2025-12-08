import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'storage_config.dart';
import 'config_service.dart';
import 'log_service.dart';

/// Service for managing web themes (HTML templates and CSS)
/// Handles extraction of bundled themes and theme selection
class WebThemeService {
  static final WebThemeService _instance = WebThemeService._internal();
  factory WebThemeService() => _instance;
  WebThemeService._internal();

  static const String _defaultTheme = 'default';
  static const String _configKey = 'settings.webTheme';

  /// List of app types that have theme templates
  static const List<String> appTypes = [
    'chat', 'www', 'forum', 'blog', 'events', 'alerts', 'files'
  ];

  /// Bundled theme assets to extract
  static const List<String> _bundledAssets = [
    'themes/default/styles.css',
    'themes/default/chat/index.html',
    'themes/default/chat/styles.css',
    'themes/default/www/index.html',
    'themes/default/www/styles.css',
    'themes/default/forum/index.html',
    'themes/default/forum/styles.css',
    'themes/default/blog/index.html',
    'themes/default/blog/styles.css',
    'themes/default/events/index.html',
    'themes/default/events/styles.css',
    'themes/default/alerts/index.html',
    'themes/default/alerts/styles.css',
    'themes/default/files/index.html',
    'themes/default/files/styles.css',
  ];

  String? _themesDir;
  bool _initialized = false;

  /// Initialize the theme service and extract bundled themes if needed
  Future<void> init() async {
    if (_initialized) return;
    if (kIsWeb) {
      // Web platform doesn't need theme extraction
      _initialized = true;
      return;
    }

    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) {
      throw StateError(
        'StorageConfig must be initialized before WebThemeService. '
        'Call StorageConfig().init() first.',
      );
    }

    _themesDir = '${storageConfig.baseDir}/themes';

    // Ensure themes directory exists
    final themesDir = Directory(_themesDir!);
    if (!await themesDir.exists()) {
      await themesDir.create(recursive: true);
    }

    // Extract bundled themes if default theme doesn't exist
    final defaultThemeDir = Directory('$_themesDir/default');
    if (!await defaultThemeDir.exists()) {
      await _extractBundledThemes();
    }

    _initialized = true;
    LogService().log('WebThemeService initialized: $_themesDir');
  }

  /// Extract bundled theme assets to the themes directory
  Future<void> _extractBundledThemes() async {
    LogService().log('Extracting bundled themes...');

    for (final assetPath in _bundledAssets) {
      try {
        final content = await rootBundle.loadString(assetPath);
        final targetPath = '$_themesDir/${assetPath.substring(7)}'; // Remove 'themes/' prefix

        final file = File(targetPath);
        await file.parent.create(recursive: true);
        await file.writeAsString(content);

        LogService().log('Extracted: $assetPath -> $targetPath');
      } catch (e) {
        LogService().log('Warning: Could not extract $assetPath: $e');
      }
    }

    LogService().log('Theme extraction complete');
  }

  /// Get the themes directory path
  String get themesDir => _themesDir ?? '';

  /// Get list of available themes
  Future<List<String>> getAvailableThemes() async {
    if (kIsWeb || _themesDir == null) {
      return [_defaultTheme];
    }

    final themes = <String>[];
    final themesDir = Directory(_themesDir!);

    if (await themesDir.exists()) {
      await for (final entity in themesDir.list()) {
        if (entity is Directory) {
          final themeName = entity.path.split('/').last;
          // Verify it has a styles.css file
          final stylesFile = File('${entity.path}/styles.css');
          if (await stylesFile.exists()) {
            themes.add(themeName);
          }
        }
      }
    }

    if (themes.isEmpty) {
      themes.add(_defaultTheme);
    }

    themes.sort();
    return themes;
  }

  /// Get the currently selected theme
  String getCurrentTheme() {
    return ConfigService().getNestedValue(_configKey, _defaultTheme) as String;
  }

  /// Set the current theme
  void setCurrentTheme(String themeName) {
    ConfigService().setNestedValue(_configKey, themeName);
    LogService().log('Web theme changed to: $themeName');
  }

  /// Get the path to a theme's directory
  String getThemePath(String themeName) {
    return '$_themesDir/$themeName';
  }

  /// Get the global styles.css content for a theme
  Future<String?> getGlobalStyles([String? themeName]) async {
    if (kIsWeb || _themesDir == null) return null;

    final theme = themeName ?? getCurrentTheme();
    final file = File('$_themesDir/$theme/styles.css');

    if (await file.exists()) {
      return await file.readAsString();
    }
    return null;
  }

  /// Get app-specific styles.css content for a theme
  Future<String?> getAppStyles(String appType, [String? themeName]) async {
    if (kIsWeb || _themesDir == null) return null;

    final theme = themeName ?? getCurrentTheme();
    final file = File('$_themesDir/$theme/$appType/styles.css');

    if (await file.exists()) {
      return await file.readAsString();
    }
    return null;
  }

  /// Get combined styles (global + app-specific)
  Future<String> getCombinedStyles(String appType, [String? themeName]) async {
    final globalStyles = await getGlobalStyles(themeName) ?? '';
    final appStyles = await getAppStyles(appType, themeName) ?? '';

    return '$globalStyles\n\n/* App-specific styles */\n$appStyles';
  }

  /// Get the index.html template for an app type
  Future<String?> getTemplate(String appType, [String? themeName]) async {
    if (kIsWeb || _themesDir == null) return null;

    final theme = themeName ?? getCurrentTheme();
    final file = File('$_themesDir/$theme/$appType/index.html');

    if (await file.exists()) {
      return await file.readAsString();
    }
    return null;
  }

  /// Process a template by replacing placeholders with values
  String processTemplate(String template, Map<String, String> variables) {
    var result = template;
    for (final entry in variables.entries) {
      result = result.replaceAll('{{${entry.key}}}', entry.value);
    }
    return result;
  }

  /// Check if a theme exists
  Future<bool> themeExists(String themeName) async {
    if (kIsWeb || _themesDir == null) return themeName == _defaultTheme;

    final themeDir = Directory('$_themesDir/$themeName');
    final stylesFile = File('$_themesDir/$themeName/styles.css');

    return await themeDir.exists() && await stylesFile.exists();
  }

  /// Copy a theme to create a new one
  Future<bool> duplicateTheme(String sourceName, String newName) async {
    if (kIsWeb || _themesDir == null) return false;

    final sourceDir = Directory('$_themesDir/$sourceName');
    final targetDir = Directory('$_themesDir/$newName');

    if (!await sourceDir.exists()) {
      LogService().log('Source theme does not exist: $sourceName');
      return false;
    }

    if (await targetDir.exists()) {
      LogService().log('Target theme already exists: $newName');
      return false;
    }

    try {
      await _copyDirectory(sourceDir, targetDir);
      LogService().log('Duplicated theme: $sourceName -> $newName');
      return true;
    } catch (e) {
      LogService().log('Error duplicating theme: $e');
      return false;
    }
  }

  /// Recursively copy a directory
  Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);

    await for (final entity in source.list()) {
      final newPath = '${target.path}/${entity.path.split('/').last}';

      if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
  }

  /// Delete a theme (cannot delete 'default')
  Future<bool> deleteTheme(String themeName) async {
    if (kIsWeb || _themesDir == null) return false;
    if (themeName == _defaultTheme) {
      LogService().log('Cannot delete the default theme');
      return false;
    }

    final themeDir = Directory('$_themesDir/$themeName');

    if (!await themeDir.exists()) {
      return false;
    }

    try {
      await themeDir.delete(recursive: true);

      // If deleted theme was current, revert to default
      if (getCurrentTheme() == themeName) {
        setCurrentTheme(_defaultTheme);
      }

      LogService().log('Deleted theme: $themeName');
      return true;
    } catch (e) {
      LogService().log('Error deleting theme: $e');
      return false;
    }
  }

  /// Re-extract bundled themes (useful for updates)
  Future<void> resetBundledThemes() async {
    if (kIsWeb || _themesDir == null) return;
    await _extractBundledThemes();
  }
}
