import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/vm_state.dart';
import 'download_service.dart';
import 'qemu_service.dart';
import 'vm_config_service.dart';

class VmController extends ChangeNotifier {
  VmState _state = const VmState();
  VmState get state => _state;

  final _config = VmConfigService();
  final _download = DownloadService();
  final _qemu = QemuService();

  DownloadService get download => _download;
  QemuService get qemu => _qemu;

  /// Output stream — QEMU serial console.
  final _outputController = StreamController<List<int>>.broadcast();
  Stream<List<int>> get outputStream => _outputController.stream;

  /// Input goes to QEMU stdin (serial console).
  void writeInput(String data) {
    _qemu.write(data);
  }

  StreamSubscription? _qemuStdout;
  StreamSubscription? _qemuStderr;

  Future<void> initialize() async {
    await _config.initialize();

    if (await _config.isSetupComplete()) {
      _setState(_state.copyWith(status: VmStatus.ready));
    } else {
      _setState(_state.copyWith(status: VmStatus.setup));
    }
  }

  Future<void> startDownload() async {
    _setState(_state.copyWith(
      status: VmStatus.setup,
      downloadStage: DownloadStage.qemu,
      downloadProgress: 0.0,
    ));

    _download.progress.addListener(_onDownloadProgress);

    try {
      await _download.downloadAndSetup();

      if (await _config.isSetupComplete()) {
        _setState(_state.copyWith(status: VmStatus.ready));
      }
    } catch (e) {
      _setState(_state.copyWith(
        status: VmStatus.error,
        errorMessage: 'Download failed',
        errorDetails: e.toString(),
      ));
    } finally {
      _download.progress.removeListener(_onDownloadProgress);
    }
  }

  void cancelDownload() {
    _download.cancel();
    _setState(_state.copyWith(status: VmStatus.setup, downloadProgress: 0.0));
  }

  Future<void> startVm() async {
    try {
      await _qemu.start();
    } catch (e) {
      _setState(_state.copyWith(
        status: VmStatus.error,
        errorMessage: 'Failed to start QEMU',
        errorDetails: e.toString(),
      ));
      return;
    }

    // Pipe QEMU stdout/stderr to terminal
    _qemuStdout = _qemu.stdout?.listen((data) {
      _outputController.add(data);
    });
    _qemuStderr = _qemu.stderr?.listen((data) {
      _outputController.add(data);
    });

    _setState(_state.copyWith(status: VmStatus.connected));
  }

  Future<void> stopVm() async {
    _cancelStreams();
    _qemu.kill();
    _setState(_state.copyWith(status: VmStatus.ready));
  }

  void _cancelStreams() {
    _qemuStdout?.cancel();
    _qemuStderr?.cancel();
  }

  void retry() {
    if (_state.status == VmStatus.error) {
      initialize();
    }
  }

  String get memory => _config.memory;
  set memory(String value) {
    _config.memory = value;
    notifyListeners();
  }

  int get cpus => _config.cpus;
  set cpus(int value) {
    _config.cpus = value;
    notifyListeners();
  }

  void _onDownloadProgress() {
    _setState(_state.copyWith(downloadProgress: _download.progress.value));
  }

  void _setState(VmState newState) {
    _state = newState;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelStreams();
    _outputController.close();
    _qemu.kill();
    super.dispose();
  }
}
