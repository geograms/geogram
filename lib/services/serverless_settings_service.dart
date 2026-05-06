/// Singleton wrapper for ServerlessSettings persistence.
///
/// Settings live at `{callsign}/p2p/serverless_settings.json` inside whatever
/// ProfileStorage the active profile uses (encrypted SQLite or filesystem).
/// CLAUDE.md rule: never raw `File`/`Directory` for files inside the profile
/// folder.
library;

import 'dart:async';

import '../models/serverless_settings.dart';
import 'app_service.dart';
import 'log_service.dart';

class ServerlessSettingsService {
  ServerlessSettingsService._();
  static final ServerlessSettingsService _instance =
      ServerlessSettingsService._();
  factory ServerlessSettingsService() => _instance;

  static const String _path = 'p2p/serverless_settings.json';

  final LogService _log = LogService();
  ServerlessSettings _current = ServerlessSettings();
  bool _loaded = false;
  final _changes = StreamController<ServerlessSettings>.broadcast();

  ServerlessSettings get current => _current;
  Stream<ServerlessSettings> get onChanged => _changes.stream;
  bool get isLoaded => _loaded;

  Future<ServerlessSettings> load() async {
    final storage = AppService().profileStorage;
    if (storage == null) {
      _loaded = true;
      return _current;
    }
    try {
      final json = await storage.readJson(_path);
      if (json != null) {
        _current = ServerlessSettings.fromJson(json);
      }
    } catch (e) {
      _log.warn('ServerlessSettings: failed to load, using defaults: $e');
    }
    _loaded = true;
    return _current;
  }

  Future<void> save(ServerlessSettings next) async {
    _current = next;
    final storage = AppService().profileStorage;
    if (storage != null) {
      try {
        await storage.writeJson(_path, next.toJson());
      } catch (e) {
        _log.error('ServerlessSettings: save failed: $e');
      }
    }
    if (!_changes.isClosed) _changes.add(next);
  }

  Future<void> update(
      void Function(ServerlessSettings draft) mutate) async {
    final draft = ServerlessSettings.fromJson(_current.toJson());
    mutate(draft);
    await save(draft);
  }
}
