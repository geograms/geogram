/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Image widget that fetches bytes from a remote device through the
 * generic /api/content/{appType}/{itemId}/files/{path} endpoint.
 * Routed through DevicesService.makeDeviceApiRequest so every
 * transport ConnectionManager supports (LAN / USB / BLE / WebRTC /
 * Peer Relay / Station / DHT) works the same way — NetworkImage
 * would only work for callsigns with a direct HTTP URL.
 */

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/devices_service.dart';
import '../services/remote_content_client.dart';

class RemoteContentImage extends StatefulWidget {
  final String remoteCallsign;
  final String appType;
  final String itemId;
  final String relativePath;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final Widget Function(BuildContext, Object error)? errorBuilder;

  /// When true (default) the widget asks the remote device for a
  /// ~480 px preview instead of the full-res original. Gallery
  /// grids / list tiles should keep this on; a lightbox that wants
  /// the full image should set it false.
  final bool thumbnail;

  const RemoteContentImage({
    super.key,
    required this.remoteCallsign,
    required this.appType,
    required this.itemId,
    required this.relativePath,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.errorBuilder,
    this.thumbnail = true,
  });

  @override
  State<RemoteContentImage> createState() => _RemoteContentImageState();
}

class _RemoteContentImageState extends State<RemoteContentImage> {
  Future<Uint8List?>? _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  @override
  void didUpdateWidget(covariant RemoteContentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.remoteCallsign != widget.remoteCallsign ||
        oldWidget.appType != widget.appType ||
        oldWidget.itemId != widget.itemId ||
        oldWidget.relativePath != widget.relativePath ||
        oldWidget.thumbnail != widget.thumbnail) {
      _future = _fetch();
    }
  }

  Future<Uint8List?> _fetch() async {
    try {
      var path = RemoteContent.filePath(
        appType: widget.appType,
        itemId: widget.itemId,
        relativePath: widget.relativePath,
      );
      if (widget.thumbnail) {
        path = '$path?thumb=1';
      }
      final resp = await DevicesService().makeDeviceApiRequestBytes(
        callsign: widget.remoteCallsign,
        method: 'GET',
        path: path,
      );
      if (resp == null || resp.statusCode != 200) return null;
      return resp.bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        Widget child;
        if (snapshot.connectionState != ConnectionState.done) {
          child = SizedBox(
            width: widget.width,
            height: widget.height,
            child: const Center(
                child: CircularProgressIndicator(strokeWidth: 2)),
          );
        } else if (snapshot.hasError || snapshot.data == null) {
          child = widget.errorBuilder != null
              ? widget.errorBuilder!(
                  context, snapshot.error ?? 'Image unavailable')
              : _defaultError(context);
        } else {
          child = Image.memory(
            snapshot.data!,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            errorBuilder: (ctx, err, stack) =>
                widget.errorBuilder != null
                    ? widget.errorBuilder!(ctx, err)
                    : _defaultError(ctx),
          );
        }
        return widget.borderRadius != null
            ? ClipRRect(borderRadius: widget.borderRadius!, child: child)
            : child;
      },
    );
  }

  Widget _defaultError(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: widget.width,
      height: widget.height,
      color: theme.colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
