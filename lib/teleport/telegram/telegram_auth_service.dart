/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Telegram authentication state machine.
 * Driven by TDLib's updateAuthorizationState events.
 */

import '../../services/log_service.dart';
import 'models/telegram_auth_state.dart';
import 'tdlib_client.dart';

/// Callback for auth state transitions.
typedef AuthStateCallback = void Function(TelegramAuthStateData state);

/// Manages the Telegram login flow (phone+SMS, QR code, 2FA).
class TelegramAuthService {
  final TdlibClient _client;
  final AuthStateCallback _onStateChanged;

  TelegramAuthStateData _currentState = const TelegramAuthStateData(
    state: TelegramAuthState.uninitialized,
  );

  TelegramAuthStateData get currentState => _currentState;

  TelegramAuthService(this._client, this._onStateChanged);

  /// Handle an updateAuthorizationState event from TDLib.
  void handleUpdate(Map<String, dynamic> update) {
    final authState =
        update['authorization_state'] as Map<String, dynamic>? ?? {};
    final type = authState['@type'] as String? ?? '';

    LogService().debug('TelegramAuth: $type');

    switch (type) {
      case 'authorizationStateWaitTdlibParameters':
        _setState(TelegramAuthState.waitingParameters);
        break;

      case 'authorizationStateWaitPhoneNumber':
        _setState(TelegramAuthState.waitingPhone);
        break;

      case 'authorizationStateWaitCode':
        _setState(TelegramAuthState.waitingCode);
        break;

      case 'authorizationStateWaitPassword':
        _setState(TelegramAuthState.waitingPassword);
        break;

      case 'authorizationStateWaitOtherDeviceConfirmation':
        final link = authState['link'] as String? ?? '';
        _setState(TelegramAuthState.waitingQrScan, qrLink: link);
        break;

      case 'authorizationStateReady':
        _setState(TelegramAuthState.ready);
        break;

      case 'authorizationStateClosing':
        _setState(TelegramAuthState.closing);
        break;

      case 'authorizationStateClosed':
        _setState(TelegramAuthState.closed);
        break;

      default:
        LogService().debug('TelegramAuth: unhandled auth state: $type');
    }
  }

  // --- Login methods ---

  /// Start phone number login flow.
  Future<void> setPhoneNumber(String phoneNumber) async {
    await _client.sendRequest({
      '@type': 'setAuthenticationPhoneNumber',
      'phone_number': phoneNumber,
    });
  }

  /// Submit the SMS verification code.
  Future<void> checkCode(String code) async {
    await _client.sendRequest({
      '@type': 'checkAuthenticationCode',
      'code': code,
    });
  }

  /// Submit 2FA password.
  Future<void> checkPassword(String password) async {
    await _client.sendRequest({
      '@type': 'checkAuthenticationPassword',
      'password': password,
    });
  }

  /// Start QR code login flow.
  Future<void> requestQrCode() async {
    await _client.sendRequest({
      '@type': 'requestQrCodeAuthentication',
      'other_user_ids': <int>[],
    });
  }

  /// Log out the current session.
  Future<void> logOut() async {
    await _client.sendRequest({'@type': 'logOut'});
  }

  // --- Private ---

  void _setState(TelegramAuthState state, {String? qrLink, String? error}) {
    _currentState = TelegramAuthStateData(
      state: state,
      qrLink: qrLink ?? _currentState.qrLink,
      errorMessage: error,
      phoneNumber: _currentState.phoneNumber,
    );
    _onStateChanged(_currentState);
  }
}
