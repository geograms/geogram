/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import '../models/news_article.dart';
import '../services/i18n_service.dart';
import '../pages/location_picker_page.dart';

/// Dialog for creating a new news article with multilanguage support
class NewNewsDialog extends StatefulWidget {
  final String defaultLanguage;

  const NewNewsDialog({
    Key? key,
    this.defaultLanguage = 'en',
  }) : super(key: key);

  @override
  State<NewNewsDialog> createState() => _NewNewsDialogState();
}

class _NewNewsDialogState extends State<NewNewsDialog> {
  final _formKey = GlobalKey<FormState>();
  final _i18n = I18nService();

  // Controllers for each language
  final Map<String, TextEditingController> _headlineControllers = {};
  final Map<String, TextEditingController> _contentControllers = {};
  final Map<String, int> _contentLengths = {};

  final _latitudeController = TextEditingController();
  final _longitudeController = TextEditingController();
  final _addressController = TextEditingController();
  final _radiusController = TextEditingController();
  final _sourceController = TextEditingController();
  final _tagsController = TextEditingController();

  NewsClassification _classification = NewsClassification.normal;
  DateTime? _expiryDateTime;

  // Languages currently being edited
  final List<String> _activeLanguages = [];

  // Most common languages at the top for easy selection
  static const List<Map<String, String>> _availableLanguages = [
    {'code': 'en', 'name': 'English'},
    {'code': 'pt', 'name': 'Português'},
    {'code': 'es', 'name': 'Español'},
    {'code': 'fr', 'name': 'Français'},
    {'code': 'de', 'name': 'Deutsch'},
    {'code': 'it', 'name': 'Italiano'},
    {'code': 'nl', 'name': 'Nederlands'},
    {'code': 'ru', 'name': 'Русский'},
    {'code': 'zh', 'name': '中文'},
    {'code': 'ja', 'name': '日本語'},
    {'code': 'ar', 'name': 'العربية'},
  ];

  @override
  void initState() {
    super.initState();

    // Add default language
    _addLanguage(widget.defaultLanguage);
  }

  void _addLanguage(String langCode) {
    if (!_activeLanguages.contains(langCode)) {
      setState(() {
        _activeLanguages.add(langCode);
        _headlineControllers[langCode] = TextEditingController();
        _contentControllers[langCode] = TextEditingController();
        _contentLengths[langCode] = 0;

        _contentControllers[langCode]!.addListener(() {
          setState(() {
            _contentLengths[langCode] = _contentControllers[langCode]!.text.length;
          });
        });
      });
    }
  }

  void _removeLanguage(String langCode) {
    if (_activeLanguages.length > 1) {
      setState(() {
        _headlineControllers[langCode]?.dispose();
        _contentControllers[langCode]?.dispose();
        _headlineControllers.remove(langCode);
        _contentControllers.remove(langCode);
        _contentLengths.remove(langCode);
        _activeLanguages.remove(langCode);
      });
    }
  }

  @override
  void dispose() {
    for (var controller in _headlineControllers.values) {
      controller.dispose();
    }
    for (var controller in _contentControllers.values) {
      controller.dispose();
    }
    _latitudeController.dispose();
    _longitudeController.dispose();
    _addressController.dispose();
    _radiusController.dispose();
    _sourceController.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  List<String> _parseTags() {
    if (_tagsController.text.trim().isEmpty) return [];

    return _tagsController.text
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList();
  }

  void _publish() {
    if (_formKey.currentState!.validate()) {
      // Build headlines and contents maps
      final headlines = <String, String>{};
      final contents = <String, String>{};

      for (var lang in _activeLanguages) {
        final headline = _headlineControllers[lang]!.text.trim();
        final content = _contentControllers[lang]!.text.trim();

        if (headline.isNotEmpty) {
          headlines[lang] = headline;
        }
        if (content.isNotEmpty) {
          contents[lang] = content;
        }
      }

      // Validate at least one headline and content
      if (headlines.isEmpty || contents.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please provide at least one headline and content')),
        );
        return;
      }

      // Validate radius requires location
      final radius = double.tryParse(_radiusController.text);
      final lat = double.tryParse(_latitudeController.text);
      final lon = double.tryParse(_longitudeController.text);

      if (radius != null && (lat == null || lon == null)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('radius_requires_location'))),
        );
        return;
      }

      // Validate expiry is in future
      if (_expiryDateTime != null && _expiryDateTime!.isBefore(DateTime.now())) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('expiry_must_be_future'))),
        );
        return;
      }

      Navigator.pop(context, {
        'headlines': headlines,
        'contents': contents,
        'classification': _classification,
        'latitude': lat,
        'longitude': lon,
        'address': _addressController.text.trim().isNotEmpty
            ? _addressController.text.trim()
            : null,
        'radiusKm': radius,
        'expiryDateTime': _expiryDateTime,
        'source': _sourceController.text.trim().isNotEmpty
            ? _sourceController.text.trim()
            : null,
        'tags': _parseTags(),
      });
    }
  }

  Future<void> _pickExpiryDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (date != null && mounted) {
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.now(),
      );

      if (time != null && mounted) {
        setState(() {
          _expiryDateTime = DateTime(
            date.year,
            date.month,
            date.day,
            time.hour,
            time.minute,
          );
        });
      }
    }
  }

  Future<void> _openMapPicker() async {
    // Get current coordinates if available
    LatLng? initialPosition;
    final lat = double.tryParse(_latitudeController.text.trim());
    final lon = double.tryParse(_longitudeController.text.trim());
    if (lat != null && lon != null && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
      initialPosition = LatLng(lat, lon);
    }

    // Open location picker
    final result = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (context) => LocationPickerPage(
          initialPosition: initialPosition,
        ),
      ),
    );

    // Update coordinates if location was selected
    if (result != null && mounted) {
      setState(() {
        _latitudeController.text = result.latitude.toStringAsFixed(6);
        _longitudeController.text = result.longitude.toStringAsFixed(6);
      });
    }
  }

  String _getLanguageName(String code) {
    final lang = _availableLanguages.firstWhere(
      (l) => l['code'] == code,
      orElse: () => {'code': code, 'name': code.toUpperCase()},
    );
    return lang['name']!;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      child: Container(
        width: 800,
        constraints: const BoxConstraints(maxHeight: 900),
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _i18n.t('new_news_article'),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // Language selector
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: 'Add language',
                    onSelected: _addLanguage,
                    itemBuilder: (context) => _availableLanguages
                        .where((lang) => !_activeLanguages.contains(lang['code']))
                        .map((lang) => PopupMenuItem<String>(
                              value: lang['code']!,
                              child: Text(lang['name']!),
                            ))
                        .toList(),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // Form fields
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Language tabs and content
                      if (_activeLanguages.isNotEmpty) ...[
                        // Language tabs
                        Wrap(
                          spacing: 4,
                          children: _activeLanguages.map((lang) {
                            return Chip(
                              label: Text(_getLanguageName(lang)),
                              deleteIcon: _activeLanguages.length > 1
                                  ? const Icon(Icons.close, size: 16)
                                  : null,
                              onDeleted: _activeLanguages.length > 1
                                  ? () => _removeLanguage(lang)
                                  : null,
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 16),

                        // Fields for each language
                        ..._activeLanguages.map((lang) {
                          return ExpansionTile(
                            title: Text('${_getLanguageName(lang)} Content'),
                            initiallyExpanded: lang == _activeLanguages.first,
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  children: [
                                    // Headline for this language
                                    TextFormField(
                                      controller: _headlineControllers[lang],
                                      decoration: InputDecoration(
                                        labelText: '${_i18n.t('headline_required')} (${lang.toUpperCase()})',
                                        hintText: _i18n.t('enter_headline'),
                                        border: const OutlineInputBorder(),
                                      ),
                                      validator: (value) {
                                        if (lang == _activeLanguages.first) {
                                          if (value == null || value.trim().isEmpty) {
                                            return 'At least first language headline is required';
                                          }
                                        }
                                        if (value != null && value.trim().length > 100) {
                                          return _i18n.t('headline_max_100_chars');
                                        }
                                        return null;
                                      },
                                      textInputAction: TextInputAction.next,
                                      maxLength: 100,
                                    ),
                                    const SizedBox(height: 16),
                                    // Content for this language
                                    TextFormField(
                                      controller: _contentControllers[lang],
                                      decoration: InputDecoration(
                                        labelText: '${_i18n.t('content_max_500_chars')} (${lang.toUpperCase()})',
                                        hintText: _i18n.t('content_max_500_chars_hint'),
                                        border: const OutlineInputBorder(),
                                        alignLabelWithHint: true,
                                        helperText: '${_contentLengths[lang] ?? 0} / 500 characters',
                                        helperStyle: TextStyle(
                                          color: (_contentLengths[lang] ?? 0) > 500 ? Colors.red : null,
                                        ),
                                      ),
                                      maxLines: 8,
                                      maxLength: 500,
                                      validator: (value) {
                                        if (lang == _activeLanguages.first) {
                                          if (value == null || value.trim().isEmpty) {
                                            return 'At least first language content is required';
                                          }
                                        }
                                        if (value != null && value.trim().length > 500) {
                                          return _i18n.t('content_exceeds_500_chars');
                                        }
                                        return null;
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        }).toList(),

                        const Divider(),
                        const SizedBox(height: 16),
                      ],

                      // Classification dropdown
                      DropdownButtonFormField<NewsClassification>(
                        value: _classification,
                        decoration: InputDecoration(
                          labelText: _i18n.t('classification'),
                          border: const OutlineInputBorder(),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: NewsClassification.normal,
                            child: Row(
                              children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: const BoxDecoration(
                                    color: Colors.blue,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(_i18n.t('classification_normal')),
                              ],
                            ),
                          ),
                          DropdownMenuItem(
                            value: NewsClassification.urgent,
                            child: Row(
                              children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: const BoxDecoration(
                                    color: Colors.orange,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(_i18n.t('classification_urgent')),
                              ],
                            ),
                          ),
                          DropdownMenuItem(
                            value: NewsClassification.danger,
                            child: Row(
                              children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: const BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(_i18n.t('classification_danger')),
                              ],
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _classification = value;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      // Location section
                      ExpansionTile(
                        title: Text(_i18n.t('location_coordinates')),
                        initiallyExpanded: false,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextFormField(
                                        controller: _latitudeController,
                                        decoration: InputDecoration(
                                          labelText: _i18n.t('latitude'),
                                          hintText: '37.774929',
                                          border: const OutlineInputBorder(),
                                        ),
                                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                        inputFormatters: [
                                          FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*')),
                                        ],
                                        validator: (value) {
                                          if (value != null && value.isNotEmpty) {
                                            final lat = double.tryParse(value);
                                            if (lat == null || lat < -90 || lat > 90) {
                                              return 'Invalid latitude';
                                            }
                                          }
                                          return null;
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TextFormField(
                                        controller: _longitudeController,
                                        decoration: InputDecoration(
                                          labelText: _i18n.t('longitude'),
                                          hintText: '-122.419418',
                                          border: const OutlineInputBorder(),
                                        ),
                                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                        inputFormatters: [
                                          FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*')),
                                        ],
                                        validator: (value) {
                                          if (value != null && value.isNotEmpty) {
                                            final lon = double.tryParse(value);
                                            if (lon == null || lon < -180 || lon > 180) {
                                              return 'Invalid longitude';
                                            }
                                          }
                                          return null;
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton.filledTonal(
                                      onPressed: _openMapPicker,
                                      icon: const Icon(Icons.map),
                                      tooltip: _i18n.t('select_on_map'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                TextFormField(
                                  controller: _addressController,
                                  decoration: InputDecoration(
                                    labelText: _i18n.t('address'),
                                    hintText: _i18n.t('address_hint'),
                                    border: const OutlineInputBorder(),
                                  ),
                                  maxLength: 200,
                                ),
                                const SizedBox(height: 16),
                                TextFormField(
                                  controller: _radiusController,
                                  decoration: InputDecoration(
                                    labelText: _i18n.t('radius_km'),
                                    hintText: _i18n.t('radius_hint'),
                                    border: const OutlineInputBorder(),
                                  ),
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
                                  ],
                                  validator: (value) {
                                    if (value != null && value.isNotEmpty) {
                                      final radius = double.tryParse(value);
                                      if (radius == null || radius < 0.1 || radius > 100) {
                                        return _i18n.t('radius_min_max');
                                      }
                                    }
                                    return null;
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Expiry date picker
                      ListTile(
                        title: Text(_i18n.t('expiry_date')),
                        subtitle: Text(
                          _expiryDateTime != null
                              ? '${_expiryDateTime!.year}-${_expiryDateTime!.month.toString().padLeft(2, '0')}-${_expiryDateTime!.day.toString().padLeft(2, '0')} ${_expiryDateTime!.hour.toString().padLeft(2, '0')}:${_expiryDateTime!.minute.toString().padLeft(2, '0')}'
                              : _i18n.t('expiry_hint'),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_expiryDateTime != null)
                              IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  setState(() {
                                    _expiryDateTime = null;
                                  });
                                },
                              ),
                            IconButton(
                              icon: const Icon(Icons.calendar_today),
                              onPressed: _pickExpiryDateTime,
                            ),
                          ],
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: 16),
                      // Source field
                      TextFormField(
                        controller: _sourceController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('source'),
                          hintText: _i18n.t('source_hint'),
                          border: const OutlineInputBorder(),
                        ),
                        maxLength: 150,
                      ),
                      const SizedBox(height: 16),
                      // Tags field
                      TextFormField(
                        controller: _tagsController,
                        decoration: InputDecoration(
                          labelText: _i18n.t('tags'),
                          hintText: _i18n.t('tags_hint'),
                          border: const OutlineInputBorder(),
                          helperText: _i18n.t('separate_tags_commas'),
                        ),
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
                    onPressed: _publish,
                    icon: const Icon(Icons.publish, size: 18),
                    label: Text(_i18n.t('publish')),
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
