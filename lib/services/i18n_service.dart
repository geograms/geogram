import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'log_service.dart';
import 'config_service.dart';

class I18nService {
  static final I18nService _instance = I18nService._internal();
  factory I18nService() => _instance;
  I18nService._internal();

  Map<String, String> _translations = {};
  String _currentLanguage = 'en_US';
  final List<String> _supportedLanguages = ['en_US', 'pt_PT'];

  // Language display names
  final Map<String, String> _languageNames = {
    'en_US': 'English (US)',
    'pt_PT': 'Português (Portugal)',
  };

  // Notifier for UI updates when language changes
  final ValueNotifier<String> languageNotifier = ValueNotifier<String>('en_US');

  /// Initialize the i18n service with a default language
  Future<void> init({String? language}) async {
    LogService().log('I18nService initializing...');
    print('I18N INIT: Starting initialization'); // Debug for web console

    // Try to load saved language from config, or use provided, or default to en_US
    final configLanguage = ConfigService().getNestedValue('settings.language', 'en_US');
    print('I18N INIT: Config language value: $configLanguage (type: ${configLanguage.runtimeType})'); // Debug

    String languageToLoad = language ?? configLanguage as String;
    print('I18N INIT: Language to load (before normalize): $languageToLoad'); // Debug

    // Normalize language codes (e.g., 'en' -> 'en_US', 'pt' -> 'pt_PT')
    languageToLoad = _normalizeLanguageCode(languageToLoad);
    print('I18N INIT: Language to load (after normalize): $languageToLoad'); // Debug

    // Validate language is supported
    if (!_supportedLanguages.contains(languageToLoad)) {
      LogService().log('WARNING: Unsupported language $languageToLoad, falling back to en_US');
      print('I18N INIT: WARNING - Unsupported language, falling back to en_US'); // Debug
      languageToLoad = 'en_US';
    }

    _currentLanguage = languageToLoad;
    print('I18N INIT: About to load language: $_currentLanguage'); // Debug
    await _loadLanguage(_currentLanguage);
    print('I18N INIT: Language loaded, translations count: ${_translations.length}'); // Debug
    languageNotifier.value = _currentLanguage;

    LogService().log('I18nService initialized with language: $_currentLanguage');
    print('I18N INIT: Initialization complete'); // Debug
  }

  /// Normalize language codes to full locale format
  String _normalizeLanguageCode(String code) {
    // Map short codes to full locale codes
    const Map<String, String> shortCodeMap = {
      'en': 'en_US',
      'pt': 'pt_PT',
    };

    // If it's a short code, expand it
    if (shortCodeMap.containsKey(code)) {
      return shortCodeMap[code]!;
    }

    return code;
  }

  /// Load a language file
  Future<void> _loadLanguage(String language) async {
    try {
      LogService().log('Loading language file: $language');
      print('I18N: Loading language file: $language'); // Debug for web console

      // Load the JSON file from assets
      // On web, rootBundle requires asset paths exactly as declared in pubspec.yaml
      final assetPath = 'languages/$language.json';
      print('I18N: Asset path: $assetPath'); // Debug for web console

      final String jsonString = await rootBundle.loadString(assetPath);
      print('I18N: Loaded JSON string length: ${jsonString.length}'); // Debug for web console

      final Map<String, dynamic> jsonMap = json.decode(jsonString);

      // Convert to Map<String, String>
      _translations = jsonMap.map((key, value) => MapEntry(key, value.toString()));

      LogService().log('Language file loaded successfully: $language (${_translations.length} translations)');
      print('I18N: Language file loaded successfully: $language (${_translations.length} translations)'); // Debug for web console
      print('I18N: Sample translations - welcome_to_geogram: ${_translations['welcome_to_geogram']}'); // Debug
    } catch (e, stackTrace) {
      LogService().log('ERROR loading language file $language: $e');
      LogService().log('Stack trace: $stackTrace');
      print('I18N ERROR: $e'); // Debug for web console
      print('I18N Stack trace: $stackTrace'); // Debug for web console

      // If loading fails, ensure we have empty translations rather than crashing
      _translations = {};
    }
  }

  /// Change the current language
  Future<void> setLanguage(String language) async {
    if (!_supportedLanguages.contains(language)) {
      LogService().log('ERROR: Cannot set unsupported language: $language');
      return;
    }

    if (_currentLanguage == language) {
      LogService().log('Language $language is already set');
      return;
    }

    LogService().log('Changing language from $_currentLanguage to $language');
    _currentLanguage = language;
    await _loadLanguage(language);

    // Save to config for persistence
    ConfigService().setNestedValue('settings.language', language);

    languageNotifier.value = language;

    LogService().log('Language changed successfully to: $language');
  }

  /// Get a translated string by key
  /// Supports parameter substitution with {0}, {1}, etc.
  String translate(String key, {List<String>? params}) {
    // Debug: Check if translations are loaded
    if (_translations.isEmpty && key != 'DEBUG_CHECK') {
      print('I18N TRANSLATE WARNING: Translations map is empty! Key: $key');
    }

    String translation = _translations[key] ?? key;

    // If parameters are provided, substitute them
    if (params != null && params.isNotEmpty) {
      for (int i = 0; i < params.length; i++) {
        translation = translation.replaceAll('{$i}', params[i]);
      }
    }

    return translation;
  }

  /// Shorthand for translate
  String t(String key, {List<String>? params}) {
    return translate(key, params: params);
  }

  /// Get the current language code
  String get currentLanguage => _currentLanguage;

  /// Get list of supported languages
  List<String> get supportedLanguages => List.unmodifiable(_supportedLanguages);

  /// Get language display name
  String getLanguageName(String languageCode) {
    return _languageNames[languageCode] ?? languageCode;
  }

  /// Get all language names as a map
  Map<String, String> get languageNames => Map.unmodifiable(_languageNames);
}

/// Extension to make translation easier in widgets
extension I18nExtension on String {
  String get tr => I18nService().translate(this);
  String trParams(List<String> params) => I18nService().translate(this, params: params);
}
