import 'package:arya_app/src/app/arya_app.dart';
import 'package:arya_app/src/core/window_helpers.dart';
import 'package:arya_app/src/features/settings/settings_window_app.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

export 'package:arya_app/src/app/arya_app.dart';

Future<void> main([List<String> args = const []]) async {
  WidgetsFlutterBinding.ensureInitialized();

  final subWindowLaunch = parseSubWindowLaunch(args);
  if (subWindowLaunch != null) {
    runApp(
      SettingsWindowApp(
        windowController: WindowController.fromWindowId(
          subWindowLaunch.windowId,
        ),
      ),
    );
    return;
  }

  await configureDesktopWindow();
  runApp(const AryaApp());
}
