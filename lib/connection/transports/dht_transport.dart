/// DHT Transport — P2P discovery transport for ConnectionManager.
///
/// Priority 25: between WebRTC (15) and Station (30).
/// Currently handles discovery only — direct data transport via
/// hole punching is planned for a future iteration.
library;

import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../services/log_service.dart';
import '../../services/app_args.dart';
import '../../services/security_service.dart';
import '../../p2p/p2p_service.dart';
import '../transport.dart';
import '../transport_message.dart';

class DhtTransport extends Transport with TransportMixin {
  @override
  String get id => 'dht';

  @override
  String get name => 'P2P Direct';

  @override
  int get priority => 25;

  @override
  bool get isAvailable {
    if (kIsWeb) return false;
    if (AppArgs().internetOnly) return false;
    if (SecurityService().bleOnlyMode) return false;
    return true;
  }

  @override
  Future<void> initialize() async {
    LogService().log('DhtTransport: Initializing...');
    markInitialized();
    LogService().log('DhtTransport: Initialized');
  }

  @override
  Future<void> dispose() async {
    LogService().log('DhtTransport: Disposing...');
    await disposeMixin();
    LogService().log('DhtTransport: Disposed');
  }

  @override
  Future<bool> canReach(String callsign) async => false;

  @override
  Future<int> getQuality(String callsign) async => 0;

  @override
  Future<TransportResult> send(
    TransportMessage message, {
    Duration? timeout,
  }) async {
    return TransportResult.failure(
      error: 'DHT direct transport not yet implemented',
      transportUsed: id,
    );
  }

  @override
  Future<void> sendAsync(TransportMessage message) async {}
}
