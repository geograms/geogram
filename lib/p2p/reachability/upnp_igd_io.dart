/// Minimal pure-Dart UPnP-IGD client (BT-DHT-v2 §7.3).
///
/// Implements just enough of the IGD profile to add/remove a port mapping
/// and read the WAN external IP. Aggressive timeouts (3s SSDP, 5s SOAP)
/// keep startup snappy on hostile networks where UPnP would otherwise hang.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class UpnpMappingResult {
  final bool ok;
  final String? externalAddress;
  final int? externalPort;
  final Duration leaseDuration;
  final String? error;
  const UpnpMappingResult({
    required this.ok,
    this.externalAddress,
    this.externalPort,
    this.leaseDuration = Duration.zero,
    this.error,
  });
}

/// Bumped each time an SSDP / SOAP step times out — surfaced via the debug
/// API to help spot routers where UPnP is misbehaving.
int upnpTimeoutCount = 0;

const Duration _ssdpTimeout = Duration(seconds: 3);
const Duration _soapTimeout = Duration(seconds: 5);

Future<UpnpMappingResult> upnpAddPortMapping({
  required int externalPort,
  required int internalPort,
  required String description,
  Duration leaseDuration = const Duration(hours: 1),
}) async {
  final svc = await _discover();
  if (svc == null) {
    return const UpnpMappingResult(ok: false, error: 'no IGD discovered');
  }

  final localIp = await _pickLocalIPv4();
  if (localIp == null) {
    return const UpnpMappingResult(ok: false, error: 'no local IPv4');
  }

  final body = '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:AddPortMapping xmlns:u="${svc.serviceType}">
      <NewRemoteHost></NewRemoteHost>
      <NewExternalPort>$externalPort</NewExternalPort>
      <NewProtocol>UDP</NewProtocol>
      <NewInternalPort>$internalPort</NewInternalPort>
      <NewInternalClient>$localIp</NewInternalClient>
      <NewEnabled>1</NewEnabled>
      <NewPortMappingDescription>$description</NewPortMappingDescription>
      <NewLeaseDuration>${leaseDuration.inSeconds}</NewLeaseDuration>
    </u:AddPortMapping>
  </s:Body>
</s:Envelope>''';

  try {
    final resp = await _soap(svc, 'AddPortMapping', body)
        .timeout(_soapTimeout);
    if (resp.statusCode != 200) {
      return UpnpMappingResult(
          ok: false, error: 'AddPortMapping HTTP ${resp.statusCode}');
    }
  } on TimeoutException {
    upnpTimeoutCount++;
    return const UpnpMappingResult(ok: false, error: 'AddPortMapping timeout');
  } catch (e) {
    return UpnpMappingResult(ok: false, error: 'AddPortMapping: $e');
  }

  String? externalIp;
  try {
    final ipBody = '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetExternalIPAddress xmlns:u="${svc.serviceType}"/>
  </s:Body>
</s:Envelope>''';
    final r =
        await _soap(svc, 'GetExternalIPAddress', ipBody).timeout(_soapTimeout);
    if (r.statusCode == 200) {
      final body = await utf8.decoder.bind(r).join();
      final m = RegExp(r'<NewExternalIPAddress>([^<]+)</NewExternalIPAddress>')
          .firstMatch(body);
      if (m != null) externalIp = m.group(1);
    }
  } on TimeoutException {
    upnpTimeoutCount++;
  } catch (_) {}

  return UpnpMappingResult(
    ok: true,
    externalAddress: externalIp,
    externalPort: externalPort,
    leaseDuration: leaseDuration,
  );
}

Future<bool> upnpDeletePortMapping({required int externalPort}) async {
  final svc = await _discover();
  if (svc == null) return false;
  final body = '''<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:DeletePortMapping xmlns:u="${svc.serviceType}">
      <NewRemoteHost></NewRemoteHost>
      <NewExternalPort>$externalPort</NewExternalPort>
      <NewProtocol>UDP</NewProtocol>
    </u:DeletePortMapping>
  </s:Body>
</s:Envelope>''';
  try {
    final r =
        await _soap(svc, 'DeletePortMapping', body).timeout(_soapTimeout);
    return r.statusCode == 200;
  } on TimeoutException {
    upnpTimeoutCount++;
    return false;
  } catch (_) {
    return false;
  }
}

// ---- internals ----

class _IgdService {
  final Uri controlUrl;
  final String serviceType;
  _IgdService(this.controlUrl, this.serviceType);
}

_IgdService? _cachedService;
DateTime? _cachedAt;

Future<_IgdService?> _discover() async {
  final cached = _cachedService;
  if (cached != null &&
      _cachedAt != null &&
      DateTime.now().difference(_cachedAt!) < const Duration(minutes: 30)) {
    return cached;
  }
  final loc = await _ssdpDiscover();
  if (loc == null) return null;
  final svc = await _parseDeviceDescriptor(loc);
  if (svc != null) {
    _cachedService = svc;
    _cachedAt = DateTime.now();
  }
  return svc;
}

Future<Uri?> _ssdpDiscover() async {
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;
    final completer = Completer<Uri?>();

    sock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = sock!.receive();
      if (dg == null) return;
      final text = utf8.decode(dg.data, allowMalformed: true);
      final m = RegExp(r'LOCATION:\s*(\S+)', caseSensitive: false)
          .firstMatch(text);
      if (m != null && !completer.isCompleted) {
        completer.complete(Uri.tryParse(m.group(1)!.trim()));
      }
    });

    const search = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n';

    sock.send(utf8.encode(search), InternetAddress('239.255.255.250'), 1900);

    final loc = await completer.future.timeout(_ssdpTimeout, onTimeout: () {
      upnpTimeoutCount++;
      return null;
    });
    return loc;
  } catch (_) {
    return null;
  } finally {
    sock?.close();
  }
}

Future<_IgdService?> _parseDeviceDescriptor(Uri location) async {
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = _soapTimeout;
    final req = await client.getUrl(location).timeout(_soapTimeout);
    final resp = await req.close().timeout(_soapTimeout);
    if (resp.statusCode != 200) return null;
    final xml = await utf8.decoder.bind(resp).join();
    const wanIp = 'urn:schemas-upnp-org:service:WANIPConnection:1';
    const wanPpp = 'urn:schemas-upnp-org:service:WANPPPConnection:1';
    for (final st in [wanIp, wanPpp]) {
      final svcRe = RegExp(
          '<service>([\\s\\S]*?<serviceType>$st</serviceType>[\\s\\S]*?)</service>',
          caseSensitive: false);
      final svcMatch = svcRe.firstMatch(xml);
      if (svcMatch == null) continue;
      final block = svcMatch.group(1)!;
      final ctrlRe = RegExp(r'<controlURL>([^<]+)</controlURL>');
      final ctrlMatch = ctrlRe.firstMatch(block);
      if (ctrlMatch == null) continue;
      final ctrlUrl = ctrlMatch.group(1)!.trim();
      return _IgdService(location.resolve(ctrlUrl), st);
    }
  } on TimeoutException {
    upnpTimeoutCount++;
  } catch (_) {
    return null;
  } finally {
    client?.close(force: true);
  }
  return null;
}

Future<HttpClientResponse> _soap(
    _IgdService svc, String action, String body) async {
  final client = HttpClient()..connectionTimeout = _soapTimeout;
  try {
    final req = await client.postUrl(svc.controlUrl).timeout(_soapTimeout);
    final encoded = utf8.encode(body);
    req.headers
      ..set('Content-Type', 'text/xml; charset="utf-8"')
      ..set('SOAPAction', '"${svc.serviceType}#$action"');
    // Many consumer routers (FRITZ!Box, etc.) reject SOAP without a
    // declared Content-Length and return HTTP 411. Set it explicitly
    // and write bytes — req.write+close() can default to chunked.
    req.contentLength = encoded.length;
    req.add(encoded);
    return await req.close();
  } finally {
    // Caller must drain the response; intentionally not closing client here.
  }
}

Future<String?> _pickLocalIPv4() async {
  try {
    final ifaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final iface in ifaces) {
      for (final addr in iface.addresses) {
        if (addr.type == InternetAddressType.IPv4 &&
            !addr.isLoopback &&
            !addr.isLinkLocal) {
          return addr.address;
        }
      }
    }
  } catch (_) {}
  return null;
}
