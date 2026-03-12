import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'vm_config_service.dart';

class QemuService {
  Process? _process;

  bool get isRunning => _process != null;

  Stream<List<int>>? get stdout => _process?.stdout;
  Stream<List<int>>? get stderr => _process?.stderr;

  Future<void> start() async {
    if (_process != null) return;

    final config = VmConfigService();
    final args = _buildArgs(config);

    _process = await Process.start(config.qemuPath, args);
  }

  /// Write input to QEMU's stdin (serial console).
  void write(String data) {
    _process?.stdin.add(utf8.encode(data));
  }

  /// Kill QEMU immediately. No graceful shutdown — just die.
  void kill() {
    _process?.kill(ProcessSignal.sigkill);
    _process = null;
  }

  List<String> _buildArgs(VmConfigService config) {
    return [
      '-m', config.memory,
      '-smp', '${config.cpus}',
      ..._accelArgs(),
      '-drive', 'file=${config.imagePath},format=qcow2,if=virtio',
      '-netdev', 'user,id=net0',
      '-device', 'virtio-net-pci,netdev=net0',
      '-nographic',
    ];
  }

  List<String> _accelArgs() {
    if (Platform.isLinux) {
      if (File('/dev/kvm').existsSync()) {
        return ['-enable-kvm', '-cpu', 'host'];
      }
      return ['-cpu', 'qemu64'];
    }

    if (Platform.isWindows) {
      try {
        final result = Process.runSync(
          VmConfigService().qemuPath,
          ['-accel', 'help'],
        );
        if (result.stdout.toString().contains('whpx')) {
          return ['-accel', 'whpx', '-cpu', 'max'];
        }
      } catch (_) {}
      return ['-accel', 'tcg'];
    }

    return ['-cpu', 'qemu64'];
  }
}
