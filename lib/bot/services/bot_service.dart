/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/bot_message.dart';
import '../models/music_track.dart';
import '../models/vision_result.dart';
import 'music_generation_service.dart';
import 'vision_service.dart';
import '../../services/log_service.dart';
import '../../services/user_location_service.dart';
import '../../services/i18n_service.dart';
import '../../services/debug_controller.dart';
import '../../util/event_bus.dart';

/// Service for managing bot conversations and AI interactions
class BotService {
  static final BotService _instance = BotService._internal();
  factory BotService() => _instance;
  BotService._internal();

  final List<BotMessage> _messages = [];
  final _messagesController = StreamController<List<BotMessage>>.broadcast();

  bool _initialized = false;
  bool _isProcessing = false;

  // World cities data
  List<Map<String, dynamic>>? _cities;

  // Settings
  bool _modelLoaded = false;
  String? _currentModel;

  // Vision service for image analysis
  final VisionService _visionService = VisionService();

  // Music generation service
  final MusicGenerationService _musicService = MusicGenerationService();

  // Debug controller for executing internal commands
  final DebugController _debugController = DebugController();

  // EventBus subscriptions
  final List<EventSubscription> _eventSubscriptions = [];

  Stream<List<BotMessage>> get messagesStream => _messagesController.stream;
  List<BotMessage> get messages => List.unmodifiable(_messages);
  bool get isProcessing => _isProcessing;
  bool get modelLoaded => _modelLoaded;
  String? get currentModel => _currentModel;

  /// Initialize the bot service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await _loadConversationHistory();
      await _loadWorldCities();
      await _visionService.initialize();
      await _musicService.initialize();
      _setupEventBusListeners();
      _initialized = true;
      LogService().log('BotService initialized');
    } catch (e) {
      LogService().log('Error initializing BotService: $e');
    }
  }

  /// Setup EventBus listeners for real-time updates
  void _setupEventBusListeners() {
    // Listen for connection state changes
    _eventSubscriptions.add(
      EventBus().on<ConnectionStateChangedEvent>((event) {
        LogService().log('BotService: Connection state changed: ${event.connectionType} = ${event.isConnected}');
      }),
    );

    // Listen for direct messages
    _eventSubscriptions.add(
      EventBus().on<DirectMessageReceivedEvent>((event) {
        LogService().log('BotService: DM received from ${event.fromCallsign}');
      }),
    );

    // Listen for alerts
    _eventSubscriptions.add(
      EventBus().on<AlertReceivedEvent>((event) {
        LogService().log('BotService: Alert received: ${event.type} from ${event.senderCallsign}');
      }),
    );
  }

  /// Load world cities database
  Future<void> _loadWorldCities() async {
    try {
      final csvData = await rootBundle.loadString('assets/worldcities.csv');
      final lines = csvData.split('\n');

      if (lines.isEmpty) return;

      // Parse header
      final header = _parseCsvLine(lines[0]);
      _cities = [];

      for (var i = 1; i < lines.length; i++) {
        if (lines[i].trim().isEmpty) continue;
        final values = _parseCsvLine(lines[i]);
        if (values.length < header.length) continue;

        final city = <String, dynamic>{};
        for (var j = 0; j < header.length; j++) {
          city[header[j]] = values[j];
        }
        _cities!.add(city);
      }

      LogService().log('BotService: Loaded ${_cities!.length} cities');
    } catch (e) {
      LogService().log('BotService: Error loading world cities: $e');
    }
  }

  /// Parse a CSV line handling quoted fields
  List<String> _parseCsvLine(String line) {
    final result = <String>[];
    var current = '';
    var inQuotes = false;

    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        result.add(current);
        current = '';
      } else {
        current += char;
      }
    }
    result.add(current);

    return result;
  }

  /// Send a message and get a response
  Future<void> sendMessage(String content, {String? imagePath}) async {
    if (content.trim().isEmpty && imagePath == null) return;
    if (_isProcessing) return;

    _isProcessing = true;

    // Add user message
    final userMessage = BotMessage.user(content, imagePath: imagePath);
    _messages.add(userMessage);
    _notifyListeners();

    // Add thinking indicator
    final thinkingMessage = BotMessage.thinking();
    _messages.add(thinkingMessage);
    _notifyListeners();

    try {
      // Process the query (with optional image)
      final response = await _processQuery(content, imagePath: imagePath);

      // Remove thinking indicator and add response
      _messages.removeWhere((m) => m.isThinking);
      _messages.add(response);
      _notifyListeners();

      // Save conversation
      await _saveConversationHistory();
    } catch (e) {
      // Remove thinking indicator and add error
      _messages.removeWhere((m) => m.isThinking);
      _messages.add(BotMessage.error('Error: $e'));
      _notifyListeners();
    }

    _isProcessing = false;
  }

  /// Process a user query
  Future<BotMessage> _processQuery(String query, {String? imagePath}) async {
    final lowerQuery = query.toLowerCase();
    final sources = <String>[];

    // Simulate some processing time
    await Future.delayed(const Duration(milliseconds: 500));

    // Check if we have an image to analyze
    if (imagePath != null) {
      return await _handleImageQuery(imagePath, query);
    }

    // Check for debug/system commands (internal app feature)
    if (_isDebugCommand(lowerQuery)) {
      return await _handleDebugCommand(query);
    }

    // Check for distance queries
    if (_isDistanceQuery(lowerQuery)) {
      return await _handleDistanceQuery(query);
    }

    // Check for nearest city query
    if (_isNearestCityQuery(lowerQuery)) {
      return await _handleNearestCityQuery();
    }

    // Check for "where am I" query
    if (_isWhereAmIQuery(lowerQuery)) {
      return await _handleWhereAmIQuery();
    }

    // Check for city info query
    if (_isCityInfoQuery(lowerQuery)) {
      return await _handleCityInfoQuery(query);
    }

    // Check for music generation query
    if (_musicService.isMusicQuery(lowerQuery)) {
      LogService().log('BotService: Detected music query: $query');
      return await _handleMusicQuery(query);
    }

    // Default response - provide helpful suggestions
    return BotMessage.bot(
      _getDefaultResponse(),
      sources: sources,
    );
  }

  /// Handle music generation query
  Future<BotMessage> _handleMusicQuery(String query) async {
    // Parse the request to get duration and genre info
    final request = _musicService.parsePrompt(query);

    // Check if we have an AI model for higher quality
    final hasAI = await _musicService.hasAIModel();

    // Build a helpful response message
    String message;
    if (hasAI) {
      message = 'Generating ${request.duration.inMinutes > 0 ? "${request.duration.inMinutes} minute(s)" : "${request.duration.inSeconds} seconds"} of ${request.genre} music using AI...';
    } else {
      message = 'Generating ${request.duration.inMinutes > 0 ? "${request.duration.inMinutes} minute(s)" : "${request.duration.inSeconds} seconds"} of ${request.genre} music.\n\n'
          'Tip: For higher quality AI-generated music, download a music model in Bot Settings.';
    }

    // Create stream directly - the async* generator won't start until subscribed
    final stream = _musicService.generateMusic(query);
    LogService().log('BotService: Created music generation stream');
    return BotMessage.musicGenerating(stream, content: message);
  }

  /// Check if query is a debug/system command
  bool _isDebugCommand(String query) {
    // Commands that trigger debug API actions
    final debugPrefixes = [
      'run ',
      'execute ',
      'trigger ',
      '/debug ',
      '/run ',
      'scan ',
      'refresh ',
      'navigate ',
      'go to ',
      'open ',
      'send dm ',
      'send message ',
      'connect ',
      'disconnect ',
      'show toast ',
    ];

    for (final prefix in debugPrefixes) {
      if (query.startsWith(prefix)) return true;
    }

    // Check for specific commands
    final debugKeywords = [
      'ble scan',
      'bluetooth scan',
      'scan bluetooth',
      'scan devices',
      'refresh devices',
      'local scan',
      'network scan',
      'connect station',
      'disconnect station',
      'start advertising',
      'ble advertise',
    ];

    for (final keyword in debugKeywords) {
      if (query.contains(keyword)) return true;
    }

    return false;
  }

  /// Handle debug/system commands
  Future<BotMessage> _handleDebugCommand(String query) async {
    final lowerQuery = query.toLowerCase();

    // Parse command and parameters
    String action;
    Map<String, dynamic> params = {};

    // BLE Scan
    if (lowerQuery.contains('ble scan') ||
        lowerQuery.contains('bluetooth scan') ||
        lowerQuery.contains('scan bluetooth') ||
        lowerQuery.contains('scan devices')) {
      action = 'ble_scan';
    }
    // BLE Advertise
    else if (lowerQuery.contains('ble advertise') ||
        lowerQuery.contains('start advertising')) {
      action = 'ble_advertise';
    }
    // Refresh devices
    else if (lowerQuery.contains('refresh devices') ||
        lowerQuery.contains('refresh all')) {
      action = 'refresh_devices';
    }
    // Local network scan
    else if (lowerQuery.contains('local scan') ||
        lowerQuery.contains('network scan') ||
        lowerQuery.contains('scan local') ||
        lowerQuery.contains('scan network')) {
      action = 'local_scan';
    }
    // Connect station
    else if (lowerQuery.contains('connect station') ||
        lowerQuery.contains('connect to station')) {
      action = 'connect_station';
      // Extract URL if provided
      final urlMatch = RegExp(r'(wss?://\S+)').firstMatch(query);
      if (urlMatch != null) {
        params['url'] = urlMatch.group(1);
      }
    }
    // Disconnect station
    else if (lowerQuery.contains('disconnect station') ||
        lowerQuery.contains('disconnect from station')) {
      action = 'disconnect_station';
    }
    // Navigate to panel
    else if (lowerQuery.startsWith('navigate ') ||
        lowerQuery.startsWith('go to ') ||
        lowerQuery.startsWith('open ')) {
      action = 'navigate';
      // Extract panel name
      final panels = ['collections', 'maps', 'devices', 'settings', 'logs', 'bluetooth', 'ble'];
      for (final panel in panels) {
        if (lowerQuery.contains(panel)) {
          params['panel'] = panel == 'bluetooth' || panel == 'ble' ? 'devices' : panel;
          break;
        }
      }
      if (!params.containsKey('panel')) {
        return BotMessage.bot(
          'Please specify a panel to navigate to. Available panels: collections, maps, devices, settings, logs',
        );
      }
    }
    // Send DM
    else if (lowerQuery.startsWith('send dm ') ||
        lowerQuery.startsWith('send message to ')) {
      action = 'send_dm';
      // Parse "send dm to CALLSIGN: MESSAGE" or "send dm CALLSIGN MESSAGE"
      final dmMatch = RegExp(r'(?:send (?:dm|message) (?:to )?)?([A-Z0-9-]+)[:\s]+(.+)', caseSensitive: false).firstMatch(query);
      if (dmMatch != null) {
        params['callsign'] = dmMatch.group(1)!.toUpperCase();
        params['content'] = dmMatch.group(2)!.trim();
      } else {
        return BotMessage.bot(
          'Please specify a callsign and message. Example: "send dm X1ABC: Hello!"',
        );
      }
    }
    // Show toast
    else if (lowerQuery.startsWith('show toast ') ||
        lowerQuery.startsWith('toast ')) {
      action = 'toast';
      final message = query.replaceFirst(RegExp(r'^(show )?toast\s+', caseSensitive: false), '');
      params['message'] = message;
    }
    // Open station chat
    else if (lowerQuery.contains('open chat') ||
        lowerQuery.contains('station chat')) {
      action = 'open_station_chat';
    }
    // Unknown command - try to execute as-is
    else {
      // Try to parse as "run ACTION PARAMS" or "execute ACTION PARAMS"
      final cmdMatch = RegExp(r'^(?:run|execute|trigger|/debug|/run)\s+(\w+)(?:\s+(.+))?$', caseSensitive: false).firstMatch(query);
      if (cmdMatch != null) {
        action = cmdMatch.group(1)!.toLowerCase();
        final paramsStr = cmdMatch.group(2);
        if (paramsStr != null) {
          // Try to parse key=value pairs
          for (final pair in paramsStr.split(RegExp(r'\s+'))) {
            final parts = pair.split('=');
            if (parts.length == 2) {
              params[parts[0]] = parts[1];
            }
          }
        }
      } else {
        return BotMessage.bot(
          _getDebugHelpMessage(),
        );
      }
    }

    // Execute the debug action
    final result = _debugController.executeAction(action, params);

    if (result['success'] == true) {
      return BotMessage.bot(
        result['message'] as String,
        sources: ['debug_api'],
      );
    } else {
      return BotMessage.bot(
        'Command failed: ${result['error']}',
      );
    }
  }

  /// Get help message for debug commands
  String _getDebugHelpMessage() {
    return '''**Available Commands:**

**Device & Network:**
- "scan devices" or "ble scan" - Start Bluetooth scan
- "ble advertise" - Start BLE advertising
- "refresh devices" - Refresh all device sources
- "local scan" or "network scan" - Scan local network

**Station:**
- "connect station" - Connect to default station
- "connect station wss://..." - Connect to specific station
- "disconnect station" - Disconnect from station
- "open chat" - Open station chat

**Navigation:**
- "go to maps" - Navigate to Maps panel
- "go to devices" - Navigate to Devices panel
- "go to settings" - Navigate to Settings panel

**Messaging:**
- "send dm CALLSIGN: message" - Send direct message
- "show toast message" - Display a toast notification

**Generic:**
- "run ACTION" - Execute any debug API action''';
  }

  /// Handle image analysis queries
  Future<BotMessage> _handleImageQuery(String imagePath, String question) async {
    try {
      // Check if vision models are available
      final hasVision = await _visionService.hasVisionModel();
      if (!hasVision) {
        return BotMessage.bot(
          'No vision model installed. Please go to Bot Settings to download a vision model.',
        );
      }

      // Analyze the image
      final visionResult = await _visionService.analyzeImage(
        imagePath,
        question: question.isNotEmpty ? question : null,
      );

      // Build response from vision result
      final response = _buildVisionResponse(visionResult, question);

      return BotMessage.bot(
        response,
        sources: [visionResult.modelUsed],
        visionResult: visionResult,
      );
    } catch (e) {
      LogService().log('BotService: Vision analysis error: $e');
      return BotMessage.bot(
        'Error analyzing image: $e',
      );
    }
  }

  /// Build a response from vision analysis result
  String _buildVisionResponse(VisionResult result, String question) {
    final buffer = StringBuffer();

    // Add description if available
    if (result.description != null && result.description!.isNotEmpty) {
      buffer.writeln(result.description);
      buffer.writeln();
    }

    // Add species identification if available
    if (result.species != null) {
      buffer.writeln('**Species Identification:**');
      buffer.writeln('- Scientific name: ${result.species!.scientificName}');
      if (result.species!.commonName != null) {
        buffer.writeln('- Common name: ${result.species!.commonName}');
      }
      buffer.writeln('- Confidence: ${(result.species!.confidence * 100).toStringAsFixed(1)}%');
      if (result.species!.isToxic) {
        buffer.writeln();
        buffer.writeln('${result.species!.warning ?? 'Warning: This species may be toxic.'}');
      }
      buffer.writeln();
    }

    // Add extracted text if available
    if (result.extractedText != null && result.extractedText!.isNotEmpty) {
      buffer.writeln('**Text found:**');
      buffer.writeln(result.extractedText);
      if (result.transliteration != null) {
        buffer.writeln();
        buffer.writeln('**Transliteration:** ${result.transliteration}');
      }
      if (result.translation != null) {
        buffer.writeln('**Translation:** ${result.translation}');
      }
      buffer.writeln();
    }

    // Add detected objects if available
    if (result.objects.isNotEmpty) {
      buffer.writeln('**Objects detected:**');
      final objectCounts = <String, int>{};
      for (final obj in result.objects) {
        objectCounts[obj.label] = (objectCounts[obj.label] ?? 0) + 1;
      }
      for (final entry in objectCounts.entries) {
        final count = entry.value > 1 ? ' (${entry.value})' : '';
        buffer.writeln('- ${entry.key}$count');
      }
      buffer.writeln();
    }

    // Add labels if available
    if (result.labels.isNotEmpty && result.species == null) {
      buffer.writeln('**Classifications:** ${result.labels.take(5).join(', ')}');
      buffer.writeln();
    }

    // Add processing info
    buffer.writeln('_Analyzed in ${result.processingTimeMs}ms using ${result.modelUsed}_');

    return buffer.toString().trim();
  }

  bool _isDistanceQuery(String query) {
    return query.contains('how far') ||
        query.contains('distance to') ||
        query.contains('distance from') ||
        query.contains('km to') ||
        query.contains('far to') ||
        query.contains('far are we');
  }

  bool _isNearestCityQuery(String query) {
    return query.contains('nearest city') ||
        query.contains('closest city') ||
        query.contains('nearby city');
  }

  bool _isWhereAmIQuery(String query) {
    return query.contains('where am i') ||
        query.contains('my location') ||
        query.contains('current location');
  }

  bool _isCityInfoQuery(String query) {
    return query.contains('tell me about') ||
        query.contains('info about') ||
        query.contains('population of') ||
        query.contains('what is');
  }

  Future<BotMessage> _handleDistanceQuery(String query) async {
    // Extract city name from query
    final cityName = _extractCityName(query);
    if (cityName == null) {
      return BotMessage.bot(
        'I couldn\'t identify which city you\'re asking about. Please specify a city name.',
      );
    }

    // Find the city
    final city = _findCity(cityName);
    if (city == null) {
      return BotMessage.bot(
        'I couldn\'t find a city named "$cityName" in my database.',
      );
    }

    // Get current location
    final location = await _getCurrentLocation();
    if (location == null) {
      return BotMessage.bot(
        'I need access to your location to calculate the distance. Please enable location services.',
      );
    }

    // Calculate distance
    final cityLat = double.tryParse(city['lat'].toString()) ?? 0;
    final cityLng = double.tryParse(city['lng'].toString()) ?? 0;
    final distance = _calculateDistance(location.$1, location.$2, cityLat, cityLng);

    final cityNameStr = city['city'] ?? cityName;
    final country = city['country'] ?? '';

    return BotMessage.bot(
      '**$cityNameStr** ($country) is approximately **${distance.toStringAsFixed(1)} km** from your current location.',
      sources: ['worldcities.csv'],
    );
  }

  Future<BotMessage> _handleNearestCityQuery() async {
    final location = await _getCurrentLocation();
    if (location == null) {
      return BotMessage.bot(
        'I need access to your location to find nearby cities. Please enable location services.',
      );
    }

    if (_cities == null || _cities!.isEmpty) {
      return BotMessage.bot(
        'City database is not available.',
      );
    }

    // Find nearest cities
    final citiesWithDistance = <Map<String, dynamic>>[];
    for (final city in _cities!) {
      final lat = double.tryParse(city['lat'].toString()) ?? 0;
      final lng = double.tryParse(city['lng'].toString()) ?? 0;
      final distance = _calculateDistance(location.$1, location.$2, lat, lng);
      citiesWithDistance.add({...city, 'distance': distance});
    }

    citiesWithDistance.sort((a, b) =>
      (a['distance'] as double).compareTo(b['distance'] as double));

    final nearest = citiesWithDistance.take(5).toList();

    final buffer = StringBuffer();
    buffer.writeln('Based on your current location (${location.$1.toStringAsFixed(4)}, ${location.$2.toStringAsFixed(4)}):');
    buffer.writeln();
    buffer.writeln('**Nearest cities:**');

    for (var i = 0; i < nearest.length; i++) {
      final city = nearest[i];
      final distance = city['distance'] as double;
      final distStr = distance < 1
          ? '${(distance * 1000).round()} m'
          : '${distance.toStringAsFixed(1)} km';
      buffer.writeln('${i + 1}. **${city['city']}**, ${city['country']} ($distStr)');
    }

    return BotMessage.bot(
      buffer.toString(),
      sources: ['worldcities.csv'],
    );
  }

  Future<BotMessage> _handleWhereAmIQuery() async {
    final location = await _getCurrentLocation();
    if (location == null) {
      return BotMessage.bot(
        'I need access to your location. Please enable location services.',
      );
    }

    if (_cities == null || _cities!.isEmpty) {
      return BotMessage.bot(
        'Your coordinates: ${location.$1.toStringAsFixed(4)}, ${location.$2.toStringAsFixed(4)}',
      );
    }

    // Find nearest city
    Map<String, dynamic>? nearestCity;
    double nearestDistance = double.infinity;

    for (final city in _cities!) {
      final lat = double.tryParse(city['lat'].toString()) ?? 0;
      final lng = double.tryParse(city['lng'].toString()) ?? 0;
      final distance = _calculateDistance(location.$1, location.$2, lat, lng);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestCity = city;
      }
    }

    if (nearestCity == null) {
      return BotMessage.bot(
        'Your coordinates: ${location.$1.toStringAsFixed(4)}, ${location.$2.toStringAsFixed(4)}',
      );
    }

    final buffer = StringBuffer();
    buffer.writeln('Based on your GPS coordinates (${location.$1.toStringAsFixed(4)}, ${location.$2.toStringAsFixed(4)}):');
    buffer.writeln();
    buffer.writeln('You are near **${nearestCity['city']}**, ${nearestCity['country']}');
    buffer.writeln('- Distance: ${nearestDistance.toStringAsFixed(1)} km');
    if (nearestCity['admin_name'] != null && nearestCity['admin_name'].toString().isNotEmpty) {
      buffer.writeln('- Region: ${nearestCity['admin_name']}');
    }
    if (nearestCity['capital'] == 'primary') {
      buffer.writeln('- This is the capital city');
    }

    return BotMessage.bot(
      buffer.toString(),
      sources: ['worldcities.csv'],
    );
  }

  Future<BotMessage> _handleCityInfoQuery(String query) async {
    final cityName = _extractCityName(query);
    if (cityName == null) {
      return BotMessage.bot(
        'Please specify which city you want to know about.',
      );
    }

    final city = _findCity(cityName);
    if (city == null) {
      return BotMessage.bot(
        'I couldn\'t find a city named "$cityName" in my database.',
      );
    }

    final buffer = StringBuffer();
    buffer.writeln('**${city['city']}**');
    buffer.writeln();
    buffer.writeln('- Country: ${city['country']} (${city['iso2']})');
    if (city['admin_name'] != null && city['admin_name'].toString().isNotEmpty) {
      buffer.writeln('- Region: ${city['admin_name']}');
    }
    final population = int.tryParse(city['population'].toString()) ?? 0;
    if (population > 0) {
      buffer.writeln('- Population: ${_formatNumber(population)}');
    }
    buffer.writeln('- Coordinates: ${city['lat']}, ${city['lng']}');
    if (city['capital'] == 'primary') {
      buffer.writeln('- Capital: Yes (national capital)');
    } else if (city['capital'] == 'admin') {
      buffer.writeln('- Capital: Regional capital');
    }

    return BotMessage.bot(
      buffer.toString(),
      sources: ['worldcities.csv'],
    );
  }

  String? _extractCityName(String query) {
    // Common patterns
    final patterns = [
      RegExp(r'to\s+([a-zA-ZÀ-ÿ\s]+?)(?:\?|$|\.)', caseSensitive: false),
      RegExp(r'from\s+([a-zA-ZÀ-ÿ\s]+?)(?:\?|$|\.)', caseSensitive: false),
      RegExp(r'about\s+([a-zA-ZÀ-ÿ\s]+?)(?:\?|$|\.)', caseSensitive: false),
      RegExp(r'of\s+([a-zA-ZÀ-ÿ\s]+?)(?:\?|$|\.)', caseSensitive: false),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(query);
      if (match != null && match.group(1) != null) {
        final name = match.group(1)!.trim();
        if (name.isNotEmpty && name.length > 2) {
          return name;
        }
      }
    }

    return null;
  }

  Map<String, dynamic>? _findCity(String name) {
    if (_cities == null) return null;

    final lowerName = name.toLowerCase().trim();

    // Exact match first
    for (final city in _cities!) {
      if (city['city_ascii'].toString().toLowerCase() == lowerName ||
          city['city'].toString().toLowerCase() == lowerName) {
        return city;
      }
    }

    // Partial match
    for (final city in _cities!) {
      if (city['city_ascii'].toString().toLowerCase().contains(lowerName) ||
          city['city'].toString().toLowerCase().contains(lowerName)) {
        return city;
      }
    }

    return null;
  }

  Future<(double, double)?> _getCurrentLocation() async {
    try {
      final location = UserLocationService().currentLocation;
      if (location != null && location.isValid) {
        return (location.latitude, location.longitude);
      }
    } catch (e) {
      LogService().log('BotService: Error getting location: $e');
    }
    return null;
  }

  /// Calculate distance between two coordinates using Haversine formula
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371.0; // km

    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) * cos(_toRadians(lat2)) *
        sin(dLon / 2) * sin(dLon / 2);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return earthRadius * c;
  }

  double _toRadians(double degrees) => degrees * pi / 180;

  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(0)}K';
    }
    return number.toString();
  }

  String _getDefaultResponse() {
    final i18n = I18nService();
    return '''${i18n.t('bot_greeting')}

${i18n.t('bot_example_questions')}
- "${i18n.t('bot_example_nearby')}"
- "${i18n.t('bot_example_events')}"
- "${i18n.t('bot_example_distance')}"
- "Where am I?"
- "Tell me about Tokyo"

**Image Analysis** (attach an image):
- "What's in this photo?"
- "Identify this plant"
- "What does this sign say?"

**Music Generation:**
- "Play 5 minutes of jazz"
- "Generate ambient music"
- "Play rock music"

**Commands** (internal app control):
- "scan devices" - Start BLE scan
- "go to settings" - Navigate to panel
- Type "run" for more commands''';
  }

  void _notifyListeners() {
    _messagesController.add(List.unmodifiable(_messages));
  }

  /// Clear conversation history
  Future<void> clearConversation() async {
    _messages.clear();
    _notifyListeners();
    await _saveConversationHistory();
  }

  /// Update a music generating message with the completed track
  Future<void> updateMusicMessage(String messageId, MusicTrack track) async {
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index == -1) {
      LogService().log('BotService: Message $messageId not found for music update');
      return;
    }

    // Replace the message with a completed music message
    final oldMessage = _messages[index];
    final newMessage = BotMessage(
      id: oldMessage.id,
      content: 'Generated ${track.genreDisplayName} music',
      isUser: false,
      timestamp: oldMessage.timestamp,
      musicTrack: track,
    );

    _messages[index] = newMessage;
    _notifyListeners();
    await _saveConversationHistory();
    LogService().log('BotService: Updated message $messageId with music track');
  }

  /// Load conversation history from file
  Future<void> _loadConversationHistory() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/bot_conversation.json');

      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> json = jsonDecode(content);
        _messages.clear();
        _messages.addAll(json.map((j) => BotMessage.fromJson(j)));
        _notifyListeners();
      }
    } catch (e) {
      LogService().log('BotService: Error loading conversation: $e');
    }
  }

  /// Save conversation history to file
  Future<void> _saveConversationHistory() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/bot_conversation.json');

      final json = _messages
          .where((m) => !m.isThinking)
          .map((m) => m.toJson())
          .toList();

      await file.writeAsString(jsonEncode(json));
    } catch (e) {
      LogService().log('BotService: Error saving conversation: $e');
    }
  }

  void dispose() {
    // Cancel EventBus subscriptions
    for (final subscription in _eventSubscriptions) {
      subscription.cancel();
    }
    _eventSubscriptions.clear();

    _visionService.dispose();
    _messagesController.close();
  }

  /// Get the vision service for external access (e.g., settings page)
  VisionService get visionService => _visionService;

  /// Get the music service for external access (e.g., settings page)
  MusicGenerationService get musicService => _musicService;
}
