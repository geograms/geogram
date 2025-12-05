/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import '../services/relay_node_service.dart';

/// Node status in the topology
enum NodeStatus {
  online,
  offline,
  unknown,
}

/// A node in the network topology
class TopologyNode {
  final String callsign;
  final String npub;
  final String relayId;
  final String type;
  final double? latitude;
  final double? longitude;
  final NodeStatus status;
  final DateTime? lastSeen;
  final List<String> channels;

  TopologyNode({
    required this.callsign,
    required this.npub,
    required this.relayId,
    required this.type,
    this.latitude,
    this.longitude,
    this.status = NodeStatus.unknown,
    this.lastSeen,
    this.channels = const [],
  });

  factory TopologyNode.fromJson(Map<String, dynamic> json) {
    final location = json['location'] as Map<String, dynamic>?;
    final statusStr = json['status'] as String? ?? 'unknown';

    NodeStatus status;
    switch (statusStr) {
      case 'online':
        status = NodeStatus.online;
        break;
      case 'offline':
        status = NodeStatus.offline;
        break;
      default:
        status = NodeStatus.unknown;
    }

    return TopologyNode(
      callsign: json['callsign'] as String,
      npub: json['npub'] as String? ?? '',
      relayId: json['relay_id'] as String? ?? '',
      type: json['type'] as String? ?? 'node',
      latitude: location?['lat'] as double?,
      longitude: location?['lon'] as double?,
      status: status,
      lastSeen: json['last_seen'] != null
          ? DateTime.tryParse((json['last_seen'] as String).replaceAll('_', ':').replaceFirst(' ', 'T'))
          : null,
      channels: (json['channels'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
    );
  }
}

/// A connection between two nodes
class TopologyConnection {
  final String from;
  final String to;
  final List<String> channels;
  final String quality;
  final int? latencyMs;
  final DateTime? lastSync;

  TopologyConnection({
    required this.from,
    required this.to,
    this.channels = const [],
    this.quality = 'unknown',
    this.latencyMs,
    this.lastSync,
  });

  factory TopologyConnection.fromJson(Map<String, dynamic> json) {
    return TopologyConnection(
      from: json['from'] as String,
      to: json['to'] as String,
      channels: (json['channels'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
      quality: json['quality'] as String? ?? 'unknown',
      latencyMs: json['latency_ms'] as int?,
      lastSync: json['last_sync'] != null
          ? DateTime.tryParse((json['last_sync'] as String).replaceAll('_', ':').replaceFirst(' ', 'T'))
          : null,
    );
  }
}

/// Page for viewing network topology
class RelayTopologyPage extends StatefulWidget {
  const RelayTopologyPage({super.key});

  @override
  State<RelayTopologyPage> createState() => _RelayTopologyPageState();
}

class _RelayTopologyPageState extends State<RelayTopologyPage> {
  final RelayNodeService _relayNodeService = RelayNodeService();

  Map<String, TopologyNode> _nodes = {};
  List<TopologyConnection> _connections = [];
  bool _isLoading = true;
  String? _error;
  String? _selectedNode;

  // View mode
  bool _showMapView = false;

  @override
  void initState() {
    super.initState();
    _loadTopology();
  }

  Future<void> _loadTopology() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final relayDir = await _relayNodeService.getRelayDirectory();
      final topologyFile = File(path.join(relayDir.path, 'sync', 'topology.json'));

      if (!await topologyFile.exists()) {
        // Create mock data for visualization
        _createMockTopology();
        setState(() {
          _isLoading = false;
        });
        return;
      }

      final content = await topologyFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;

      // Parse nodes
      final nodesJson = json['nodes'] as Map<String, dynamic>? ?? {};
      _nodes = {};
      for (final entry in nodesJson.entries) {
        _nodes[entry.key] = TopologyNode.fromJson(entry.value as Map<String, dynamic>);
      }

      // Parse connections
      final connectionsJson = json['connections'] as List<dynamic>? ?? [];
      _connections = connectionsJson
          .map((c) => TopologyConnection.fromJson(c as Map<String, dynamic>))
          .toList();

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      // Create mock data on error
      _createMockTopology();
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _createMockTopology() {
    final node = _relayNodeService.relayNode;
    if (node == null) return;

    // Add current node
    _nodes = {
      node.callsign: TopologyNode(
        callsign: node.callsign,
        npub: node.npub,
        relayId: node.id,
        type: node.isRoot ? 'root' : 'node',
        latitude: node.config.coverage?.latitude,
        longitude: node.config.coverage?.longitude,
        status: node.isRunning ? NodeStatus.online : NodeStatus.offline,
        lastSeen: DateTime.now(),
        channels: node.config.channels.map((c) => c.type).toList(),
      ),
    };

    // If this is a node, add the root as well
    if (node.isNode && node.rootCallsign != null) {
      _nodes[node.rootCallsign!] = TopologyNode(
        callsign: node.rootCallsign!,
        npub: node.rootNpub ?? '',
        relayId: '',
        type: 'root',
        status: NodeStatus.unknown,
        channels: ['internet'],
      );

      _connections = [
        TopologyConnection(
          from: node.rootCallsign!,
          to: node.callsign,
          channels: ['internet'],
          quality: 'unknown',
        ),
      ];
    } else {
      _connections = [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Network Topology'),
        actions: [
          IconButton(
            icon: Icon(_showMapView ? Icons.account_tree : Icons.map),
            onPressed: () => setState(() => _showMapView = !_showMapView),
            tooltip: _showMapView ? 'Graph view' : 'Map view',
          ),
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _loadTopology,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Error: $_error'))
              : Column(
                  children: [
                    _buildStatsBar(),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: _showMapView ? _buildMapView() : _buildGraphView(),
                          ),
                          if (_selectedNode != null)
                            Container(
                              width: 300,
                              decoration: BoxDecoration(
                                border: Border(left: BorderSide(color: Colors.grey[300]!)),
                              ),
                              child: _buildNodeDetail(_nodes[_selectedNode]!),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildStatsBar() {
    final onlineCount = _nodes.values.where((n) => n.status == NodeStatus.online).length;
    final offlineCount = _nodes.values.where((n) => n.status == NodeStatus.offline).length;
    final rootCount = _nodes.values.where((n) => n.type == 'root').length;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.grey[100],
      child: Row(
        children: [
          _buildStatChip(Icons.hub, 'Nodes', '${_nodes.length}'),
          SizedBox(width: 16),
          _buildStatChip(Icons.check_circle, 'Online', '$onlineCount', Colors.green),
          SizedBox(width: 16),
          _buildStatChip(Icons.cancel, 'Offline', '$offlineCount', Colors.red),
          SizedBox(width: 16),
          _buildStatChip(Icons.link, 'Connections', '${_connections.length}'),
          Spacer(),
          Text(
            'Root: $rootCount',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(IconData icon, String label, String value, [Color? color]) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color ?? Colors.grey[600]),
        SizedBox(width: 4),
        Text(value, style: TextStyle(fontWeight: FontWeight.bold)),
        SizedBox(width: 4),
        Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
      ],
    );
  }

  Widget _buildGraphView() {
    if (_nodes.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.account_tree, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('No nodes in topology', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: _TopologyPainter(
            nodes: _nodes,
            connections: _connections,
            selectedNode: _selectedNode,
          ),
          child: GestureDetector(
            onTapDown: (details) => _handleTap(details, constraints),
          ),
        );
      },
    );
  }

  void _handleTap(TapDownDetails details, BoxConstraints constraints) {
    final positions = _calculateNodePositions(constraints.maxWidth, constraints.maxHeight);

    for (final entry in positions.entries) {
      final pos = entry.value;
      final distance = math.sqrt(
        math.pow(details.localPosition.dx - pos.dx, 2) +
            math.pow(details.localPosition.dy - pos.dy, 2),
      );

      if (distance < 30) {
        setState(() {
          _selectedNode = _selectedNode == entry.key ? null : entry.key;
        });
        return;
      }
    }

    // Clicked outside any node
    setState(() {
      _selectedNode = null;
    });
  }

  Map<String, Offset> _calculateNodePositions(double width, double height) {
    final positions = <String, Offset>{};
    final nodeList = _nodes.keys.toList();
    final centerX = width / 2;
    final centerY = height / 2;
    final radius = math.min(width, height) / 3;

    // Find root node
    final rootIndex = nodeList.indexWhere((k) => _nodes[k]?.type == 'root');

    if (rootIndex >= 0) {
      // Place root at center
      positions[nodeList[rootIndex]] = Offset(centerX, centerY);

      // Place other nodes in a circle around root
      final others = nodeList.where((k) => _nodes[k]?.type != 'root').toList();
      for (var i = 0; i < others.length; i++) {
        final angle = (2 * math.pi * i) / others.length - math.pi / 2;
        positions[others[i]] = Offset(
          centerX + radius * math.cos(angle),
          centerY + radius * math.sin(angle),
        );
      }
    } else {
      // No root, place all in a circle
      for (var i = 0; i < nodeList.length; i++) {
        final angle = (2 * math.pi * i) / nodeList.length - math.pi / 2;
        positions[nodeList[i]] = Offset(
          centerX + radius * math.cos(angle),
          centerY + radius * math.sin(angle),
        );
      }
    }

    return positions;
  }

  Widget _buildMapView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.map, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text('Map view requires location data', style: TextStyle(color: Colors.grey)),
          SizedBox(height: 8),
          Text(
            'Nodes with coordinates will be shown on the map',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildNodeDetail(TopologyNode node) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: _getStatusColor(node.status).withOpacity(0.2),
                child: Icon(
                  node.type == 'root' ? Icons.hub : Icons.device_hub,
                  color: _getStatusColor(node.status),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(node.callsign, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    Text(node.type == 'root' ? 'Root Relay' : 'Node Relay',
                        style: TextStyle(color: Colors.grey[600])),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.close),
                onPressed: () => setState(() => _selectedNode = null),
              ),
            ],
          ),
          Divider(height: 24),
          _buildDetailRow('Status', _getStatusText(node.status)),
          _buildDetailRow('Relay ID', node.relayId.isNotEmpty ? node.relayId : 'N/A'),
          _buildDetailRow('NPUB', _truncateNpub(node.npub)),
          if (node.lastSeen != null)
            _buildDetailRow('Last seen', _formatDateTime(node.lastSeen!)),
          if (node.latitude != null && node.longitude != null)
            _buildDetailRow('Location', '${node.latitude!.toStringAsFixed(4)}, ${node.longitude!.toStringAsFixed(4)}'),
          SizedBox(height: 16),
          Text('Channels', style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          if (node.channels.isEmpty)
            Text('No channels', style: TextStyle(color: Colors.grey))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: node.channels.map((c) => Chip(
                avatar: Icon(_getChannelIcon(c), size: 16),
                label: Text(c, style: TextStyle(fontSize: 12)),
              )).toList(),
            ),
          SizedBox(height: 16),
          Text('Connections', style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          ..._connections
              .where((c) => c.from == node.callsign || c.to == node.callsign)
              .map((c) => _buildConnectionTile(c, node.callsign)),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 80, child: Text(label, style: TextStyle(color: Colors.grey[600]))),
          Expanded(
            child: SelectableText(value, style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionTile(TopologyConnection conn, String currentNode) {
    final otherNode = conn.from == currentNode ? conn.to : conn.from;
    final qualityColor = _getQualityColor(conn.quality);

    return Card(
      child: ListTile(
        dense: true,
        leading: Icon(Icons.link, color: qualityColor),
        title: Text(otherNode),
        subtitle: Text(
          '${conn.quality}${conn.latencyMs != null ? ' - ${conn.latencyMs}ms' : ''}',
          style: TextStyle(fontSize: 11),
        ),
        trailing: Wrap(
          spacing: 4,
          children: conn.channels.take(2).map((c) =>
            Icon(_getChannelIcon(c), size: 14, color: Colors.grey),
          ).toList(),
        ),
        onTap: () => setState(() => _selectedNode = otherNode),
      ),
    );
  }

  String _truncateNpub(String npub) {
    if (npub.isEmpty) return 'N/A';
    if (npub.length > 20) {
      return '${npub.substring(0, 10)}...${npub.substring(npub.length - 8)}';
    }
    return npub;
  }

  Color _getStatusColor(NodeStatus status) {
    switch (status) {
      case NodeStatus.online:
        return Colors.green;
      case NodeStatus.offline:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String _getStatusText(NodeStatus status) {
    switch (status) {
      case NodeStatus.online:
        return 'Online';
      case NodeStatus.offline:
        return 'Offline';
      default:
        return 'Unknown';
    }
  }

  Color _getQualityColor(String quality) {
    switch (quality) {
      case 'excellent':
        return Colors.green;
      case 'good':
        return Colors.lightGreen;
      case 'fair':
        return Colors.orange;
      case 'poor':
        return Colors.red;
      case 'disconnected':
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  IconData _getChannelIcon(String channel) {
    switch (channel) {
      case 'internet':
        return Icons.public;
      case 'wifi_lan':
        return Icons.wifi;
      case 'wifi_halow':
        return Icons.wifi;
      case 'bluetooth':
        return Icons.bluetooth;
      case 'lora':
        return Icons.settings_input_antenna;
      case 'radio':
        return Icons.radio;
      case 'espmesh':
        return Icons.hub;
      case 'espnow':
        return Icons.device_hub;
      default:
        return Icons.device_hub;
    }
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// Custom painter for the network topology graph
class _TopologyPainter extends CustomPainter {
  final Map<String, TopologyNode> nodes;
  final List<TopologyConnection> connections;
  final String? selectedNode;

  _TopologyPainter({
    required this.nodes,
    required this.connections,
    this.selectedNode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final positions = _calculatePositions(size);

    // Draw connections first
    for (final conn in connections) {
      final from = positions[conn.from];
      final to = positions[conn.to];
      if (from == null || to == null) continue;

      final paint = Paint()
        ..color = _getQualityColor(conn.quality)
        ..strokeWidth = conn.quality == 'excellent' ? 3 : 2
        ..style = PaintingStyle.stroke;

      canvas.drawLine(from, to, paint);
    }

    // Draw nodes
    for (final entry in positions.entries) {
      final node = nodes[entry.key];
      if (node == null) continue;

      final pos = entry.value;
      final isSelected = entry.key == selectedNode;
      final isRoot = node.type == 'root';

      // Node circle
      final circlePaint = Paint()
        ..color = _getStatusColor(node.status)
        ..style = PaintingStyle.fill;

      final radius = isRoot ? 25.0 : 20.0;
      canvas.drawCircle(pos, radius, circlePaint);

      // Selection ring
      if (isSelected) {
        final ringPaint = Paint()
          ..color = Colors.blue
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(pos, radius + 5, ringPaint);
      }

      // Node label
      final textPainter = TextPainter(
        text: TextSpan(
          text: entry.key,
          style: TextStyle(
            color: Colors.black87,
            fontSize: 11,
            fontWeight: isRoot ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(pos.dx - textPainter.width / 2, pos.dy + radius + 5),
      );
    }
  }

  Map<String, Offset> _calculatePositions(Size size) {
    final positions = <String, Offset>{};
    final nodeList = nodes.keys.toList();
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final radius = math.min(size.width, size.height) / 3;

    // Find root node
    final rootIndex = nodeList.indexWhere((k) => nodes[k]?.type == 'root');

    if (rootIndex >= 0) {
      positions[nodeList[rootIndex]] = Offset(centerX, centerY);

      final others = nodeList.where((k) => nodes[k]?.type != 'root').toList();
      for (var i = 0; i < others.length; i++) {
        final angle = (2 * math.pi * i) / others.length - math.pi / 2;
        positions[others[i]] = Offset(
          centerX + radius * math.cos(angle),
          centerY + radius * math.sin(angle),
        );
      }
    } else {
      for (var i = 0; i < nodeList.length; i++) {
        final angle = (2 * math.pi * i) / nodeList.length - math.pi / 2;
        positions[nodeList[i]] = Offset(
          centerX + radius * math.cos(angle),
          centerY + radius * math.sin(angle),
        );
      }
    }

    return positions;
  }

  Color _getStatusColor(NodeStatus status) {
    switch (status) {
      case NodeStatus.online:
        return Colors.green;
      case NodeStatus.offline:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  Color _getQualityColor(String quality) {
    switch (quality) {
      case 'excellent':
        return Colors.green;
      case 'good':
        return Colors.lightGreen;
      case 'fair':
        return Colors.orange;
      case 'poor':
        return Colors.red;
      default:
        return Colors.grey[400]!;
    }
  }

  @override
  bool shouldRepaint(covariant _TopologyPainter oldDelegate) {
    return oldDelegate.selectedNode != selectedNode ||
        oldDelegate.nodes != nodes ||
        oldDelegate.connections != connections;
  }
}
