/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Core Signal bridge service — singleton that owns the SignalClient,
 * manages lifecycle, and exposes a unified event stream.
 * Mirrors TelegramService 1:1, adapted for Signal's UUID-based identity.
 */

import 'dart:async';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import 'models/signal_auth_state.dart';
import 'signal_client.dart';
import 'signal_ffi.dart';
import 'signal_auth_service.dart';
import 'signal_cache_service.dart';
import 'signal_chat_service.dart';
import 'signal_storage_service.dart';

/// Event types emitted by the Signal bridge.
enum SignalEventType {
  connected,
  disconnected,
  authStateChanged,
  chatListUpdated,
  newMessage,
  messageStatusUpdated,
  typingUpdate,
  contactUpdated,
  error,
}

/// An event from the Signal bridge.
class SignalEvent {
  final SignalEventType type;
  final dynamic data;

  const SignalEvent(this.type, [this.data]);

  @override
  String toString() => 'SignalEvent($type)';
}

/// Core Signal bridge singleton.
///
/// Follows the TelegramService pattern: singleton + ProfileStorage + event stream.
class SignalService {
  static final SignalService _instance = SignalService._internal();
  factory SignalService() => _instance;
  SignalService._internal();

  SignalClient? _client;
  SignalStorageService? _storageService;
  SignalAuthService? _authService;
  SignalChatService? _chatService;
  SignalCacheService? _cacheService;
  ProfileStorage? _storage;

  bool _initialized = false;
  String? _initializedForCallsign;
  StreamSubscription<Map<String, dynamic>>? _updateSub;

  final StreamController<SignalEvent> _eventController =
      StreamController<SignalEvent>.broadcast();

  /// Stream of Signal bridge events.
  Stream<SignalEvent> get events => _eventController.stream;

  /// Current auth state data.
  SignalAuthStateData get authState =>
      _authService?.currentState ??
      const SignalAuthStateData(state: SignalAuthState.uninitialized);

  /// Auth service for link/QR flow.
  SignalAuthService? get authService => _authService;

  /// Chat service for conversation/message operations.
  SignalChatService? get chatService => _chatService;

  /// Cache service for per-conversation SQLite message caching.
  SignalCacheService? get cacheService => _cacheService;

  /// Storage service for config/status persistence.
  SignalStorageService? get storageService => _storageService;

  /// Whether the service is initialized and the SignalClient is running.
  bool get isRunning => _client?.isRunning ?? false;

  /// Whether libsignal_bridge is available on this platform.
  static bool get isAvailable => SignalFfi.isAvailable;

  /// Set profile storage — must be called before initialize().
  void setStorage(ProfileStorage storage) {
    _storage = storage;
    _initialized = false;
  }

  /// Initialize the Signal bridge for the given callsign/teleport path.
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

    _storageService = SignalStorageService(_storage!, teleportPath);
    await _storageService!.ensureDirectories();

    _initializedForCallsign = callsign;
    _initialized = true;

    LogService().log('SignalService: initialized for $callsign');
  }

  /// Connect — create the SignalClient and start processing updates.
  ///
  /// Reads config from config.json and sends setSignalParameters.
  Future<void> connect() async {
    if (!_initialized || _storageService == null) {
      throw StateError('SignalService not initialized');
    }

    if (_client?.isRunning == true) return;

    final config = await _storageService!.readConfig();
    if (config == null) {
      throw StateError('Signal config.json not found — run setup first');
    }

    // Resolve absolute paths for Signal database and files directories
    final pfx = _storageService!.prefix;
    final dbDir = _storage!.getAbsolutePath(
        '${pfx.isEmpty ? "" : "$pfx/"}signal/signal_db');
    final mediaDir = _storage!.getAbsolutePath(
        '${pfx.isEmpty ? "" : "$pfx/"}signal/media');

    // Create cache service for per-conversation SQLite message caching
    _cacheService = SignalCacheService(_storage!, _storageService!.prefix);
    await _cacheService!.ensureCacheDir();

    _client = SignalClient();
    _client!.start();

    // Wire up sub-services
    _authService = SignalAuthService(_client!, _onAuthStateChanged);
    _chatService = SignalChatService(_client!, _onChatEvent,
        cacheService: _cacheService);

    // Listen to all Signal updates and dispatch to sub-services
    _updateSub = _client!.updates.listen(_dispatchUpdate);

    // Send Signal parameters
    _client!.send({
      '@type': 'setSignalParameters',
      'database_directory': dbDir,
      'media_directory': mediaDir,
      'device_name': config['device_name'] ?? 'Geogram Desktop',
    });

    await _storageService!.writeStatus({
      'state': 'connecting',
      'last_connect': DateTime.now().toUtc().toIso8601String(),
    });

    _eventController.add(const SignalEvent(SignalEventType.connected));
    LogService().log('SignalService: connected');
  }

  /// Disconnect and stop the Signal client.
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

    _eventController.add(const SignalEvent(SignalEventType.disconnected));
    LogService().log('SignalService: disconnected');
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

    LogService().log('SignalService: destroyed');
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
    if (type == 'updateAuthState') {
      _authService?.handleUpdate(update);
      return;
    }

    // Chat/message-related updates
    if (type == 'updateNewMessage' ||
        type == 'updateMessageStatus' ||
        type == 'updateTyping' ||
        type == 'updateContact') {
      _chatService?.handleUpdate(update);
      return;
    }
  }

  void _onAuthStateChanged(SignalAuthStateData state) {
    _eventController
        .add(SignalEvent(SignalEventType.authStateChanged, state));

    // When auth is ready, register the bridge as active
    if (state.state == SignalAuthState.ready) {
      _storageService?.registerBridge(enabled: true);
      _storageService?.writeStatus({
        'state': 'authenticated',
        'last_auth': DateTime.now().toUtc().toIso8601String(),
      });
    }
  }

  void _onChatEvent(SignalEventType type, dynamic data) {
    _eventController.add(SignalEvent(type, data));
  }
}
