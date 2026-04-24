/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/postcard.dart';
import '../services/i18n_service.dart';
import 'contact_picker_page.dart';
import 'location_picker_page.dart';
import 'place_picker_page.dart';

/// Full-screen page for composing a new postcard.
///
/// Replaces the old NewPostcardDialog. On save it pops with the same
/// Map<String, dynamic> shape the browser page expects, so the caller
/// stays unchanged aside from using Navigator.push instead of showDialog.
class NewPostcardPage extends StatefulWidget {
  const NewPostcardPage({super.key});

  @override
  State<NewPostcardPage> createState() => _NewPostcardPageState();
}

class _NewPostcardPageState extends State<NewPostcardPage> {
  final _formKey = GlobalKey<FormState>();
  final _i18n = I18nService();
  final _titleController = TextEditingController();
  final _recipientNpubController = TextEditingController();
  final _recipientCallsignController = TextEditingController();
  final _contentController = TextEditingController();
  final _ttlController = TextEditingController();

  String _messageType = 'open';
  String _priority = 'normal';
  bool _paymentRequested = false;
  final List<RecipientLocation> _recipientLocations = [];

  @override
  void dispose() {
    _titleController.dispose();
    _recipientNpubController.dispose();
    _recipientCallsignController.dispose();
    _contentController.dispose();
    _ttlController.dispose();
    super.dispose();
  }

  Future<void> _pickContact() async {
    final result = await Navigator.push<ContactPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => ContactPickerPage(i18n: _i18n),
      ),
    );
    if (result == null || !mounted) return;
    final contact = result.contact;
    setState(() {
      _recipientCallsignController.text = contact.callsign;
      _recipientNpubController.text = contact.npub ?? '';
    });
  }

  Future<void> _addLocationFromMap() async {
    final picked = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (_) => const LocationPickerPage(),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _recipientLocations.add(RecipientLocation(
        latitude: picked.latitude,
        longitude: picked.longitude,
      ));
    });
  }

  Future<void> _addLocationFromCity() async {
    final result = await Navigator.push<PlacePickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => PlacePickerPage(i18n: _i18n),
      ),
    );
    if (result == null || !mounted) return;
    final place = result.place;
    setState(() {
      _recipientLocations.add(RecipientLocation(
        latitude: place.latitude,
        longitude: place.longitude,
        locationName: place.getName('EN'),
      ));
    });
  }

  Future<void> _addLocationManually() async {
    final added = await showDialog<RecipientLocation>(
      context: context,
      builder: (_) => const _ManualLocationDialog(),
    );
    if (added == null || !mounted) return;
    setState(() {
      _recipientLocations.add(added);
    });
  }

  void _removeRecipientLocation(int index) {
    setState(() {
      _recipientLocations.removeAt(index);
    });
  }

  void _create() {
    if (!_formKey.currentState!.validate()) return;

    final callsign = _recipientCallsignController.text.trim();
    final npub = _recipientNpubController.text.trim();
    if (callsign.isEmpty && npub.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('recipient_required')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_recipientLocations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('add_at_least_one_location')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final ttlText = _ttlController.text.trim();

    Navigator.pop(context, {
      'title': _titleController.text.trim(),
      'recipientNpub': npub,
      'recipientCallsign': callsign.isNotEmpty ? callsign : null,
      'recipientLocations': _recipientLocations,
      'type': _messageType,
      'content': _contentController.text.trim(),
      'ttl': ttlText.isNotEmpty ? int.tryParse(ttlText) : null,
      'priority': _priority,
      'paymentRequested': _paymentRequested,
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('new_postcard')),
        actions: [
          TextButton(
            onPressed: _create,
            child: Text(
              _i18n.t('create_postcard'),
              style: TextStyle(color: theme.colorScheme.onPrimary),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Title
            TextFormField(
              controller: _titleController,
              decoration: InputDecoration(
                labelText: _i18n.t('postcard_title'),
                hintText: _i18n.t('enter_postcard_title'),
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return _i18n.t('title_is_required');
                }
                if (value.trim().length < 3) {
                  return _i18n.t('title_min_3_chars');
                }
                return null;
              },
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 24),

            // Recipient section
            Text(
              _i18n.t('recipient'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _i18n.t('recipient_hint'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickContact,
              icon: const Icon(Icons.contacts, size: 18),
              label: Text(_i18n.t('pick_from_contacts')),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _recipientCallsignController,
              decoration: InputDecoration(
                labelText: _i18n.t('recipient_callsign'),
                hintText: _i18n.t('enter_callsign'),
                border: const OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _recipientNpubController,
              decoration: InputDecoration(
                labelText: _i18n.t('recipient_npub_optional'),
                hintText: 'npub1...',
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                final trimmed = value?.trim() ?? '';
                if (trimmed.isEmpty) return null; // npub is optional now
                if (!trimmed.startsWith('npub1')) {
                  return _i18n.t('invalid_npub_format');
                }
                return null;
              },
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 24),

            // Recipient Locations
            Text(
              _i18n.t('choose_possible_locations'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _i18n.t('recipient_locations_hint'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (_recipientLocations.isEmpty)
              Text(
                _i18n.t('no_locations_added'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              ..._recipientLocations.asMap().entries.map((entry) {
                final index = entry.key;
                final location = entry.value;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.place, size: 20),
                      const SizedBox(width: 8),
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
                              '${location.latitude.toStringAsFixed(5)}, '
                              '${location.longitude.toStringAsFixed(5)}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, size: 18),
                        onPressed: () => _removeRecipientLocation(index),
                      ),
                    ],
                  ),
                );
              }),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _addLocationFromMap,
                  icon: const Icon(Icons.map, size: 18),
                  label: Text(_i18n.t('pick_on_map')),
                ),
                OutlinedButton.icon(
                  onPressed: _addLocationFromCity,
                  icon: const Icon(Icons.location_city, size: 18),
                  label: Text(_i18n.t('pick_a_city')),
                ),
                OutlinedButton.icon(
                  onPressed: _addLocationManually,
                  icon: const Icon(Icons.edit_location_alt, size: 18),
                  label: Text(_i18n.t('enter_coordinates')),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Message type
            Text(
              _i18n.t('message_type'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: 'open',
                  label: Text(_i18n.t('open')),
                  icon: const Icon(Icons.lock_open, size: 18),
                ),
                ButtonSegment(
                  value: 'encrypted',
                  label: Text(_i18n.t('encrypted')),
                  icon: const Icon(Icons.lock, size: 18),
                ),
              ],
              selected: {_messageType},
              onSelectionChanged: (Set<String> selection) {
                setState(() {
                  _messageType = selection.first;
                });
              },
            ),
            const SizedBox(height: 16),

            // Content
            TextFormField(
              controller: _contentController,
              decoration: InputDecoration(
                labelText: _i18n.t('message_content'),
                hintText: _i18n.t('enter_message'),
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: 6,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return _i18n.t('message_is_required');
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Priority
            DropdownButtonFormField<String>(
              value: _priority,
              decoration: InputDecoration(
                labelText: _i18n.t('priority'),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                  value: 'normal',
                  child: Text(_i18n.t('normal')),
                ),
                DropdownMenuItem(
                  value: 'high',
                  child: Text(_i18n.t('high')),
                ),
                DropdownMenuItem(
                  value: 'urgent',
                  child: Text(_i18n.t('urgent')),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _priority = value;
                  });
                }
              },
            ),
            const SizedBox(height: 16),

            // TTL (optional)
            TextFormField(
              controller: _ttlController,
              decoration: InputDecoration(
                labelText: _i18n.t('ttl_days_optional'),
                hintText: '30',
                border: const OutlineInputBorder(),
                suffixText: _i18n.t('days'),
              ),
              keyboardType: TextInputType.number,
              validator: (value) {
                if (value != null && value.trim().isNotEmpty) {
                  final ttl = int.tryParse(value.trim());
                  if (ttl == null || ttl <= 0) {
                    return _i18n.t('invalid_ttl');
                  }
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Payment requested
            SwitchListTile(
              title: Text(_i18n.t('payment_requested')),
              subtitle: Text(_i18n.t('request_payment_for_delivery')),
              value: _paymentRequested,
              onChanged: (value) {
                setState(() {
                  _paymentRequested = value;
                });
              },
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

/// Fallback dialog for hand-entering lat/lon + optional name. Kept for the
/// rare case where the user has exact coordinates (e.g. copied from a
/// device/GPS log) and neither the map nor the city picker is appropriate.
class _ManualLocationDialog extends StatefulWidget {
  const _ManualLocationDialog();

  @override
  State<_ManualLocationDialog> createState() => _ManualLocationDialogState();
}

class _ManualLocationDialogState extends State<_ManualLocationDialog> {
  final _formKey = GlobalKey<FormState>();
  final _i18n = I18nService();
  final _latitudeController = TextEditingController();
  final _longitudeController = TextEditingController();
  final _locationNameController = TextEditingController();

  @override
  void dispose() {
    _latitudeController.dispose();
    _longitudeController.dispose();
    _locationNameController.dispose();
    super.dispose();
  }

  void _add() {
    if (!_formKey.currentState!.validate()) return;
    final name = _locationNameController.text.trim();
    Navigator.pop(
      context,
      RecipientLocation(
        latitude: double.parse(_latitudeController.text.trim()),
        longitude: double.parse(_longitudeController.text.trim()),
        locationName: name.isNotEmpty ? name : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_i18n.t('enter_coordinates')),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _latitudeController,
              decoration: InputDecoration(
                labelText: _i18n.t('latitude'),
                hintText: '38.7223',
                border: const OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return _i18n.t('latitude_is_required');
                }
                final lat = double.tryParse(value.trim());
                if (lat == null || lat < -90 || lat > 90) {
                  return _i18n.t('invalid_latitude');
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _longitudeController,
              decoration: InputDecoration(
                labelText: _i18n.t('longitude'),
                hintText: '-9.1393',
                border: const OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return _i18n.t('longitude_is_required');
                }
                final lon = double.tryParse(value.trim());
                if (lon == null || lon < -180 || lon > 180) {
                  return _i18n.t('invalid_longitude');
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _locationNameController,
              decoration: InputDecoration(
                labelText: _i18n.t('location_name_optional'),
                hintText: _i18n.t('eg_cafe_name'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_i18n.t('cancel')),
        ),
        FilledButton(
          onPressed: _add,
          child: Text(_i18n.t('add')),
        ),
      ],
    );
  }
}
