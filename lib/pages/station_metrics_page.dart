/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../services/station_node_service.dart';
import '../station.dart' show ServerStats;

/// Full station metrics page with time-bucketed stats, bandwidth, and popular devices.
class StationMetricsPage extends StatelessWidget {
  const StationMetricsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final server = StationNodeService().stationServer;
    final stats = server?.stats;

    return Scaffold(
      appBar: AppBar(title: Text('Station Metrics')),
      body: stats == null
          ? Center(child: Text('Station not running'))
          : SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildRequestsSection(stats),
                  SizedBox(height: 16),
                  _buildBandwidthSection(stats),
                  SizedBox(height: 16),
                  _buildPopularDevicesSection(stats),
                ],
              ),
            ),
    );
  }

  Widget _buildRequestsSection(ServerStats stats) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('REQUESTS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _metricTile('Today', _formatCount(stats.requestsToday))),
                Expanded(child: _metricTile('This Week', _formatCount(stats.requestsThisWeek))),
              ],
            ),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _metricTile('This Month', _formatCount(stats.requestsThisMonth))),
                Expanded(child: _metricTile('All Time', _formatCount(stats.totalApiRequests))),
              ],
            ),
            SizedBox(height: 12),
            Divider(height: 1),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _metricTile('Connections', _formatCount(stats.totalConnections))),
                Expanded(child: _metricTile('Messages', _formatCount(stats.totalMessages))),
              ],
            ),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _metricTile('Tile Requests', _formatCount(stats.totalTileRequests))),
                Expanded(child: _metricTile('Cache Hits', _formatCount(stats.tilesServedFromCache))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBandwidthSection(ServerStats stats) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('BANDWIDTH', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _metricTile('Today', _formatBytes(stats.bytesServedToday))),
                Expanded(child: _metricTile('All Time', _formatBytes(stats.bytesServedTotal))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPopularDevicesSection(ServerStats stats) {
    final topDevices = stats.topDevices;
    final totalRequests = topDevices.fold<int>(0, (sum, e) => sum + e.value);

    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('POPULAR DEVICES', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            SizedBox(height: 12),
            if (topDevices.isEmpty)
              Text('No device activity yet', style: TextStyle(color: Colors.grey[600], fontSize: 13))
            else
              ...topDevices.take(20).map((entry) {
                final pct = totalRequests > 0 ? entry.value / totalRequests : 0.0;
                return Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 70,
                        child: Text(entry.key, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: pct,
                          backgroundColor: Colors.grey[200],
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      SizedBox(width: 8),
                      Text(_formatCount(entry.value), style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _metricTile(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
      ],
    );
  }

  static String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1099511627776) return '${(bytes / 1099511627776).toStringAsFixed(1)} TB';
    if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}
