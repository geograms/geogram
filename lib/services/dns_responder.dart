/// Minimal DNS responder for captive portal detection.
///
/// Listens on UDP port 53 and responds to every DNS query with an A record
/// pointing to [gatewayIp]. This makes all DNS lookups resolve to the portal
/// server, triggering captive-portal detection on Android/iOS/Windows/macOS.
///
/// Pure `dart:io` — no external dependencies.
library;

import 'dart:io';
import 'dart:typed_data';

import 'log_service.dart';

class DnsResponder {
  RawDatagramSocket? _socket;
  InternetAddress? _gatewayAddress;

  bool get isRunning => _socket != null;

  /// Start listening on all IPv4 interfaces, port 53.
  /// [gatewayIp] is the A-record answer for every query (e.g. `192.168.49.1`).
  Future<void> start(String gatewayIp) async {
    if (_socket != null) return;

    _gatewayAddress = InternetAddress(gatewayIp);

    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 53);
      _socket!.listen(_handleDatagram, onError: (e) {
        LogService().log('DNS responder error: $e');
      });
      LogService().log('DNS responder started on port 53 → $gatewayIp');
    } catch (e) {
      LogService().log('DNS responder failed to bind port 53: $e');
      _socket = null;
      rethrow;
    }
  }

  /// Stop the DNS responder.
  Future<void> stop() async {
    _socket?.close();
    _socket = null;
    _gatewayAddress = null;
    LogService().log('DNS responder stopped');
  }

  // ── Packet handling ──────────────────────────────────────────────

  void _handleDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;

    final datagram = _socket?.receive();
    if (datagram == null) return;

    final query = datagram.data;
    if (query.length < 12) return; // too short to be a valid DNS packet

    final response = _buildResponse(query);
    if (response != null) {
      _socket?.send(response, datagram.address, datagram.port);
    }
  }

  /// Build a DNS response that answers every A query with [_gatewayAddress].
  ///
  /// DNS packet format (RFC 1035):
  ///   Header: 12 bytes (ID, flags, counts)
  ///   Question: variable (copied from query)
  ///   Answer: 16 bytes (name pointer + type + class + TTL + rdlength + rdata)
  Uint8List? _buildResponse(Uint8List query) {
    if (_gatewayAddress == null) return null;

    // Parse header
    final id = query.sublist(0, 2);
    final qdCount = (query[4] << 8) | query[5];
    if (qdCount == 0) return null;

    // Skip over the question section to find its end
    var offset = 12;
    for (var i = 0; i < qdCount; i++) {
      // Skip labels
      while (offset < query.length) {
        final len = query[offset];
        if (len == 0) {
          offset++; // null terminator
          break;
        }
        if ((len & 0xC0) == 0xC0) {
          offset += 2; // pointer
          break;
        }
        offset += len + 1;
      }
      offset += 4; // QTYPE (2) + QCLASS (2)
    }

    if (offset > query.length) return null;

    final questionSection = query.sublist(12, offset);
    final ipBytes = _gatewayAddress!.rawAddress;

    // Build response
    final builder = BytesBuilder();

    // Header
    builder.add(id); // Transaction ID
    builder.add([0x81, 0x80]); // Flags: response, authoritative, recursion available
    builder.add([0, qdCount >> 8, 0, qdCount & 0xFF]); // QD count (same as query)
    builder.add([0, qdCount >> 8, 0, qdCount & 0xFF]); // AN count (one answer per question)
    builder.add([0, 0]); // NS count
    builder.add([0, 0]); // AR count

    // Question section (copy from query)
    builder.add(questionSection);

    // Answer section — one A record per question
    // Use name pointer (0xC00C) pointing to offset 12 in the packet (first question name)
    var nameOffset = 12;
    for (var i = 0; i < qdCount; i++) {
      builder.add([0xC0, nameOffset & 0xFF]); // Name pointer
      builder.add([0, 1]); // TYPE A
      builder.add([0, 1]); // CLASS IN
      builder.add([0, 0, 0, 60]); // TTL 60 seconds
      builder.add([0, 4]); // RDLENGTH 4
      builder.add(ipBytes); // RDATA (IPv4 address)

      // Advance nameOffset past this question's labels + QTYPE + QCLASS
      while (nameOffset < query.length) {
        final len = query[nameOffset];
        if (len == 0) {
          nameOffset++;
          break;
        }
        if ((len & 0xC0) == 0xC0) {
          nameOffset += 2;
          break;
        }
        nameOffset += len + 1;
      }
      nameOffset += 4; // QTYPE + QCLASS
    }

    return builder.toBytes() as Uint8List;
  }
}
