// CLI Chat Service - Uses the same ChatService as desktop for persistence
// This ensures messages from CLI are visible in desktop and vice versa
import 'dart:io';
import '../models/chat_message.dart';
import '../models/chat_channel.dart';
import '../services/chat_service.dart';
import 'pure_storage_config.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';

/// CLI Chat Service - provides chat functionality for CLI mode
/// Uses the shared ChatService for persistence, ensuring CLI and desktop
/// share the same chat data.
class CliChatService {
  static final CliChatService _instance = CliChatService._internal();
  factory CliChatService() => _instance;
  CliChatService._internal();

  final ChatService _chatService = ChatService();
  String? _currentCallsign;
  String? _currentNpub;
  String? _currentNsec;
  bool _initialized = false;

  /// Get the underlying ChatService
  ChatService get chatService => _chatService;

  /// Get current callsign
  String? get currentCallsign => _currentCallsign;

  /// Get channels (chat rooms)
  List<ChatChannel> get channels => _chatService.channels;

  /// Get channel by ID
  ChatChannel? getChannel(String channelId) => _chatService.getChannel(channelId);

  /// Initialize chat service for a specific profile
  Future<void> initialize(String callsign, {String? npub, String? nsec}) async {
    if (_initialized && _currentCallsign == callsign) return;

    _currentCallsign = callsign;
    _currentNpub = npub;
    _currentNsec = nsec;

    final storageConfig = PureStorageConfig();
    if (!storageConfig.isInitialized) {
      throw StateError('PureStorageConfig must be initialized first');
    }

    // Collection path is the chat subfolder within the device directory
    // This matches the desktop structure: devices/<callsign>/chat/
    final collectionPath = '${storageConfig.devicesDir}/$callsign/chat';

    // Ensure collection directory exists
    final collectionDir = Directory(collectionPath);
    if (!await collectionDir.exists()) {
      await collectionDir.create(recursive: true);
      stderr.writeln('CliChatService: Created collection directory: $collectionPath');
    }

    // Initialize the underlying ChatService
    await _chatService.initializeCollection(collectionPath, creatorNpub: npub);

    // Ensure main channel exists
    if (_chatService.channels.isEmpty) {
      await createChannel('main', 'Main Chat', description: 'Public group chat');
    }

    _initialized = true;
    stderr.writeln('CliChatService: Initialized for $callsign with ${_chatService.channels.length} channels');
  }

  /// Check if initialized
  bool get isInitialized => _initialized;

  /// Create a new channel (chat room)
  Future<ChatChannel?> createChannel(
    String id,
    String name, {
    String? description,
    List<String>? participants,
  }) async {
    if (!_initialized) return null;

    try {
      // Check if channel already exists
      if (_chatService.getChannel(id) != null) {
        stderr.writeln('CliChatService: Channel already exists: $id');
        return _chatService.getChannel(id);
      }

      ChatChannel channel;
      if (id == 'main') {
        channel = ChatChannel.main(
          name: name,
          description: description,
        );
      } else {
        channel = ChatChannel.group(
          id: id,
          name: name,
          participants: participants ?? ['*'],
          description: description,
        );
      }

      return await _chatService.createChannel(channel);
    } catch (e) {
      stderr.writeln('CliChatService: Error creating channel: $e');
      return null;
    }
  }

  /// Delete a channel (cannot delete main)
  Future<bool> deleteChannel(String channelId) async {
    if (!_initialized) return false;
    if (channelId == 'main') return false;

    try {
      await _chatService.deleteChannel(channelId);
      return true;
    } catch (e) {
      stderr.writeln('CliChatService: Error deleting channel: $e');
      return false;
    }
  }

  /// Rename a channel
  Future<bool> renameChannel(String channelId, String newName) async {
    if (!_initialized) return false;

    final channel = _chatService.getChannel(channelId);
    if (channel == null) return false;

    try {
      final updatedChannel = channel.copyWith(name: newName);
      await _chatService.updateChannel(updatedChannel);
      return true;
    } catch (e) {
      stderr.writeln('CliChatService: Error renaming channel: $e');
      return false;
    }
  }

  /// Post a message to a channel
  Future<bool> postMessage(
    String channelId,
    String content, {
    Map<String, String>? metadata,
  }) async {
    if (!_initialized || _currentCallsign == null) return false;

    final channel = _chatService.getChannel(channelId);
    if (channel == null) {
      stderr.writeln('CliChatService: Channel not found: $channelId');
      return false;
    }

    try {
      // Build metadata with signature if we have keys
      final msgMetadata = <String, String>{
        if (_currentNpub != null) 'npub': _currentNpub!,
        'channel': channelId,
        ...?metadata,
      };

      // Sign the message if we have nsec
      if (_currentNpub != null && _currentNsec != null) {
        final signature = _generateSchnorrSignature(content, msgMetadata, _currentNsec!);
        if (signature.isNotEmpty) {
          msgMetadata['signature'] = signature;
          msgMetadata['verified'] = 'true'; // Self-signed messages are verified
        }
      }

      // Create message with current user's callsign
      final message = ChatMessage.now(
        author: _currentCallsign!,
        content: content,
        metadata: msgMetadata.isNotEmpty ? msgMetadata : null,
      );

      await _chatService.saveMessage(channelId, message);
      return true;
    } catch (e) {
      stderr.writeln('CliChatService: Error posting message: $e');
      return false;
    }
  }

  /// Generate BIP-340 Schnorr signature for a message
  String _generateSchnorrSignature(
    String content,
    Map<String, String> metadata,
    String nsec,
  ) {
    try {
      // Decode nsec to get private key hex
      final privateKeyHex = NostrCrypto.decodeNsec(nsec);
      final publicKeyHex = NostrCrypto.derivePublicKey(privateKeyHex);

      // Create a NOSTR event for signing
      final event = NostrEvent.textNote(
        pubkeyHex: publicKeyHex,
        content: content,
        tags: [
          ['t', 'chat'],
          ['channel', metadata['channel'] ?? 'main'],
        ],
      );

      // Calculate event ID and sign with BIP-340 Schnorr signature
      event.calculateId();
      event.sign(privateKeyHex);

      return event.sig ?? '';
    } catch (e) {
      stderr.writeln('CliChatService: Error generating signature: $e');
      return '';
    }
  }

  /// Load messages from a channel
  Future<List<ChatMessage>> loadMessages(
    String channelId, {
    int limit = 100,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    if (!_initialized) return [];

    try {
      return await _chatService.loadMessages(
        channelId,
        limit: limit,
        startDate: startDate,
        endDate: endDate,
      );
    } catch (e) {
      stderr.writeln('CliChatService: Error loading messages: $e');
      return [];
    }
  }

  /// Get message count for a channel
  Future<int> getMessageCount(String channelId) async {
    if (!_initialized) return 0;
    return await _chatService.getMessageCount(channelId);
  }

  /// Search messages in a channel
  Future<List<ChatMessage>> searchMessages(
    String channelId,
    String query, {
    int limit = 50,
  }) async {
    if (!_initialized) return [];
    return await _chatService.searchMessages(channelId, query, limit: limit);
  }

  /// Delete a message (requires moderation permissions)
  Future<bool> deleteMessage(String channelId, ChatMessage message) async {
    if (!_initialized) return false;

    try {
      await _chatService.deleteMessage(channelId, message, _currentNpub);
      return true;
    } catch (e) {
      stderr.writeln('CliChatService: Error deleting message: $e');
      return false;
    }
  }

  /// Refresh channels list
  Future<void> refreshChannels() async {
    if (!_initialized) return;
    await _chatService.refreshChannels();
  }

  /// Get all channels as a map (for compatibility with existing CLI code)
  Map<String, ChatChannel> get channelsMap {
    final map = <String, ChatChannel>{};
    for (final channel in _chatService.channels) {
      map[channel.id] = channel;
    }
    return map;
  }
}
