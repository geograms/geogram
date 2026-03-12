import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'models/vm_state.dart';
import 'services/vm_controller.dart';
import 'widgets/connecting_view.dart';
import 'widgets/error_view.dart';
import 'widgets/ready_view.dart';
import 'widgets/setup_view.dart';
import 'widgets/terminal_view.dart';

class VmLauncherApp extends StatelessWidget {
  const VmLauncherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Geogram Dev VM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const _VmHome(),
    );
  }
}

class _VmHome extends StatefulWidget {
  const _VmHome();

  @override
  State<_VmHome> createState() => _VmHomeState();
}

class _VmHomeState extends State<_VmHome> with WindowListener {
  final _controller = VmController();

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _controller.addListener(_onStateChange);
    _controller.initialize();
  }

  void _onStateChange() {
    if (mounted) setState(() {});
  }

  @override
  void onWindowClose() {
    _controller.qemu.kill();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _controller.removeListener(_onStateChange);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _buildView(),
      ),
    );
  }

  Widget _buildView() {
    switch (_controller.state.status) {
      case VmStatus.setup:
        return SetupView(controller: _controller);
      case VmStatus.ready:
        return ReadyView(controller: _controller);
      case VmStatus.starting:
        return ConnectingView(controller: _controller);
      case VmStatus.connected:
        return TerminalView(controller: _controller);
      case VmStatus.error:
        return ErrorView(controller: _controller);
    }
  }
}
