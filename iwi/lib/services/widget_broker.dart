/*
 * WidgetBroker — host-side router for widget.request / widget.response
 * messages. Implements the "one wapp can provide multiple widgets"
 * rule and the "user preferences pick the default provider" rule.
 *
 * Flow:
 *   1. Caller wapp emits `{"type":"widget.request", "widget": "<id>",
 *      "req_id": "<opaque>", "args": {...}}` via hal_msg_send.
 *   2. wapp_page.dart `_drainOutbox` forwards it to
 *      [WidgetBroker.handleRequest] with the caller's engineId.
 *   3. Broker looks up providers in [WidgetRegistry], picks one via
 *      user preference (or first registered), spins up a HEADLESS
 *      [WappEngine] for that provider's wasm, injects the request,
 *      and drives `module_handle_event` synchronously.
 *   4. The provider's outbox is scanned for a `widget.response`
 *      matching `req_id`. The engine is then disposed.
 *   5. The matched response is delivered to the caller engine via
 *      [WappEngine.lookup] + sendMessage + handleEvent so the
 *      caller's `module_handle_event` runs immediately. Any outbox
 *      messages the caller produces in response land in its own
 *      outbox and surface on its next tick (max latency = one wapp
 *      tick interval).
 *
 * Not handled yet:
 *   - UI-rendering providers (file picker, gallery). Those need a
 *     windowed route with the provider wapp displayed on top until
 *     the user interacts. A separate code path will be added when a
 *     real UI widget lands.
 *   - Cross-process provider fan-out (mesh / BLE).
 *   - Provider concurrency limits. Today every request spins up a
 *     fresh engine; a very chatty caller could thrash the allocator.
 */

import 'dart:convert';

import '../main.dart' show WappManifest;
import '../wapp/wapp_engine.dart';
import 'preferences_service.dart';
import 'storage_paths.dart' show wappPackageStorage;
import 'widget_registry.dart';

class WidgetBroker {
  WidgetBroker._();
  static final WidgetBroker instance = WidgetBroker._();

  /// Main entry point called from `wapp_page.dart` when a caller
  /// wapp emits a `widget.request` message.
  Future<void> handleRequest({
    required String callerEngineId,
    required String widgetId,
    required String reqId,
    required Map<String, dynamic> args,
  }) async {
    if (widgetId.isEmpty || reqId.isEmpty) {
      _deliverError(callerEngineId, reqId,
          'widget.request missing widget/req_id');
      return;
    }

    final providers = WidgetRegistry.instance.providersFor(widgetId);
    if (providers.isEmpty) {
      _deliverError(
          callerEngineId, reqId, 'no provider registered for "$widgetId"');
      return;
    }

    final provider = await _resolveProvider(widgetId, providers);
    if (provider == null) {
      _deliverError(
          callerEngineId, reqId, 'no provider selected for "$widgetId"');
      return;
    }

    final pkg = wappPackageStorage(provider.dirPath);
    final wasmBytes = await pkg.readBytes('app.wasm');
    if (wasmBytes == null) {
      _deliverError(callerEngineId, reqId,
          'provider "${provider.id}" has no app.wasm');
      return;
    }

    final headless = WappEngine();
    try {
      await headless.load(wasmBytes);
      headless.init();

      final request = <String, dynamic>{
        'type': 'widget.request',
        'widget': widgetId,
        'req_id': reqId,
        'reply_to': callerEngineId,
        'args': args,
      };
      headless.sendMessage(jsonEncode(request));
      headless.handleEvent();

      final response = _findResponse(headless.drainOutbox(), reqId);
      if (response == null) {
        _deliverError(callerEngineId, reqId,
            'provider "${provider.id}" did not emit widget.response');
        return;
      }

      _deliverResponse(callerEngineId, reqId,
          result: response['result'] as Map<String, dynamic>?,
          providerWappId: provider.id);
    } catch (e) {
      _deliverError(
          callerEngineId, reqId, 'provider "${provider.id}" threw: $e');
    } finally {
      headless.dispose();
    }
  }

  // ── Provider resolution ─────────────────────────────────────────

  /// Pick the provider for [widgetId] given the user preference and
  /// the full list of registered providers. Preference takes
  /// priority; first registered provider is the fallback when there
  /// is no preference or the preferred provider is no longer
  /// installed.
  Future<WappManifest?> _resolveProvider(
    String widgetId,
    List<WappManifest> providers,
  ) async {
    if (providers.isEmpty) return null;
    if (providers.length == 1) return providers.first;

    final prefs = await PreferencesService.instance();
    final preferredId = prefs.getPreferredProvider(widgetId);
    if (preferredId != null) {
      for (final p in providers) {
        if (p.id == preferredId) return p;
      }
    }
    return providers.first;
  }

  // ── Outbox scraping ─────────────────────────────────────────────

  Map<String, dynamic>? _findResponse(List<String> outbox, String reqId) {
    for (final raw in outbox) {
      try {
        final msg = jsonDecode(raw);
        if (msg is! Map<String, dynamic>) continue;
        if (msg['type'] != 'widget.response') continue;
        if (msg['req_id'] != reqId) continue;
        return msg;
      } catch (_) {}
    }
    return null;
  }

  // ── Response delivery to the caller ─────────────────────────────

  void _deliverResponse(
    String callerEngineId,
    String reqId, {
    required Map<String, dynamic>? result,
    required String providerWappId,
  }) {
    _sendToCaller(callerEngineId, {
      'type': 'widget.response',
      'req_id': reqId,
      'widget_provider': providerWappId,
      if (result != null) 'result': result,
    });
  }

  void _deliverError(
      String callerEngineId, String reqId, String message) {
    _sendToCaller(callerEngineId, {
      'type': 'widget.response',
      'req_id': reqId,
      'error': message,
    });
  }

  void _sendToCaller(String callerEngineId, Map<String, dynamic> payload) {
    final engine = WappEngine.lookup(callerEngineId);
    if (engine == null) return;
    engine.sendMessage(jsonEncode(payload));
    // Fire the caller's module_handle_event immediately so the
    // wapp can consume the response now. Any outbox messages the
    // wapp emits in its handler will drain on its next tick.
    engine.handleEvent();
  }
}
