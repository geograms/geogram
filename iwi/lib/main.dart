import 'dart:async';
import 'dart:io' show Directory, File, Platform, Process;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'models/monitored_task.dart';
import 'pages/welcome_page.dart';
import 'services/event_bus.dart';
import 'services/host_event_bridge.dart';
import 'services/notification_service.dart';
import 'services/preferences_service.dart';
import 'services/profile_service.dart';
import 'services/profile_storage.dart';
import 'services/storage_paths.dart';
import 'services/task_monitor_service.dart';
import 'services/wapp_signing_service.dart';
import 'services/widget_registry.dart';
import 'util/wapp_icons.dart';
import 'wapp/wapp_engine.dart';
import 'wapp/wapp_page.dart';

/// Global messenger key. Held outside any widget so the
/// [NotificationService] can drive snackbars without needing a
/// BuildContext from inside an event handler.
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  // Required before any async work that touches platform channels.
  WidgetsFlutterBinding.ensureInitialized();

  // Register core host services as parallel boot tasks so they run
  // through the orchestrator (and show up in the tasks wapp with the
  // boot:parallel pill). They are cheap and independent, so parallel
  // is correct — no contention for CPU or memory.
  BootOrchestrator.instance.register(
    id: 'notification-service',
    name: 'Notification service',
    description:
        'Registers the system tray notification backend and subscribes '
        'to host ErrorEvent. In-app display is handled by the '
        'NotificationLayer overlay wrapping the launcher.',
    mode: BootStart.parallel,
    init: () async {
      NotificationService.instance.init();
    },
  );
  BootOrchestrator.instance.register(
    id: 'host-event-bridge',
    name: 'Host → wapp event bridge',
    description:
        'Republishes AppStarted/WappLoaded/WappUnloaded/WappCrashed/'
        'ErrorEvent on the wapp event broker as system.* topics.',
    mode: BootStart.parallel,
    init: () async {
      HostEventBridge.instance.install();
    },
  );
  BootOrchestrator.instance.register(
    id: 'profile-service',
    name: 'Profile service',
    description:
        'Loads profiles.json and the active profile id. Must run '
        'before the launcher scan because storage_paths.dart '
        'resolves apps/ and wapps/ under the active profile folder.',
    mode: BootStart.sequential,
    init: () async {
      await ProfileService.instance.load();
    },
  );

  // Run every registered boot task. Sequential boot tasks run first,
  // alone, in registration order; then all parallels run concurrently.
  await BootOrchestrator.instance.runAll();

  runApp(IwiApp(messengerKey: rootMessengerKey));
}

class IwiApp extends StatefulWidget {
  final GlobalKey<ScaffoldMessengerState> messengerKey;
  const IwiApp({super.key, required this.messengerKey});

  @override
  State<IwiApp> createState() => _IwiAppState();
}

class _IwiAppState extends State<IwiApp> {
  @override
  void initState() {
    super.initState();
    // Rebuild the root whenever the active profile changes so that
    // (a) the welcome-page → launcher handoff flips cleanly on first
    //     profile creation, and
    // (b) profile switches re-route storage paths and trigger a
    //     launcher rescan on the fresh apps/ folder.
    ProfileService.instance.activeProfileNotifier.addListener(_onProfileChanged);
  }

  @override
  void dispose() {
    ProfileService.instance.activeProfileNotifier
        .removeListener(_onProfileChanged);
    super.dispose();
  }

  void _onProfileChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hasProfile = ProfileService.instance.hasProfiles &&
        ProfileService.instance.activeProfile != null;
    return MaterialApp(
      title: 'geogram',
      // Kept for ad-hoc Flutter snackbars (e.g. settings delete errors).
      // The unified NotificationService does NOT use this — it pipes
      // everything through the NotificationLayer overlay below.
      scaffoldMessengerKey: widget.messengerKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      // The NotificationLayer is installed via `builder`, not `home:`,
      // so it sits ABOVE the Navigator. That way its stacking overlay
      // renders on top of whatever route is currently visible — the
      // launcher AND every pushed wapp page. If we wrapped only
      // `home:`, wapp pages (which are siblings of home in the
      // navigator stack) would cover the notification cards.
      builder: (context, child) {
        return NotificationLayer(child: child ?? const SizedBox.shrink());
      },
      home: hasProfile
          ? const LauncherPage()
          : WelcomePage(
              // saveAndActivate already flips activeProfileNotifier,
              // so the _onProfileChanged setState above will rebuild
              // this widget with hasProfile==true and swap to the
              // launcher. onComplete is a no-op hook for any future
              // analytics / telemetry.
              onComplete: () {},
            ),
    );
  }
}

// ── Wapp manifest model ──────────────────────────────────────────────

class WappManifest {
  final String id;

  /// On-disk folder name (last path segment of [dirPath]). Slug-only,
  /// no spaces — used as the key into `installedAppsStorage()` and
  /// `wappDataStorageFor()`.
  final String name;

  /// Human-readable display name. Read from `manifest.description`
  /// (which is the convention used by every hand-written wapp —
  /// short title in `description`, long text in `summary`). Falls
  /// back to the folder name when `description` is blank.
  final String title;

  /// Long-form description. Read from `manifest.summary`, falling
  /// back to `manifest.description`.
  final String description;

  final String kind;
  final String? icon;
  final String dirPath;

  /// Publisher npub extracted from this wapp's `signature.json`
  /// sidecar (if any). Empty means the wapp is unsigned. Populated
  /// during launcher scan via [WappSigningService.readPublisherNpub].
  final String publisherNpub;

  /// Widget IDs this wapp advertises in its `provides.widgets` array.
  /// Empty list means the wapp is not a widget provider. One wapp
  /// can provide any number of widgets.
  final List<String> providedWidgets;

  WappManifest({
    required this.id,
    required this.name,
    required this.title,
    required this.description,
    required this.kind,
    this.icon,
    required this.dirPath,
    this.publisherNpub = '',
    this.providedWidgets = const [],
  });

  factory WappManifest.fromJson(
    Map<String, dynamic> json,
    String dirPath, {
    String publisherNpub = '',
  }) {
    final id = json['id'] as String? ?? '';
    final folderName = dirPath.split(Platform.pathSeparator).last;
    final manifestDescription = json['description'] as String? ?? '';
    final manifestSummary = json['summary'] as String? ?? '';

    // Parse provides.widgets — an array of widget IDs this wapp
    // registers as a provider for. Anything non-string is dropped.
    final provides = json['provides'];
    final widgetsList = provides is Map<String, dynamic>
        ? provides['widgets']
        : null;
    final providedWidgets = widgetsList is List
        ? widgetsList.whereType<String>().toList()
        : const <String>[];

    return WappManifest(
      id: id,
      name: folderName.isNotEmpty ? folderName : id.split('.').last,
      title: manifestDescription.isNotEmpty ? manifestDescription : folderName,
      description: manifestSummary.isNotEmpty
          ? manifestSummary
          : manifestDescription,
      kind: json['kind'] as String? ?? 'app',
      icon: json['icon'] as String?,
      dirPath: dirPath,
      publisherNpub: publisherNpub,
      providedWidgets: providedWidgets,
    );
  }

  /// Map wapp IDs to Material icons. Delegates to the shared
  /// [wappIconFor] so the launcher grid and the wapp Store use the
  /// same visual identity for any given wapp.
  IconData get iconData => wappIconFor('$id $name');

  /// Extract a short text label from `manifest.icon` if one is set.
  /// Path-shaped values (`media/icons/foo.svg`) return null so the
  /// caller falls through to [svgIconPath] instead. Returns up to
  /// the first two grapheme-ish chars so an emoji ZWJ sequence
  /// doesn't get truncated mid-sequence.
  String? get textIcon {
    final raw = icon;
    if (raw == null || raw.isEmpty) return null;
    if (raw.contains('/') || raw.contains('\\')) return null;
    return raw.characters.take(2).toString();
  }

  /// Absolute path to an SVG icon sidecar if one is referenced by
  /// `manifest.icon`. Null when the manifest points elsewhere or
  /// isn't path-shaped at all. The launcher uses this to decide
  /// whether to render the SVG instead of falling back to
  /// [iconData].
  String? get svgIconPath {
    final raw = icon;
    if (raw == null || raw.isEmpty) return null;
    if (!raw.toLowerCase().endsWith('.svg')) return null;
    if (!raw.contains('/') && !raw.contains('\\')) return null;
    return '$dirPath${Platform.pathSeparator}$raw';
  }

  /// Pick a color based on the id hash.
  Color get color {
    final colors = [
      const Color(0xFF0F3460),
      const Color(0xFF533483),
      const Color(0xFF1A5276),
      const Color(0xFF6C3483),
      const Color(0xFF1E8449),
      const Color(0xFFB9770E),
      const Color(0xFF943126),
      const Color(0xFF2E4053),
    ];
    return colors[id.hashCode.abs() % colors.length];
  }
}

// ── Launcher ──────────────────────────────────────────────────────────

class LauncherPage extends StatefulWidget {
  const LauncherPage({super.key});

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage> {
  List<WappManifest>? _wapps;

  @override
  void initState() {
    super.initState();
    _scanArchive();
    // Re-scan whenever the user switches profiles so the grid
    // reflects the new profile's apps/ folder. storage_paths.dart
    // already routes through the active profile, so just triggering
    // a rescan is enough.
    ProfileService.instance.activeProfileNotifier
        .addListener(_onProfileChanged);
  }

  @override
  void dispose() {
    ProfileService.instance.activeProfileNotifier
        .removeListener(_onProfileChanged);
    super.dispose();
  }

  void _onProfileChanged() {
    setState(() => _wapps = null);
    _scanArchive();
  }

  Future<void> _scanArchive() async {
    // Wrap the scan in the task monitor so its startup time and any
    // failures are visible in the same place as every other startup
    // step. This is the canonical "template process method" pattern —
    // every startup task should go through runMonitoredStartup.
    await runMonitoredStartup(
      'launcher.scan',
      'Scan installed wapps',
      _scanArchiveBody,
      description: 'Reads the in-repo install wapp + every installed-apps '
          'subdirectory and parses their manifest.json',
    );
    if (_wapps != null) {
      EventBus().fire(AppStartedEvent());
    }
  }

  Future<void> _scanArchiveBody() async {
    final wapps = <WappManifest>[];
    final seen = <String>{};

    // 1. User-installed wapps first so a forked built-in overrides
    //    the source-tree original — this is how editing a built-in
    //    via the App Creator Projects tab actually takes effect on
    //    the launcher grid.
    final installed = installedAppsStorage();
    if (await installed.directoryExists('')) {
      final entries = await installed.listDirectory('');
      for (final entry in entries) {
        if (!entry.isDirectory) continue;
        final pkg = wappPackageStorage(installed.getAbsolutePath(entry.path));
        await _scanManifest(pkg, wapps, seen);
      }
    }

    // 2. Built-in wapps from the in-repo wapps/archive/ tree. The
    //    seen-set dedup means any id already brought in by a user
    //    install is skipped here. Directory.current.path is OK to
    //    read — it is the runtime CWD, not profile data, and is the
    //    only reliable anchor for relative dev-time paths into the
    //    source.
    final archiveCandidates = [
      '${Directory.current.path}/../wapps/archive',
      '${Directory.current.path}/../../wapps/archive',
    ];
    for (final archivePath in archiveCandidates) {
      final archive = wappPackageStorage(archivePath);
      if (!await archive.directoryExists('')) continue;
      final entries = await archive.listDirectory('');
      for (final entry in entries) {
        if (!entry.isDirectory) continue;
        final pkg = wappPackageStorage(archive.getAbsolutePath(entry.path));
        await _scanManifest(pkg, wapps, seen);
      }
      break; // first archive dir that exists wins
    }

    // Rebuild the widget registry from the fresh scan. Wapps that
    // got uninstalled since last scan stop appearing as providers;
    // newly installed ones immediately become available.
    WidgetRegistry.instance.clear();
    for (final m in wapps) {
      WidgetRegistry.instance.register(m);
    }

    if (mounted) setState(() => _wapps = wapps);
  }

  Future<void> _scanManifest(
      ProfileStorage pkg, List<WappManifest> wapps, Set<String> seen) async {
    final json = await pkg.readJson('manifest.json');
    if (json == null) return;
    try {
      // Backfill signature on the fly when missing — phase 1 of the
      // wapp-signing plan. If the active profile has no nsec yet the
      // sign step is a no-op and publisherNpub stays empty. Signing
      // writes a `signature.json` sidecar into the wapp's directory
      // so built-ins (writable in dev checkouts) and user installs
      // (writable under the profile data dir) both get covered.
      var publisher = await WappSigningService.instance.readPublisherNpub(pkg);
      if (publisher.isEmpty &&
          ProfileService.instance.activeProfile != null) {
        final wappId = (json['id'] as String?) ?? '';
        final wappVersion = (json['version'] as String?) ?? '1.0.0';
        if (wappId.isNotEmpty) {
          final ok = await WappSigningService.instance.signPackage(
            pkg,
            wappId: wappId,
            wappVersion: wappVersion,
          );
          if (ok) {
            publisher =
                await WappSigningService.instance.readPublisherNpub(pkg);
          }
        }
      }
      final manifest = WappManifest.fromJson(
        json,
        pkg.basePath,
        publisherNpub: publisher,
      );
      if (manifest.kind == 'app' && seen.add(manifest.id)) {
        wapps.add(manifest);
      }
    } catch (_) {}
  }

  void _openWapp(WappManifest manifest) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WappPage(
          wappDir: manifest.dirPath,
          title: manifest.title.isNotEmpty ? manifest.title : manifest.name,
        ),
      ),
    ).then((_) => _scanArchive()); // Rescan after returning (new installs)
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const _ProfileSwitcher(),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const IwiSettingsPage()),
              );
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_wapps == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final entries = <_LauncherEntry>[
      for (final wapp in _wapps!)
        _LauncherEntry(
          // Prefer the manifest-declared title; fall back to the
          // folder name so old wapps without a proper description
          // field still show something.
          name: wapp.title.isNotEmpty ? wapp.title : wapp.name,
          icon: wapp.iconData,
          textIcon: wapp.textIcon,
          svgIconPath: wapp.svgIconPath,
          color: wapp.color,
          onTap: () => _openWapp(wapp),
        ),
    ];

    if (entries.isEmpty) {
      return const Center(
        child: Text('No wapps found', style: TextStyle(color: Colors.grey)),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 120,
          mainAxisSpacing: 20,
          crossAxisSpacing: 20,
        ),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final e = entries[index];
          return _AppIcon(
            name: e.name,
            icon: e.icon,
            textIcon: e.textIcon,
            svgIconPath: e.svgIconPath,
            color: e.color,
            onTap: e.onTap,
          );
        },
      ),
    );
  }
}

class _LauncherEntry {
  final String name;
  final IconData icon;
  final String? textIcon;
  final String? svgIconPath;
  final Color color;
  final VoidCallback onTap;

  const _LauncherEntry({
    required this.name,
    required this.icon,
    required this.color,
    required this.onTap,
    this.textIcon,
    this.svgIconPath,
  });
}

/// Compact AppBar title showing the active profile's display name
/// with a popup menu to switch to any other profile or add a new one.
/// Listens directly to [ProfileService.instance.activeProfileNotifier]
/// so the label updates the instant `switchTo` fires.
class _ProfileSwitcher extends StatefulWidget {
  const _ProfileSwitcher();

  @override
  State<_ProfileSwitcher> createState() => _ProfileSwitcherState();
}

class _ProfileSwitcherState extends State<_ProfileSwitcher> {
  @override
  void initState() {
    super.initState();
    ProfileService.instance.activeProfileNotifier.addListener(_refresh);
  }

  @override
  void dispose() {
    ProfileService.instance.activeProfileNotifier.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _addProfileFlow() async {
    // Push the welcome page as a modal to generate / import another
    // profile. On completion, saveAndActivate fires the notifier and
    // this widget rebuilds with the fresh display name. canCancel
    // adds a back arrow and leaves the user inside the current
    // profile if they bail out.
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WelcomePage(
          canCancel: true,
          onComplete: () => Navigator.of(context).pop(),
        ),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = ProfileService.instance;
    final active = service.activeProfile;
    final label = active?.displayName ?? 'No profile';
    final cs = Theme.of(context).colorScheme;

    return PopupMenuButton<String>(
      tooltip: 'Switch profile',
      offset: const Offset(0, 40),
      onSelected: (value) async {
        if (value == '__add__') {
          await _addProfileFlow();
        } else {
          await service.switchTo(value);
        }
      },
      itemBuilder: (ctx) => [
        for (final p in service.profiles)
          PopupMenuItem<String>(
            value: p.id,
            child: Row(
              children: [
                Icon(
                  p.id == active?.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: cs.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(p.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(p.callsign,
                          style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                              fontFamily: 'monospace')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: '__add__',
          child: Row(
            children: [
              Icon(Icons.person_add, size: 18),
              SizedBox(width: 8),
              Text('Add profile…'),
            ],
          ),
        ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.badge, size: 20, color: cs.primary),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const Icon(Icons.arrow_drop_down, size: 20),
        ],
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  final String name;
  final IconData icon;
  final String? textIcon;
  final String? svgIconPath;
  final Color color;
  final VoidCallback onTap;

  const _AppIcon({
    required this.name,
    required this.icon,
    required this.color,
    required this.onTap,
    this.textIcon,
    this.svgIconPath,
  });

  @override
  Widget build(BuildContext context) {
    // Icon resolution order: SVG file (picked by the user in App
    // Creator and persisted as media/icons/icon.svg), then a short
    // text label (emoji / single char), then the Material icon
    // guess from [WappManifest.iconData]. All three cases render
    // as white glyphs inside the 56x56 coloured tile: SVGs get a
    // srcIn colour filter that repaints every non-transparent pixel
    // white (SVGs in the wild are authored in black or dark
    // strokes), and emoji glyphs — which ignore TextStyle.color
    // because they come from a colour font — are wrapped in a
    // ColorFiltered so their alpha mask is repainted white too.
    const whiteFilter = ColorFilter.mode(Colors.white, BlendMode.srcIn);
    final hasSvg = svgIconPath != null && svgIconPath!.isNotEmpty;
    final hasText = textIcon != null && textIcon!.isNotEmpty;
    Widget inner;
    if (hasSvg) {
      inner = Padding(
        padding: const EdgeInsets.all(8),
        child: SvgPicture.file(
          File(svgIconPath!),
          fit: BoxFit.contain,
          colorFilter: whiteFilter,
          placeholderBuilder: (_) => const SizedBox.shrink(),
        ),
      );
    } else if (hasText) {
      inner = ColorFiltered(
        colorFilter: whiteFilter,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              textIcon!,
              style: const TextStyle(
                fontSize: 32,
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    } else {
      inner = Icon(icon, size: 28, color: Colors.white);
    }
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: inner,
          ),
          const SizedBox(height: 6),
          Text(
            name,
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ── Iwi Settings ─────────────────────────────────────────────────────

class IwiSettingsPage extends StatefulWidget {
  const IwiSettingsPage({super.key});

  @override
  State<IwiSettingsPage> createState() => _IwiSettingsPageState();
}

class _IwiSettingsPageState extends State<IwiSettingsPage> {
  PreferencesService? _prefs;
  String? _dataDir;
  List<_WappDataEntry> _wappDataEntries = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await PreferencesService.instance();
    final defaultPath = wappsDataStorage(prefs).basePath;
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _dataDir = prefs.wappDataDir ?? defaultPath;
    });
    await _refreshWappData();
  }

  Future<void> _refreshWappData() async {
    final dataDir = _dataDir;
    if (dataDir == null) return;
    final storage = FilesystemProfileStorage(dataDir);
    if (!await storage.directoryExists('')) {
      if (mounted) setState(() => _wappDataEntries = []);
      return;
    }
    final subdirs = await storage.listDirectory('');
    final entries = <_WappDataEntry>[];
    for (final sub in subdirs) {
      if (!sub.isDirectory) continue;
      var size = 0;
      try {
        final children =
            await storage.listDirectory(sub.path, recursive: true);
        for (final c in children) {
          if (!c.isDirectory) size += c.size ?? 0;
        }
      } catch (_) {}
      entries.add(_WappDataEntry(
        sub.name,
        storage.getAbsolutePath(sub.path),
        size,
      ));
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    if (mounted) setState(() => _wappDataEntries = entries);
  }

  /// Human-readable description of the current locale pref for the
  /// Settings subtitle. Shows "Auto — pt_PT" when no explicit choice
  /// has been made (so the user can see what "Auto" resolved to),
  /// and just the explicit locale otherwise.
  String _localeSubtitle() {
    final p = _prefs;
    if (p == null) return '';
    final explicit = p.localePreference;
    final effective = p.activeLocale();
    if (explicit == null || explicit.isEmpty) return 'Auto — $effective';
    return effective;
  }

  /// Persist the new locale preference and fire [LocaleChangedEvent]
  /// so every open [WappPage] reloads its translations. The empty
  /// string value ("") resets to "Auto" (follows the OS).
  void _onLocaleChanged(String? value) {
    final p = _prefs;
    if (p == null) return;
    p.localePreference = (value == null || value.isEmpty) ? null : value;
    setState(() {});
    EventBus().fire(LocaleChangedEvent(locale: p.activeLocale()));
  }

  Future<void> _pickDirectory() async {
    final defaultPath =
        _prefs == null ? '' : wappsDataStorage(_prefs!).basePath;
    final controller = TextEditingController(text: _dataDir);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wapp Data Directory'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Each wapp stores its settings and files in a subfolder here, '
              'named after the wapp ID.',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: 'Directory path',
                filled: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.folder_open),
                  tooltip: 'Reset to default',
                  onPressed: () => controller.text = defaultPath,
                ),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && _prefs != null) {
      // Create the directory through the abstraction so the same code path
      // will work later with encrypted/IndexedDB backends.
      await FilesystemProfileStorage(result).createDirectory('');
      _prefs!.wappDataDir = result;
      if (mounted) setState(() => _dataDir = result);
      await _refreshWappData();
    }
  }

  Future<void> _openDataDir() async {
    final dataDir = _dataDir;
    if (dataDir == null) return;
    // Make sure it exists (via the abstraction), then hand the absolute
    // path to the platform's external file manager.
    await FilesystemProfileStorage(dataDir).createDirectory('');
    if (Platform.isLinux) {
      await Process.run('xdg-open', [dataDir]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [dataDir]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [dataDir]);
    }
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _prefs == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // ── Language ──
                Text('Language',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )),
                const SizedBox(height: 4),
                Text(
                  'Controls how wapps resolve their @key translation '
                  'sentinels. "Auto" follows the operating system.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
                  ),
                  color: cs.surfaceContainerLow,
                  child: ListTile(
                    leading: const Icon(Icons.language),
                    title: const Text('Language'),
                    subtitle: Text(
                      _localeSubtitle(),
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                    trailing: DropdownButton<String>(
                      value: _prefs?.localePreference ?? '',
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: '', child: Text('Auto')),
                        DropdownMenuItem(
                            value: 'en', child: Text('English')),
                        DropdownMenuItem(
                            value: 'pt', child: Text('Português')),
                        DropdownMenuItem(
                            value: 'de', child: Text('Deutsch')),
                        DropdownMenuItem(
                            value: 'fr', child: Text('Français')),
                        DropdownMenuItem(
                            value: 'es', child: Text('Español')),
                      ],
                      onChanged: _onLocaleChanged,
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // ── Data Directory ──
                Text('Storage',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )),
                const SizedBox(height: 4),
                Text(
                  'Where wapp settings, downloads, and user files are stored.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
                  ),
                  color: cs.surfaceContainerLow,
                  child: ListTile(
                    leading: const Icon(Icons.folder),
                    title: const Text('Wapp Data Directory'),
                    subtitle: Text(
                      _dataDir ?? 'Not set',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.open_in_new),
                          tooltip: 'Open in file explorer',
                          onPressed: _openDataDir,
                        ),
                        const Icon(Icons.edit),
                      ],
                    ),
                    onTap: _pickDirectory,
                  ),
                ),
                const SizedBox(height: 24),

                // ── Per-wapp data ──
                Text('Wapp Data',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )),
                const SizedBox(height: 4),
                Text(
                  'Each subfolder contains settings and files for one wapp.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                ..._buildWappDataList(cs),
              ],
            ),
    );
  }

  List<Widget> _buildWappDataList(ColorScheme cs) {
    final entries = _wappDataEntries;
    if (entries.isEmpty) {
      return [
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
          ),
          color: cs.surfaceContainerLow,
          child: const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('No wapp data yet'),
            subtitle: Text('Data folders are created when a wapp first runs.'),
          ),
        ),
      ];
    }

    return [
      Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < entries.length; i++) ...[
              ListTile(
                leading: const Icon(Icons.extension),
                title: Text(entries[i].name),
                subtitle: Text(
                  _humanSize(entries[i].size),
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
                trailing: IconButton(
                  icon: Icon(Icons.delete_outline, color: cs.error),
                  tooltip: 'Delete wapp data',
                  onPressed: () => _confirmDelete(entries[i]),
                ),
              ),
              if (i < entries.length - 1)
                Divider(
                    height: 1,
                    thickness: 1,
                    color: cs.outlineVariant.withAlpha(50)),
            ],
          ],
        ),
      ),
    ];
  }

  Future<void> _confirmDelete(_WappDataEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${entry.name}?'),
        content: Text(
            'This will permanently delete all settings and files for '
            '"${entry.name}" (${_humanSize(entry.size)}).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        // Split the absolute path into parent + leaf and delete via the
        // abstraction so the same code path works with non-filesystem
        // backends in the future.
        final sep = Platform.pathSeparator;
        final slashIdx = entry.path.lastIndexOf(sep);
        if (slashIdx > 0) {
          final parent = entry.path.substring(0, slashIdx);
          final leaf = entry.path.substring(slashIdx + 1);
          await FilesystemProfileStorage(parent)
              .deleteDirectory(leaf, recursive: true);
        }
        await _refreshWappData();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete: $e')),
          );
        }
      }
    }
  }
}

class _WappDataEntry {
  final String name;
  final String path;
  final int size;
  _WappDataEntry(this.name, this.path, this.size);
}

// ── Wapp Runner (generic WASM module runner) ─────────────────────────

class WappRunnerPage extends StatefulWidget {
  final String? title;
  final String? wasmPath;

  const WappRunnerPage({super.key, this.title, this.wasmPath});

  @override
  State<WappRunnerPage> createState() => _WappRunnerPageState();
}

class _WappRunnerPageState extends State<WappRunnerPage> {
  final _engine = WappEngine();
  final _msgController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _tickTimer;
  String _status = 'Not loaded';

  @override
  void initState() {
    super.initState();
    // Auto-load if a wasm path was provided
    if (widget.wasmPath != null) {
      _loadWasmFromFile(widget.wasmPath!);
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _engine.dispose();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadWasmFromFile(String path) async {
    setState(() => _status = 'Loading...');
    try {
      final sep = Platform.pathSeparator;
      final slashIdx = path.lastIndexOf(sep);
      if (slashIdx < 0) {
        setState(() => _status = 'Invalid path: $path');
        return;
      }
      final dir = path.substring(0, slashIdx);
      final file = path.substring(slashIdx + 1);
      final bytes = await FilesystemProfileStorage(dir).readBytes(file);
      if (bytes == null) {
        setState(() => _status = 'wasm not found: $path');
        return;
      }
      await _startEngine(bytes);
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _loadWasmFromAsset() async {
    setState(() => _status = 'Loading...');
    try {
      final bytes = await rootBundle.load('assets/hello_world.wasm');
      await _startEngine(bytes.buffer.asUint8List());
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _startEngine(Uint8List bytes) async {
    await _engine.load(bytes);
    _engine.init();

    final interval = _engine.tickIntervalMs;
    _tickTimer = Timer.periodic(Duration(milliseconds: interval), (_) {
      _engine.tick();
      _engine.handleEvent();
      setState(() {});
      _scrollToBottom();
    });

    setState(() => _status = 'Running (tick every ${interval}ms)');
    _scrollToBottom();
  }

  void _sendMessage() {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;
    _engine.sendMessage(text);
    _engine.handleEvent();
    _msgController.clear();
    setState(() {});
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Color _levelColor(int level) {
    return switch (level) {
      0 => Colors.grey,
      1 => Colors.lightBlueAccent,
      2 => Colors.orange,
      3 => Colors.redAccent,
      _ => Colors.white,
    };
  }

  @override
  Widget build(BuildContext context) {
    final outbox = _engine.drainOutbox();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? 'Wapp Runner'),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: _engine.isLoaded ? Colors.green.withAlpha(30) : Colors.grey.withAlpha(30),
            child: Row(
              children: [
                Icon(
                  _engine.isLoaded ? Icons.check_circle : Icons.circle_outlined,
                  size: 14,
                  color: _engine.isLoaded ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_status, style: const TextStyle(fontSize: 13)),
                ),
                if (!_engine.isLoaded && widget.wasmPath == null)
                  TextButton.icon(
                    onPressed: _loadWasmFromAsset,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Load hello_world.wasm'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _engine.logs.length + outbox.length,
              itemBuilder: (context, index) {
                if (index < _engine.logs.length) {
                  final log = _engine.logs[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: '[${log.levelName}] ',
                          style: TextStyle(
                            color: _levelColor(log.level),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            fontFamily: 'monospace',
                          ),
                        ),
                        TextSpan(
                          text: log.message,
                          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                        ),
                      ]),
                    ),
                  );
                } else {
                  final msg = outbox[index - _engine.logs.length];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Text(
                      '<< $msg',
                      style: const TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: Colors.amber,
                      ),
                    ),
                  );
                }
              },
            ),
          ),
          if (_engine.isLoaded)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.grey.shade800)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgController,
                      decoration: const InputDecoration(
                        hintText: 'Send message to module...',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
