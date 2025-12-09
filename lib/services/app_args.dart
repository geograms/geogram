/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Centralized command line arguments parsing for Geogram Desktop
///
/// This service parses and holds command line arguments that configure
/// the application at startup. It should be initialized before other services.
///
/// Supported arguments:
///   --port=PORT, -p PORT       API server port (default: 3456)
///   --data-dir=PATH, -d PATH   Data directory (default: ~/.local/share/geogram-desktop)
///   --cli                      Run in CLI mode (no GUI)
///   --http-api                 Enable HTTP API on startup
///   --debug-api                Enable Debug API on startup
///   --new-identity             Create a new identity on startup (useful for testing)
///   --identity-type=TYPE       Identity type: 'client' (default) or 'station'
///   --nickname=NAME            Nickname for the new identity
///   --skip-intro               Skip the intro/welcome screen on first launch
///   --scan-localhost=RANGE     Scan localhost ports for other instances (e.g., 5000-6000)
///   --help, -h                 Show help and exit
///   --version, -v              Show version and exit
///   --verbose                  Enable verbose logging
///
/// Environment variables (lower priority than CLI args):
///   GEOGRAM_PORT              API server port
///   GEOGRAM_DATA_DIR          Data directory
///
/// Example usage:
///   geogram_desktop --port=3457 --data-dir=/tmp/geogram-test
///   geogram_desktop -p 3457 -d /tmp/geogram-test
///   geogram_desktop --new-identity --identity-type=station --nickname="Test Station"
class AppArgs {
  static final AppArgs _instance = AppArgs._internal();
  factory AppArgs() => _instance;
  AppArgs._internal();

  /// Default API port
  static const int defaultPort = 3456;

  /// Whether args have been parsed
  bool _initialized = false;

  /// Parsed values
  int _port = defaultPort;
  String? _dataDir;
  bool _cliMode = false;
  bool _httpApi = false;
  bool _debugApi = false;
  bool _newIdentity = false;
  String _identityType = 'client'; // 'client' or 'station'
  String? _nickname;
  bool _skipIntro = false;
  String? _scanLocalhostRange; // e.g., "5000-6000" for scanning localhost ports
  bool _showHelp = false;
  bool _showVersion = false;
  bool _verbose = false;

  /// Get the API port
  int get port => _port;

  /// Get the custom data directory (null = use default)
  String? get dataDir => _dataDir;

  /// Whether running in CLI mode (no GUI)
  bool get cliMode => _cliMode;

  /// Whether to enable HTTP API on startup
  bool get httpApi => _httpApi;

  /// Whether to enable Debug API on startup
  bool get debugApi => _debugApi;

  /// Whether to create a new identity on startup
  bool get newIdentity => _newIdentity;

  /// Identity type for new identity: 'client' or 'station'
  String get identityType => _identityType;

  /// Whether the identity type is station
  bool get isStation => _identityType == 'station';

  /// Nickname for the new identity
  String? get nickname => _nickname;

  /// Whether to skip the intro/welcome screen on first launch
  bool get skipIntro => _skipIntro;

  /// Localhost port range to scan for other Geogram instances (e.g., "5000-6000")
  String? get scanLocalhostRange => _scanLocalhostRange;

  /// Whether localhost port scanning is enabled
  bool get scanLocalhostEnabled => _scanLocalhostRange != null;

  /// Get the localhost port range as start/end integers
  /// Returns null if not set or invalid format
  (int, int)? get scanLocalhostPorts {
    if (_scanLocalhostRange == null) return null;
    final parts = _scanLocalhostRange!.split('-');
    if (parts.length != 2) return null;
    final start = int.tryParse(parts[0].trim());
    final end = int.tryParse(parts[1].trim());
    if (start == null || end == null) return null;
    if (start < 1 || end > 65535 || start > end) return null;
    return (start, end);
  }

  /// Whether to show help and exit
  bool get showHelp => _showHelp;

  /// Whether to show version and exit
  bool get showVersion => _showVersion;

  /// Whether verbose logging is enabled
  bool get verbose => _verbose;

  /// Whether args have been initialized
  bool get isInitialized => _initialized;

  /// Initialize by parsing command line arguments
  ///
  /// This should be called early in main() before other services are initialized.
  /// On web platforms, this is a no-op and uses defaults.
  void parse(List<String> args) {
    if (_initialized) return;

    if (kIsWeb) {
      _initialized = true;
      return;
    }

    // First, check environment variables (lower priority)
    _parseEnvironment();

    // Then parse CLI args (higher priority, overrides env vars)
    _parseArgs(args);

    _initialized = true;
  }

  /// Parse environment variables
  void _parseEnvironment() {
    // Port from environment
    final envPort = Platform.environment['GEOGRAM_PORT'];
    if (envPort != null) {
      final parsed = int.tryParse(envPort);
      if (parsed != null && parsed > 0 && parsed < 65536) {
        _port = parsed;
      }
    }

    // Data directory from environment
    final envDataDir = Platform.environment['GEOGRAM_DATA_DIR'];
    if (envDataDir != null && envDataDir.isNotEmpty) {
      _dataDir = envDataDir;
    }
  }

  /// Parse command line arguments
  void _parseArgs(List<String> args) {
    // Combine executable arguments and script arguments
    final allArgs = <String>[];

    // Add direct args
    allArgs.addAll(args);

    // Also check Platform.executableArguments for Flutter desktop
    try {
      final execArgs = Platform.executableArguments;
      bool foundDashes = false;
      for (final arg in execArgs) {
        if (arg == '--') {
          foundDashes = true;
          continue;
        }
        if (foundDashes) {
          allArgs.add(arg);
        }
      }
    } catch (e) {
      // Ignore if not available
    }

    for (int i = 0; i < allArgs.length; i++) {
      final arg = allArgs[i];

      // --port=PORT format
      if (arg.startsWith('--port=')) {
        final value = arg.substring('--port='.length);
        final parsed = int.tryParse(value);
        if (parsed != null && parsed > 0 && parsed < 65536) {
          _port = parsed;
        }
        continue;
      }

      // --port PORT or -p PORT format
      if ((arg == '--port' || arg == '-p') && i + 1 < allArgs.length) {
        final parsed = int.tryParse(allArgs[i + 1]);
        if (parsed != null && parsed > 0 && parsed < 65536) {
          _port = parsed;
        }
        i++; // Skip next arg
        continue;
      }

      // --data-dir=PATH format
      if (arg.startsWith('--data-dir=')) {
        _dataDir = arg.substring('--data-dir='.length);
        continue;
      }

      // --data-dir PATH or -d PATH format
      if ((arg == '--data-dir' || arg == '-d') && i + 1 < allArgs.length) {
        _dataDir = allArgs[i + 1];
        i++; // Skip next arg
        continue;
      }

      // Boolean flags
      if (arg == '--cli' || arg == '-cli') {
        _cliMode = true;
        continue;
      }

      if (arg == '--http-api') {
        _httpApi = true;
        continue;
      }

      if (arg == '--debug-api') {
        _debugApi = true;
        continue;
      }

      if (arg == '--new-identity') {
        _newIdentity = true;
        continue;
      }

      // --identity-type=TYPE format
      if (arg.startsWith('--identity-type=')) {
        final value = arg.substring('--identity-type='.length).toLowerCase();
        if (value == 'station' || value == 'client') {
          _identityType = value;
        }
        continue;
      }

      // --nickname=NAME format
      if (arg.startsWith('--nickname=')) {
        _nickname = arg.substring('--nickname='.length);
        continue;
      }

      if (arg == '--skip-intro') {
        _skipIntro = true;
        continue;
      }

      // --scan-localhost=RANGE format (e.g., --scan-localhost=5000-6000)
      if (arg.startsWith('--scan-localhost=')) {
        _scanLocalhostRange = arg.substring('--scan-localhost='.length);
        continue;
      }

      if (arg == '--help' || arg == '-h') {
        _showHelp = true;
        continue;
      }

      if (arg == '--version' || arg == '-v') {
        _showVersion = true;
        continue;
      }

      if (arg == '--verbose') {
        _verbose = true;
        continue;
      }
    }
  }

  /// Reset for testing
  void reset() {
    _initialized = false;
    _port = defaultPort;
    _dataDir = null;
    _cliMode = false;
    _httpApi = false;
    _debugApi = false;
    _newIdentity = false;
    _identityType = 'client';
    _nickname = null;
    _skipIntro = false;
    _scanLocalhostRange = null;
    _showHelp = false;
    _showVersion = false;
    _verbose = false;
  }

  /// Get usage help text
  static String getHelpText() {
    return '''
Geogram Desktop - Amateur Radio Communication Platform

Usage:
  geogram_desktop [options]

Options:
  --port=PORT, -p PORT       API server port (default: $defaultPort)
  --data-dir=PATH, -d PATH   Data directory path
  --cli                      Run in CLI mode (no GUI)
  --http-api                 Enable HTTP API on startup
  --debug-api                Enable Debug API on startup
  --new-identity             Create a new identity on startup
  --identity-type=TYPE       Identity type: 'client' (default) or 'station'
  --nickname=NAME            Nickname for the new identity
  --skip-intro               Skip intro/welcome screen on first launch
  --scan-localhost=RANGE     Scan localhost ports for other instances (e.g., 5000-6000)
  --verbose                  Enable verbose logging
  --help, -h                 Show this help message
  --version, -v              Show version information

Environment Variables:
  GEOGRAM_PORT               API server port (overridden by --port)
  GEOGRAM_DATA_DIR           Data directory (overridden by --data-dir)

Examples:
  # Run with default settings
  geogram_desktop

  # Run on custom port (useful for testing multiple instances)
  geogram_desktop --port=3457

  # Run with custom data directory
  geogram_desktop --data-dir=/tmp/geogram-test

  # Run two instances for testing
  geogram_desktop --port=3456 --data-dir=~/.geogram-instance1
  geogram_desktop --port=3457 --data-dir=~/.geogram-instance2

  # Create a new client identity for testing
  geogram_desktop --new-identity --nickname="Test Client" --data-dir=/tmp/test

  # Create a new station identity for testing
  geogram_desktop --new-identity --identity-type=station --nickname="Test Station"

  # CLI mode
  geogram_desktop --cli
''';
  }

  /// Get a summary of current configuration
  Map<String, dynamic> toMap() {
    return {
      'port': _port,
      'dataDir': _dataDir,
      'cliMode': _cliMode,
      'httpApi': _httpApi,
      'debugApi': _debugApi,
      'newIdentity': _newIdentity,
      'identityType': _identityType,
      'nickname': _nickname,
      'skipIntro': _skipIntro,
      'scanLocalhostRange': _scanLocalhostRange,
      'verbose': _verbose,
      'initialized': _initialized,
    };
  }

  @override
  String toString() {
    return 'AppArgs(port: $_port, dataDir: $_dataDir, cliMode: $_cliMode, httpApi: $_httpApi, debugApi: $_debugApi, newIdentity: $_newIdentity, identityType: $_identityType, nickname: $_nickname, skipIntro: $_skipIntro, scanLocalhostRange: $_scanLocalhostRange, verbose: $_verbose)';
  }
}
