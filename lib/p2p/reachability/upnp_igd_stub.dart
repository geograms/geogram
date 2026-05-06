/// Web stub: UPnP-IGD requires raw UDP/TCP, unavailable in browsers.
library;

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

Future<UpnpMappingResult> upnpAddPortMapping({
  required int externalPort,
  required int internalPort,
  required String description,
  Duration leaseDuration = const Duration(hours: 1),
}) async =>
    const UpnpMappingResult(ok: false, error: 'UPnP unsupported on web');

Future<bool> upnpDeletePortMapping({required int externalPort}) async => false;

int upnpTimeoutCount = 0;
