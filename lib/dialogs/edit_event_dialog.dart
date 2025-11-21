/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/event.dart';
import '../services/i18n_service.dart';

/// Dialog for editing an existing event
class EditEventDialog extends StatefulWidget {
  final Event event;

  const EditEventDialog({Key? key, required this.event}) : super(key: key);

  @override
  State<EditEventDialog> createState() => _EditEventDialogState();
}

class _EditEventDialogState extends State<EditEventDialog> {
  final _formKey = GlobalKey<FormState>();
  final _i18n = I18nService();
  late TextEditingController _titleController;
  late TextEditingController _locationController;
  late TextEditingController _locationNameController;
  late TextEditingController _contentController;
  late TextEditingController _adminsController;
  late TextEditingController _moderatorsController;
  late TextEditingController _startDateController;
  late TextEditingController _endDateController;

  late bool _isOnline;
  late DateTime _eventDateTime;
  late DateTime? _startDate;
  late DateTime? _endDate;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.event.title);
    _locationController = TextEditingController(
      text: widget.event.isOnline ? '' : widget.event.location,
    );
    _locationNameController = TextEditingController(text: widget.event.locationName ?? '');
    _contentController = TextEditingController(text: widget.event.content);
    _adminsController = TextEditingController(
      text: widget.event.admins.join(', '),
    );
    _moderatorsController = TextEditingController(
      text: widget.event.moderators.join(', '),
    );
    _isOnline = widget.event.isOnline;

    // Initialize date fields
    if (widget.event.isMultiDay) {
      _startDate = _parseDate(widget.event.startDate ?? '');
      _endDate = _parseDate(widget.event.endDate ?? '');
      _startDateController = TextEditingController(text: widget.event.startDate ?? '');
      _endDateController = TextEditingController(text: widget.event.endDate ?? '');
      _eventDateTime = DateTime.now();
    } else {
      _eventDateTime = widget.event.dateTime;
      _startDateController = TextEditingController();
      _endDateController = TextEditingController();
    }
  }

  DateTime? _parseDate(String dateStr) {
    try {
      if (dateStr.isEmpty) return null;
      return DateTime.parse(dateStr);
    } catch (e) {
      return null;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _locationNameController.dispose();
    _contentController.dispose();
    _adminsController.dispose();
    _moderatorsController.dispose();
    _startDateController.dispose();
    _endDateController.dispose();
    super.dispose();
  }

  Future<void> _selectEventDateTime() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _eventDateTime,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (pickedDate != null && mounted) {
      final pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(_eventDateTime),
      );

      if (pickedTime != null && mounted) {
        setState(() {
          _eventDateTime = DateTime(
            pickedDate.year,
            pickedDate.month,
            pickedDate.day,
            pickedTime.hour,
            pickedTime.minute,
          );
        });
      }
    }
  }

  Future<void> _selectStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      setState(() {
        _startDate = picked;
        final dateStr = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
        _startDateController.text = dateStr;
      });
    }
  }

  Future<void> _selectEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? _startDate ?? DateTime.now(),
      firstDate: _startDate ?? DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null) {
      setState(() {
        _endDate = picked;
        final dateStr = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
        _endDateController.text = dateStr;
      });
    }
  }

  List<String> _parseNpubs(String text) {
    if (text.trim().isEmpty) return [];

    return text
        .split(',')
        .map((npub) => npub.trim())
        .where((npub) => npub.isNotEmpty)
        .toList();
  }

  void _save() {
    if (_formKey.currentState!.validate()) {
      final location = _isOnline ? 'online' : _locationController.text.trim();

      final result = <String, dynamic>{
        'title': _titleController.text.trim(),
        'location': location,
        'locationName': _locationNameController.text.trim().isNotEmpty
            ? _locationNameController.text.trim()
            : null,
        'content': _contentController.text.trim(),
        'admins': _parseNpubs(_adminsController.text),
        'moderators': _parseNpubs(_moderatorsController.text),
      };

      // Add date information
      if (widget.event.isMultiDay) {
        result['startDate'] = _startDateController.text.trim();
        result['endDate'] = _endDateController.text.trim();
        print('EditEventDialog: Saving multi-day event with dates: ${result['startDate']} - ${result['endDate']}');
      } else {
        result['eventDateTime'] = _eventDateTime;
        print('EditEventDialog: Saving single-day event with dateTime: $_eventDateTime');
      }

      Navigator.pop(context, result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      child: Container(
        width: 600,
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
                _i18n.t('edit_event'),
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
                      // Event title
                      TextFormField(
                        controller: _titleController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('event_title'),
                          hintText: _i18n.t('enter_event_title'),
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

                      // Date editing
                      if (widget.event.isMultiDay) ...[
                        // Multi-day event: start and end dates
                        Text(
                          _i18n.t('event_dates'),
                          style: theme.textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _selectStartDate,
                                icon: const Icon(Icons.calendar_today, size: 18),
                                label: Text(
                                  _startDateController.text.isNotEmpty
                                      ? _startDateController.text
                                      : _i18n.t('start_date'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _selectEndDate,
                                icon: const Icon(Icons.calendar_today, size: 18),
                                label: Text(
                                  _endDateController.text.isNotEmpty
                                      ? _endDateController.text
                                      : _i18n.t('end_date'),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        // Single-day event: date and time
                        Text(
                          _i18n.t('event_date'),
                          style: theme.textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _selectEventDateTime,
                          icon: const Icon(Icons.calendar_today, size: 18),
                          label: Text(
                            '${_eventDateTime.year}-${_eventDateTime.month.toString().padLeft(2, '0')}-${_eventDateTime.day.toString().padLeft(2, '0')} '
                            '${_eventDateTime.hour.toString().padLeft(2, '0')}:${_eventDateTime.minute.toString().padLeft(2, '0')}',
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      // Location type toggle
                      SwitchListTile(
                        title: Text(_i18n.t('online_event')),
                        value: _isOnline,
                        onChanged: (value) {
                          setState(() {
                            _isOnline = value;
                            if (value) {
                              _locationController.clear();
                            }
                          });
                        },
                        contentPadding: EdgeInsets.zero,
                      ),
                      // Location field (if not online)
                      if (!_isOnline) ...[
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _locationController,
                          decoration: InputDecoration(
                            labelText: _i18n.t('location_coords'),
                            hintText: '40.7128,-74.0060',
                            border: const OutlineInputBorder(),
                            helperText: _i18n.t('enter_latitude_longitude'),
                          ),
                          validator: (value) {
                            if (!_isOnline && (value == null || value.trim().isEmpty)) {
                              return _i18n.t('location_required');
                            }
                            if (!_isOnline && !value!.contains(',')) {
                              return _i18n.t('invalid_coords_format');
                            }
                            return null;
                          },
                          textInputAction: TextInputAction.next,
                        ),
                      ],
                      const SizedBox(height: 16),
                      // Location name (optional)
                      TextFormField(
                        controller: _locationNameController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('location_name'),
                          hintText: _i18n.t('enter_location_name'),
                          border: const OutlineInputBorder(),
                        ),
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 16),
                      // Content
                      TextFormField(
                        controller: _contentController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('description'),
                          hintText: _i18n.t('enter_event_description'),
                          border: const OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        maxLines: 6,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return _i18n.t('description_required');
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 16),
                      // Admins
                      TextFormField(
                        controller: _adminsController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('admins_optional'),
                          hintText: _i18n.t('npubs_comma_separated'),
                          border: const OutlineInputBorder(),
                          helperText: _i18n.t('admins_help'),
                        ),
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 16),
                      // Moderators
                      TextFormField(
                        controller: _moderatorsController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('moderators_optional'),
                          hintText: _i18n.t('npubs_comma_separated'),
                          border: const OutlineInputBorder(),
                          helperText: _i18n.t('moderators_help'),
                        ),
                        textInputAction: TextInputAction.done,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(_i18n.t('cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save, size: 18),
                    label: Text(_i18n.t('save')),
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
