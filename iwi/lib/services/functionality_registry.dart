/*
 * FunctionalityRegistry — map of functionalityId → providers.
 *
 * The launcher rebuilds this whenever it scans for wapps. Providers
 * are WappManifest entries whose manifest.json declared one or more
 * functionality IDs under `provides.functionalities`, plus a
 * synthetic "Geogram Core" entry for the HAL capabilities built
 * into the runtime itself.
 *
 * Each functionality carries an optional [FunctionalityDef] with
 * endpoint signatures (params, return types) so alternative
 * providers know exactly what contract they must implement.
 */

import '../main.dart' show WappManifest;

// ── API definition data classes ─────────────────────────────────────

class ParamDef {
  final String name;
  final String type;
  final String description;
  const ParamDef(this.name, this.type, [this.description = '']);

  factory ParamDef.fromJson(Map<String, dynamic> json) => ParamDef(
        json['name'] as String? ?? '',
        json['type'] as String? ?? 'any',
        json['description'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        if (description.isNotEmpty) 'description': description,
      };
}

class ReturnDef {
  final String type;
  final String description;
  final Map<String, String> fields;
  const ReturnDef(this.type, [this.description = '', this.fields = const {}]);

  factory ReturnDef.fromJson(dynamic json) {
    if (json is String) return ReturnDef(json);
    if (json is Map<String, dynamic>) {
      final fields = <String, String>{};
      final rawFields = json['fields'];
      if (rawFields is Map) {
        for (final e in rawFields.entries) {
          fields[e.key.toString()] = e.value?.toString() ?? 'any';
        }
      }
      return ReturnDef(
        json['type'] as String? ?? 'void',
        json['description'] as String? ?? '',
        fields,
      );
    }
    return const ReturnDef('void');
  }
}

class EndpointDef {
  final String name;
  final String description;
  final List<ParamDef> params;
  final ReturnDef returns;
  const EndpointDef(this.name, this.description, this.params, this.returns);

  factory EndpointDef.fromJson(Map<String, dynamic> json) {
    final rawParams = json['params'];
    final params = rawParams is List
        ? rawParams
            .whereType<Map<String, dynamic>>()
            .map(ParamDef.fromJson)
            .toList()
        : const <ParamDef>[];
    return EndpointDef(
      json['name'] as String? ?? '',
      json['description'] as String? ?? '',
      params,
      ReturnDef.fromJson(json['returns'] ?? 'void'),
    );
  }
}

class FunctionalityDef {
  final String id;
  final String description;
  final List<EndpointDef> endpoints;
  const FunctionalityDef(this.id, this.description,
      [this.endpoints = const []]);

  factory FunctionalityDef.fromJson(Map<String, dynamic> json) {
    final rawEndpoints = json['endpoints'];
    final endpoints = rawEndpoints is List
        ? rawEndpoints
            .whereType<Map<String, dynamic>>()
            .map(EndpointDef.fromJson)
            .toList()
        : const <EndpointDef>[];
    return FunctionalityDef(
      json['id'] as String? ?? '',
      json['description'] as String? ?? '',
      endpoints,
    );
  }
}

// ── Registry ────────────────────────────────────────────────────────

class FunctionalityRegistry {
  FunctionalityRegistry._();
  static final FunctionalityRegistry instance = FunctionalityRegistry._();

  final Map<String, List<WappManifest>> _providers = {};

  /// API definitions keyed by functionality ID. Populated from core
  /// definitions and from wapp manifests that use the rich object
  /// format in `provides.functionalities`.
  final Map<String, FunctionalityDef> _defs = {};

  void clear() {
    _providers.clear();
    _defs.clear();
  }

  void registerCore() {
    for (final entry in coreFunctionalities.entries) {
      (_providers[entry.key] ??= []).add(_coreManifest);
      _defs[entry.key] = entry.value;
    }
  }

  void register(WappManifest manifest) {
    for (final id in manifest.providedFunctionalities) {
      if (id.isEmpty) continue;
      (_providers[id] ??= []).add(manifest);
    }
    // Merge any rich definitions the manifest carries.
    for (final def in manifest.functionalityDefs) {
      if (def.id.isEmpty) continue;
      // Wapp definitions don't overwrite core — they supplement.
      _defs.putIfAbsent(def.id, () => def);
    }
  }

  List<WappManifest> providersFor(String functionalityId) {
    return List.unmodifiable(_providers[functionalityId] ?? const []);
  }

  FunctionalityDef? defFor(String functionalityId) => _defs[functionalityId];

  Set<String> get allFunctionalityIds => _providers.keys.toSet();

  Map<String, List<String>> toJson() => {
        for (final entry in _providers.entries)
          entry.key: [for (final p in entry.value) p.id],
      };

  static final WappManifest _coreManifest = WappManifest(
    id: 'geogram.core',
    name: 'core',
    title: 'Geogram Core',
    description: 'Built-in HAL capabilities provided by the geogram runtime.',
    kind: 'system',
    dirPath: '',
    providedFunctionalities: coreFunctionalities.keys.toList(),
  );

  // ── Core HAL API definitions ──────────────────────────────────────

  static final coreFunctionalities = <String, FunctionalityDef>{
    'hal.log': FunctionalityDef('hal.log', 'Logging', [
      EndpointDef('hal_log', 'Write a log message', [
        ParamDef('level', 'int', '0=debug, 1=info, 2=warn, 3=error'),
        ParamDef('msg', 'string', 'Message text'),
      ], ReturnDef('void')),
    ]),
    'hal.time': FunctionalityDef('hal.time', 'Time functions', [
      EndpointDef('hal_time_ms', 'Monotonic ms since host start', [],
          ReturnDef('uint64', 'Milliseconds')),
      EndpointDef('hal_time_epoch', 'Unix epoch seconds (0 if no RTC)', [],
          ReturnDef('uint64', 'Seconds')),
    ]),
    'hal.yield': FunctionalityDef('hal.yield', 'Cooperative multitasking', [
      EndpointDef('hal_yield', 'Yield to other tasks (ESP32)', [],
          ReturnDef('void')),
    ]),
    'hal.platform':
        FunctionalityDef('hal.platform', 'Platform identification', [
      EndpointDef('hal_platform', 'Get platform name', [
        ParamDef('buf', 'buffer', 'Output buffer'),
      ], ReturnDef('uint32', 'Bytes written. Values: esp32, android, linux-desktop, linux-cli')),
    ]),
    'hal.heap': FunctionalityDef('hal.heap', 'Heap status', [
      EndpointDef('hal_heap_free', 'Free heap bytes available to module', [],
          ReturnDef('uint32', 'Bytes')),
    ]),
    'hal.kv': FunctionalityDef(
        'hal.kv', 'Key-value storage (scoped per module)', [
      EndpointDef('hal_kv_get', 'Read a value by key', [
        ParamDef('key', 'string', 'Key to look up'),
      ], ReturnDef('bytes', 'Value bytes, 0 length if not found')),
      EndpointDef('hal_kv_set', 'Write a key-value pair', [
        ParamDef('key', 'string'),
        ParamDef('value', 'bytes'),
      ], ReturnDef('int', '0 on success, -1 on error')),
      EndpointDef('hal_kv_delete', 'Delete a key', [
        ParamDef('key', 'string'),
      ], ReturnDef('int', '0 on success, -1 if not found')),
      EndpointDef('hal_kv_list', 'List keys by prefix', [
        ParamDef('prefix', 'string', 'Key prefix to match'),
      ], ReturnDef('uint32', 'Count of matching keys; null-separated in buffer')),
      EndpointDef('hal_kv_exists', 'Check if a key exists', [
        ParamDef('key', 'string'),
      ], ReturnDef('int', '1 if exists, 0 if not')),
      EndpointDef('hal_kv_size', 'Get value size without reading', [
        ParamDef('key', 'string'),
      ], ReturnDef('uint32', 'Size in bytes, 0 if not found')),
    ]),
    'hal.i18n': FunctionalityDef('hal.i18n', 'Internationalization', [
      EndpointDef('hal_i18n_get', 'Look up translation key against lang/*.json', [
        ParamDef('key', 'string', 'Translation key'),
      ], ReturnDef('string', 'Translated text, empty if missing')),
    ]),
    'hal.file':
        FunctionalityDef('hal.file', 'File I/O (scoped per module)', [
      EndpointDef('hal_file_open', 'Open a file', [
        ParamDef('path', 'string', 'Relative path'),
        ParamDef('mode', 'int', '0=read, 1=write, 2=append'),
      ], ReturnDef('int', 'Handle (>=0) or -1 on error')),
      EndpointDef('hal_file_read', 'Read from an open file', [
        ParamDef('handle', 'int'),
      ], ReturnDef('int', 'Bytes read, 0 on EOF, -1 on error')),
      EndpointDef('hal_file_write', 'Write to an open file', [
        ParamDef('handle', 'int'),
        ParamDef('data', 'bytes'),
      ], ReturnDef('int', 'Bytes written or -1 on error')),
      EndpointDef('hal_file_close', 'Close a file handle', [
        ParamDef('handle', 'int'),
      ], ReturnDef('void')),
    ]),
    'hal.http':
        FunctionalityDef('hal.http', 'HTTP requests (async polling)', [
      EndpointDef('hal_http_request', 'Start an HTTP request', [
        ParamDef('method', 'int', '0=GET, 1=POST, 2=PUT, 3=DELETE'),
        ParamDef('url', 'string'),
        ParamDef('body', 'string', 'Request body (empty for GET)'),
      ], ReturnDef('int', 'Request ID or -1 on error')),
      EndpointDef('hal_http_poll', 'Check if request is complete', [
        ParamDef('request_id', 'int'),
      ], ReturnDef('int', '0=pending, 1=complete, -1=error')),
      EndpointDef('hal_http_read_response', 'Read response body', [
        ParamDef('request_id', 'int'),
      ], ReturnDef('bytes', 'Response body bytes')),
      EndpointDef('hal_http_status', 'Get HTTP status code', [
        ParamDef('request_id', 'int'),
      ], ReturnDef('int', 'HTTP status code or -1 if pending')),
      EndpointDef('hal_http_free', 'Free request resources', [
        ParamDef('request_id', 'int'),
      ], ReturnDef('void')),
    ]),
    'hal.msg': FunctionalityDef(
        'hal.msg', 'Inter-wapp messaging (host ↔ module JSON)', [
      EndpointDef('hal_msg_send', 'Send a JSON message to the host', [
        ParamDef('json', 'string', 'JSON-encoded message'),
      ], ReturnDef('void')),
      EndpointDef('hal_msg_available', 'Bytes in next pending message', [],
          ReturnDef('uint32', '0 if none')),
      EndpointDef('hal_msg_recv', 'Receive next pending message', [],
          ReturnDef('string', 'JSON message bytes')),
    ]),
    'hal.event': FunctionalityDef(
        'hal.event', 'Event pub/sub between modules', [
      EndpointDef('hal_event_subscribe', 'Subscribe to a topic', [
        ParamDef('topic', 'string'),
      ], ReturnDef('int', '0 on success, -1 on error')),
      EndpointDef('hal_event_unsubscribe', 'Unsubscribe from a topic', [
        ParamDef('topic', 'string'),
      ], ReturnDef('int', '0 on success, -1 if not subscribed')),
      EndpointDef('hal_event_publish', 'Publish data to a topic', [
        ParamDef('topic', 'string'),
        ParamDef('data', 'bytes'),
      ], ReturnDef('int', 'Number of subscribers notified')),
      EndpointDef('hal_event_available', 'Size of next pending event', [],
          ReturnDef('uint32', '0 if none')),
      EndpointDef('hal_event_recv', 'Receive next event', [],
          ReturnDef('bytes', 'Topic + data bytes')),
    ]),
    'hal.lib': FunctionalityDef('hal.lib', 'Cross-module library calls', [
      EndpointDef('hal_lib_call', 'Call a function in another module', [
        ParamDef('lib_id', 'string', 'Target module ID'),
        ParamDef('fn_name', 'string', 'Function name'),
        ParamDef('args', 'string', 'JSON arguments'),
      ], ReturnDef('string',
          'JSON result. Errors: -1=lib not found, -2=fn not found, -3=buffer too small, -4=internal')),
    ]),
    'hal.lora': FunctionalityDef('hal.lora', 'LoRa radio communication', [
      EndpointDef('hal_lora_available_hw', 'Check if LoRa hardware is present', [],
          ReturnDef('int', '1 if present, 0 otherwise')),
      EndpointDef('hal_lora_send', 'Send data over LoRa', [
        ParamDef('data', 'bytes'),
      ], ReturnDef('int', '0 on success, -1 on error')),
      EndpointDef('hal_lora_available', 'Bytes available to read', [],
          ReturnDef('uint32')),
      EndpointDef('hal_lora_recv', 'Receive LoRa data', [],
          ReturnDef('bytes', 'Received data')),
    ]),
    'hal.ble': FunctionalityDef('hal.ble', 'Bluetooth Low Energy', [
      EndpointDef('hal_ble_scan_start', 'Start BLE scanning', [],
          ReturnDef('int', '0 on success')),
      EndpointDef('hal_ble_scan_stop', 'Stop BLE scanning', [],
          ReturnDef('void')),
      EndpointDef('hal_ble_scan_read', 'Read scan results (JSON)', [],
          ReturnDef('string', 'JSON scan results, empty if none')),
      EndpointDef('hal_ble_advertise', 'Start BLE advertising', [
        ParamDef('data', 'bytes', 'Advertisement payload'),
      ], ReturnDef('int', '0 on success')),
      EndpointDef('hal_ble_advertise_stop', 'Stop BLE advertising', [],
          ReturnDef('void')),
    ]),
    'hal.sensor': FunctionalityDef(
        'hal.sensor', 'Hardware sensors (returns INT32_MIN if N/A)', [
      EndpointDef('hal_sensor_temperature', 'Temperature', [],
          ReturnDef('int', 'Centidegrees C (2500 = 25.00°C)')),
      EndpointDef('hal_sensor_humidity', 'Humidity', [],
          ReturnDef('int', 'Centipercent (6500 = 65.00%)')),
      EndpointDef('hal_sensor_battery', 'Battery voltage', [],
          ReturnDef('int', 'Millivolts (3700 = 3.7V)')),
      EndpointDef('hal_sensor_gps_lat', 'GPS latitude', [],
          ReturnDef('int', 'Latitude × 1e7')),
      EndpointDef('hal_sensor_gps_lon', 'GPS longitude', [],
          ReturnDef('int', 'Longitude × 1e7')),
    ]),
    'hal.display': FunctionalityDef('hal.display', 'Display/screen output', [
      EndpointDef('hal_display_width', 'Screen width', [],
          ReturnDef('uint32', 'Pixels, 0 if no display')),
      EndpointDef('hal_display_height', 'Screen height', [],
          ReturnDef('uint32', 'Pixels, 0 if no display')),
      EndpointDef('hal_display_clear', 'Clear the display', [],
          ReturnDef('void')),
      EndpointDef('hal_display_text', 'Draw text', [
        ParamDef('x', 'int'),
        ParamDef('y', 'int'),
        ParamDef('color', 'int', '0=black, 1=white'),
        ParamDef('text', 'string'),
      ], ReturnDef('void')),
      EndpointDef('hal_display_pixel', 'Draw a pixel', [
        ParamDef('x', 'int'),
        ParamDef('y', 'int'),
        ParamDef('color', 'int'),
      ], ReturnDef('void')),
      EndpointDef('hal_display_rect', 'Draw a filled rectangle', [
        ParamDef('x', 'int'),
        ParamDef('y', 'int'),
        ParamDef('w', 'int'),
        ParamDef('h', 'int'),
        ParamDef('color', 'int'),
      ], ReturnDef('void')),
      EndpointDef('hal_display_flush', 'Flush buffer to physical display', [],
          ReturnDef('void')),
    ]),
    'hal.gpio':
        FunctionalityDef('hal.gpio', 'GPIO pins (ESP32 only)', [
      EndpointDef('hal_gpio_mode', 'Set pin mode', [
        ParamDef('pin', 'int'),
        ParamDef('mode', 'int', '0=input, 1=output, 2=input_pullup'),
      ], ReturnDef('void')),
      EndpointDef('hal_gpio_read', 'Read pin value', [
        ParamDef('pin', 'int'),
      ], ReturnDef('int', '0 or 1')),
      EndpointDef('hal_gpio_write', 'Write pin value', [
        ParamDef('pin', 'int'),
        ParamDef('value', 'int', '0 or 1'),
      ], ReturnDef('void')),
    ]),
  };
}
