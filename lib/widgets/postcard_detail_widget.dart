/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/postcard.dart';
import '../services/i18n_service.dart';
import '../services/map_tile_service.dart' show MapTileService, MapLayerType;

/// Widget for displaying full postcard details
class PostcardDetailWidget extends StatelessWidget {
  final Postcard postcard;
  final String appPath;
  final String? currentCallsign;
  final String? currentUserNpub;
  final bool isSender;
  final bool isRecipient;
  final VoidCallback onRefresh;

  const PostcardDetailWidget({
    Key? key,
    required this.postcard,
    required this.appPath,
    this.currentCallsign,
    this.currentUserNpub,
    required this.isSender,
    required this.isRecipient,
    required this.onRefresh,
  }) : super(key: key);

  Color _getStatusColor(String status) {
    switch (status) {
      case 'in-transit':
        return Colors.blue;
      case 'delivered':
        return Colors.green;
      case 'acknowledged':
        return Colors.purple;
      case 'expired':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();

    return Column(
      children: [
        // Header toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              // Status badge
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _getStatusColor(postcard.status).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _getStatusIcon(postcard.status),
                      size: 16,
                      color: _getStatusColor(postcard.status),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      i18n.t(postcard.status.replaceAll('-', '_')),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: _getStatusColor(postcard.status),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              // Action buttons
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: onRefresh,
                tooltip: i18n.t('refresh'),
              ),
              if (!isSender && postcard.status == 'in-transit')
                IconButton(
                  icon: const Icon(Icons.add_location),
                  onPressed: () {
                    _showAddStampDialog(context);
                  },
                  tooltip: i18n.t('add_stamp'),
                ),
              if (!isSender && postcard.status == 'in-transit' && isRecipient)
                IconButton(
                  icon: const Icon(Icons.done),
                  onPressed: () {
                    _showDeliverDialog(context);
                  },
                  tooltip: i18n.t('deliver_postcard'),
                ),
            ],
          ),
        ),
        // Scrollable content — title and message are the focus.
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Title ─────────────────────────────────────────
                Text(
                  postcard.title,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 6),
                // Subdued one-line metadata: date · encryption · priority · ttl
                _buildMetaLine(theme, i18n),
                const SizedBox(height: 20),

                // ── Message body ──────────────────────────────────
                _buildLetterBody(theme, i18n),
                const SizedBox(height: 20),

                // ── From / To compact lines ───────────────────────
                _buildParticipantsCompact(theme, i18n),
                const SizedBox(height: 24),

                // ── Path story (timeline of where it has been) ────
                if (postcard.stamps.isNotEmpty ||
                    postcard.deliveryReceipt != null ||
                    postcard.returnStamps.isNotEmpty)
                  _buildPathStorySection(theme, i18n),

                // ── Possible destinations (mini map) ──────────────
                if (postcard.recipientLocations.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _buildPossibleDestinationsSection(theme, i18n),
                ],

                // ── Raw stamp / receipt / ack details (collapsed) ─
                if (postcard.stamps.isNotEmpty ||
                    postcard.deliveryReceipt != null ||
                    postcard.returnStamps.isNotEmpty ||
                    postcard.acknowledgment != null) ...[
                  const SizedBox(height: 24),
                  _buildRawDetailsSection(theme, i18n),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// One-line metadata under the title: date · type · priority · ttl.
  Widget _buildMetaLine(ThemeData theme, I18nService i18n) {
    final muted = theme.colorScheme.onSurfaceVariant;
    final parts = <String>[
      postcard.displayDate,
      i18n.t(postcard.type),
      i18n.t(postcard.priority),
      if (postcard.ttl != null) '${postcard.ttl} ${i18n.t('days')}',
    ];
    return Text(
      parts.join(' · '),
      style: theme.textTheme.bodySmall?.copyWith(color: muted),
    );
  }

  /// Letter-style message body — the visual focus of the screen.
  Widget _buildLetterBody(ThemeData theme, I18nService i18n) {
    final accent = _getStatusColor(postcard.status);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: accent, width: 4)),
      ),
      child: postcard.isEncrypted
          ? _buildEncryptedContent(theme, i18n)
          : SelectableText(
              postcard.content,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 16,
                height: 1.55,
                fontFamily: 'serif',
              ),
            ),
    );
  }

  /// Compact From / To rows. Single line each, callsign in normal weight,
  /// shortened npub trailing in a muted monospace tail.
  Widget _buildParticipantsCompact(ThemeData theme, I18nService i18n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildParticipantRow(
          theme: theme,
          label: i18n.t('from'),
          callsign: postcard.senderCallsign,
          npub: postcard.senderNpub,
        ),
        const SizedBox(height: 4),
        _buildParticipantRow(
          theme: theme,
          label: i18n.t('to'),
          callsign: postcard.recipientCallsign,
          npub: postcard.recipientNpub,
        ),
      ],
    );
  }

  Widget _buildParticipantRow({
    required ThemeData theme,
    required String label,
    String? callsign,
    required String npub,
  }) {
    final muted = theme.colorScheme.onSurfaceVariant;
    final shortNpub = _npubPreview(npub, 14);
    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: muted),
          ),
        ),
        Text(
          callsign ?? shortNpub,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (callsign != null && npub.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              shortNpub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: muted,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
        IconButton(
          icon: const Icon(Icons.copy, size: 14),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: npub));
          },
          tooltip: i18n_t_safe('copy_npub'),
        ),
      ],
    );
  }

  // Tiny helper so we don't blow up if a future i18n key is missing.
  String i18n_t_safe(String key) => I18nService().t(key);

  // ── Path story (where the postcard has been) ────────────────────

  Widget _buildPathStorySection(ThemeData theme, I18nService i18n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          i18n.t('path_story'),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        _buildPathTimeline(theme, i18n),
      ],
    );
  }

  /// Render the journey as a vertical timeline:
  ///   ● Sender
  ///   │ via BLE
  ///   ● BRAVO2 — Lisbon Cafe · 14:30
  ///   │ via Satellite
  ///   ● ALPHA1 — NYC Penn · 10:15
  ///   ● Delivered to recipient — NYC · 18:45
  Widget _buildPathTimeline(ThemeData theme, I18nService i18n) {
    final entries = <_TimelineEntry>[];

    // Sender — origin of the chain.
    entries.add(_TimelineEntry(
      icon: Icons.send,
      title: postcard.senderCallsign,
      subtitle: i18n.t('sender'),
      color: _getStatusColor(postcard.status),
      isOrigin: true,
    ));

    // Outbound stamps.
    for (final stamp in postcard.stamps) {
      entries.add(_TimelineEntry(
        icon: Icons.location_on,
        title: stamp.stamperCallsign,
        subtitle: _stampSubtitle(stamp),
        color: Colors.blue.shade600,
        viaLabel: stamp.receivedVia,
      ));
    }

    // Delivery receipt.
    if (postcard.deliveryReceipt != null) {
      final r = postcard.deliveryReceipt!;
      entries.add(_TimelineEntry(
        icon: Icons.mark_email_read_outlined,
        title: postcard.recipientCallsign ??
            i18n.t('recipient'),
        subtitle:
            '${i18n.t('delivered_at')} ${r.displayTimestamp}'
            '${r.deliveryLocationName != null ? ' · ${r.deliveryLocationName}' : ''}',
        color: Colors.green.shade700,
      ));
    }

    // Return-leg stamps.
    for (final stamp in postcard.returnStamps) {
      entries.add(_TimelineEntry(
        icon: Icons.keyboard_return,
        title: stamp.stamperCallsign,
        subtitle: '${i18n.t('return')} · ${_stampSubtitle(stamp)}',
        color: Colors.purple.shade400,
        viaLabel: stamp.receivedVia,
      ));
    }

    // Sender acknowledgment.
    if (postcard.acknowledgment != null) {
      entries.add(_TimelineEntry(
        icon: Icons.done_all,
        title: postcard.senderCallsign,
        subtitle:
            '${i18n.t('acknowledged')} · ${postcard.acknowledgment!.displayTimestamp}',
        color: Colors.purple.shade700,
      ));
    }

    return Column(
      children: [
        for (var i = 0; i < entries.length; i++)
          _buildTimelineRow(
            theme,
            entries[i],
            isLast: i == entries.length - 1,
          ),
      ],
    );
  }

  String _stampSubtitle(PostcardStamp stamp) {
    final coords =
        '${stamp.latitude.toStringAsFixed(2)}, ${stamp.longitude.toStringAsFixed(2)}';
    final loc = stamp.locationName ?? coords;
    return '$loc · ${stamp.displayTimestamp}';
  }

  Widget _buildTimelineRow(
    ThemeData theme,
    _TimelineEntry entry, {
    required bool isLast,
  }) {
    final muted = theme.colorScheme.onSurfaceVariant;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Dot + connector column.
          SizedBox(
            width: 28,
            child: Column(
              children: [
                const SizedBox(height: 4),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: entry.color,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black12,
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Icon(entry.icon, size: 12, color: Colors.white),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (entry.subtitle.isNotEmpty)
                    Text(
                      entry.subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  if (entry.viaLabel != null && entry.viaLabel!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${I18nService().t('via')} ${entry.viaLabel}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Possible destinations (mini map) ────────────────────────────

  Widget _buildPossibleDestinationsSection(ThemeData theme, I18nService i18n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          i18n.t('possible_destinations'),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          i18n.t('possible_destinations_hint'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 200,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _DestinationsMap(
              locations: postcard.recipientLocations
                  .map((l) => LatLng(l.latitude, l.longitude))
                  .toList(),
              accent: _getStatusColor(postcard.status),
            ),
          ),
        ),
      ],
    );
  }

  // ── Raw details (collapsed by default) ──────────────────────────

  Widget _buildRawDetailsSection(ThemeData theme, I18nService i18n) {
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 8),
        leading: const Icon(Icons.unfold_more),
        title: Text(i18n.t('show_full_journey_details')),
        children: [
          if (postcard.stamps.isNotEmpty)
            _buildSection(
              title: '${i18n.t('forward_journey')} (${postcard.stamps.length} ${i18n.t('hops')})',
              theme: theme,
              child: _buildStampsList(postcard.stamps, theme, i18n),
            ),
          if (postcard.deliveryReceipt != null) ...[
            const SizedBox(height: 12),
            _buildSection(
              title: i18n.t('delivery_receipt'),
              theme: theme,
              child:
                  _buildDeliveryReceipt(postcard.deliveryReceipt!, theme, i18n),
            ),
          ],
          if (postcard.returnStamps.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildSection(
              title: '${i18n.t('return_journey')} (${postcard.returnStamps.length} ${i18n.t('hops')})',
              theme: theme,
              child: _buildStampsList(postcard.returnStamps, theme, i18n),
            ),
          ],
          if (postcard.acknowledgment != null) ...[
            const SizedBox(height: 12),
            _buildSection(
              title: i18n.t('sender_acknowledgment'),
              theme: theme,
              child: _buildAcknowledgment(postcard.acknowledgment!, theme, i18n),
            ),
          ],
        ],
      ),
    );
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'in-transit':
        return Icons.local_shipping_outlined;
      case 'delivered':
        return Icons.done;
      case 'acknowledged':
        return Icons.done_all;
      case 'expired':
        return Icons.error_outline;
      default:
        return Icons.mail_outline;
    }
  }

  Widget _buildMetadataChip({
    required IconData icon,
    required String label,
    required ThemeData theme,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required ThemeData theme,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  Widget _buildParticipant({
    required IconData icon,
    required String label,
    String? callsign,
    required String npub,
    required ThemeData theme,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  callsign ?? _npubPreview(npub, 16),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (callsign != null && npub.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    _npubPreview(npub, 20),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: npub));
            },
            tooltip: 'Copy npub',
          ),
        ],
      ),
    );
  }

  Widget _buildPlainContent(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
      ),
      child: Text(
        postcard.content,
        style: theme.textTheme.bodyMedium,
      ),
    );
  }

  Widget _buildEncryptedContent(ThemeData theme, I18nService i18n) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.error.withOpacity(0.3),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.lock, color: theme.colorScheme.error),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  i18n.t('encrypted_message'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            postcard.content,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStampsList(List<PostcardStamp> stamps, ThemeData theme, I18nService i18n) {
    return Column(
      children: stamps.map((stamp) => _buildStampCard(stamp, theme, i18n)).toList(),
    );
  }

  Widget _buildStampCard(PostcardStamp stamp, ThemeData theme, I18nService i18n) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${i18n.t('hop')} #${stamp.number}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Spacer(),
              Icon(Icons.verified, size: 16, color: Colors.green),
              const SizedBox(width: 4),
              Text(
                i18n.t('verified'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.green,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildStampDetail(Icons.person, i18n.t('carrier'), stamp.stamperCallsign, theme),
          const SizedBox(height: 8),
          _buildStampDetail(Icons.schedule, i18n.t('timestamp'), stamp.displayTimestamp, theme),
          const SizedBox(height: 8),
          _buildStampDetail(Icons.place, i18n.t('location'),
            stamp.locationName ?? '${stamp.latitude}, ${stamp.longitude}', theme),
          const SizedBox(height: 8),
          _buildStampDetail(Icons.swap_horiz, i18n.t('received_from'), stamp.receivedFrom, theme),
          const SizedBox(height: 8),
          _buildStampDetail(Icons.wifi, i18n.t('received_via'), stamp.receivedVia, theme),
        ],
      ),
    );
  }

  Widget _buildStampDetail(IconData icon, String label, String value, ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _buildDeliveryReceipt(PostcardDeliveryReceipt receipt, ThemeData theme, I18nService i18n) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.green.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.done_all, color: Colors.green),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  i18n.t('delivered_successfully'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildStampDetail(Icons.person, i18n.t('delivered_by'), receipt.carrierCallsign, theme),
          const SizedBox(height: 8),
          _buildStampDetail(Icons.schedule, i18n.t('delivered_at'), receipt.displayTimestamp, theme),
          const SizedBox(height: 8),
          _buildStampDetail(Icons.place, i18n.t('delivery_location'),
            receipt.deliveryLocationName ?? '${receipt.deliveryLatitude}, ${receipt.deliveryLongitude}', theme),
          if (receipt.deliveryNote != null) ...[
            const SizedBox(height: 8),
            _buildStampDetail(Icons.note, i18n.t('note'), receipt.deliveryNote!, theme),
          ],
        ],
      ),
    );
  }

  Widget _buildAcknowledgment(PostcardAcknowledgment ack, ThemeData theme, I18nService i18n) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.purple.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.purple.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle, color: Colors.purple),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  i18n.t('acknowledged_by_sender'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.purple,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildStampDetail(Icons.schedule, i18n.t('received_at'), ack.displayTimestamp, theme),
          if (ack.acknowledgmentNote != null) ...[
            const SizedBox(height: 8),
            _buildStampDetail(Icons.note, i18n.t('note'), ack.acknowledgmentNote!, theme),
          ],
        ],
      ),
    );
  }

  Widget _buildRecipientLocations(ThemeData theme, I18nService i18n) {
    return Column(
      children: postcard.recipientLocations.map((location) {
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.place, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (location.locationName != null)
                      Text(
                        location.locationName!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    Text(
                      '${location.latitude}, ${location.longitude}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  void _showAddStampDialog(BuildContext context) {
    // TODO: Implement add stamp dialog
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Add stamp dialog - TODO')),
    );
  }

  void _showDeliverDialog(BuildContext context) {
    // TODO: Implement deliver postcard dialog
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Deliver postcard dialog - TODO')),
    );
  }

  /// Truncate an npub for display without blowing up when it's shorter
  /// than the requested length — or empty, which happens for postcards
  /// created with only a callsign.
  String _npubPreview(String npub, int max) {
    if (npub.isEmpty) return '—';
    if (npub.length <= max) return npub;
    return '${npub.substring(0, max)}…';
  }
}

/// One vertical step in the path-story timeline.
class _TimelineEntry {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final String? viaLabel;
  final bool isOrigin;

  const _TimelineEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    this.viaLabel,
    this.isOrigin = false,
  });
}

/// Small embedded map showing every recipient location for a postcard
/// — the "possible destinations" the message might end up reaching.
/// Auto-fits to show all markers; falls back to centering on the first
/// when only one location is present.
class _DestinationsMap extends StatefulWidget {
  final List<LatLng> locations;
  final Color accent;

  const _DestinationsMap({required this.locations, required this.accent});

  @override
  State<_DestinationsMap> createState() => _DestinationsMapState();
}

class _DestinationsMapState extends State<_DestinationsMap> {
  final MapController _controller = MapController();
  final MapTileService _tiles = MapTileService();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _tiles.initialize().then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  LatLng _center() {
    if (widget.locations.isEmpty) return const LatLng(0, 0);
    var lat = 0.0, lng = 0.0;
    for (final p in widget.locations) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / widget.locations.length, lng / widget.locations.length);
  }

  double _initialZoom() {
    if (widget.locations.length <= 1) return 6.0;
    // Rough span → zoom heuristic; FlutterMap fitCamera not used to keep
    // this widget lightweight.
    var minLat = double.infinity, maxLat = -double.infinity;
    var minLng = double.infinity, maxLng = -double.infinity;
    for (final p in widget.locations) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final span = (maxLat - minLat).abs() + (maxLng - minLng).abs();
    if (span > 80) return 1;
    if (span > 30) return 2;
    if (span > 10) return 3;
    if (span > 3) return 5;
    if (span > 0.5) return 8;
    return 10;
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(child: CircularProgressIndicator());
    }
    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: _center(),
        initialZoom: _initialZoom(),
        minZoom: 1,
        maxZoom: 18,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        ValueListenableBuilder<MapLayerType>(
          valueListenable: _tiles.layerTypeNotifier,
          builder: (context, layerType, _) {
            return TileLayer(
              urlTemplate: _tiles.getTileUrl(layerType),
              userAgentPackageName: 'dev.geogram',
              subdomains: const [],
              keepBuffer: 2,
              tileBuilder: (_, w, __) => w,
              evictErrorTileStrategy:
                  EvictErrorTileStrategy.notVisibleRespectMargin,
              tileProvider: _tiles.getTileProvider(layerType),
            );
          },
        ),
        MarkerLayer(
          markers: [
            for (final p in widget.locations)
              Marker(
                point: p,
                width: 28,
                height: 28,
                child: Container(
                  decoration: BoxDecoration(
                    color: widget.accent,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 3,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.place, size: 16, color: Colors.white),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
