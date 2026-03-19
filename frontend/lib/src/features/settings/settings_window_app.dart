import 'package:arya_app/src/features/settings/settings_workspace.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

class SettingsWindowApp extends StatefulWidget {
  const SettingsWindowApp({super.key, required this.windowController});

  final WindowController windowController;

  @override
  State<SettingsWindowApp> createState() => _SettingsWindowAppState();
}

class _SettingsWindowAppState extends State<SettingsWindowApp> {
  @override
  void initState() {
    super.initState();
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      if (call.method == 'windowType') {
        return 'settings';
      }
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arya Settings',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF1A212A),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
      ),
      home: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Container(
                height: 58,
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: const BoxDecoration(
                  color: Color(0xFF2A323B),
                  border: Border(
                    bottom: BorderSide(color: Color(0xFF38414B), width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    const Text(
                      'Settings',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => widget.windowController.hide(),
                      tooltip: 'Close',
                      icon: const Icon(Icons.close, color: Color(0xFFA9B2BE)),
                    ),
                  ],
                ),
              ),
              const Expanded(child: SettingsWorkspace()),
            ],
          ),
        ),
      ),
    );
  }
}
