/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/postcard.dart';
import '../services/i18n_service.dart';

/// Widget for displaying full postcard details
class PostcardDetailWidget extends StatelessWidget {
  final Postcard postcard;
  final String collectionPath;
  final String? currentCallsign;
  final String? currentUserNpub;
  final bool isSender;
  final bool isRecipient;
  final VoidCallback onRefresh;

  const PostcardDetailWidget({
    Key? key,
    required this.postcard,
    required this.collectionPath,
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
        // Scrollable content
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title
                Text(
                  postcard.title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                // Metadata row
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _buildMetadataChip(
                      icon: Icons.calendar_today,
                      label: postcard.displayDate,
                      theme: theme,
                    ),
                    _buildMetadataChip(
                      icon: postcard.isEncrypted ? Icons.lock : Icons.lock_open,
                      label: i18n.t(postcard.type),
                      theme: theme,
                    ),
                    _buildMetadataChip(
                      icon: Icons.priority_high,
                      label: i18n.t(postcard.priority),
                      theme: theme,
                    ),
                    if (postcard.ttl != null)
                      _buildMetadataChip(
                        icon: Icons.hourglass_bottom,
                        label: '${postcard.ttl} ${i18n.t('days')}',
                        theme: theme,
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                // Sender and Recipient
                _buildSection(
                  title: i18n.t('participants'),
                  theme: theme,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildParticipant(
                        icon: Icons.send,
                        label: i18n.t('sender'),
                        callsign: postcard.senderCallsign,
                        npub: postcard.senderNpub,
                        theme: theme,
                      ),
                      const SizedBox(height: 12),
                      _buildParticipant(
                        icon: Icons.person_outline,
                        label: i18n.t('recipient'),
                        callsign: postcard.recipientCallsign,
                        npub: postcard.recipientNpub,
                        theme: theme,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                // Message content
                _buildSection(
                  title: i18n.t('message'),
                  theme: theme,
                  child: postcard.isEncrypted
                      ? _buildEncryptedContent(theme, i18n)
                      : _buildPlainContent(theme),
                ),
                const SizedBox(height: 24),
                // Forward journey stamps
                if (postcard.stamps.isNotEmpty) ...[
                  _buildSection(
                    title: '${i18n.t('forward_journey')} (${postcard.stamps.length} ${i18n.t('hops')})',
                    theme: theme,
                    child: _buildStampsList(postcard.stamps, theme, i18n),
                  ),
                  const SizedBox(height: 24),
                ],
                // Delivery receipt
                if (postcard.deliveryReceipt != null) ...[
                  _buildSection(
                    title: i18n.t('delivery_receipt'),
                    theme: theme,
                    child: _buildDeliveryReceipt(postcard.deliveryReceipt!, theme, i18n),
                  ),
                  const SizedBox(height: 24),
                ],
                // Return journey stamps
                if (postcard.returnStamps.isNotEmpty) ...[
                  _buildSection(
                    title: '${i18n.t('return_journey')} (${postcard.returnStamps.length} ${i18n.t('hops')})',
                    theme: theme,
                    child: _buildStampsList(postcard.returnStamps, theme, i18n),
                  ),
                  const SizedBox(height: 24),
                ],
                // Acknowledgment
                if (postcard.acknowledgment != null) ...[
                  _buildSection(
                    title: i18n.t('sender_acknowledgment'),
                    theme: theme,
                    child: _buildAcknowledgment(postcard.acknowledgment!, theme, i18n),
                  ),
                  const SizedBox(height: 24),
                ],
                // Recipient locations
                if (postcard.recipientLocations.isNotEmpty) ...[
                  _buildSection(
                    title: i18n.t('recipient_locations'),
                    theme: theme,
                    child: _buildRecipientLocations(theme, i18n),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
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
                  callsign ?? npub.substring(0, 16) + '...',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (callsign != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    npub.substring(0, 20) + '...',
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
}
