import 'dart:io';

import 'package:arya_app/src/core/app_constants.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

bool get supportsDesktopWindowControls {
  if (isFlutterTest || kIsWeb) {
    return false;
  }
  if (Platform.environment.containsKey('FLUTTER_TEST') ||
      Platform.environment.containsKey('DART_TEST')) {
    return false;
  }
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}

Future<void> configureDesktopWindow() async {
  if (!supportsDesktopWindowControls) {
    return;
  }

  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: compactWindowSize,
    minimumSize: compactWindowSize,
    center: false,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    backgroundColor: Colors.transparent,
  );

  await windowManager.waitUntilReadyToShow(options);
  await windowManager.setAsFrameless();
  await windowManager.setAlwaysOnTop(true);
  await windowManager.setResizable(false);
  await windowManager.setMinimizable(false);
  await windowManager.setMaximizable(false);
  await windowManager.setHasShadow(false);
  await windowManager.setSkipTaskbar(true);

  if (Platform.isMacOS) {
    await windowManager.setVisibleOnAllWorkspaces(
      true,
      visibleOnFullScreen: true,
    );
    await windowManager.focus();
  }

  await positionWindowAtBottomRight();
  await windowManager.show();
  await windowManager.focus();
}

Future<void> positionWindowAtBottomRight() async {
  final display = await screenRetriever.getPrimaryDisplay();
  final visiblePosition = display.visiblePosition ?? Offset.zero;
  final visibleSize = display.visibleSize ?? display.size;

  final target = Offset(
    visiblePosition.dx +
        visibleSize.width -
        compactWindowSize.width -
        windowMarginRight,
    visiblePosition.dy +
        visibleSize.height -
        compactWindowSize.height -
        windowMarginBottom,
  );

  await windowManager.setPosition(target);
}

Future<void> resizeWindowKeepingBottomRightAnchor(Size nextSize) async {
  final currentPosition = await windowManager.getPosition();
  final currentSize = await windowManager.getSize();

  final nextPosition = Offset(
    currentPosition.dx + currentSize.width - nextSize.width,
    currentPosition.dy + currentSize.height - nextSize.height,
  );

  await windowManager.setBounds(
    Rect.fromLTWH(
      nextPosition.dx,
      nextPosition.dy,
      nextSize.width,
      nextSize.height,
    ),
    animate: true,
  );
}

Future<Map<String, dynamic>?> getCurrentWindowDisplayRegion() async {
  if (!supportsDesktopWindowControls) {
    return null;
  }
  try {
    final windowPosition = await windowManager.getPosition();
    final windowSize = await windowManager.getSize();
    final centerX = windowPosition.dx + (windowSize.width / 2);
    final centerY = windowPosition.dy + (windowSize.height / 2);

    final displays = await screenRetriever.getAllDisplays();
    Display? selected;
    for (final display in displays) {
      final pos = display.visiblePosition ?? Offset.zero;
      final size = display.visibleSize ?? display.size;
      final right = pos.dx + size.width;
      final bottom = pos.dy + size.height;
      final containsCenter = centerX >= pos.dx &&
          centerX < right &&
          centerY >= pos.dy &&
          centerY < bottom;
      if (containsCenter) {
        selected = display;
        break;
      }
    }
    selected ??= await screenRetriever.getPrimaryDisplay();
    final regionPos = selected.visiblePosition ?? Offset.zero;
    final regionSize = selected.visibleSize ?? selected.size;
    final scaleFactor = selected.scaleFactor ?? 1.0;
    return {
      'left': regionPos.dx.round(),
      'top': regionPos.dy.round(),
      'width': regionSize.width.round(),
      'height': regionSize.height.round(),
      'scaleFactor': scaleFactor,
    };
  } catch (_) {
    return null;
  }
}
