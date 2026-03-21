import 'package:arya_app/src/app/arya_app.dart';
import 'package:arya_app/src/core/window_helpers.dart';
import 'package:flutter/material.dart';

export 'package:arya_app/src/app/arya_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await configureDesktopWindow();
  runApp(const AryaApp());
}
