import '../services/profile_service.dart';
import '../services/station_service.dart';

/// Format a callsign for use in URL path segments.
///
/// Callsigns are stored/derived in uppercase (e.g. X1SU86) but URLs
/// use lowercase for easier typing: `/x1su86/meet/emu`.
/// The server accepts both cases, so this is purely cosmetic.
String callsignForUrl(String callsign) => callsign.toLowerCase();

/// Build a full station URL for a given app path.
///
/// Takes a station WebSocket URL (e.g. `wss://p2p.radio`) and an app-relative
/// path (e.g. `shared/box/`) and returns the full HTTPS URL with callsign:
/// `https://p2p.radio/brito/shared/box/`
///
/// Returns null if callsign is empty or station URL is invalid.
String? buildStationAppUrl(String stationWsUrl, String appPath) {
  final callsign = ProfileService().getProfile().callsign;
  if (callsign.isEmpty) return null;

  var domain = stationWsUrl
      .replaceFirst('wss://', '')
      .replaceFirst('ws://', '');
  if (domain.endsWith('/')) domain = domain.substring(0, domain.length - 1);

  final path = appPath.startsWith('/') ? appPath.substring(1) : appPath;
  return 'https://$domain/${callsignForUrl(callsign)}/$path';
}
