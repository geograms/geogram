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

/// Full-screen "new postcard" composer.
///
/// Intent: front-load the two fields the user actually thinks about (who is
/// this going to, what does it say) and push everything else out of the way.
///
/// Layout (top → bottom):
///   • AppBar  → Send action on the right
///   • To      → single row, contact picker icon + callsign field; NPUB
///               is hidden behind an expand toggle (advanced)
///   • Title   → short subject line
///   • Message → large multiline; a small lock icon in the field's top-right
///               toggles open ⇄ encrypted and surfaces a snackbar
///   • Route hints → de-emphasized list of chips + single "Add area" button
///                   that opens a bottom sheet (map / city / coordinates)
///   • More options → ExpansionTile hiding priority / TTL / payment
class NewPostcardPage extends StatefulWidget {
  const NewPostcardPage({super.key});

  @override
  State<NewPostcardPage> createState() => _NewPostcardPageState();
}

class _NewPostcardPageState extends State<NewPostcardPage> {
  final _formKey = GlobalKey<FormState>();
  final _i18n = I18nService();

  final _titleController = TextEditingController();
  final _recipientCallsignController = TextEditingController();
  final _recipientNpubController = TextEditingController();
  final _contentController = TextEditingController();
  final _ttlController = TextEditingController();

  bool _encrypted = false;
  bool _showAdvancedRecipient = false;
  String _priority = 'normal';
  bool _paymentRequested = false;
  final List<RecipientLocation> _recipientLocations = [];

  @override
  void dispose() {
    _titleController.dispose();
    _recipientCallsignController.dispose();
    _recipientNpubController.dispose();
    _contentController.dispose();
    _ttlController.dispose();
    super.dispose();
  }

  // ── Recipient ─────────────────────────────────────────────────────

  Future<void> _pickContact() async {
    final result = await Navigator.push<ContactPickerResult>(
      context,
      MaterialPageRoute(builder: (_) => ContactPickerPage(i18n: _i18n)),
    );
    if (result == null || !mounted) return;
    setState(() {
      _recipientCallsignController.text = result.contact.callsign;
      _recipientNpubController.text = result.contact.npub ?? '';
    });
  }

  // ── Encryption toggle ─────────────────────────────────────────────

  void _toggleEncryption() {
    setState(() => _encrypted = !_encrypted);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              _encrypted ? Icons.lock : Icons.lock_open,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _encrypted
                    ? _i18n.t('encrypted_postcard_toast')
                    : _i18n.t('open_postcard_toast'),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Route hints ───────────────────────────────────────────────────

  Future<void> _addAreaMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.map),
              title: Text(_i18n.t('pick_on_map')),
              onTap: () => Navigator.pop(ctx, 'map'),
            ),
            ListTile(
              leading: const Icon(Icons.location_city),
              title: Text(_i18n.t('pick_a_city')),
              onTap: () => Navigator.pop(ctx, 'city'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_location_alt),
              title: Text(_i18n.t('enter_coordinates')),
              onTap: () => Navigator.pop(ctx, 'coords'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'map':
        await _addLocationFromMap();
        break;
      case 'city':
        await _addLocationFromCity();
        break;
      case 'coords':
        await _addLocationManually();
        break;
    }
  }

  Future<void> _addLocationFromMap() async {
    final picked = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(builder: (_) => const LocationPickerPage()),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _recipientLocations.add(
        RecipientLocation(
          latitude: picked.latitude,
          longitude: picked.longitude,
        ),
      );
    });
  }

  Future<void> _addLocationFromCity() async {
    final result = await Navigator.push<PlacePickerResult>(
      context,
      MaterialPageRoute(builder: (_) => PlacePickerPage(i18n: _i18n)),
    );
    if (result == null || !mounted) return;
    final p = result.place;
    setState(() {
      _recipientLocations.add(
        RecipientLocation(
          latitude: p.latitude,
          longitude: p.longitude,
          locationName: p.getName('EN'),
        ),
      );
    });
  }

  Future<void> _addLocationManually() async {
    final added = await showDialog<RecipientLocation>(
      context: context,
      builder: (_) => const _ManualLocationDialog(),
    );
    if (added == null || !mounted) return;
    setState(() => _recipientLocations.add(added));
  }

  void _removeRecipientLocation(int index) {
    setState(() => _recipientLocations.removeAt(index));
  }

  String _locationChipLabel(RecipientLocation loc) {
    if (loc.locationName != null && loc.locationName!.isNotEmpty) {
      return loc.locationName!;
    }
    return '${loc.latitude.toStringAsFixed(2)}, ${loc.longitude.toStringAsFixed(2)}';
  }

  // ── Submit ────────────────────────────────────────────────────────

  void _send() {
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
      'type': _encrypted ? 'encrypted' : 'open',
      'content': _contentController.text.trim(),
      'ttl': ttlText.isNotEmpty ? int.tryParse(ttlText) : null,
      'priority': _priority,
      'paymentRequested': _paymentRequested,
    });
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('new_postcard')),
        actions: [
          TextButton(
            onPressed: _send,
            child: Text(
              _i18n.t('send'),
              style: TextStyle(
                color: theme.colorScheme.onPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          children: [
            _buildRecipientRow(theme),
            const SizedBox(height: 12),
            _buildTitleRow(theme),
            const SizedBox(height: 12),
            _buildMessageArea(theme),
            const SizedBox(height: 20),
            _buildRouteHints(theme),
            const SizedBox(height: 12),
            _buildMoreOptions(theme),
          ],
        ),
      ),
    );
  }

  // Recipient: compact single row + optional advanced NPUB.
  Widget _buildRecipientRow(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: _recipientCallsignController,
          decoration: InputDecoration(
            labelText: _i18n.t('to'),
            hintText: _i18n.t('recipient_inline_hint'),
            prefixIcon: const Icon(Icons.person_outline),
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.contacts_outlined),
                  tooltip: _i18n.t('pick_from_contacts'),
                  onPressed: _pickContact,
                ),
                IconButton(
                  icon: Icon(
                    _showAdvancedRecipient
                        ? Icons.expand_less
                        : Icons.expand_more,
                  ),
                  tooltip: _i18n.t('recipient_npub_optional'),
                  onPressed: () => setState(
                    () => _showAdvancedRecipient = !_showAdvancedRecipient,
                  ),
                ),
              ],
            ),
          ),
          textInputAction: TextInputAction.next,
        ),
        if (_showAdvancedRecipient) ...[
          const SizedBox(height: 8),
          TextFormField(
            controller: _recipientNpubController,
            decoration: InputDecoration(
              labelText: _i18n.t('recipient_npub_optional'),
              hintText: 'npub1...',
              prefixIcon: const Icon(Icons.key_outlined),
              border: const OutlineInputBorder(),
            ),
            validator: (value) {
              final trimmed = value?.trim() ?? '';
              if (trimmed.isEmpty) return null;
              if (!trimmed.startsWith('npub1')) {
                return _i18n.t('invalid_npub_format');
              }
              return null;
            },
            textInputAction: TextInputAction.next,
          ),
        ],
      ],
    );
  }

  Widget _buildTitleRow(ThemeData theme) {
    return TextFormField(
      controller: _titleController,
      decoration: InputDecoration(
        labelText: _i18n.t('postcard_title'),
        hintText: _i18n.t('enter_postcard_title'),
        prefixIcon: const Icon(Icons.title),
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
    );
  }

  Widget _buildMessageArea(ThemeData theme) {
    return Stack(
      children: [
        TextFormField(
          controller: _contentController,
          decoration: InputDecoration(
            labelText: _i18n.t('message'),
            hintText: _i18n.t('enter_message'),
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
            // Inner padding leaves room for the lock icon in the top-right.
            contentPadding: const EdgeInsets.fromLTRB(12, 16, 48, 12),
          ),
          maxLines: 8,
          minLines: 6,
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return _i18n.t('message_is_required');
            }
            return null;
          },
        ),
        Positioned(
          top: 4,
          right: 4,
          child: IconButton(
            icon: Icon(
              _encrypted ? Icons.lock : Icons.lock_open,
              color: _encrypted
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            tooltip: _encrypted
                ? _i18n.t('encrypted')
                : _i18n.t('open'),
            onPressed: _toggleEncryption,
          ),
        ),
      ],
    );
  }

  Widget _buildRouteHints(ThemeData theme) {
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _i18n.t('route_hints'),
          style: theme.textTheme.labelLarge?.copyWith(color: muted),
        ),
        const SizedBox(height: 2),
        Text(
          _i18n.t('route_hints_short'),
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ..._recipientLocations.asMap().entries.map((entry) {
              return InputChip(
                avatar: const Icon(Icons.place, size: 16),
                label: Text(_locationChipLabel(entry.value)),
                onDeleted: () => _removeRecipientLocation(entry.key),
              );
            }),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: Text(_i18n.t('add_area')),
              onPressed: _addAreaMenu,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMoreOptions(ThemeData theme) {
    return Theme(
      // Remove the divider lines that ExpansionTile draws by default, so
      // the "More options" block sits quietly at the bottom of the form.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
        leading: const Icon(Icons.tune),
        title: Text(_i18n.t('more_options')),
        children: [
          DropdownButtonFormField<String>(
            value: _priority,
            decoration: InputDecoration(
              labelText: _i18n.t('priority'),
              border: const OutlineInputBorder(),
              isDense: true,
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
              if (value != null) setState(() => _priority = value);
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _ttlController,
            decoration: InputDecoration(
              labelText: _i18n.t('ttl_days_optional'),
              hintText: '30',
              border: const OutlineInputBorder(),
              suffixText: _i18n.t('days'),
              isDense: true,
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
          const SizedBox(height: 4),
          SwitchListTile(
            title: Text(_i18n.t('payment_requested')),
            subtitle: Text(
              _i18n.t('request_payment_for_delivery'),
              style: theme.textTheme.bodySmall,
            ),
            value: _paymentRequested,
            onChanged: (value) => setState(() => _paymentRequested = value),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ],
      ),
    );
  }
}

/// Fallback dialog for pasting known coordinates. Used when the user
/// taps "Enter coordinates" on the route-hint bottom sheet.
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
