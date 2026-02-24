/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Core Telegram bridge service — singleton that owns the TDLib client,
 * manages lifecycle, and exposes a unified event stream.
 */

import 'dart:async';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import 'models/telegram_auth_state.dart';
import 'tdlib_client.dart';
import 'tdlib_ffi.dart';
import 'telegram_auth_service.dart';
import 'telegram_cache_service.dart';
import 'telegram_chat_service.dart';
import 'telegram_storage_service.dart';

/// Event types emitted by the Telegram bridge.
enum TelegramEventType {
  connected,
  disconnected,
  authStateChanged,
  chatListUpdated,
  newMessage,
  messageEdited,
  messagesDeleted,
  typingUpdate,
  reactionsUpdated,
  error,
}

/// An event from the Telegram bridge.
class TelegramEvent {
  final TelegramEventType type;
  final dynamic data;

  const TelegramEvent(this.type, [this.data]);

  @override
  String toString() => 'TelegramEvent($type)';
}

/// Core Telegram bridge singleton.
///
/// Follows the NNTPService pattern: singleton + ProfileStorage + event stream.
class TelegramService {
  static final TelegramService _instance = TelegramService._internal();
  factory TelegramService() => _instance;
  TelegramService._internal();

  /// Default TDLib API credentials (from official TDLib examples).
  /// Users can override these in the setup page if they have their own.
  static const int defaultApiId = 94575;
  static const String defaultApiHash = 'a3406de8d171bb422bb6ddf3bbd800e2';

  TdlibClient? _client;
  TelegramStorageService? _storageService;
  TelegramAuthService? _authService;
  TelegramChatService? _chatService;
  TelegramCacheService? _cacheService;
  ProfileStorage? _storage;

  bool _initialized = false;
  String? _initializedForCallsign;
  StreamSubscription<Map<String, dynamic>>? _updateSub;

  final StreamController<TelegramEvent> _eventController =
      StreamController<TelegramEvent>.broadcast();

  /// Stream of Telegram bridge events.
  Stream<TelegramEvent> get events => _eventController.stream;

  /// Current auth state data.
  TelegramAuthStateData get authState =>
      _authService?.currentState ??
      const TelegramAuthStateData(state: TelegramAuthState.uninitialized);

  /// Auth service for login flows.
  TelegramAuthService? get authService => _authService;

  /// Chat service for chat/message operations.
  TelegramChatService? get chatService => _chatService;

  /// Cache service for per-chat SQLite message caching.
  TelegramCacheService? get cacheService => _cacheService;

  /// Storage service for config/status persistence.
  TelegramStorageService? get storageService => _storageService;

  /// Whether the service is initialized and the TDLib client is running.
  bool get isRunning => _client?.isRunning ?? false;

  /// Whether TDLib is available on this platform.
  static bool get isAvailable => TdlibFfi.isAvailable;

  /// Set profile storage — must be called before initialize().
  void setStorage(ProfileStorage storage) {
    _storage = storage;
    _initialized = false;
  }

  /// Initialize the Telegram bridge for the given callsign/teleport path.
  ///
  /// [teleportPath] is the relative path to the teleport collection
  /// (e.g. "teleport-xxx") within the profile storage.
  Future<void> initialize(String teleportPath, String callsign) async {
    if (_initialized && _initializedForCallsign == callsign) return;

    if (_initialized) {
      await disconnect();
    }

    if (_storage == null) {
      throw StateError('Call setStorage() before initialize()');
    }

    _storageService = TelegramStorageService(_storage!, teleportPath);
    await _storageService!.ensureDirectories();

    _initializedForCallsign = callsign;
    _initialized = true;

    LogService().log('TelegramService: initialized for $callsign');
  }

  /// Connect — create the TDLib client and start processing updates.
  ///
  /// Reads api_id and api_hash from config.json and sends setTdlibParameters.
  Future<void> connect() async {
    if (!_initialized || _storageService == null) {
      throw StateError('TelegramService not initialized');
    }

    if (_client?.isRunning == true) return;

    final config = await _storageService!.readConfig();
    if (config == null) {
      throw StateError('Telegram config.json not found — run setup first');
    }

    final apiId = config['api_id'];
    final apiHash = config['api_hash'] as String?;
    if (apiId == null || apiHash == null) {
      throw StateError('api_id and api_hash required in config.json');
    }

    // Resolve absolute paths for TDLib database and files directories
    final pfx = _storageService!.prefix;
    final dbDir = _storage!.getAbsolutePath(
        '${pfx.isEmpty ? "" : "$pfx/"}telegram/tdlib_db');
    final filesDir = _storage!.getAbsolutePath(
        '${pfx.isEmpty ? "" : "$pfx/"}telegram/media');

    // Create cache service for per-chat SQLite message caching
    _cacheService = TelegramCacheService(_storage!, _storageService!.prefix);
    await _cacheService!.ensureCacheDir();

    _client = TdlibClient();
    _client!.start();

    // Wire up sub-services
    _authService = TelegramAuthService(_client!, _onAuthStateChanged);
    _chatService = TelegramChatService(_client!, _onChatEvent,
        cacheService: _cacheService);

    // Listen to all TDLib updates and dispatch to sub-services
    _updateSub = _client!.updates.listen(_dispatchUpdate);

    // Send TDLib parameters
    _client!.send({
      '@type': 'setTdlibParameters',
      'database_directory': dbDir,
      'files_directory': filesDir,
      'api_id': apiId is int ? apiId : int.parse(apiId.toString()),
      'api_hash': apiHash,
      'system_language_code': 'en',
      'device_model': 'Geogram Desktop',
      'application_version': '1.0',
    });

    await _storageService!.writeStatus({
      'state': 'connecting',
      'last_connect': DateTime.now().toUtc().toIso8601String(),
    });

    _eventController.add(const TelegramEvent(TelegramEventType.connected));
    LogService().log('TelegramService: connected');
  }

  /// Disconnect and stop the TDLib client.
  Future<void> disconnect() async {
    _updateSub?.cancel();
    _updateSub = null;

    _authService = null;
    _chatService = null;

    _cacheService?.dispose();
    _cacheService = null;

    _client?.stop();
    _client = null;

    if (_storageService != null) {
      await _storageService!.writeStatus({
        'state': 'disconnected',
        'last_disconnect': DateTime.now().toUtc().toIso8601String(),
      });
    }

    _eventController.add(const TelegramEvent(TelegramEventType.disconnected));
    LogService().log('TelegramService: disconnected');
  }

  /// Destroy the bridge — disconnect and remove registration.
  Future<void> destroy() async {
    await disconnect();

    if (_storageService != null) {
      await _storageService!.unregisterBridge();
    }

    _initialized = false;
    _initializedForCallsign = null;
    _storageService = null;

    LogService().log('TelegramService: destroyed');
  }

  /// Dispose resources.
  void dispose() {
    disconnect();
    _eventController.close();
  }

  // --- Private ---

  void _dispatchUpdate(Map<String, dynamic> update) {
    final type = update['@type'] as String? ?? '';

    // Auth-related updates
    if (type == 'updateAuthorizationState') {
      _authService?.handleUpdate(update);
      return;
    }

    // Chat-related updates
    if (type.startsWith('updateChat') ||
        type == 'updateNewChat' ||
        type == 'updateNewMessage' ||
        type == 'updateSupergroup' ||
        type == 'updateMessageEdited' ||
        type == 'updateMessageContent' ||
        type == 'updateDeleteMessages' ||
        type == 'updateUserChatAction' ||
        type == 'updateMessageInteractionInfo') {
      _chatService?.handleUpdate(update);
      return;
    }
  }

  void _onAuthStateChanged(TelegramAuthStateData state) {
    _eventController
        .add(TelegramEvent(TelegramEventType.authStateChanged, state));

    // When auth is ready, register the bridge as active
    if (state.state == TelegramAuthState.ready) {
      _storageService?.registerBridge(enabled: true);
      _storageService?.writeStatus({
        'state': 'authenticated',
        'last_auth': DateTime.now().toUtc().toIso8601String(),
      });
    }
  }

  void _onChatEvent(TelegramEventType type, dynamic data) {
    _eventController.add(TelegramEvent(type, data));
  }
}
