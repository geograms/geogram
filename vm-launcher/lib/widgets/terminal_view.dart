import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' as xterm;

import '../services/vm_controller.dart';

class TerminalView extends StatefulWidget {
  final VmController controller;

  const TerminalView({super.key, required this.controller});

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> {
  late final xterm.Terminal _terminal;
  late final xterm.TerminalController _termController;
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    _terminal = xterm.Terminal(maxLines: 10000);
    _termController = xterm.TerminalController();

    // QEMU serial console output → terminal
    widget.controller.outputStream.listen((data) {
      _terminal.write(utf8.decode(data, allowMalformed: true));
    });

    // Keystrokes → QEMU stdin (serial console)
    _terminal.onOutput = (data) {
      widget.controller.writeInput(data);
    };
  }

  @override
  void dispose() {
    _termController.dispose();
    super.dispose();
  }

  void _onStop() async {
    setState(() => _stopping = true);
    await widget.controller.stopVm();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyQ,
            control: true, shift: true): _onStop,
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            Positioned.fill(
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: EdgeInsets.zero,
                  viewPadding: EdgeInsets.zero,
                  viewInsets: EdgeInsets.zero,
                ),
                child: Container(
                  color: Colors.black,
                  child: xterm.TerminalView(
                  _terminal,
                  controller: _termController,
                  autofocus: true,
                  cursorType: xterm.TerminalCursorType.block,
                  padding: EdgeInsets.zero,
                  textScaler: TextScaler.noScaling,
                  textStyle: xterm.TerminalStyle(
                    fontSize: 20,
                    fontFamily: 'Ubuntu Sans Mono',
                    fontFamilyFallback: const [
                      'Ubuntu Mono',
                      'DejaVu Sans Mono',
                      'Consolas',
                      'monospace',
                    ],
                  ),
                  theme: const xterm.TerminalTheme(
                    cursor: Color(0xFFFFFFFF),
                    selection: Color(0x80FFFFFF),
                    foreground: Color(0xFFD4D4D4),
                    background: Color(0xFF000000),
                    black: Color(0xFF000000),
                    red: Color(0xFFCD3131),
                    green: Color(0xFF0DBC79),
                    yellow: Color(0xFFE5E510),
                    blue: Color(0xFF2472C8),
                    magenta: Color(0xFFBC3FBC),
                    cyan: Color(0xFF11A8CD),
                    white: Color(0xFFE5E5E5),
                    brightBlack: Color(0xFF666666),
                    brightRed: Color(0xFFF14C4C),
                    brightGreen: Color(0xFF23D18B),
                    brightYellow: Color(0xFFF5F543),
                    brightBlue: Color(0xFF3B8EEA),
                    brightMagenta: Color(0xFFD670D6),
                    brightCyan: Color(0xFF29B8DB),
                    brightWhite: Color(0xFFFFFFFF),
                    searchHitBackground: Color(0xFFFFDF5D),
                    searchHitBackgroundCurrent: Color(0xFFFF9632),
                    searchHitForeground: Color(0xFF000000),
                  ),
                ),
              ),
            ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: _stopping
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.withAlpha(100)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.red,
                            ),
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Shutting down...',
                            style: TextStyle(color: Colors.red, fontSize: 12),
                          ),
                        ],
                      ),
                    )
                  : Opacity(
                      opacity: 0.4,
                      child: IconButton(
                        icon:
                            const Icon(Icons.stop_circle, color: Colors.red),
                        tooltip: 'Stop VM (Ctrl+Shift+Q)',
                        onPressed: _onStop,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
