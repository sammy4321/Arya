import 'dart:io';

import 'package:arya_app/src/core/window_helpers.dart';
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// Rectangular region in logical screen coordinates for targeted capture.
class CaptureRegion {
  const CaptureRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;
}

/// Service for capturing screenshots while optionally hiding the assistant window.
class ScreenshotService {
  ScreenshotService._();

  static final ScreenshotService instance = ScreenshotService._();

  bool _isCapturing = false;

  bool get isCapturing => _isCapturing;

  /// Captures a screenshot.
  ///
  /// When [region] is provided, only that logical-pixel rectangle is captured
  /// (using `screencapture -R` on macOS). This is critical for multi-monitor
  /// setups where the default `screencapture` stitches all displays into one
  /// wide image, making coordinates completely wrong after resize.
  ///
  /// When [hideWindow] is true (default), the assistant window is hidden before
  /// capture and shown after.
  ///
  /// When [hideWindow] is false, the capture happens without touching the
  /// window at all — no hide, no show, no focus stealing.
  ///
  /// The resulting image is resized to [region.width] logical pixels so that
  /// pixel coordinates in the image match mouse coordinates 1:1 within the
  /// captured region.
  Future<String?> captureFullScreen({
    bool hideWindow = true,
    CaptureRegion? region,
  }) async {
    if (_isCapturing) return null;

    _isCapturing = true;

    try {
      if (hideWindow && supportsDesktopWindowControls) {
        await windowManager.hide();
        await Future.delayed(const Duration(milliseconds: 220));
      }

      final screenshotPath = await _captureToTempFile(region: region);
      if (screenshotPath != null && region != null && Platform.isMacOS) {
        await _resizeToLogical(screenshotPath, region.width);
      }
      return screenshotPath;
    } finally {
      if (hideWindow && supportsDesktopWindowControls) {
        await windowManager.show();
      }
      _isCapturing = false;
    }
  }

  Future<void> _resizeToLogical(String path, int logicalWidth) async {
    try {
      final result = await Process.run('sips', [
        '--resampleWidth', '$logicalWidth', path,
      ]);
      debugPrint('[Screenshot] sips resize to $logicalWidth exit=${result.exitCode}');
    } catch (e) {
      debugPrint('[Screenshot] sips resize failed: $e');
    }
  }

  Future<String?> _captureToTempFile({CaptureRegion? region}) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filePath = '${Directory.systemTemp.path}/arya_capture_$timestamp.png';

    if (Platform.isMacOS) {
      return _captureOnMacOS(filePath, region: region);
    }

    if (Platform.isLinux) {
      return _captureOnLinux(filePath);
    }

    if (Platform.isWindows) {
      return _captureOnWindows(filePath);
    }

    return null;
  }

  Future<String?> _captureOnMacOS(String filePath, {CaptureRegion? region}) async {
    final args = <String>['-x'];
    if (region != null) {
      args.addAll(['-R', '${region.x},${region.y},${region.width},${region.height}']);
    }
    args.add(filePath);

    debugPrint('[Screenshot] screencapture ${args.join(' ')}');
    final result = await Process.run('screencapture', args);
    if (result.exitCode == 0) {
      return filePath;
    }
    debugPrint('[Screenshot] screencapture failed exit=${result.exitCode}');
    return null;
  }

  Future<String?> _captureOnLinux(String filePath) async {
    final linuxCommands = <List<String>>[
      ['grim', filePath],
      ['gnome-screenshot', '-f', filePath],
      ['scrot', filePath],
    ];

    for (final command in linuxCommands) {
      try {
        final result = await Process.run(command.first, command.sublist(1));
        if (result.exitCode == 0) {
          return filePath;
        }
      } catch (_) {
        // Try next available capture utility.
      }
    }
    return null;
  }

  Future<String?> _captureOnWindows(String filePath) async {
    final escapedPath = filePath.replaceAll("'", "''");
    final script = '''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
\$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
\$bitmap = New-Object System.Drawing.Bitmap \$bounds.Width, \$bounds.Height
\$graphics = [System.Drawing.Graphics]::FromImage(\$bitmap)
\$graphics.CopyFromScreen(\$bounds.Location, [System.Drawing.Point]::Empty, \$bounds.Size)
\$bitmap.Save('$escapedPath', [System.Drawing.Imaging.ImageFormat]::Png)
\$graphics.Dispose()
\$bitmap.Dispose()
''';
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      script,
    ]);
    if (result.exitCode == 0) {
      return filePath;
    }
    return null;
  }
}
