/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Signal authentication state machine.
 * Driven by updateAuthState events from the Signal bridge.
 *
 * Simpler than Telegram — QR-code device linking only.
 * No phone/SMS/2FA flow.
 */

import '../../services/log_service.dart';
import 'models/signal_auth_state.dart';
import 'signal_client.dart';

/// Callback for auth state transitions.
typedef SignalAuthStateCallback = void Function(SignalAuthStateData state);

/// Manages the Signal device-linking flow (QR code only).
class SignalAuthService {
  final SignalClient _client;
  final SignalAuthStateCallback _onStateChanged;

  SignalAuthStateData _currentState = const SignalAuthStateData(
    state: SignalAuthState.uninitialized,
  );

  SignalAuthStateData get currentState => _currentState;

  SignalAuthService(this._client, this._onStateChanged);

  /// Handle an updateAuthState event from the Signal bridge.
  void handleUpdate(Map<String, dynamic> update) {
    final stateStr = update['state'] as String? ?? '';

    LogService().debug('SignalAuth: $stateStr');

    switch (stateStr) {
      case 'waitingLink':
        _setState(SignalAuthState.waitingLink);
        break;

      case 'waitingQrScan':
        final url = update['provisioning_url'] as String? ?? '';
        _setState(SignalAuthState.waitingQrScan, provisioningUrl: url);
        break;

      case 'linked':
        _setState(SignalAuthState.linked);
        break;

      case 'ready':
        _setState(SignalAuthState.ready);
        break;

      case 'error':
        final errorMsg = update['error_message'] as String?;
        _setState(SignalAuthState.error, error: errorMsg);
        break;

      case 'closed':
        _setState(SignalAuthState.closed);
        break;

      default:
        LogService().debug('SignalAuth: unhandled auth state: $stateStr');
    }
  }

  // --- Login methods ---

  /// Request a new device link — triggers QR code generation.
  ///
  /// The bridge will emit updateAuthState with state=waitingQrScan
  /// and a provisioning_url that encodes to a QR code.
  Future<void> requestLinkDevice({String? deviceName}) async {
    final request = <String, dynamic>{
      '@type': 'requestLinkDevice',
    };
    if (deviceName != null) {
      request['device_name'] = deviceName;
    }
    await _client.sendRequest(request);
  }

  /// Unlink the current device (log out).
  Future<void> unlinkDevice() async {
    await _client.sendRequest({'@type': 'unlinkDevice'});
  }

  // --- Private ---

  /// Reset auth state to uninitialized — clears stale QR URL.
  /// Call before re-entering the auth page.
  void resetState() {
    _currentState = const SignalAuthStateData(
      state: SignalAuthState.uninitialized,
    );
  }

  void _setState(SignalAuthState state,
      {String? provisioningUrl, String? error}) {
    _currentState = SignalAuthStateData(
      state: state,
      provisioningUrl: state == SignalAuthState.waitingQrScan
          ? (provisioningUrl ?? _currentState.provisioningUrl)
          : null,
      errorMessage: error,
    );
    _onStateChanged(_currentState);
  }
}
