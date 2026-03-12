import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class VmConfigService {
  static final VmConfigService _instance = VmConfigService._();
  factory VmConfigService() => _instance;
  VmConfigService._();

  late SharedPreferences _prefs;

  /// If the vm/ folder is next to the executable, use it directly.
  String? _localVmDir;

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _localVmDir = await _findLocalVmDir();
  }

  bool get hasLocalVm => _localVmDir != null;

  /// Look for vm/ folder relative to the executable (sibling directory).
  Future<String?> _findLocalVmDir() async {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    // Walk up from the bundle dir to find the repo vm/ folder.
    // In dev: exe is in build/linux/x64/release/bundle/ or debug/bundle/
    // In release alongside vm/: exe is next to vm/
    for (var dir = exeDir; ; dir = p.dirname(dir)) {
      final candidate = p.join(dir, 'vm');
      final qemu = File(_qemuPathIn(candidate));
      final image = File(p.join(candidate, 'geogram-dev.qcow2'));
      if (await qemu.exists() && await image.exists()) {
        return candidate;
      }
      if (dir == p.dirname(dir)) break; // filesystem root
    }
    return null;
  }

  String _qemuPathIn(String vmDir) {
    final platform = Platform.isWindows ? 'windows' : 'linux';
    final binary = Platform.isWindows
        ? 'qemu-system-x86_64.exe'
        : 'qemu-system-x86_64';
    return p.join(vmDir, 'bin', platform, binary);
  }

  String get dataDir {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ?? '';
      return p.join(appData, 'GeogramVM');
    }
    return p.join(Platform.environment['HOME'] ?? '/tmp', '.geogram-vm');
  }

  String get qemuPath {
    if (_localVmDir != null) return _qemuPathIn(_localVmDir!);
    final platform = Platform.isWindows ? 'windows' : 'linux';
    final binary = Platform.isWindows
        ? 'qemu-system-x86_64.exe'
        : 'qemu-system-x86_64';
    return p.join(dataDir, 'qemu', platform, binary);
  }

  String get imagePath {
    if (_localVmDir != null) return p.join(_localVmDir!, 'geogram-dev.qcow2');
    return p.join(dataDir, 'images', 'geogram-dev.qcow2');
  }

  String get memory => _prefs.getString('memory') ?? '4G';
  set memory(String value) => _prefs.setString('memory', value);

  int get cpus => _prefs.getInt('cpus') ?? _defaultCpus;
  set cpus(int value) => _prefs.setInt('cpus', value);

  int get _defaultCpus {
    final count = Platform.numberOfProcessors ~/ 2;
    return count < 2 ? 2 : count;
  }

  Future<bool> isSetupComplete() async {
    if (_localVmDir != null) return true;
    final qemuExists = await File(qemuPath).exists();
    final imageExists = await File(imagePath).exists();
    return qemuExists && imageExists;
  }

  Future<void> ensureDirectories() async {
    final qDir = p.dirname(qemuPath);
    await Directory(qDir).create(recursive: true);
    await Directory(p.dirname(imagePath)).create(recursive: true);
  }
}
