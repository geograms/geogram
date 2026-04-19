import 'dart:io';

/// Returns all local IPv4 addresses (excluding loopback) across every
/// network interface on this host.
Future<List<String>> getLocalIPv4Addresses() async {
  final interfaces = await NetworkInterface.list();
  return interfaces
      .expand((i) => i.addresses)
      .where((a) => a.type == InternetAddressType.IPv4 && !a.isLoopback)
      .map((a) => a.address)
      .toList();
}

/// True if [ip] is private / loopback / link-local / unique-local.
/// Covers IPv4 (RFC1918, 127/8, 169.254/16) and IPv6 (::1, fe80::, fc/fd).
bool isPrivateIp(String ip) {
  try {
    final addr = InternetAddress(ip);
    if (addr.type == InternetAddressType.IPv4) {
      final parts = ip.split('.');
      if (parts.length != 4) return false;
      final first = int.parse(parts[0]);
      final second = int.parse(parts[1]);
      if (first == 10) return true;
      if (first == 172 && second >= 16 && second <= 31) return true;
      if (first == 192 && second == 168) return true;
      if (first == 127) return true;
      if (first == 169 && second == 254) return true;
    } else if (addr.type == InternetAddressType.IPv6) {
      if (ip == '::1') return true;
      final lower = ip.toLowerCase();
      if (lower.startsWith('fe80:')) return true;
      if (lower.startsWith('fc') || lower.startsWith('fd')) return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}
