/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * WASM HAL callback service — routes HAL callbacks from the Rust bridge
 * to Dart services when needed (e.g., HTTP requests, storage, sensors).
 *
 * Phase 1: Minimal implementation. The Rust bridge handles most HAL
 * functions directly. This service will grow in later phases as async
 * HAL operations (HTTP, BLE scan results) need Dart-side handling.
 */

import 'dart:async';

import '../util/event_bus.dart';
import 'log_service.dart';
import 'wasm_module_service.dart';

/// Routes HAL callbacks from wasm_bridge to Dart services.
///
/// Listens to WasmModuleService events and handles any that require
/// Dart-side processing (e.g., proxying HTTP requests through Dart's
/// http client, forwarding sensor data from platform channels).
class WasmHalService {
  static final WasmHalService _instance = WasmHalService._internal();
  factory WasmHalService() => _instance;
  WasmHalService._internal();

  StreamSubscription<WasmEvent>? _eventSub;
  bool _initialized = false;

  /// Module message handlers registered by the host app.
  final Map<String, void Function(Map<String, dynamic>)> _messageHandlers = {};

  /// Initialize HAL routing.
  void initialize() {
    if (_initialized) return;

    final service = WasmModuleService();
    _eventSub = service.events.listen(_handleEvent);
    _initialized = true;

    LogService().log('WasmHalService: initialized');
  }

  /// Register a handler for messages from a specific module.
  void registerMessageHandler(String moduleId, void Function(Map<String, dynamic>) handler) {
    _messageHandlers[moduleId] = handler;
  }

  /// Unregister a module message handler.
  void unregisterMessageHandler(String moduleId) {
    _messageHandlers.remove(moduleId);
  }

  /// Clean up.
  void dispose() {
    _eventSub?.cancel();
    _eventSub = null;
    _messageHandlers.clear();
    _initialized = false;
  }

  void _handleEvent(WasmEvent event) {
    switch (event.type) {
      case WasmEventType.moduleMessage:
        _handleModuleMessage(event);
      case WasmEventType.moduleEvent:
        _handleModuleEvent(event);
      case WasmEventType.moduleLog:
        // Module logs are already handled by WasmModuleService
        break;
      default:
        break;
    }
  }

  void _handleModuleEvent(WasmEvent event) {
    final data = event.data as Map<String, dynamic>?;
    if (data == null) return;

    final moduleId = data['moduleId'] as String? ?? '';
    final topic = data['topic'] as String? ?? '';
    final payload = data['data'] as String? ?? '';

    EventBus().fire(WappEventBridgeEvent(
      moduleId: moduleId,
      topic: topic,
      data: payload,
    ));
  }

  void _handleModuleMessage(WasmEvent event) {
    final moduleId = event.moduleId;
    if (moduleId == null) return;

    final data = event.data as Map<String, dynamic>?;
    if (data == null) return;

    // Check for registered handler
    final handler = _messageHandlers[moduleId];
    if (handler != null) {
      handler(data);
      return;
    }

    // Default: log unhandled module messages
    LogService().log('WasmHalService: unhandled message from $moduleId: ${data['data']}');
  }
}
