import 'dart:convert';
import 'dart:io';

import 'package:arya_app/src/features/assistant/services/screenshot_service.dart';
import 'package:flutter/foundation.dart';

/// A parsed UI element from the screen's accessibility tree.
class UIElement {
  const UIElement({
    required this.id,
    required this.role,
    this.title = '',
    this.value = '',
    this.description = '',
    this.parentId,
    this.depth = 0,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int id;
  final String role;
  final String title;
  final String value;
  final String description;
  final int? parentId;
  final int depth;
  final int x;
  final int y;
  final int width;
  final int height;

  int get centerX => x + width ~/ 2;
  int get centerY => y + height ~/ 2;

  String get label {
    if (title.isNotEmpty) return title;
    if (description.isNotEmpty) return description;
    if (value.isNotEmpty) return value;
    return '';
  }

  /// Compact single-line representation for LLM prompts.
  String toPromptLine() {
    final parts = <String>['[$id] $role'];
    if (title.isNotEmpty) parts.add('"$title"');
    if (value.isNotEmpty) parts.add('value="$value"');
    if (description.isNotEmpty && description != title) {
      parts.add('desc="$description"');
    }
    parts.add('depth=$depth');
    if (parentId != null) parts.add('parent=$parentId');
    parts.add('@ ($centerX, $centerY)');
    parts.add('size=${width}x$height');
    return parts.join(' ');
  }

  factory UIElement.fromJson(Map<String, dynamic> json) {
    return UIElement(
      id: _intFrom(json['id']) ?? 0,
      role: json['role'] as String? ?? '',
      title: json['title'] as String? ?? '',
      value: json['value'] as String? ?? '',
      description: json['desc'] as String? ?? '',
      parentId: _intFrom(json['parent_id']),
      depth: _intFrom(json['depth']) ?? 0,
      x: _intFrom(json['x']) ?? 0,
      y: _intFrom(json['y']) ?? 0,
      width: _intFrom(json['w']) ?? 0,
      height: _intFrom(json['h']) ?? 0,
    );
  }

  static int? _intFrom(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }
}

/// Formats a list of [UIElement]s into a text block suitable for LLM prompts.
String formatUIElementsForPrompt(List<UIElement> elements) {
  if (elements.isEmpty) return '';
  final lines = elements.map((e) => e.toPromptLine()).join('\n');
  final graphLines = _formatHierarchyGraph(elements);
  return '''
## UI Elements visible on screen
Elements are listed with center coordinates (use these for precise clicking).
Format: [id] Role "label" depth=D parent=P @ (center_x, center_y) size=WxH

$lines

## UI hierarchy graph (parent -> children)
$graphLines''';
}

String _formatHierarchyGraph(List<UIElement> elements) {
  if (elements.isEmpty) return '[empty]';
  final byParent = <int?, List<int>>{};
  for (final el in elements) {
    byParent.putIfAbsent(el.parentId, () => <int>[]).add(el.id);
  }
  for (final ids in byParent.values) {
    ids.sort();
  }

  final roots = byParent[null] ?? const <int>[];
  final lines = <String>[
    roots.isEmpty ? 'roots: [none]' : 'roots: ${roots.map((id) => '[$id]').join(', ')}',
  ];

  final parentIds = byParent.keys.whereType<int>().toList()..sort();
  for (final parentId in parentIds) {
    final children = byParent[parentId] ?? const <int>[];
    if (children.isEmpty) continue;
    lines.add('[$parentId] -> ${children.map((id) => '[$id]').join(', ')}');
  }
  return lines.join('\n');
}

/// Parses the UI of the frontmost application using macOS Accessibility APIs.
///
/// On non-macOS platforms returns an empty list. Falls back gracefully when
/// accessibility permissions are not granted.
class UIParserService {
  UIParserService._();

  static final UIParserService instance = UIParserService._();

  String? _cachedBinaryPath;

  /// Pre-compiles the Swift accessibility binary so the first real parse is fast.
  Future<void> warmUp() async {
    if (!Platform.isMacOS) return;
    await _ensureBinary();
  }

  /// Returns the PID of the topmost on-screen application that isn't us
  /// **and** whose window overlaps the given screen [region].
  ///
  /// Uses `CGWindowListCopyWindowInfo` via the compiled binary's
  /// `--find-target` mode, which walks the window stacking order (front to
  /// back) and returns the first normal-layer window whose bounds intersect
  /// the capture region and whose PID differs from ours. On multi-monitor
  /// setups this ensures we target the app on the same screen as Arya.
  Future<int?> getFrontmostPid({CaptureRegion? region}) async {
    if (!Platform.isMacOS) return null;
    final binary = await _ensureBinary();
    if (binary == null) return null;

    try {
      final args = ['--find-target', '$pid'];
      if (region != null) {
        args.addAll([
          '${region.x}',
          '${region.y}',
          '${region.width}',
          '${region.height}',
        ]);
      }
      final result = await Process.run(binary, args)
          .timeout(const Duration(seconds: 4));
      if (result.exitCode != 0) {
        debugPrint('[UIParser] --find-target failed: '
            '${(result.stderr as String).trim()}');
        return null;
      }
      final parsed = int.tryParse((result.stdout as String).trim());
      debugPrint('[UIParser] Target PID resolved: $parsed '
          '(own=$pid, region=${region != null ? "${region.x},${region.y} ${region.width}x${region.height}" : "any"})');
      return (parsed != null && parsed > 0) ? parsed : null;
    } catch (e) {
      debugPrint('[UIParser] getFrontmostPid error: $e');
      return null;
    }
  }

  /// Parses a specific application's UI element tree.
  ///
  /// [targetPid] identifies the application to parse. When null the binary
  /// falls back to the frontmost app (which may be Arya itself — avoid this
  /// by always supplying a PID captured while the Arya window was hidden).
  ///
  /// When [region] is provided, only elements overlapping that region are
  /// returned with coordinates converted to region-relative values.
  Future<List<UIElement>> parseScreen({
    CaptureRegion? region,
    int? targetPid,
  }) async {
    if (!Platform.isMacOS) return [];

    try {
      final raw = await _runBinary(targetPid: targetPid);
      if (raw.isEmpty || raw == '[]') return [];

      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];

      var elements = decoded
          .whereType<Map<String, dynamic>>()
          .map(UIElement.fromJson)
          .where(_isUsefulElement)
          .toList();

      if (region != null) {
        elements = _filterAndOffset(elements, region);
      }

      elements.sort(_interactivePriority);
      elements = _fillMissingHierarchy(_reindexAndRelink(elements));

      debugPrint('[UIParser] Parsed ${elements.length} elements '
          '(pid=${targetPid ?? "frontmost"})');
      return elements;
    } catch (e) {
      debugPrint('[UIParser] Failed: $e');
      return [];
    }
  }

  /// Keeps only elements that overlap [region] and shifts coordinates to
  /// region-relative so they match the cropped screenshot.
  List<UIElement> _filterAndOffset(
    List<UIElement> elements,
    CaptureRegion region,
  ) {
    final result = <UIElement>[];
    final regionRight = region.x + region.width;
    final regionBottom = region.y + region.height;

    for (final el in elements) {
      final elRight = el.x + el.width;
      final elBottom = el.y + el.height;

      final overlaps = el.x < regionRight &&
          elRight > region.x &&
          el.y < regionBottom &&
          elBottom > region.y;
      if (!overlaps) continue;

      result.add(UIElement(
        id: el.id,
        role: el.role,
        title: el.title,
        value: el.value,
        description: el.description,
        parentId: el.parentId,
        depth: el.depth,
        x: el.x - region.x,
        y: el.y - region.y,
        width: el.width,
        height: el.height,
      ));
    }
    return result;
  }

  List<UIElement> _reindexAndRelink(List<UIElement> elements) {
    if (elements.isEmpty) return elements;
    final oldToNew = <int, int>{};
    for (var i = 0; i < elements.length; i++) {
      oldToNew[elements[i].id] = i + 1;
    }

    return [
      for (final el in elements)
        UIElement(
          id: oldToNew[el.id]!,
          role: el.role,
          title: el.title,
          value: el.value,
          description: el.description,
          parentId: el.parentId != null ? oldToNew[el.parentId!] : null,
          depth: el.depth,
          x: el.x,
          y: el.y,
          width: el.width,
          height: el.height,
        ),
    ];
  }

  static const _containerLikeRoles = {
    'Window',
    'Dialog',
    'Sheet',
    'Group',
    'ScrollArea',
    'SplitGroup',
    'Toolbar',
    'List',
    'Table',
    'Row',
    'Outline',
    'WebArea',
    'TabGroup',
    'MenuBar',
    'LayoutArea',
    'Browser',
    'Menu',
  };

  List<UIElement> _fillMissingHierarchy(List<UIElement> elements) {
    if (elements.isEmpty) return elements;
    final byId = <int, UIElement>{for (final e in elements) e.id: e};
    final parentById = <int, int?>{
      for (final e in elements) e.id: e.parentId,
    };

    for (final child in elements) {
      if (parentById[child.id] != null) continue;
      int? bestParent;
      var bestArea = 0x7fffffff;
      for (final candidate in elements) {
        if (candidate.id == child.id) continue;
        if (!_containerLikeRoles.contains(candidate.role)) continue;
        if (!_contains(candidate, child)) continue;
        final area = candidate.width * candidate.height;
        if (area <= 0) continue;
        if (area < bestArea) {
          bestArea = area;
          bestParent = candidate.id;
        }
      }
      if (bestParent != null) {
        parentById[child.id] = bestParent;
      }
    }

    final depthById = <int, int>{};
    int computeDepth(int id, Set<int> path) {
      final cached = depthById[id];
      if (cached != null) return cached;
      if (path.contains(id)) return 0;
      final parent = parentById[id];
      if (parent == null || !byId.containsKey(parent)) {
        depthById[id] = 0;
        return 0;
      }
      final nextPath = <int>{...path, id};
      final depth = computeDepth(parent, nextPath) + 1;
      depthById[id] = depth;
      return depth;
    }

    return [
      for (final e in elements)
        UIElement(
          id: e.id,
          role: e.role,
          title: e.title,
          value: e.value,
          description: e.description,
          parentId: parentById[e.id],
          depth: computeDepth(e.id, <int>{}),
          x: e.x,
          y: e.y,
          width: e.width,
          height: e.height,
        ),
    ];
  }

  bool _contains(UIElement outer, UIElement inner) {
    const pad = 2;
    final outerLeft = outer.x - pad;
    final outerTop = outer.y - pad;
    final outerRight = outer.x + outer.width + pad;
    final outerBottom = outer.y + outer.height + pad;
    final innerLeft = inner.x;
    final innerTop = inner.y;
    final innerRight = inner.x + inner.width;
    final innerBottom = inner.y + inner.height;
    final strictlyLarger =
        outer.width * outer.height > inner.width * inner.height;
    if (!strictlyLarger) return false;
    return innerLeft >= outerLeft &&
        innerTop >= outerTop &&
        innerRight <= outerRight &&
        innerBottom <= outerBottom;
  }

  /// Filters out noise: empty StaticText, tiny icon-spacer elements, etc.
  static bool _isUsefulElement(UIElement el) {
    // Empty StaticText (icon spacers, decorative) — no useful info.
    if (el.role == 'StaticText' &&
        el.title.isEmpty &&
        el.description.isEmpty &&
        (el.value.isEmpty || el.value.trim().isEmpty)) {
      return false;
    }
    // Tiny elements (≤18px in both dimensions) are icon spacers / decorative.
    if (el.width <= 18 && el.height <= 18 && el.label.isEmpty) {
      return false;
    }
    return true;
  }

  static const _interactiveRoles = {
    'Button',
    'TextField',
    'TextArea',
    'CheckBox',
    'RadioButton',
    'PopUpButton',
    'ComboBox',
    'Slider',
    'MenuItem',
    'MenuBarItem',
    'Link',
    'Tab',
    'Cell',
  };

  int _interactivePriority(UIElement a, UIElement b) {
    final aScore = _interactiveRoles.contains(a.role) ? 0 : 1;
    final bScore = _interactiveRoles.contains(b.role) ? 0 : 1;
    return aScore.compareTo(bScore);
  }

  // ---------------------------------------------------------------------------
  // Binary compilation & execution
  // ---------------------------------------------------------------------------

  Future<String?> _ensureBinary() async {
    if (_cachedBinaryPath != null) {
      if (await File(_cachedBinaryPath!).exists()) return _cachedBinaryPath;
    }

    final cacheDir = '${Directory.systemTemp.path}/arya_ui_parser';
    final binaryPath = '$cacheDir/ui_parser_v8';
    final sourcePath = '$cacheDir/ui_parser_v8.swift';

    if (await File(binaryPath).exists()) {
      _cachedBinaryPath = binaryPath;
      return binaryPath;
    }

    try {
      await Directory(cacheDir).create(recursive: true);
      await File(sourcePath).writeAsString(_swiftSource);

      debugPrint('[UIParser] Compiling accessibility parser…');
      final result = await Process.run(
        'swiftc',
        ['-O', '-o', binaryPath, sourcePath],
      ).timeout(const Duration(seconds: 45));

      if (result.exitCode != 0) {
        debugPrint(
          '[UIParser] Compilation failed: ${(result.stderr as String).trim()}',
        );
        return null;
      }

      debugPrint('[UIParser] Compiled successfully → $binaryPath');
      _cachedBinaryPath = binaryPath;
      return binaryPath;
    } catch (e) {
      debugPrint('[UIParser] Compilation error: $e');
      return null;
    }
  }

  Future<String> _runBinary({int? targetPid}) async {
    final path = await _ensureBinary();
    if (path == null) return '[]';

    try {
      final args = targetPid != null ? ['$targetPid'] : <String>[];
      final result =
          await Process.run(path, args).timeout(const Duration(seconds: 6));

      if (result.exitCode != 0) {
        debugPrint('[UIParser] Binary exit=${result.exitCode}: '
            '${(result.stderr as String).trim()}');
        return '[]';
      }
      return (result.stdout as String).trim();
    } catch (e) {
      debugPrint('[UIParser] Execution failed: $e');
      return '[]';
    }
  }

  // ---------------------------------------------------------------------------
  // Swift source — compiled once, cached in /tmp/arya_ui_parser/
  // ---------------------------------------------------------------------------

  static const _swiftSource = r'''
import Cocoa

// =========================================================================
// Mode 1: --find-target <own_pid> [<rx> <ry> <rw> <rh>]
//   Walks CGWindowList (front-to-back) to find the topmost normal-layer
//   window that doesn't belong to <own_pid>. When region bounds are given,
//   only windows whose frame overlaps that rectangle are considered — this
//   is critical on multi-monitor setups so we target the app on the same
//   screen as our capture region.
// =========================================================================
if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--find-target" {
    let ownPid = Int32(CommandLine.arguments[2]) ?? -1

    var hasRegion = false
    var rx = 0, ry = 0, rw = 0, rh = 0
    if CommandLine.arguments.count >= 7 {
        rx = Int(CommandLine.arguments[3]) ?? 0
        ry = Int(CommandLine.arguments[4]) ?? 0
        rw = Int(CommandLine.arguments[5]) ?? 0
        rh = Int(CommandLine.arguments[6]) ?? 0
        hasRegion = rw > 0 && rh > 0
    }

    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let winList = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        print("-1"); exit(0)
    }
    for w in winList {
        guard let wPid = w[kCGWindowOwnerPID as String] as? Int32,
              wPid != ownPid,
              let layer = w[kCGWindowLayer as String] as? Int,
              layer == 0
        else { continue }

        if hasRegion {
            guard let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let wx = bounds["X"] as? Int,
                  let wy = bounds["Y"] as? Int,
                  let ww = bounds["Width"] as? Int,
                  let wh = bounds["Height"] as? Int
            else { continue }
            let overlaps = wx < rx + rw && wx + ww > rx &&
                           wy < ry + rh && wy + wh > ry
            if !overlaps { continue }
        }

        print(wPid)
        exit(0)
    }
    print("-1"); exit(0)
}

// =========================================================================
// Mode 2: [<pid>]  — parse accessibility tree of given PID (or frontmost)
// =========================================================================
var eid = 0
let maxEls = Int.max

// Interactive roles — always emit even without a label, because they are
// actionable click/type targets.
let interactiveRoles: Set<String> = [
    "AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
    "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider",
    "AXMenuItem", "AXMenuBarItem", "AXMenu",
    "AXLink", "AXTab", "AXImage", "AXHeading",
    "AXStaticText", "AXCell"
]

// Container / structural roles — only emit if they carry a meaningful label.
// Their children are ALWAYS traversed regardless.
let containerRoles: Set<String> = [
    "AXGroup", "AXScrollArea", "AXSplitGroup", "AXToolbar",
    "AXList", "AXTable", "AXRow", "AXOutline",
    "AXWindow", "AXSheet", "AXDialog", "AXWebArea",
    "AXTabGroup", "AXMenuBar", "AXLayoutArea", "AXBrowser"
]

func ser(_ el: AXUIElement, _ d: Int, _ parentEmittedId: Int?) -> [[String: Any]] {
    if d > 25 || eid >= maxEls { return [] }
    var r: [[String: Any]] = []

    var roleRef: AnyObject?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
    let role = (roleRef as? String) ?? ""

    var titleRef: AnyObject?
    AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef)
    let title = (titleRef as? String) ?? ""

    var valRef: AnyObject?
    AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valRef)
    var valStr = ""
    if let v = valRef as? String { valStr = String(v.prefix(100)) }

    var descRef: AnyObject?
    AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descRef)
    let desc = (descRef as? String) ?? ""

    var x = 0, y = 0, w = 0, h = 0

    var posRef: AnyObject?
    if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
       let pv = posRef {
        var pt = CGPoint.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
        x = Int(pt.x); y = Int(pt.y)
    }

    var szRef: AnyObject?
    if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &szRef) == .success,
       let sv = szRef {
        var sz = CGSize.zero
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        w = Int(sz.width); h = Int(sz.height)
    }

    var emittedId: Int? = nil
    if w > 3 && h > 3 {
        let labeled = !title.isEmpty || !desc.isEmpty || !valStr.isEmpty
        let isInteractive = interactiveRoles.contains(role)
        let isContainer = containerRoles.contains(role)

        // Emit interactive elements always; containers only when labeled;
        // unknown roles when labeled.
        let shouldEmit = isInteractive || (labeled && !isContainer) ||
                         (isContainer && labeled)
        if shouldEmit {
            eid += 1
            emittedId = eid
            var entry: [String: Any] = [
                "id": emittedId!,
                "role": role.hasPrefix("AX") ? String(role.dropFirst(2)) : role,
                "x": x, "y": y, "w": w, "h": h,
                "depth": d
            ]
            if let p = parentEmittedId { entry["parent_id"] = p }
            if !title.isEmpty { entry["title"] = title }
            if !valStr.isEmpty { entry["value"] = valStr }
            if !desc.isEmpty { entry["desc"] = desc }
            r.append(entry)
        }
    }

    // Always recurse into children regardless of whether we emitted this node.
    var chRef: AnyObject?
    AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef)
    if let children = chRef as? [AXUIElement] {
        let nextParent = emittedId ?? parentEmittedId
        for child in children {
            if eid >= maxEls { break }
            r.append(contentsOf: ser(child, d + 1, nextParent))
        }
    }
    return r
}

var targetPid: pid_t
if CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) {
    targetPid = pid
} else {
    guard let app = NSWorkspace.shared.frontmostApplication else {
        print("[]"); exit(0)
    }
    targetPid = app.processIdentifier
}
let el = AXUIElementCreateApplication(targetPid)
let result = ser(el, 0, nil)
if let data = try? JSONSerialization.data(withJSONObject: result),
   let str = String(data: data, encoding: .utf8) {
    print(str)
} else {
    print("[]")
}
''';
}
