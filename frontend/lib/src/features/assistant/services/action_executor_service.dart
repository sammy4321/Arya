import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nutdart/nutdart.dart';

/// Executes desktop actions (mouse, keyboard) using nutdart FFI plugin.
/// Text input uses a pre-compiled Swift binary for fast, correct Unicode
/// key-event injection on macOS (nutdart's CGEvent path has pointer bugs).
class ActionExecutorService {
  ActionExecutorService._();
  static final ActionExecutorService instance = ActionExecutorService._();

  String? _typeTextBinaryPath;

  /// PID of the target application. Set before executing actions so that
  /// clicks and keystrokes are directed to the correct process.
  int? targetAppPid;

  /// Activate the target application so it receives keyboard focus.
  /// CGEvent clicks from our process don't transfer keyboard focus
  /// to the clicked window — we must do it explicitly. Also needed
  /// before accessibility parsing so macOS returns the full UI tree.
  Future<void> activateTargetApp() async {
    final pid = targetAppPid;
    if (pid == null || !Platform.isMacOS) return;
    try {
      await Process.run('osascript', [
        '-e',
        'tell application "System Events" to set frontmost of '
            '(first process whose unix id is $pid) to true',
      ]).timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } catch (e) {
      debugPrint('[Executor] activateTargetApp($pid) failed: $e');
    }
  }

  Future<ActionResult> executeStep(Map<String, dynamic> step) async {
    final action = (step['action'] as String? ?? '').toLowerCase().trim();
    final args = step['args'] as Map<String, dynamic>? ?? {};
    debugPrint('[Executor] action=$action args=$args');

    switch (action) {
      case 'move_mouse':
        return _moveMouse(args);
      case 'click':
        return _click(args);
      case 'type_text':
        return _typeText(args);
      case 'press_keys':
        return _pressKeys(args);
      case 'wait':
        return _wait(args);
      default:
        return ActionResult(ok: false, detail: 'Unsupported action: $action');
    }
  }

  Future<ActionResult> _moveMouse(Map<String, dynamic> args) async {
    try {
      final x = (args['x'] as num?)?.toInt() ?? 0;
      final y = (args['y'] as num?)?.toInt() ?? 0;
      final duration = (args['duration'] as num?)?.toDouble() ?? 0.3;

      final before = Mouse.getPosition();
      final steps = (duration * 60).clamp(1, 120).toInt();
      final dx = (x - before.x) / steps;
      final dy = (y - before.y) / steps;
      final sleepMs = ((duration * 1000) / steps).round().clamp(1, 50);

      for (var i = 1; i <= steps; i++) {
        Mouse.moveTo(
          (before.x + dx * i).round(),
          (before.y + dy * i).round(),
        );
        await Future<void>.delayed(Duration(milliseconds: sleepMs));
      }

      Mouse.moveTo(x, y);
      final after = Mouse.getPosition();
      return ActionResult(
        ok: true,
        detail: 'Moved from (${before.x},${before.y}) to (${after.x},${after.y})',
      );
    } catch (e) {
      return ActionResult(ok: false, detail: 'move_mouse failed: $e');
    }
  }

  Future<ActionResult> _click(Map<String, dynamic> args) async {
    try {
      await activateTargetApp();

      if (args.containsKey('x') && args.containsKey('y')) {
        final x = (args['x'] as num?)?.toInt() ?? 0;
        final y = (args['y'] as num?)?.toInt() ?? 0;
        Mouse.moveTo(x, y);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      final button = (args['button'] as String? ?? 'left').toLowerCase();
      final clicks = (args['clicks'] as num?)?.toInt() ?? 1;

      final mouseButton =
          button == 'right' ? MouseButton.right : MouseButton.left;

      for (var i = 0; i < clicks.clamp(1, 3); i++) {
        Mouse.click(mouseButton);
        if (i < clicks - 1) {
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
      }

      final pos = Mouse.getPosition();
      return ActionResult(
        ok: true,
        detail: 'Clicked $button at (${pos.x},${pos.y})',
      );
    } catch (e) {
      return ActionResult(ok: false, detail: 'click failed: $e');
    }
  }

  /// Types text using a Swift CGEvent script on macOS. This correctly handles
  /// Unicode via CGEventKeyboardSetUnicodeString — the same API nutdart tries
  /// to use but gets wrong due to C pointer bugs that crash the app.
  /// The Swift version does it correctly and runs as a subprocess.
  Future<ActionResult> _typeText(Map<String, dynamic> args) async {
    try {
      final text = args['text'] as String? ?? '';
      if (text.isEmpty) {
        return ActionResult(ok: true, detail: 'No text to type');
      }

      await activateTargetApp();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      debugPrint('[Executor] type_text: typing "${text.length} chars" via Swift CGEvent');

      if (Platform.isMacOS) {
        final ok = await _typeViaSwiftCGEvent(text);
        if (ok) {
          debugPrint('[Executor] type_text: Swift CGEvent succeeded');
          return ActionResult(ok: true, detail: 'Typed ${text.length} chars');
        }
        debugPrint('[Executor] type_text: Swift CGEvent failed, trying AppleScript fallback');
        final ok2 = await _typeViaAppleScript(text);
        if (ok2) {
          debugPrint('[Executor] type_text: AppleScript succeeded');
          return ActionResult(ok: true, detail: 'Typed ${text.length} chars');
        }
        debugPrint('[Executor] type_text: all methods failed');
        return ActionResult(ok: false, detail: 'type_text: all macOS methods failed');
      }

      // Non-macOS fallback: nutdart (may have issues)
      Keyboard.type(text);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return ActionResult(ok: true, detail: 'Typed ${text.length} chars');
    } catch (e) {
      debugPrint('[Executor] type_text failed: $e');
      return ActionResult(ok: false, detail: 'type_text failed: $e');
    }
  }

  static const _typeTextSwiftSource = r'''
import Cocoa

let text = CommandLine.arguments[1]
let src = CGEventSource(stateID: .hidSystemState)

for char in text {
    let s = String(char)
    var utf16 = Array(s.utf16)
    let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
    let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
    keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    keyDown.post(tap: CGEventTapLocation.cghidEventTap)
    keyUp.post(tap: CGEventTapLocation.cghidEventTap)
    Thread.sleep(forTimeInterval: 0.02)
}
''';

  static const _typeTextBinaryName = 'arya_type_text_v2';

  Future<String?> _ensureTypeTextBinary() async {
    if (_typeTextBinaryPath != null) return _typeTextBinaryPath;
    try {
      final dir = Directory.systemTemp;
      final bin = '${dir.path}/$_typeTextBinaryName';
      if (File(bin).existsSync()) {
        _typeTextBinaryPath = bin;
        return bin;
      }
      final src = '${dir.path}/$_typeTextBinaryName.swift';
      File(src).writeAsStringSync(_typeTextSwiftSource);
      final res = await Process.run(
        'swiftc', ['-O', '-o', bin, src],
      ).timeout(const Duration(seconds: 30));
      if (res.exitCode == 0) {
        _typeTextBinaryPath = bin;
        debugPrint('[Executor] Compiled type_text binary: $bin');
        return bin;
      }
      debugPrint('[Executor] swiftc failed: ${(res.stderr as String).trim()}');
      return null;
    } catch (e) {
      debugPrint('[Executor] _ensureTypeTextBinary error: $e');
      return null;
    }
  }

  /// Pre-compile the type_text Swift binary so subsequent calls are instant.
  Future<void> warmUp() async {
    if (Platform.isMacOS) await _ensureTypeTextBinary();
  }

  Future<bool> _typeViaSwiftCGEvent(String text) async {
    final binary = await _ensureTypeTextBinary();
    if (binary == null) return false;

    try {
      final result = await Process.run(binary, [text])
          .timeout(const Duration(seconds: 10));
      debugPrint('[Executor] type_text binary exit=${result.exitCode} '
          'stderr=${(result.stderr as String).trim()}');
      return result.exitCode == 0;
    } catch (e) {
      debugPrint('[Executor] type_text binary exception: $e');
      return false;
    }
  }

  Future<bool> _typeViaAppleScript(String text) async {
    final escaped = text
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"');
    final script = 'tell application "System Events" to keystroke "$escaped"';
    try {
      final result = await Process.run(
        'osascript', ['-e', script],
      ).timeout(const Duration(seconds: 10));
      debugPrint('[Executor] AppleScript exit=${result.exitCode} '
          'stderr=${(result.stderr as String).trim()}');
      return result.exitCode == 0;
    } catch (e) {
      debugPrint('[Executor] AppleScript exception: $e');
      return false;
    }
  }

  /// Safe solo keys that can be pressed without a modifier.
  static const _allowedSoloKeys = {
    'enter', 'return', 'escape', 'esc', 'tab', 'space', 'backspace', 'delete',
    'up', 'down', 'left', 'right', 'arrowup', 'arrowdown', 'arrowleft', 'arrowright',
    'home', 'end', 'pageup', 'pagedown',
  };

  /// Key combos that are explicitly blocked because they can kill the app,
  /// close windows, or cause destructive system-level actions.
  static const _blockedCombos = {
    'cmd+q', 'cmd+w', 'cmd+c', 'cmd+z', 'cmd+h', 'cmd+m',
    'cmd+shift+q', 'cmd+option+esc',
    'ctrl+c', 'ctrl+z', 'ctrl+q', 'ctrl+w',
    'alt+f4',
    'cmd+`',  'cmd+tab', 'ctrl+tab',
    'cmd+shift+p', 'ctrl+shift+p',
    'cmd+n', 'ctrl+n',
    'cmd+t', 'ctrl+t',
    'cmd+shift+n', 'ctrl+shift+n',
  };

  Future<ActionResult> _pressKeys(Map<String, dynamic> args) async {
    try {
      await activateTargetApp();

      var keys = args['keys'];
      if (keys is String) keys = [keys];
      if (keys is! List || keys.isEmpty) {
        return ActionResult(ok: false, detail: 'No keys provided');
      }

      final keyNames = keys.cast<String>().map((k) => k.toLowerCase()).toList();

      final comboStr = keyNames.join('+');
      if (_blockedCombos.contains(comboStr)) {
        debugPrint('[Executor] *** BLOCKED key combo: $comboStr');
        return ActionResult(
          ok: false,
          detail: 'Blocked: $comboStr is not allowed (could close the app or cause damage)',
        );
      }

      if (keyNames.length == 1) {
        final key = keyNames.first;
        if (!_allowedSoloKeys.contains(key) && key.length != 1) {
          return ActionResult(
            ok: false,
            detail: 'Blocked: solo key "$key" is not in the allowed list',
          );
        }
        _tapSingleKey(key);
      } else {
        final modifiers = <String>[];
        String? mainKey;
        for (final k in keyNames) {
          if (_isModifier(k)) {
            modifiers.add(k);
          } else {
            mainKey = k;
          }
        }
        if (mainKey != null && modifiers.isNotEmpty) {
          Keyboard.tapWithModifiers(
            _toNutKey(mainKey),
            modifiers.map(_toNutModifier).toList(),
          );
        } else {
          for (final k in keyNames) {
            _tapSingleKey(k);
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        }
      }

      return ActionResult(
        ok: true,
        detail: 'Pressed ${keyNames.join(' + ')}',
      );
    } catch (e) {
      return ActionResult(ok: false, detail: 'press_keys failed: $e');
    }
  }

  Future<ActionResult> _wait(Map<String, dynamic> args) async {
    final seconds = ((args['seconds'] as num?)?.toDouble() ?? 1.0).clamp(0.1, 10.0);
    await Future<void>.delayed(Duration(milliseconds: (seconds * 1000).round()));
    return ActionResult(ok: true, detail: 'Waited ${seconds.toStringAsFixed(1)}s');
  }

  void _tapSingleKey(String key) {
    Keyboard.tap(_toNutKey(key));
  }

  bool _isModifier(String key) {
    return {'cmd', 'command', 'ctrl', 'control', 'shift', 'alt', 'option', 'meta', 'super', 'win'}
        .contains(key);
  }

  String _toNutModifier(String key) {
    switch (key) {
      case 'cmd':
      case 'command':
      case 'meta':
      case 'super':
      case 'win':
        return 'cmd';
      case 'ctrl':
      case 'control':
        return 'ctrl';
      case 'alt':
      case 'option':
        return 'alt';
      case 'shift':
        return 'shift';
      default:
        return key;
    }
  }

  String _toNutKey(String key) {
    switch (key) {
      case 'enter':
      case 'return':
        return 'enter';
      case 'esc':
      case 'escape':
        return 'escape';
      case 'del':
      case 'delete':
        return 'delete';
      case 'backspace':
        return 'backspace';
      case 'tab':
        return 'tab';
      case 'space':
        return 'space';
      case 'up':
      case 'arrowup':
        return 'up';
      case 'down':
      case 'arrowdown':
        return 'down';
      case 'left':
      case 'arrowleft':
        return 'left';
      case 'right':
      case 'arrowright':
        return 'right';
      case 'home':
        return 'home';
      case 'end':
        return 'end';
      case 'pageup':
        return 'pageup';
      case 'pagedown':
        return 'pagedown';
      default:
        return key;
    }
  }
}

class ActionResult {
  const ActionResult({required this.ok, required this.detail});

  final bool ok;
  final String detail;
}
