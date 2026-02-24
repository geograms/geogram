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

import '../../../services/app_service.dart';
import '../../../services/location_provider_service.dart';
import '../../../services/profile_service.dart';
import '../../../services/user_location_service.dart';
import '../aprs_service.dart';
import '../models/aprs_packet.dart';
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

  @override
  void initState() {
    super.initState();
    _eventSub = AprsService().events.listen((_) {
      if (mounted) setState(() {});
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
    // Use LocationProviderService for position — it resolves via
    // GPS / IP-geolocation / profile fallback (same source APRS uses).
    final locPos = LocationProviderService().currentPosition;
    final myLoc = locPos != null
        ? UserLocation(
            latitude: locPos.latitude,
            longitude: locPos.longitude,
            timestamp: locPos.timestamp,
            source: locPos.source,
          )
        : UserLocationService().currentLocation;
    // The effective radius for display filtering: use drag value while
    // sliding, otherwise the committed service value.
    final effectiveRadius = _draggingRadius ?? aprs.radiusKm;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('APRS'),
          actions: [
            Switch(
              value: aprs.isEnabled,
              onChanged: (on) {
                if (on) {
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
              icon: const Icon(Icons.settings),
              tooltip: 'APRS Settings',
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
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Stream'),
              Tab(text: 'Messages'),
            ],
          ),
        ),
        body: Column(
          children: [
            _buildRadiusSlider(context, aprs),
            Expanded(
              child: TabBarView(
                children: [
                  _StreamTab(
                    packets: aprs.streamPackets,
                    myLocation: myLoc,
                    radiusKm: effectiveRadius,
                  ),
                  _MessagesTab(
                    messages: aprs.messages,
                    myLocation: myLoc,
                    lastKnownPositions: aprs.lastKnownPositions,
                    radiusKm: effectiveRadius,
                  ),
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
            'Range',
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
            width: 70,
            child: Text(
              radiusText,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    if (packets.isEmpty) {
      return const Center(child: Text('No packets received yet'));
    }

    // Build filtered list: keep packets that are within radius, or have no
    // known position (so they don't silently vanish).
    final filtered = <(AprsPacket, double?)>[];
    for (int i = packets.length - 1; i >= 0; i--) {
      final pkt = packets[i];
      final dist = distanceKm(pkt.latitude, pkt.longitude, myLocation);
      if (dist == null || dist <= radiusKm) {
        filtered.add((pkt, dist));
      }
    }

    if (filtered.isEmpty) {
      return const Center(child: Text('No packets within this range'));
    }

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final (pkt, dist) = filtered[index];
        final distStr = dist != null ? formatDistanceKm(dist) : null;
        final theme = Theme.of(context);
        return ListTile(
          leading: Icon(
            _iconForType(pkt.type),
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
              if (distStr != null)
                Text(
                  distStr,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
          subtitle: Text(
            pkt.infoField,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            _formatTime(pkt.timestamp),
            style: theme.textTheme.bodySmall,
          ),
        );
      },
    );
  }
}

// =============================================================================
// Messages tab — directed 1:1 messages, filtered by sender distance
// =============================================================================

class _MessagesTab extends StatelessWidget {
  final List<AprsPacket> messages;
  final UserLocation? myLocation;
  final Map<String, (double, double)> lastKnownPositions;
  final double radiusKm;

  const _MessagesTab({
    required this.messages,
    this.myLocation,
    required this.lastKnownPositions,
    required this.radiusKm,
  });

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const Center(child: Text('No messages yet'));
    }

    // Build filtered list: keep messages whose sender is within radius,
    // or whose sender position is unknown (don't hide messages silently).
    final filtered = <(AprsPacket, double?)>[];
    for (int i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      final pos = lastKnownPositions[msg.fromCallsign];
      final dist = distanceKm(pos?.$1, pos?.$2, myLocation);
      if (dist == null || dist <= radiusKm) {
        filtered.add((msg, dist));
      }
    }

    if (filtered.isEmpty) {
      return const Center(child: Text('No messages within this range'));
    }

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final (msg, dist) = filtered[index];
        final distStr = dist != null ? formatDistanceKm(dist) : null;
        final theme = Theme.of(context);

        return ListTile(
          title: Row(
            children: [
              Expanded(
                child: Text(
                  msg.fromCallsign,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (distStr != null)
                Text(
                  distStr,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
          subtitle: Text(
            msg.messageText ?? msg.infoField,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatTime(msg.timestamp),
                style: theme.textTheme.bodySmall,
              ),
              if (msg.messageId != null)
                Icon(
                  msg.isAcked ? Icons.done_all : Icons.done,
                  size: 16,
                  color: msg.isAcked ? Colors.green : null,
                ),
            ],
          ),
        );
      },
    );
  }
}
