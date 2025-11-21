/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/postcard.dart';
import '../services/i18n_service.dart';

/// Dialog for creating a new postcard
class NewPostcardDialog extends StatefulWidget {
  const NewPostcardDialog({Key? key}) : super(key: key);

  @override
  State<NewPostcardDialog> createState() => _NewPostcardDialogState();
}

class _NewPostcardDialogState extends State<NewPostcardDialog> {
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

  void _addRecipientLocation() {
    showDialog(
      context: context,
      builder: (context) => _RecipientLocationDialog(
        onAdd: (location) {
          setState(() {
            _recipientLocations.add(location);
          });
        },
      ),
    );
  }

  void _removeRecipientLocation(int index) {
    setState(() {
      _recipientLocations.removeAt(index);
    });
  }

  void _create() {
    if (_formKey.currentState!.validate()) {
      // Validate recipient locations
      if (_recipientLocations.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('add_at_least_one_location')),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final recipientCallsign = _recipientCallsignController.text.trim();
      final ttlText = _ttlController.text.trim();

      Navigator.pop(context, {
        'title': _titleController.text.trim(),
        'recipientNpub': _recipientNpubController.text.trim(),
        'recipientCallsign': recipientCallsign.isNotEmpty ? recipientCallsign : null,
        'recipientLocations': _recipientLocations,
        'type': _messageType,
        'content': _contentController.text.trim(),
        'ttl': ttlText.isNotEmpty ? int.tryParse(ttlText) : null,
        'priority': _priority,
        'paymentRequested': _paymentRequested,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      child: Container(
        width: 650,
        constraints: const BoxConstraints(maxHeight: 700),
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Text(
                _i18n.t('new_postcard'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              // Form fields
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Postcard title
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
                      const SizedBox(height: 16),
                      // Recipient NPUB
                      TextFormField(
                        controller: _recipientNpubController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('recipient_npub'),
                          hintText: 'npub1...',
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return _i18n.t('npub_is_required');
                          }
                          if (!value.trim().startsWith('npub1')) {
                            return _i18n.t('invalid_npub_format');
                          }
                          return null;
                        },
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 16),
                      // Recipient Callsign (optional)
                      TextFormField(
                        controller: _recipientCallsignController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('recipient_callsign_optional'),
                          hintText: _i18n.t('enter_callsign'),
                          border: const OutlineInputBorder(),
                        ),
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 16),
                      // Recipient Locations
                      Text(
                        _i18n.t('recipient_locations'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
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
                              color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.place, size: 20),
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
                                        '${location.latitude}, ${location.longitude}',
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
                        }).toList(),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _addRecipientLocation,
                        icon: const Icon(Icons.add_location, size: 18),
                        label: Text(_i18n.t('add_location')),
                      ),
                      const SizedBox(height: 16),
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
                        maxLines: 5,
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
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(_i18n.t('cancel')),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _create,
                    child: Text(_i18n.t('create_postcard')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dialog for adding a recipient location
class _RecipientLocationDialog extends StatefulWidget {
  final Function(RecipientLocation) onAdd;

  const _RecipientLocationDialog({required this.onAdd});

  @override
  State<_RecipientLocationDialog> createState() => _RecipientLocationDialogState();
}

class _RecipientLocationDialogState extends State<_RecipientLocationDialog> {
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
    if (_formKey.currentState!.validate()) {
      final latitude = double.parse(_latitudeController.text.trim());
      final longitude = double.parse(_longitudeController.text.trim());
      final locationName = _locationNameController.text.trim();

      final location = RecipientLocation(
        latitude: latitude,
        longitude: longitude,
        locationName: locationName.isNotEmpty ? locationName : null,
      );

      widget.onAdd(location);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(_i18n.t('add_location')),
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
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
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
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
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
