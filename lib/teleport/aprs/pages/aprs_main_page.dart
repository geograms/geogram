/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * APRS main page — two tabs: Stream (all received packets) and
 * Messages (1:1 directed messages). Settings gear in the AppBar.
 *
 * Both tabs filter packets client-side by distance so only entries
 * within the current radius slider value are shown.
 */

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../pages/location_picker_page.dart';
import '../../../services/app_service.dart';
import '../../../services/location_provider_service.dart';
import '../../../services/map_tile_service.dart' show MapTileService, MapLayerType;
import '../../../services/profile_service.dart';
import '../../../services/user_location_service.dart';
import '../../../services/i18n_service.dart';
import '../aprs_service.dart';
import '../models/aprs_packet.dart';
import '../widgets/aprs_conversation_list.dart';
import '../widgets/aprs_geo_chat_panel.dart';
import 'aprs_settings_page.dart';

class AprsMainPage extends StatefulWidget {
  final String appPath;

  const AprsMainPage({super.key, required this.appPath});

  @override
  State<AprsMainPage> createState() => _AprsMainPageState();
}

class _AprsMainPageState extends State<AprsMainPage> {
  StreamSubscription<AprsEvent>? _eventSub;
  double? _draggingRadius; // local visual state while slider is being dragged
  bool _paused = false; // when true, UI stops refreshing (service keeps running)

  @override
  void initState() {
    super.initState();
    _eventSub = AprsService().events.listen((_) {
      if (!_paused && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aprs = AprsService();
    // Use saved APRS position for distance calculations (set by location picker).
    // Fall back to LocationProvider / UserLocationService.
    final UserLocation? myLoc;
    if (aprs.hasLocation) {
      myLoc = UserLocation(
        latitude: aprs.savedLatitude!,
        longitude: aprs.savedLongitude!,
        timestamp: DateTime.now(),
        source: 'saved',
      );
    } else {
      final locPos = LocationProviderService().currentPosition;
      myLoc = locPos != null
          ? UserLocation(
              latitude: locPos.latitude,
              longitude: locPos.longitude,
              timestamp: locPos.timestamp,
              source: locPos.source,
            )
          : UserLocationService().currentLocation;
    }
    // The effective radius for display filtering: use drag value while
    // sliding, otherwise the committed service value.
    final effectiveRadius = _draggingRadius ?? aprs.radiusKm;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(I18nService().t('aprs_title')),
          actions: [
            Switch(
              value: aprs.isEnabled,
              onChanged: (on) {
                if (on) {
                  // Auto-obtain position from available sources if not set
                  if (!aprs.hasLocation) {
                    final locPos = LocationProviderService().currentPosition;
                    final userLoc = UserLocationService().currentLocation;
                    if (locPos != null) {
                      final profileStorage = AppService().profileStorage;
                      if (profileStorage != null) aprs.setStorage(profileStorage);
                      aprs.setLocation(locPos.latitude, locPos.longitude);
                    } else if (userLoc != null && userLoc.isValid) {
                      final profileStorage = AppService().profileStorage;
                      if (profileStorage != null) aprs.setStorage(profileStorage);
                      aprs.setLocation(userLoc.latitude, userLoc.longitude);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(I18nService().t('aprs_set_location_first')),
                        ),
                      );
                      return;
                    }
                  }
                  final profileStorage = AppService().profileStorage;
                  if (profileStorage != null) aprs.setStorage(profileStorage);
                  final profile = ProfileService().getProfile();
                  aprs.enable(callsign: profile.fullCallsign);
                } else {
                  aprs.disable();
                }
                setState(() {});
              },
            ),
            IconButton(
              icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
              tooltip: _paused ? I18nService().t('aprs_resume_updates') : I18nService().t('aprs_pause_updates'),
              onPressed: () {
                setState(() {
                  _paused = !_paused;
                });
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: I18nService().t('aprs_clear_messages'),
              onPressed: () {
                aprs.clearDisplay();
                setState(() {});
              },
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: I18nService().t('aprs_settings_title'),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        AprsSettingsPage(appPath: widget.appPath),
                  ),
                );
              },
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: I18nService().t('aprs_tab_map')),
              Tab(text: I18nService().t('aprs_tab_stream')),
              Tab(text: I18nService().t('aprs_tab_messages')),
            ],
          ),
        ),
        body: Column(
          children: [
            _buildRadiusSlider(context, aprs),
            Expanded(
              child: TabBarView(
                children: [
                  _MapTab(
                    myLocation: myLoc,
                    lastKnownPositions: aprs.lastKnownPositions,
                    streamPackets: aprs.streamPackets,
                    geoChatMessages: aprs.geoChatMessages,
                    radiusKm: effectiveRadius,
                  ),
                  _StreamTab(
                    packets: aprs.streamPackets,
                    myLocation: myLoc,
                    radiusKm: effectiveRadius,
                  ),
                  AprsConversationList(myLocation: myLoc),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  // --- Logarithmic slider helpers ---
  // Two-segment exponential so that 100 km sits at the physical midpoint.
  //   t 0.0 → 1 km   |  t 0.25 → 10 km  |  t 0.5 → 100 km
  //   t 0.75 → ~316 km  |  t 1.0 → 1000 km

  static double _sliderToKm(double t) {
    if (t <= 0.5) {
      return pow(100, t / 0.5).toDouble(); // 100^(2t): 1→100
    }
    return 100.0 * pow(10, (t - 0.5) / 0.5); // 100·10^(2(t-0.5)): 100→1000
  }

  static double _kmToSlider(double km) {
    if (km <= 1) return 0;
    if (km >= 1000) return 1;
    if (km <= 100) {
      return 0.5 * (log(km) / log(100));
    }
    return 0.5 + 0.5 * (log(km / 100) / log(10));
  }

  /// Snap km to contextual step sizes — fine near the left, coarse near right.
  static double _snapKm(double km) {
    if (km <= 5) return km.roundToDouble().clamp(1, 5);
    if (km <= 20) return (km / 2).round() * 2.0;
    if (km <= 50) return (km / 5).round() * 5.0;
    if (km <= 100) return (km / 10).round() * 10.0;
    if (km <= 300) return (km / 25).round() * 25.0;
    if (km <= 600) return (km / 50).round() * 50.0;
    return (km / 100).round() * 100.0;
  }

  Widget _buildRadiusSlider(BuildContext context, AprsService aprs) {
    final theme = Theme.of(context);
    final km = _draggingRadius ?? aprs.radiusKm;
    final sliderVal = _kmToSlider(km);

    String radiusText;
    if (km >= 10) {
      radiusText = '${km.round()} km';
    } else {
      radiusText = '${km.toStringAsFixed(1)} km';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        border: Border(
          bottom: BorderSide(color: theme.dividerColor, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.cell_tower,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Text(
            I18nService().t('aprs_range_label'),
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 8),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                value: sliderVal,
                min: 0,
                max: 1,
                onChanged: (t) {
                  // Visual feedback — filter lists immediately while dragging
                  setState(() {
                    _draggingRadius = _snapKm(_sliderToKm(t));
                  });
                },
                onChangeEnd: (t) {
                  // User released the slider — commit and send filter to server
                  final newRadius = _snapKm(_sliderToKm(t));
                  setState(() {
                    _draggingRadius = null;
                    aprs.radiusKm = newRadius;
                  });
                },
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              radiusText,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
              textAlign: TextAlign.end,
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              icon: Icon(
                Icons.my_location,
                size: 18,
                color: _hasLocation()
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              ),
              padding: EdgeInsets.zero,
              tooltip: I18nService().t('aprs_choose_location_tooltip'),
              onPressed: () => _pickLocation(context),
            ),
          ),
        ],
      ),
    );
  }

  bool _hasLocation() {
    if (AprsService().hasLocation) return true;
    final locPos = LocationProviderService().currentPosition;
    if (locPos != null) return true;
    final loc = UserLocationService().currentLocation;
    return loc != null && loc.isValid;
  }

  Future<void> _pickLocation(BuildContext context) async {
    // Use saved APRS position → LocationProvider → UserLocationService
    LatLng? initial;
    final aprsPos = AprsService();
    if (aprsPos.hasLocation) {
      initial = LatLng(aprsPos.savedLatitude!, aprsPos.savedLongitude!);
    } else {
      final locPos = LocationProviderService().currentPosition;
      if (locPos != null) {
        initial = LatLng(locPos.latitude, locPos.longitude);
      } else {
        final loc = UserLocationService().currentLocation;
        if (loc != null && loc.isValid) {
          initial = LatLng(loc.latitude, loc.longitude);
        }
      }
    }

    final picked = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerPage(initialPosition: initial),
      ),
    );

    if (picked != null && mounted) {
      final aprs = AprsService();
      // Ensure storage is wired so the position is persisted to config
      final profileStorage = AppService().profileStorage;
      if (profileStorage != null) aprs.setStorage(profileStorage);
      aprs.setLocation(picked.latitude, picked.longitude);
      // Also update UserLocationService so the UI page can read it
      UserLocationService().setManualLocation(
        picked.latitude, picked.longitude,
      );
      setState(() {});
    }
  }
}

// =============================================================================
// Shared distance helpers
// =============================================================================

/// Return the distance in km between a point and the user's location,
/// or null if either coordinate is unknown.
double? distanceKm(
  double? pktLat,
  double? pktLon,
  UserLocation? myLocation,
) {
  if (pktLat == null || pktLon == null) return null;
  if (myLocation == null || !myLocation.isValid) return null;
  return _haversineKm(
    myLocation.latitude, myLocation.longitude,
    pktLat, pktLon,
  );
}

/// Format a distance in km for display.
String formatDistanceKm(double km) {
  if (km < 1) return '${(km * 1000).round()} m';
  if (km < 100) return '${km.toStringAsFixed(1)} km';
  return '${km.round()} km';
}

double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const earthRadius = 6371.0;
  final dLat = _deg2rad(lat2 - lat1);
  final dLon = _deg2rad(lon2 - lon1);
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(_deg2rad(lat1)) * cos(_deg2rad(lat2)) *
      sin(dLon / 2) * sin(dLon / 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return earthRadius * c;
}

double _deg2rad(double deg) => deg * pi / 180;

String _formatTime(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  final s = dt.second.toString().padLeft(2, '0');
  return '$h:$m:$s';
}

/// Regex matching URLs: http(s)://... or domain.tld/... patterns.
/// Greedy match — trailing punctuation is stripped in _cleanUrl().
final _urlRegex = RegExp(
  r'https?://\S+'
  r'|(?:[a-zA-Z0-9-]+\.)+(?:com|org|net|io|de|info|eu|uk|me|radio|app|dev|cc|at|ch|fr|nl|es|it|pl|cz|se|no|fi|pt|br|au|ca|ru|jp)\S*',
  caseSensitive: false,
);

/// Strip wrapping parentheses/brackets and trailing punctuation from a URL.
String _cleanUrl(String raw) {
  var url = raw;
  // Strip matching wrapper pairs: (url), [url], <url>
  const pairs = {'(': ')', '[': ']', '<': '>'};
  for (final entry in pairs.entries) {
    if (url.startsWith(entry.key) && url.contains(entry.value)) {
      url = url.substring(1);
      final close = url.lastIndexOf(entry.value);
      if (close >= 0) url = url.substring(0, close) + url.substring(close + 1);
    }
  }
  // Strip trailing punctuation that's not part of the URL
  while (url.isNotEmpty && '.,;:!?)]\'>\"'.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

/// Builds a Text.rich with tappable URL spans.
/// Falls back to a plain Text when there are no URLs.
Widget linkifiedText(
  String text, {
  TextStyle? style,
  int? maxLines,
  TextOverflow? overflow,
}) {
  final matches = _urlRegex.allMatches(text).toList();
  if (matches.isEmpty) {
    return Text(text, style: style, maxLines: maxLines, overflow: overflow);
  }
  final spans = <InlineSpan>[];
  int prev = 0;
  for (final m in matches) {
    // Include any leading wrapper char (e.g. the '(' in '(http://...)')
    var start = m.start;
    if (start > 0 && '([<'.contains(text[start - 1])) start -= 1;
    if (start > prev) {
      spans.add(TextSpan(text: text.substring(prev, start)));
    }
    final rawWithContext = text.substring(start, m.end);
    final cleaned = _cleanUrl(rawWithContext);
    final uri = cleaned.startsWith('http') ? cleaned : 'https://$cleaned';
    spans.add(WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: GestureDetector(
        onTap: () => launchUrl(Uri.parse(uri), mode: LaunchMode.externalApplication),
        child: Text(
          cleaned,
          style: (style ?? const TextStyle()).copyWith(
            color: const Color(0xFF4FC3F7),
            decoration: TextDecoration.underline,
            decorationColor: const Color(0xFF4FC3F7),
          ),
        ),
      ),
    ));
    prev = m.end;
  }
  if (prev < text.length) {
    spans.add(TextSpan(text: text.substring(prev)));
  }
  return Text.rich(
    TextSpan(style: style, children: spans),
    maxLines: maxLines,
    overflow: overflow,
  );
}

IconData _iconForType(AprsPacketType type) {
  switch (type) {
    case AprsPacketType.position:
      return Icons.location_on;
    case AprsPacketType.message:
      return Icons.mail;
    case AprsPacketType.status:
      return Icons.info_outline;
    case AprsPacketType.weather:
      return Icons.cloud;
    case AprsPacketType.telemetry:
      return Icons.analytics;
    case AprsPacketType.other:
      return Icons.radio;
  }
}

/// Returns a specialized SVG icon if the packet info mentions LoRa or POCSAG,
/// otherwise a standard Material icon for the packet type.
Widget iconForPacket(AprsPacket pkt, {double size = 20, Color? color}) {
  final lower = pkt.infoField.toLowerCase();
  if (lower.contains('pocsag')) {
    return SvgPicture.asset(
      'assets/aprs_pocsag.svg',
      width: size,
      height: size,
    );
  }
  if (lower.contains('lora')) {
    return SvgPicture.asset(
      'assets/aprs_lora.svg',
      width: size,
      height: size,
    );
  }
  return Icon(_iconForType(pkt.type), size: size, color: color);
}

// =============================================================================
// Map tab — satellite view with station markers and radius circle
// =============================================================================

class _MapTab extends StatefulWidget {
  final UserLocation? myLocation;
  final Map<String, (double, double)> lastKnownPositions;
  final List<AprsPacket> streamPackets;
  final List<AprsPacket> geoChatMessages;
  final double radiusKm;

  const _MapTab({
    this.myLocation,
    required this.lastKnownPositions,
    required this.streamPackets,
    required this.geoChatMessages,
    required this.radiusKm,
  });

  @override
  State<_MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<_MapTab> with AutomaticKeepAliveClientMixin {
  final MapController _mapController = MapController();
  final MapTileService _mapTileService = MapTileService();
  bool _mapReady = false;
  bool _showGeoChat = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant _MapTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newLoc = widget.myLocation;
    final oldLoc = oldWidget.myLocation;
    // Recenter the map when the user's location changes
    if (_mapReady && newLoc != null && newLoc.isValid) {
      if (oldLoc == null ||
          oldLoc.latitude != newLoc.latitude ||
          oldLoc.longitude != newLoc.longitude) {
        _mapController.move(
          LatLng(newLoc.latitude, newLoc.longitude),
          _mapController.camera.zoom,
        );
      }
      // Re-zoom when radius changes
      if (oldWidget.radiusKm != widget.radiusKm) {
        _mapController.move(
          _mapController.camera.center,
          _zoomForRadius(widget.radiusKm),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final myLoc = widget.myLocation;
    if (myLoc == null || !myLoc.isValid) {
      return Center(child: Text(I18nService().t('aprs_set_location_for_map')));
    }

    final center = LatLng(myLoc.latitude, myLoc.longitude);
    final theme = Theme.of(context);

    // Build station markers — one per callsign, deduped via lastKnownPositions
    final markers = <Marker>[];
    widget.lastKnownPositions.forEach((callsign, pos) {
      final lat = pos.$1;
      final lon = pos.$2;
      final dist = _haversineKm(
        myLoc.latitude, myLoc.longitude, lat, lon,
      );
      if (dist > widget.radiusKm) return;
      markers.add(
        Marker(
          point: LatLng(lat, lon),
          width: 100,
          height: 54,
          child: GestureDetector(
            onTap: () => _showStationInfo(context, callsign, lat, lon, dist),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.white54, width: 0.5),
                  ),
                  child: Text(
                    callsign,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 1),
                SvgPicture.asset(
                  'assets/aprs_station.svg',
                  width: 28,
                  height: 28,
                ),
              ],
            ),
          ),
        ),
      );
    });

    final isWideScreen = MediaQuery.of(context).size.width > 600;

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: _zoomForRadius(widget.radiusKm),
            minZoom: 1.0,
            maxZoom: 18.0,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapReady: () {
              if (mounted) setState(() => _mapReady = true);
            },
          ),
          children: [
            // Satellite tile layer
            TileLayer(
              urlTemplate: MapTileService.satelliteTileUrl,
              userAgentPackageName: 'dev.geogram',
              subdomains: const [],
              keepBuffer: 3,
              tileProvider: _mapTileService.getTileProvider(MapLayerType.satellite),
            ),
            // Labels overlay
            TileLayer(
              urlTemplate: _mapTileService.getLabelsUrl(),
              userAgentPackageName: 'dev.geogram',
              subdomains: const [],
              keepBuffer: 3,
              tileProvider: _mapTileService.getLabelsProvider(),
            ),
            // Radius circle
            CircleLayer(
              circles: [
                CircleMarker(
                  point: center,
                  radius: widget.radiusKm * 1000,
                  useRadiusInMeter: true,
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderColor: theme.colorScheme.primary.withValues(alpha: 0.5),
                  borderStrokeWidth: 2,
                ),
              ],
            ),
            // Station markers (clustered)
            MarkerClusterLayerWidget(
              options: MarkerClusterLayerOptions(
                maxClusterRadius: 80,
                size: const Size(44, 44),
                alignment: Alignment.center,
                padding: const EdgeInsets.all(50),
                maxZoom: 15,
                markers: markers,
                builder: (context, clusterMarkers) {
                  return Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFFF6D00),
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        clusterMarkers.length.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // My position marker
            MarkerLayer(
              markers: [
                Marker(
                  point: center,
                  width: 24,
                  height: 24,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.primary,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        // Geo-chat panel — always visible on desktop, toggled on mobile
        if (_showGeoChat || isWideScreen)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 320,
            child: AprsGeoChatPanel(
              messages: widget.geoChatMessages,
              myLocation: widget.myLocation,
              onMessageTap: (lat, lon) {
                if (_mapReady) {
                  _mapController.move(
                    LatLng(lat, lon),
                    _mapController.camera.zoom,
                  );
                }
              },
              onClose: () => setState(() => _showGeoChat = false),
            ),
          ),
        // Toggle FAB (mobile only, hidden when panel is open so it
        // doesn't overlap the send button)
        if (!isWideScreen && !_showGeoChat)
          Positioned(
            right: 12,
            bottom: 12,
            child: FloatingActionButton.small(
              onPressed: () => setState(() => _showGeoChat = true),
              child: const Icon(Icons.chat_bubble_outline),
            ),
          ),
      ],
    );
  }

  void _showStationInfo(
    BuildContext context, String callsign, double lat, double lon, double dist,
  ) {
    // Collect the latest packets from this station (most recent first)
    final stationPackets = <AprsPacket>[];
    for (int i = widget.streamPackets.length - 1;
        i >= 0 && stationPackets.length < 10;
        i--) {
      final pkt = widget.streamPackets[i];
      if (pkt.fromCallsign == callsign) {
        // Dedup by info field — skip repeated beacons
        if (stationPackets.every((p) => p.infoField != pkt.infoField)) {
          stationPackets.add(pkt);
        }
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.4,
        minChildSize: 0.2,
        maxChildSize: 0.7,
        expand: false,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      callsign,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Text(
                    formatDistanceKm(dist),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Divider(height: 16),
              Expanded(
                child: stationPackets.isEmpty
                    ? Center(child: Text(I18nService().t('aprs_no_station_packets')))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: stationPackets.length,
                        itemBuilder: (context, index) {
                          final pkt = stationPackets[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                iconForPacket(
                                  pkt,
                                  size: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: linkifiedText(
                                    pkt.infoField,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _formatTime(pkt.timestamp),
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Pick a zoom level that fits the radius circle on screen.
  static double _zoomForRadius(double km) {
    // Rough approximation: at zoom 10, ~100km fits; each zoom doubles.
    if (km <= 2) return 14;
    if (km <= 5) return 13;
    if (km <= 10) return 12;
    if (km <= 25) return 11;
    if (km <= 50) return 10;
    if (km <= 100) return 9;
    if (km <= 250) return 8;
    if (km <= 500) return 7;
    return 6;
  }

  static double _haversineKm(
    double lat1, double lon1, double lat2, double lon2,
  ) {
    const earthRadius = 6371.0;
    final dLat = _deg2radLocal(lat2 - lat1);
    final dLon = _deg2radLocal(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2radLocal(lat1)) * cos(_deg2radLocal(lat2)) *
        sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  static double _deg2radLocal(double deg) => deg * pi / 180;
}

// =============================================================================
// Stream tab — all received broadcast packets, filtered by radius
// =============================================================================

class _StreamTab extends StatelessWidget {
  final List<AprsPacket> packets;
  final UserLocation? myLocation;
  final double radiusKm;

  const _StreamTab({
    required this.packets,
    this.myLocation,
    required this.radiusKm,
  });

  void _openMap(BuildContext context, double lat, double lon, String label) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LocationPickerPage(
          initialPosition: LatLng(lat, lon),
          viewOnly: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (packets.isEmpty) {
      return Center(child: Text(I18nService().t('aprs_no_packets')));
    }

    // Build filtered list: only packets with coordinates within radius.
    final filtered = <(AprsPacket, double)>[];
    for (int i = packets.length - 1; i >= 0; i--) {
      final pkt = packets[i];
      final dist = distanceKm(pkt.latitude, pkt.longitude, myLocation);
      if (dist != null && dist <= radiusKm) {
        filtered.add((pkt, dist));
      }
    }

    if (filtered.isEmpty) {
      return Center(child: Text(I18nService().t('aprs_no_packets_in_range')));
    }

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final (pkt, dist) = filtered[index];
        final distStr = formatDistanceKm(dist);
        final theme = Theme.of(context);
        return ListTile(
          leading: iconForPacket(
            pkt,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  pkt.fromCallsign,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                distStr,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          subtitle: linkifiedText(
            pkt.infoField,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatTime(pkt.timestamp),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => _openMap(context, pkt.latitude!, pkt.longitude!, pkt.fromCallsign),
                child: Icon(
                  Icons.map_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// _MessagesTab removed — replaced by AprsConversationList widget
