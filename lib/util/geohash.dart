/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Geohash encode/decode/neighbors — pure Dart, no Flutter dependency.
 * Reusable from CLI. Uses the standard base-32 geohash alphabet.
 *
 * Reference: https://en.wikipedia.org/wiki/Geohash
 */

const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

/// Encode latitude/longitude into a geohash string of given [precision].
String geohashEncode(double latitude, double longitude, {int precision = 6}) {
  double latMin = -90.0, latMax = 90.0;
  double lonMin = -180.0, lonMax = 180.0;
  bool isLon = true;
  int bit = 0;
  int ch = 0;
  final buf = StringBuffer();

  while (buf.length < precision) {
    if (isLon) {
      final mid = (lonMin + lonMax) / 2;
      if (longitude >= mid) {
        ch |= 1 << (4 - bit);
        lonMin = mid;
      } else {
        lonMax = mid;
      }
    } else {
      final mid = (latMin + latMax) / 2;
      if (latitude >= mid) {
        ch |= 1 << (4 - bit);
        latMin = mid;
      } else {
        latMax = mid;
      }
    }
    isLon = !isLon;
    bit++;
    if (bit == 5) {
      buf.write(_base32[ch]);
      bit = 0;
      ch = 0;
    }
  }
  return buf.toString();
}

/// Decoded geohash result with center point and bounding box.
class GeohashDecoded {
  final double latitude;
  final double longitude;
  final double latError;
  final double lonError;

  const GeohashDecoded({
    required this.latitude,
    required this.longitude,
    required this.latError,
    required this.lonError,
  });

  double get latMin => latitude - latError;
  double get latMax => latitude + latError;
  double get lonMin => longitude - lonError;
  double get lonMax => longitude + lonError;
}

/// Decode a geohash string to its center point and error margins.
GeohashDecoded geohashDecode(String hash) {
  double latMin = -90.0, latMax = 90.0;
  double lonMin = -180.0, lonMax = 180.0;
  bool isLon = true;

  for (int i = 0; i < hash.length; i++) {
    final ch = _base32.indexOf(hash[i]);
    if (ch < 0) continue;
    for (int bit = 4; bit >= 0; bit--) {
      if (isLon) {
        final mid = (lonMin + lonMax) / 2;
        if ((ch >> bit) & 1 == 1) {
          lonMin = mid;
        } else {
          lonMax = mid;
        }
      } else {
        final mid = (latMin + latMax) / 2;
        if ((ch >> bit) & 1 == 1) {
          latMin = mid;
        } else {
          latMax = mid;
        }
      }
      isLon = !isLon;
    }
  }

  return GeohashDecoded(
    latitude: (latMin + latMax) / 2,
    longitude: (lonMin + lonMax) / 2,
    latError: (latMax - latMin) / 2,
    lonError: (lonMax - lonMin) / 2,
  );
}

/// Get the 8 neighboring geohash cells for a given geohash.
List<String> geohashNeighbors(String hash) {
  final decoded = geohashDecode(hash);
  final lat = decoded.latitude;
  final lon = decoded.longitude;
  final latDelta = decoded.latError * 2;
  final lonDelta = decoded.lonError * 2;
  final precision = hash.length;

  return [
    geohashEncode(lat + latDelta, lon - lonDelta, precision: precision), // NW
    geohashEncode(lat + latDelta, lon, precision: precision),            // N
    geohashEncode(lat + latDelta, lon + lonDelta, precision: precision), // NE
    geohashEncode(lat, lon - lonDelta, precision: precision),            // W
    geohashEncode(lat, lon + lonDelta, precision: precision),            // E
    geohashEncode(lat - latDelta, lon - lonDelta, precision: precision), // SW
    geohashEncode(lat - latDelta, lon, precision: precision),            // S
    geohashEncode(lat - latDelta, lon + lonDelta, precision: precision), // SE
  ];
}

/// Get the geohash for a point plus all its neighbors (9-cell region).
List<String> geohashRegion(double latitude, double longitude,
    {int precision = 6}) {
  final center = geohashEncode(latitude, longitude, precision: precision);
  return [center, ...geohashNeighbors(center)];
}
