/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Signal authentication state model.
 * Simpler than Telegram — QR-code linking only (no phone/SMS/2FA).
 */

enum SignalAuthState {
  uninitialized,
  waitingLink,
  waitingQrScan,
  linked,
  ready,
  error,
  closed,
}

class SignalAuthStateData {
  final SignalAuthState state;
  final String? provisioningUrl;
  final String? errorMessage;

  const SignalAuthStateData({
    required this.state,
    this.provisioningUrl,
    this.errorMessage,
  });

  factory SignalAuthStateData.fromJson(Map<String, dynamic> json) {
    final stateStr = json['state'] as String? ?? 'uninitialized';
    return SignalAuthStateData(
      state: _parseState(stateStr),
      provisioningUrl: json['provisioning_url'] as String?,
      errorMessage: json['error_message'] as String?,
    );
  }

  static SignalAuthState _parseState(String s) {
    switch (s) {
      case 'uninitialized':
        return SignalAuthState.uninitialized;
      case 'waitingLink':
        return SignalAuthState.waitingLink;
      case 'waitingQrScan':
        return SignalAuthState.waitingQrScan;
      case 'linked':
        return SignalAuthState.linked;
      case 'ready':
        return SignalAuthState.ready;
      case 'error':
        return SignalAuthState.error;
      case 'closed':
        return SignalAuthState.closed;
      default:
        return SignalAuthState.uninitialized;
    }
  }

  SignalAuthStateData copyWith({
    SignalAuthState? state,
    String? provisioningUrl,
    String? errorMessage,
  }) {
    return SignalAuthStateData(
      state: state ?? this.state,
      provisioningUrl: provisioningUrl ?? this.provisioningUrl,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  String toString() => 'SignalAuthStateData($state)';
}
