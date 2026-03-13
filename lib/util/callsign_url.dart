/// Format a callsign for use in URL path segments.
///
/// Callsigns are stored/derived in uppercase (e.g. X1SU86) but URLs
/// use lowercase for easier typing: `/x1su86/meet/emu`.
/// The server accepts both cases, so this is purely cosmetic.
String callsignForUrl(String callsign) => callsign.toLowerCase();
