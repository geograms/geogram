/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared service interfaces for CLI and Desktop command dispatch.
 *
 * Commands cast [CommandContext.station] and [CommandContext.profileService]
 * to these interfaces instead of concrete types (StationServer,
 * CliProfileService) so that both platforms can supply their own
 * implementations.
 */

// ---------------------------------------------------------------------------
// Station
// ---------------------------------------------------------------------------

/// Read-only view of station settings used by commands.
abstract class StationSettingsReadable {
  String get callsign;
  String get npub;
  int get httpPort;
  int get httpsPort;
  String? get description;
  String? get location;
  double? get latitude;
  double? get longitude;
  bool get tileServerEnabled;
  bool get osmFallbackEnabled;
  int get maxZoomLevel;
  int get maxCacheSizeMB;
  bool get enableAprs;
  bool get enableCors;
  int get maxConnectedDevices;

  // SSL fields (used by SslCommand)
  String? get sslDomain;
  String? get sslEmail;
  bool get sslAutoRenew;
  bool get enableSsl;
  String? get sslCertPath;
  String? get sslKeyPath;
}

/// Read-only view of server statistics.
abstract class StationStatsReadable {
  int get totalConnections;
  int get totalMessages;
  int get totalApiRequests;
  int get totalTileRequests;
  int get tilesCached;
  int get tilesServedFromCache;
  int get tilesDownloaded;
  DateTime? get lastConnection;
  DateTime? get lastMessage;
  DateTime? get lastTileRequest;
}

/// Read-only view of a chat message.
abstract class ChatMessageReadable {
  String get id;
  String get roomId;
  String get senderCallsign;
  String? get senderNpub;
  String? get signature;
  String get content;
  DateTime get timestamp;
  bool get verified;
  bool get hasSignature;
}

/// Read-only view of a chat room.
abstract class ChatRoomReadable {
  String get id;
  String get name;
  String get description;
  String get creatorCallsign;
  DateTime get createdAt;
  DateTime get lastActivity;
  bool get isPublic;
  List<ChatMessageReadable> get readableMessages;
}

/// Read-only view of a connected client.
abstract class ConnectedClientReadable {
  String get id;
  String? get callsign;
  String? get nickname;
  String? get deviceType;
  DateTime get connectedAt;
}

/// Read-only view of a log entry.
abstract class LogEntryReadable {
  DateTime get timestamp;
  String get level;
  String get message;
}

/// Station operations used by commands.
///
/// Both [StationServer] (CLI) and a Desktop adapter implement this.
abstract class StationCommandInterface {
  // --- Properties ---
  bool get isRunning;
  int get connectedDevices;
  String? get dataDir;
  bool get quietMode;
  set quietMode(bool value);

  // --- Typed accessors ---
  StationSettingsReadable get settings;
  StationStatsReadable get stats;
  Map<String, ChatRoomReadable> get chatRoomsReadable;
  Map<String, ConnectedClientReadable> get clientsReadable;
  List<LogEntryReadable> get logsReadable;

  // --- Lifecycle ---
  Future<bool> start();
  Future<void> stop();
  Future<void> restart();
  Future<void> reloadSettings();
  Future<void> updateSettings(covariant Object settings);
  Map<String, dynamic> getStatus();

  // --- Settings mutation ---
  void setSetting(String key, dynamic value);

  // --- Cache ---
  void clearCache();

  // --- Device management ---
  bool kickDevice(String callsign);
  void broadcast(String message);
  Future<List<Map<String, dynamic>>> scanNetwork({int timeout = 2000});
  Future<Map<String, dynamic>?> pingDevice(String address);

  // --- Chat ---
  ChatRoomReadable? createChatRoom(String id, String name, {String? description});
  bool deleteChatRoom(String id);
  bool renameChatRoom(String oldId, String newName);
  Future<void> postMessage(String roomId, String content);
  Future<bool> deleteMessage(String roomId, String messageId);
  bool verifyMessage(covariant Object message);

  // --- Moderation ---
  bool addGlobalModerator(String npub);
  bool removeGlobalModerator(String npub);
  List<String> getGlobalModerators();
  String? resolveIdentityToNpub(String nameOrCallsign);

  // --- Logs ---
  List<LogEntryReadable> getLogs({int limit = 20});
}

// ---------------------------------------------------------------------------
// Profile
// ---------------------------------------------------------------------------

/// Read-only view of a profile used by commands.
abstract class ProfileReadable {
  String get id;
  String get callsign;
  String get npub;
  String get nsec;
  String get nickname;
  String get description;
  bool get isRelay;
  bool get isClient;
  double? get latitude;
  double? get longitude;
  String? get locationName;
  DateTime get createdAt;
  String get preferredColor;

  // Station-specific
  int? get port;
  String? get stationRole;
  String? get parentStationUrl;
  String? get networkId;
  bool get tileServerEnabled;
  bool get osmFallbackEnabled;
  bool get enableAprs;
}

/// Profile operations used by commands.
///
/// Both [CliProfileService] (CLI) and a Desktop adapter implement this.
abstract class ProfileCommandInterface {
  List<ProfileReadable> get profilesReadable;
  ProfileReadable? get activeProfileReadable;

  ProfileReadable? getProfileByCallsign(String callsign);
  Future<void> setActiveProfile(String profileId);
  Future<void> deleteProfile(String profileId);
  Future<void> updateProfile(covariant Object profile);

  List<Map<String, dynamic>> getAllDevicesSorted();
  bool isOwnedCallsign(String callsign);
}

/// Callback type for checking whether an input string is a known command.
///
/// Used by [NavigationHandler.trySendChatMessage] to distinguish chat messages
/// from commands. Implementations should check the command registry plus any
/// navigation commands (ls, cd, pwd) that are handled outside the registry.
typedef IsKnownCommandFn = bool Function(String name);
