import 'dart:io';

import 'package:flutter/services.dart';

/// Reads file paths from the native clipboard when available.
class ClipboardFileService {
  ClipboardFileService._();

  static final ClipboardFileService instance = ClipboardFileService._();

  static const MethodChannel _channel = MethodChannel('arya/clipboard_files');

  Future<List<String>> getClipboardFilePaths() async {
    if (!Platform.isMacOS) return const [];

    try {
      final dynamic rawPaths = await _channel.invokeMethod<dynamic>(
        'getClipboardFilePaths',
      );
      if (rawPaths is List) {
        return rawPaths.whereType<String>().where((p) => p.isNotEmpty).toList();
      }
    } on PlatformException {
      // Gracefully fall back to regular text paste.
    }
    return const [];
  }
}
