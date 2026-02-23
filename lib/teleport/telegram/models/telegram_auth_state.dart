/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Authorization states driven by TDLib's updateAuthorizationState.
enum TelegramAuthState {
  uninitialized,
  waitingParameters,
  waitingPhone,
  waitingCode,
  waitingPassword,
  waitingQrScan,
  ready,
  closing,
  closed,
  error,
}

/// Data associated with a specific auth state transition.
class TelegramAuthStateData {
  final TelegramAuthState state;
  final String? qrLink;
  final String? errorMessage;
  final String? phoneNumber;

  const TelegramAuthStateData({
    required this.state,
    this.qrLink,
    this.errorMessage,
    this.phoneNumber,
  });

  TelegramAuthStateData copyWith({
    TelegramAuthState? state,
    String? qrLink,
    String? errorMessage,
    String? phoneNumber,
  }) {
    return TelegramAuthStateData(
      state: state ?? this.state,
      qrLink: qrLink ?? this.qrLink,
      errorMessage: errorMessage ?? this.errorMessage,
      phoneNumber: phoneNumber ?? this.phoneNumber,
    );
  }

  @override
  String toString() => 'TelegramAuthStateData($state)';
}
