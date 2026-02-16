/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'notification_service.dart';
import 'log_service.dart';

/// System tray service for desktop platforms.
///
/// - **Linux**: Pure D-Bus StatusNotifierItem (zero system dependencies).
/// - **Windows**: `tray_manager` package for native tray icon + menu.
///
/// On unsupported platforms, [isSupported] returns false and all operations
/// are no-ops — the window closes normally instead of hiding to tray.
class TrayService with TrayListener {
  static final TrayService _instance = TrayService._internal();
  factory TrayService() => _instance;
  TrayService._internal();

  bool _initialized = false;
  bool _windowHidden = false;
  bool _trayManagerInitialized = false;

  // Linux D-Bus fields
  DBusClient? _client;
  _StatusNotifierItemObject? _sniObject;
  _DBusMenuObject? _menuObject;
  StreamSubscription? _watcherSubscription;

  /// Whether the window is currently hidden to the tray
  bool get isWindowHidden => _windowHidden;

  /// Whether this platform supports system tray
  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
       defaultTargetPlatform == TargetPlatform.windows);

  /// Initialize system tray icon and context menu
  Future<void> initialize() async {
    if (_initialized) return;
    if (!isSupported) {
      _initialized = true;
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.linux) {
      await _initializeLinux();
    } else if (defaultTargetPlatform == TargetPlatform.windows) {
      await _initializeWindows();
    }
  }

  // ---------------------------------------------------------------------------
  // Windows — tray_manager
  // ---------------------------------------------------------------------------

  Future<void> _initializeWindows() async {
    try {
      final iconPath = _resolveWindowsIconPath();
      await trayManager.setIcon(iconPath);
      await trayManager.setToolTip('Geogram');

      final menu = Menu(items: [
        MenuItem(key: 'show', label: 'Show Geogram'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit'),
      ]);
      await trayManager.setContextMenu(menu);

      trayManager.addListener(this);
      _trayManagerInitialized = true;
      _initialized = true;
      LogService().log('TrayService: Initialized tray_manager (Windows)');
    } catch (e) {
      LogService().log('TrayService: Failed to initialize tray_manager: $e');
      _initialized = true; // Avoid retries — app works without tray
    }
  }

  /// Resolve the .ico path for the Windows tray icon
  String _resolveWindowsIconPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$exeDir/data/tray_icon.ico',
      '$exeDir/data/flutter_assets/assets/geogram_icon_transparent.png',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return candidates.first;
  }

  // TrayListener callbacks (Windows)

  @override
  void onTrayIconMouseDown() {
    if (_windowHidden) {
      restoreFromTray();
    } else {
      hideToTray();
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        restoreFromTray();
        break;
      case 'quit':
        _quit();
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Linux — D-Bus StatusNotifierItem
  // ---------------------------------------------------------------------------

  Future<void> _initializeLinux() async {
    try {
      // 1. Open session bus
      _client = DBusClient.session();

      // 2. Load & decode icon PNG → ARGB pixel data for IconPixmap
      final iconBytes = await _loadIconBytes();

      // 3. Create D-Bus objects
      _menuObject = _DBusMenuObject(
        onShowClicked: () => restoreFromTray(),
        onQuitClicked: () => _quit(),
      );
      _sniObject = _StatusNotifierItemObject(
        iconArgbBytes: iconBytes,
        menuPath: _menuObject!.path,
        onActivate: () {
          if (_windowHidden) {
            restoreFromTray();
          } else {
            hideToTray();
          }
        },
      );

      // 4. Register objects on the bus
      await _client!.registerObject(_sniObject!);
      await _client!.registerObject(_menuObject!);

      // 5. Request a unique bus name for this SNI
      final busName = 'org.kde.StatusNotifierItem-$pid-1';
      try {
        await _client!.requestName(busName);
      } catch (e) {
        LogService().log('TrayService: Could not claim bus name $busName: $e');
        // Continue anyway — some hosts don't require it
      }

      // 6. Register with StatusNotifierWatcher
      await _registerWithWatcher();

      // 7. Watch for watcher restarts (e.g. panel crash/restart)
      _watchForWatcherRestart();

      _initialized = true;
      LogService().log('TrayService: Initialized D-Bus StatusNotifierItem');
    } catch (e) {
      LogService().log('TrayService: Failed to initialize: $e');
      _initialized = true; // Avoid retries — app works without tray
    }
  }

  /// Load icon PNG and convert to ARGB pixel data (48×48)
  Future<Uint8List?> _loadIconBytes() {
    return compute(_decodeIcon, _resolveLinuxIconPath());
  }

  String _resolveLinuxIconPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$exeDir/data/tray_icon.png',
      '$exeDir/data/app_icon.png',
      '$exeDir/data/flutter_assets/assets/geogram_icon_transparent.png',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return candidates.first; // will fail gracefully later
  }

  /// Decode PNG → 48×48 ARGB bytes (runs in isolate via compute)
  static Uint8List? _decodeIcon(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final raw = file.readAsBytesSync();
      var decoded = img.decodeImage(raw);
      if (decoded == null) return null;

      // Resize to 48×48
      if (decoded.width != 48 || decoded.height != 48) {
        decoded = img.copyResize(decoded, width: 48, height: 48);
      }

      // Convert to ARGB32 (network byte order = big-endian: A R G B)
      final pixels = Uint8List(48 * 48 * 4);
      int offset = 0;
      for (int y = 0; y < 48; y++) {
        for (int x = 0; x < 48; x++) {
          final pixel = decoded.getPixel(x, y);
          final a = pixel.a.toInt();
          final r = pixel.r.toInt();
          final g = pixel.g.toInt();
          final b = pixel.b.toInt();
          pixels[offset++] = a;
          pixels[offset++] = r;
          pixels[offset++] = g;
          pixels[offset++] = b;
        }
      }
      return pixels;
    } catch (_) {
      return null;
    }
  }

  /// Register our item with org.kde.StatusNotifierWatcher
  Future<void> _registerWithWatcher() async {
    if (_client == null) return;
    try {
      final watcher = DBusRemoteObject(
        _client!,
        name: 'org.kde.StatusNotifierWatcher',
        path: DBusObjectPath('/StatusNotifierWatcher'),
      );
      await watcher.callMethod(
        'org.kde.StatusNotifierWatcher',
        'RegisterStatusNotifierItem',
        [DBusString(_sniObject!.path.value)],
      );
      LogService().log('TrayService: Registered with StatusNotifierWatcher');
    } catch (e) {
      LogService().log(
        'TrayService: StatusNotifierWatcher unavailable ($e). '
        'Hint: On GNOME, install the AppIndicator/KStatusNotifierItem extension.',
      );
    }
  }

  /// Re-register if the SNI host (panel) restarts
  void _watchForWatcherRestart() {
    if (_client == null) return;
    try {
      final stream = DBusSignalStream(
        _client!,
        sender: 'org.freedesktop.DBus',
        interface: 'org.freedesktop.DBus',
        name: 'NameOwnerChanged',
      );
      _watcherSubscription = stream.listen((signal) {
        if (signal.values.length >= 3) {
          final busName = (signal.values[0] as DBusString).value;
          final newOwner = (signal.values[2] as DBusString).value;
          if (busName == 'org.kde.StatusNotifierWatcher' &&
              newOwner.isNotEmpty) {
            LogService().log('TrayService: Watcher reappeared, re-registering');
            _registerWithWatcher();
          }
        }
      });
    } catch (e) {
      LogService().log('TrayService: Could not watch for watcher restarts: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Shared public API
  // ---------------------------------------------------------------------------

  /// Hide the window to the system tray
  Future<void> hideToTray() async {
    if (!_initialized || !isSupported) return;

    // Check user setting
    final settings = NotificationService().getSettings();
    if (!settings.minimizeToTray) return;

    try {
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
      _windowHidden = true;
      LogService().log('TrayService: Window hidden to tray');
    } catch (e) {
      LogService().log('TrayService: Error hiding to tray: $e');
    }
  }

  /// Hide the window to the system tray unconditionally.
  /// Unlike [hideToTray], this bypasses the user's "Minimize to Tray" setting.
  /// Used by the --minimized CLI flag which is an explicit directive from autostart.
  Future<void> hideToTrayDirect() async {
    if (!_initialized || !isSupported) return;

    try {
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
      _windowHidden = true;
      LogService().log('TrayService: Window hidden to tray (direct)');
    } catch (e) {
      LogService().log('TrayService: Error hiding to tray (direct): $e');
    }
  }

  /// Restore the window from the system tray
  Future<void> restoreFromTray() async {
    if (!_initialized || !isSupported) return;

    try {
      _windowHidden = false;
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
      LogService().log('TrayService: Window restored from tray');
    } catch (e) {
      LogService().log('TrayService: Error restoring from tray: $e');
    }
  }

  /// Destroy the tray and close the app
  Future<void> _quit() async {
    try {
      dispose();
      await windowManager.destroy();
    } catch (e) {
      LogService().log('TrayService: Error during quit: $e');
      exit(0);
    }
  }

  void dispose() {
    // Clean up Windows tray_manager
    if (_trayManagerInitialized) {
      trayManager.removeListener(this);
      trayManager.destroy();
      _trayManagerInitialized = false;
    }

    // Clean up Linux D-Bus
    if (_initialized && defaultTargetPlatform == TargetPlatform.linux) {
      _watcherSubscription?.cancel();
      _watcherSubscription = null;
      try {
        if (_sniObject != null) _client?.unregisterObject(_sniObject!);
        if (_menuObject != null) _client?.unregisterObject(_menuObject!);
      } catch (_) {}
      _client?.close();
      _client = null;
    }
  }
}

// =============================================================================
// D-Bus objects for StatusNotifierItem protocol (Linux only)
// =============================================================================

/// org.kde.StatusNotifierItem — the tray icon itself
class _StatusNotifierItemObject extends DBusObject {
  _StatusNotifierItemObject({
    required this.iconArgbBytes,
    required this.menuPath,
    required this.onActivate,
  }) : super(DBusObjectPath('/org/geogram/StatusNotifierItem'));

  final Uint8List? iconArgbBytes;
  final DBusObjectPath menuPath;
  final VoidCallback onActivate;

  static const _interface = 'org.kde.StatusNotifierItem';

  // Icon as DBus struct: array of (width, height, ARGB-bytes)
  DBusValue get _iconPixmapValue {
    if (iconArgbBytes == null) {
      return DBusArray(
        DBusSignature('(iiay)'),
        [],
      );
    }
    return DBusArray(
      DBusSignature('(iiay)'),
      [
        DBusStruct([
          DBusInt32(48),
          DBusInt32(48),
          DBusArray.byte(iconArgbBytes!),
        ]),
      ],
    );
  }

  // Tooltip: (icon-name, icon-pixmap[], title, body)
  DBusValue get _toolTipValue {
    return DBusStruct([
      DBusString(''), // icon name (empty = use pixmap)
      DBusArray(DBusSignature('(iiay)'), []), // icon pixmap for tooltip
      DBusString('Geogram'), // title
      DBusString(''), // body
    ]);
  }

  @override
  List<DBusIntrospectInterface> introspect() => [
        DBusIntrospectInterface(
          _interface,
          methods: [
            DBusIntrospectMethod('Activate', args: [
              DBusIntrospectArgument(
                  DBusSignature.int32, DBusArgumentDirection.in_,
                  name: 'x'),
              DBusIntrospectArgument(
                  DBusSignature.int32, DBusArgumentDirection.in_,
                  name: 'y'),
            ]),
            DBusIntrospectMethod('ContextMenu', args: [
              DBusIntrospectArgument(
                  DBusSignature.int32, DBusArgumentDirection.in_,
                  name: 'x'),
              DBusIntrospectArgument(
                  DBusSignature.int32, DBusArgumentDirection.in_,
                  name: 'y'),
            ]),
            DBusIntrospectMethod('SecondaryActivate', args: [
              DBusIntrospectArgument(
                  DBusSignature.int32, DBusArgumentDirection.in_,
                  name: 'x'),
              DBusIntrospectArgument(
                  DBusSignature.int32, DBusArgumentDirection.in_,
                  name: 'y'),
            ]),
          ],
          properties: [
            DBusIntrospectProperty('Category', DBusSignature.string,
                access: DBusPropertyAccess.read),
            DBusIntrospectProperty('Id', DBusSignature.string,
                access: DBusPropertyAccess.read),
            DBusIntrospectProperty('Title', DBusSignature.string,
                access: DBusPropertyAccess.read),
            DBusIntrospectProperty('Status', DBusSignature.string,
                access: DBusPropertyAccess.read),
            DBusIntrospectProperty(
                'IconPixmap', DBusSignature('a(iiay)'),
                access: DBusPropertyAccess.read),
            DBusIntrospectProperty('ToolTip', DBusSignature('(sa(iiay)ss)'),
                access: DBusPropertyAccess.read),
            DBusIntrospectProperty('Menu', DBusSignature.objectPath,
                access: DBusPropertyAccess.read),
            DBusIntrospectProperty('ItemIsMenu', DBusSignature.boolean,
                access: DBusPropertyAccess.read),
            DBusIntrospectProperty('IconName', DBusSignature.string,
                access: DBusPropertyAccess.read),
            DBusIntrospectProperty('WindowId', DBusSignature.int32,
                access: DBusPropertyAccess.read),
          ],
          signals: [
            DBusIntrospectSignal('NewIcon'),
            DBusIntrospectSignal('NewToolTip'),
            DBusIntrospectSignal('NewStatus', args: [
              DBusIntrospectArgument(
                  DBusSignature.string, DBusArgumentDirection.out,
                  name: 'status'),
            ]),
          ],
        ),
        DBusIntrospectInterface('org.freedesktop.DBus.Properties'),
        DBusIntrospectInterface('org.freedesktop.DBus.Introspectable'),
      ];

  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
        _interface: {
          'Category': DBusString('Communications'),
          'Id': DBusString('geogram'),
          'Title': DBusString('Geogram'),
          'Status': DBusString('Active'),
          'IconPixmap': _iconPixmapValue,
          'ToolTip': _toolTipValue,
          'Menu': DBusObjectPath(menuPath.value),
          'ItemIsMenu': DBusBoolean(false),
          'IconName': DBusString(''),
          'WindowId': DBusInt32(0),
        },
      };

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface == _interface) {
      switch (call.name) {
        case 'Activate':
          onActivate();
          return DBusMethodSuccessResponse();
        case 'ContextMenu':
          // Context menu is handled via dbusmenu (Menu property)
          return DBusMethodSuccessResponse();
        case 'SecondaryActivate':
          return DBusMethodSuccessResponse();
      }
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface == _interface) {
      final props = interfacesAndProperties[_interface]!;
      if (props.containsKey(name)) {
        return DBusGetPropertyResponse(props[name]!);
      }
    }
    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface == _interface) {
      return DBusGetAllPropertiesResponse(
          interfacesAndProperties[_interface]!);
    }
    return DBusGetAllPropertiesResponse({});
  }
}

/// com.canonical.dbusmenu — right-click context menu
class _DBusMenuObject extends DBusObject {
  _DBusMenuObject({
    required this.onShowClicked,
    required this.onQuitClicked,
  }) : super(DBusObjectPath('/org/geogram/MenuBar'));

  final VoidCallback onShowClicked;
  final VoidCallback onQuitClicked;

  static const _interface = 'com.canonical.dbusmenu';

  // Menu layout: root(0) → Show Geogram(1) / separator(2) / Quit(3)
  // GetLayout returns (revision, layout) where layout is (id, properties, children)
  DBusValue _buildLayout() {
    // Each item: (int32 id, dict<string,variant> properties, array<variant> children)
    final showItem = DBusStruct([
      DBusInt32(1),
      DBusDict.stringVariant({
        'label': DBusString('Show Geogram'),
        'enabled': DBusBoolean(true),
        'visible': DBusBoolean(true),
      }),
      DBusArray(DBusSignature.variant, []),
    ]);

    final separator = DBusStruct([
      DBusInt32(2),
      DBusDict.stringVariant({
        'type': DBusString('separator'),
        'enabled': DBusBoolean(true),
        'visible': DBusBoolean(true),
      }),
      DBusArray(DBusSignature.variant, []),
    ]);

    final quitItem = DBusStruct([
      DBusInt32(3),
      DBusDict.stringVariant({
        'label': DBusString('Quit'),
        'enabled': DBusBoolean(true),
        'visible': DBusBoolean(true),
      }),
      DBusArray(DBusSignature.variant, []),
    ]);

    // Root item containing children
    return DBusStruct([
      DBusInt32(0),
      DBusDict.stringVariant({}),
      DBusArray(DBusSignature.variant, [
        DBusVariant(showItem),
        DBusVariant(separator),
        DBusVariant(quitItem),
      ]),
    ]);
  }

  @override
  List<DBusIntrospectInterface> introspect() => [
        DBusIntrospectInterface(
          _interface,
          methods: [
            DBusIntrospectMethod('GetLayout', args: [
              DBusIntrospectArgument(
                  DBusSignature.int32, DBusArgumentDirection.in_,
                  name: 'parentId'),
              DBusIntrospectArgument(
                  DBusSignature.int32, DBusArgumentDirection.in_,
                  name: 'recursionDepth'),
              DBusIntrospectArgument(
                  DBusSignature.array(DBusSignature.string),
                  DBusArgumentDirection.in_,
                  name: 'propertyNames'),
              DBusIntrospectArgument(
                  DBusSignature.uint32, DBusArgumentDirection.out,
                  name: 'revision'),
              DBusIntrospectArgument(
                  // (ia{sv}av) — the layout struct
                  DBusSignature('(ia{sv}av)'),
                  DBusArgumentDirection.out,
                  name: 'layout'),
            ]),
            DBusIntrospectMethod('GetGroupProperties', args: [
              DBusIntrospectArgument(
                  DBusSignature.array(DBusSignature.int32),
                  DBusArgumentDirection.in_,
                  name: 'ids'),
              DBusIntrospectArgument(
                  DBusSignature.array(DBusSignature.string),
                  DBusArgumentDirection.in_,
                  name: 'propertyNames'),
              DBusIntrospectArgument(
                  DBusSignature('a(ia{sv})'), DBusArgumentDirection.out,
                  name: 'properties'),
            ]),
            DBusIntrospectMethod('Event', args: [
              DBusIntrospectArgument(
                  DBusSignature.int32, DBusArgumentDirection.in_,
                  name: 'id'),
              DBusIntrospectArgument(
                  DBusSignature.string, DBusArgumentDirection.in_,
                  name: 'eventId'),
              DBusIntrospectArgument(
                  DBusSignature.variant, DBusArgumentDirection.in_,
                  name: 'data'),
              DBusIntrospectArgument(
                  DBusSignature.uint32, DBusArgumentDirection.in_,
                  name: 'timestamp'),
            ]),
            DBusIntrospectMethod('AboutToShow', args: [
              DBusIntrospectArgument(
                  DBusSignature.int32, DBusArgumentDirection.in_,
                  name: 'id'),
              DBusIntrospectArgument(
                  DBusSignature.boolean, DBusArgumentDirection.out,
                  name: 'needUpdate'),
            ]),
          ],
          properties: [
            DBusIntrospectProperty('Version', DBusSignature.uint32,
                access: DBusPropertyAccess.read),
            DBusIntrospectProperty('TextDirection', DBusSignature.string,
                access: DBusPropertyAccess.read),
            DBusIntrospectProperty('Status', DBusSignature.string,
                access: DBusPropertyAccess.read),
          ],
          signals: [
            DBusIntrospectSignal('LayoutUpdated', args: [
              DBusIntrospectArgument(
                  DBusSignature.uint32, DBusArgumentDirection.out,
                  name: 'revision'),
              DBusIntrospectArgument(
                  DBusSignature.int32, DBusArgumentDirection.out,
                  name: 'parent'),
            ]),
          ],
        ),
        DBusIntrospectInterface('org.freedesktop.DBus.Properties'),
        DBusIntrospectInterface('org.freedesktop.DBus.Introspectable'),
      ];

  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
        _interface: {
          'Version': DBusUint32(3),
          'TextDirection': DBusString('ltr'),
          'Status': DBusString('normal'),
        },
      };

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface == _interface) {
      switch (call.name) {
        case 'GetLayout':
          return DBusMethodSuccessResponse([
            DBusUint32(1), // revision
            _buildLayout(),
          ]);

        case 'GetGroupProperties':
          // Return empty array — hosts typically use GetLayout instead
          return DBusMethodSuccessResponse([
            DBusArray(DBusSignature('(ia{sv})'), []),
          ]);

        case 'Event':
          if (call.values.isNotEmpty) {
            final id = (call.values[0] as DBusInt32).value;
            final eventId = call.values.length > 1
                ? (call.values[1] as DBusString).value
                : '';
            if (eventId == 'clicked') {
              switch (id) {
                case 1:
                  onShowClicked();
                  break;
                case 3:
                  onQuitClicked();
                  break;
              }
            }
          }
          return DBusMethodSuccessResponse();

        case 'AboutToShow':
          return DBusMethodSuccessResponse([DBusBoolean(false)]);
      }
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface == _interface) {
      final props = interfacesAndProperties[_interface]!;
      if (props.containsKey(name)) {
        return DBusGetPropertyResponse(props[name]!);
      }
    }
    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface == _interface) {
      return DBusGetAllPropertiesResponse(
          interfacesAndProperties[_interface]!);
    }
    return DBusGetAllPropertiesResponse({});
  }
}
