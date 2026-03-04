// Email handling mixin for station servers
// Provides shared email send/receive/delivery/validation via EmailRelayService
import '../../services/email_relay_service.dart';
import '../../services/nip05_registry_service.dart';

/// Connected client interface needed by the email handler.
/// Both PureConnectedClient implementations satisfy this.
abstract class EmailClient {
  String get id;
  String? get callsign;
}

/// Mixin providing email handling methods shared across station implementations.
///
/// Delegates all email logic to EmailRelayService, providing only the
/// transport callbacks (client lookup, socket send, domain resolution).
mixin EmailHandlerMixin {
  // Abstract dependencies to be provided by the using class
  void emailLog(String level, String message);

  /// The station domain used for email addresses (e.g. "p2p.radio")
  String get stationDomain;

  /// Look up a connected client by ID. Returns null if not found.
  EmailClient? emailGetClientById(String clientId);

  /// Find a connected client by callsign (case-insensitive). Returns null if not found.
  EmailClient? emailFindClientByCallsign(String callsign);

  /// Find ALL connected clients by callsign (multi-device support).
  List<EmailClient> emailFindAllClientsByCallsign(String callsign);

  /// Send a message to a connected client. Returns true on success.
  bool emailSafeSocketSend(covariant EmailClient client, String data);

  // ── Shared email methods ──────────────────────────────────────────

  /// Handle email send request from a connected client
  void handleEmailSend(EmailClient client, Map<String, dynamic> message) {
    EmailRelayService().handleEmailSend(
      message: message,
      senderCallsign: client.callsign ?? 'unknown',
      senderId: client.id,
      sendToClient: _sendToClient,
      findClientByCallsign: _findClientId,
      findAllClientsByCallsign: _findAllClientIds,
      getStationDomain: () => stationDomain,
    );
  }

  /// Deliver pending emails to a newly connected client
  void deliverPendingEmails(EmailClient client, String callsign) {
    EmailRelayService().deliverPendingEmails(
      clientId: client.id,
      callsign: callsign,
      sendToClient: _sendToClient,
      getStationDomain: () => stationDomain,
    );
  }

  /// Handle incoming email from external SMTP server
  Future<bool> handleIncomingEmail(
    String from,
    List<String> to,
    String rawMessage,
  ) async {
    emailLog('INFO', 'Received external email from $from to ${to.join(", ")}');
    return EmailRelayService().handleIncomingEmail(
      from: from,
      to: to,
      rawMessage: rawMessage,
      sendToClient: _sendToClient,
      findClientByCallsign: _findClientId,
      findAllClientsByCallsign: _findAllClientIds,
      getStationDomain: () => stationDomain,
    );
  }

  /// Validate if an email address is for a local user via NIP-05 registry
  bool validateLocalRecipient(String email) {
    if (email.isEmpty) return false;
    final atIndex = email.indexOf('@');
    if (atIndex <= 0) return false;
    final localPart = email.substring(0, atIndex).toUpperCase();
    return Nip05RegistryService().getRegistration(localPart) != null;
  }

  // ── Private helpers ───────────────────────────────────────────────

  bool _sendToClient(String clientId, String msg) {
    final target = emailGetClientById(clientId);
    return target != null ? emailSafeSocketSend(target, msg) : false;
  }

  String? _findClientId(String callsign) {
    return emailFindClientByCallsign(callsign)?.id;
  }

  List<String> _findAllClientIds(String callsign) {
    return emailFindAllClientsByCallsign(callsign)
        .map((c) => c.id)
        .toList();
  }
}
