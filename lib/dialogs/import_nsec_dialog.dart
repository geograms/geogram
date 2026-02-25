import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/profile.dart';
import '../services/i18n_service.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_key_generator.dart';

Future<Map<String, dynamic>?> showImportNsecDialog({
  required BuildContext context,
  required I18nService i18n,
  bool allowProfileType = true,
  bool showQrOnMobileOnly = false,
}) async {
  final nsecController = TextEditingController();
  final formKey = GlobalKey<FormState>();
  var profileType = ProfileType.client;
  String? scannedNickname;
  var didAutoPaste = false;

  bool shouldShowQr() {
    if (kIsWeb) return false;
    if (Platform.isAndroid || Platform.isIOS) return true;
    if (!showQrOnMobileOnly && Platform.isMacOS) return true;
    return false;
  }

  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        if (!didAutoPaste) {
          didAutoPaste = true;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (nsecController.text.trim().isNotEmpty) return;
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            final text = data?.text?.trim() ?? '';
            if (text.startsWith('nsec1')) {
              nsecController.text = text;
              setDialogState(() {});
            }
          });
        }
        return AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.qr_code, size: 28),
            const SizedBox(width: 8),
            Text(i18n.t('import_profile')),
          ],
        ),
        content: SizedBox(
          width: 360,
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  i18n.t('import_nsec_hint'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: nsecController,
                  decoration: InputDecoration(
                    labelText: 'NSEC',
                    hintText: 'nsec1...',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.key),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.paste),
                      tooltip: i18n.t('paste'),
                      onPressed: () async {
                        final data = await Clipboard.getData(Clipboard.kTextPlain);
                        if (data?.text != null) {
                          nsecController.text = data!.text!.trim();
                        }
                      },
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return i18n.t('field_is_empty');
                    }
                    final trimmed = value.trim();
                    if (!trimmed.startsWith('nsec1')) {
                      return i18n.t('invalid_nsec_format');
                    }
                    try {
                      NostrCrypto.decodeNsec(trimmed);
                    } catch (e) {
                      return i18n.t('invalid_nsec_format');
                    }
                    return null;
                  },
                ),
                if (shouldShowQr()) ...[
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton.icon(
                      onPressed: () async {
                        final scanned = await Navigator.push<Map<String, String>>(
                          context,
                          MaterialPageRoute(
                            builder: (context) => NsecScannerPage(i18n: i18n),
                          ),
                        );
                        if (scanned != null) {
                          nsecController.text = scanned['nsec'] ?? '';
                          if (scanned['nickname'] != null && scanned['nickname']!.isNotEmpty) {
                            scannedNickname = scanned['nickname'];
                          }
                        }
                      },
                      icon: const Icon(Icons.qr_code_scanner),
                      label: Text(i18n.t('scan_qr')),
                    ),
                  ),
                ],
                if (allowProfileType) ...[
                  const SizedBox(height: 16),
                  Text(
                    i18n.t('profile_type'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<ProfileType>(
                    segments: [
                      ButtonSegment(
                        value: ProfileType.client,
                        label: Text(i18n.t('client')),
                        icon: const Icon(Icons.person),
                      ),
                      ButtonSegment(
                        value: ProfileType.station,
                        label: Text(i18n.t('station')),
                        icon: const Icon(Icons.cell_tower),
                      ),
                    ],
                    selected: {profileType},
                    onSelectionChanged: (selected) {
                      setDialogState(() {
                        profileType = selected.first;
                      });
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                final nsec = nsecController.text.trim();
                try {
                  final privateKeyHex = NostrCrypto.decodeNsec(nsec);
                  final publicKeyHex = NostrCrypto.derivePublicKey(privateKeyHex);
                  final npub = NostrCrypto.encodeNpub(publicKeyHex);
                  final callsign = profileType == ProfileType.station
                      ? NostrKeyGenerator.deriveStationCallsign(npub)
                      : NostrKeyGenerator.deriveCallsign(npub);
                  Navigator.of(context).pop({
                    'nsec': nsec,
                    'npub': npub,
                    'callsign': callsign,
                    'type': profileType,
                    if (scannedNickname != null) 'nickname': scannedNickname,
                  });
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(i18n.t('invalid_nsec_format')),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: Text(i18n.t('import')),
          ),
        ],
      );
      },
    ),
  );

  return result;
}

/// Full-screen scanner page for reading NSEC QR codes.
/// Returns a Map with 'nsec' and optionally 'nickname'.
class NsecScannerPage extends StatefulWidget {
  final I18nService i18n;
  const NsecScannerPage({super.key, required this.i18n});

  @override
  State<NsecScannerPage> createState() => _NsecScannerPageState();
}

class _NsecScannerPageState extends State<NsecScannerPage> {
  bool _isLoading = true;
  bool _permissionDenied = false;
  bool _permissionPermanentlyDenied = false;
  bool _hasScanned = false;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final status = await Permission.camera.status;
    if (status.isGranted) {
      setState(() => _isLoading = false);
    } else if (status.isPermanentlyDenied) {
      setState(() {
        _isLoading = false;
        _permissionDenied = true;
        _permissionPermanentlyDenied = true;
      });
    } else {
      final result = await Permission.camera.request();
      if (result.isGranted) {
        setState(() => _isLoading = false);
      } else {
        setState(() {
          _isLoading = false;
          _permissionDenied = true;
          _permissionPermanentlyDenied = result.isPermanentlyDenied;
        });
      }
    }
  }

  void _onScan(Code code) {
    if (_hasScanned || !code.isValid) return;
    final value = code.text;
    if (value == null) return;

    final trimmed = value.trim();
    String nsec;
    String? nickname;

    // Try JSON format first: {"nsec":"nsec1...","nickname":"..."}
    if (trimmed.startsWith('{')) {
      try {
        final data = jsonDecode(trimmed) as Map<String, dynamic>;
        nsec = (data['nsec'] as String?)?.trim() ?? '';
        nickname = data['nickname'] as String?;
      } catch (e) {
        return;
      }
    } else if (trimmed.startsWith('nsec1')) {
      // Backward compatibility: bare nsec string
      nsec = trimmed;
    } else {
      return;
    }

    if (!nsec.startsWith('nsec1')) return;

    // Validate it's a decodable NSEC
    try {
      NostrCrypto.decodeNsec(nsec);
    } catch (e) {
      return;
    }

    setState(() => _hasScanned = true);
    Navigator.of(context).pop({
      'nsec': nsec,
      if (nickname != null && nickname.isNotEmpty) 'nickname': nickname,
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.i18n.t('scan_qr')),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _permissionDenied
              ? _buildPermissionDenied(theme)
              : _buildScanner(theme),
    );
  }

  Widget _buildPermissionDenied(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.camera_alt_outlined, size: 64, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              _permissionPermanentlyDenied
                  ? widget.i18n.t('camera_permission_denied')
                  : widget.i18n.t('camera_permission_required'),
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (_permissionPermanentlyDenied)
              FilledButton.icon(
                onPressed: () => openAppSettings(),
                icon: const Icon(Icons.settings),
                label: Text(widget.i18n.t('open_settings')),
              )
            else
              FilledButton.icon(
                onPressed: _checkPermission,
                icon: const Icon(Icons.refresh),
                label: Text(widget.i18n.t('try_again')),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanner(ThemeData theme) {
    return Stack(
      children: [
        ReaderWidget(
          onScan: _onScan,
          isMultiScan: false,
          showFlashlight: true,
          showToggleCamera: true,
          showGallery: false,
          tryHarder: true,
          tryInverted: true,
        ),
        Positioned(
          bottom: 48,
          left: 0,
          right: 0,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 32),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.qr_code_scanner, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    widget.i18n.t('scan_nsec_qr_hint'),
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
