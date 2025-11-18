import '../models/relay.dart';
import '../services/config_service.dart';
import '../services/log_service.dart';

/// Service for managing internet relays
class RelayService {
  static final RelayService _instance = RelayService._internal();
  factory RelayService() => _instance;
  RelayService._internal();

  List<Relay> _relays = [];
  bool _initialized = false;

  /// Default relays
  static final List<Relay> _defaultRelays = [
    Relay(
      url: 'wss://relay.geogram.io',
      name: 'Geogram Primary',
      status: 'available',
      location: 'Frankfurt, Germany',
      latitude: 50.1109,
      longitude: 8.6821,
    ),
    Relay(
      url: 'wss://relay2.geogram.io',
      name: 'Geogram Secondary',
      status: 'available',
      location: 'New York, USA',
      latitude: 40.7128,
      longitude: -74.0060,
    ),
    Relay(
      url: 'wss://nostr-pub.wellorder.net',
      name: 'Wellorder',
      status: 'available',
      location: 'London, UK',
      latitude: 51.5074,
      longitude: -0.1278,
    ),
    Relay(
      url: 'wss://relay.damus.io',
      name: 'Damus',
      status: 'available',
      location: 'San Francisco, USA',
      latitude: 37.7749,
      longitude: -122.4194,
    ),
    Relay(
      url: 'wss://nos.lol',
      name: 'nos.lol',
      status: 'available',
      location: 'Amsterdam, Netherlands',
      latitude: 52.3676,
      longitude: 4.9041,
    ),
    Relay(
      url: 'wss://relay.nostr.band',
      name: 'Nostr Band',
      status: 'available',
      location: 'Singapore',
      latitude: 1.3521,
      longitude: 103.8198,
    ),
  ];

  /// Initialize relay service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await _loadRelays();
      _initialized = true;
      LogService().log('RelayService initialized with ${_relays.length} relays');
    } catch (e) {
      LogService().log('Error initializing RelayService: $e');
    }
  }

  /// Load relays from config
  Future<void> _loadRelays() async {
    final config = ConfigService().getAll();

    if (config.containsKey('relays')) {
      final relaysData = config['relays'] as List<dynamic>;
      _relays = relaysData.map((data) => Relay.fromJson(data as Map<String, dynamic>)).toList();
      LogService().log('Loaded ${_relays.length} relays from config');
    } else {
      // First time - use default relays
      _relays = _defaultRelays.map((r) => r.copyWith()).toList();

      // Set first as preferred
      if (_relays.isNotEmpty) {
        _relays[0] = _relays[0].copyWith(status: 'preferred');
      }

      await _saveRelays();
      LogService().log('Created default relay configuration');
    }
  }

  /// Save relays to config
  Future<void> _saveRelays() async {
    final relaysData = _relays.map((r) => r.toJson()).toList();
    await ConfigService().set('relays', relaysData);
    LogService().log('Saved ${_relays.length} relays to config');
  }

  /// Get all relays
  List<Relay> getAllRelays() {
    if (!_initialized) {
      throw Exception('RelayService not initialized');
    }
    return List.unmodifiable(_relays);
  }

  /// Get preferred relay
  Relay? getPreferredRelay() {
    return _relays.firstWhere(
      (r) => r.status == 'preferred',
      orElse: () => _relays.isNotEmpty ? _relays[0] : Relay(url: '', name: ''),
    );
  }

  /// Get backup relays
  List<Relay> getBackupRelays() {
    return _relays.where((r) => r.status == 'backup').toList();
  }

  /// Get available relays (not selected)
  List<Relay> getAvailableRelays() {
    return _relays.where((r) => r.status == 'available').toList();
  }

  /// Add a new relay
  Future<void> addRelay(Relay relay) async {
    // Check if URL already exists
    final exists = _relays.any((r) => r.url == relay.url);
    if (exists) {
      throw Exception('Relay URL already exists');
    }

    _relays.add(relay);
    await _saveRelays();
    LogService().log('Added relay: ${relay.name}');
  }

  /// Update relay
  Future<void> updateRelay(String url, Relay updatedRelay) async {
    final index = _relays.indexWhere((r) => r.url == url);
    if (index == -1) {
      throw Exception('Relay not found');
    }

    _relays[index] = updatedRelay;
    await _saveRelays();
    LogService().log('Updated relay: ${updatedRelay.name}');
  }

  /// Set relay as preferred
  Future<void> setPreferred(String url) async {
    // Remove preferred status from all relays
    for (var i = 0; i < _relays.length; i++) {
      if (_relays[i].status == 'preferred') {
        _relays[i] = _relays[i].copyWith(status: 'available');
      }
    }

    // Set new preferred
    final index = _relays.indexWhere((r) => r.url == url);
    if (index != -1) {
      _relays[index] = _relays[index].copyWith(status: 'preferred');
      await _saveRelays();
      LogService().log('Set preferred relay: ${_relays[index].name}');
    }
  }

  /// Set relay as backup
  Future<void> setBackup(String url) async {
    final index = _relays.indexWhere((r) => r.url == url);
    if (index != -1) {
      _relays[index] = _relays[index].copyWith(status: 'backup');
      await _saveRelays();
      LogService().log('Set backup relay: ${_relays[index].name}');
    }
  }

  /// Set relay as available (unselect)
  Future<void> setAvailable(String url) async {
    final index = _relays.indexWhere((r) => r.url == url);
    if (index != -1) {
      _relays[index] = _relays[index].copyWith(status: 'available');
      await _saveRelays();
      LogService().log('Set relay as available: ${_relays[index].name}');
    }
  }

  /// Delete relay
  Future<void> deleteRelay(String url) async {
    final index = _relays.indexWhere((r) => r.url == url);
    if (index != -1) {
      final relay = _relays[index];
      _relays.removeAt(index);
      await _saveRelays();
      LogService().log('Deleted relay: ${relay.name}');
    }
  }

  /// Test relay connection (stub for now)
  Future<void> testConnection(String url) async {
    final index = _relays.indexWhere((r) => r.url == url);
    if (index != -1) {
      // Simulate connection test
      await Future.delayed(const Duration(seconds: 1));

      // For now, just update last checked time
      _relays[index] = _relays[index].copyWith(
        lastChecked: DateTime.now(),
        isConnected: true,
        latency: 50 + (url.hashCode % 100), // Simulated latency
      );

      await _saveRelays();
      LogService().log('Tested relay: ${_relays[index].name}');
    }
  }
}
