import 'dart:convert';
import 'dart:io';

import 'package:arya_app/src/features/assistant/services/openrouter_client.dart';
import 'package:arya_app/src/features/assistant/services/tavily_client.dart';
import 'package:flutter/foundation.dart';

/// Plans one next step at a time for Take Action, via LLM with vision.
/// Sends the latest screenshot **and** structured UI element data so the
/// model can see the actual screen and pick correct coordinates.
class StepPlanner {
  StepPlanner({
    OpenRouterClient? openRouterClient,
    TavilyClient? tavilyClient,
  })  : _openRouter = openRouterClient ?? OpenRouterClient(),
        _tavily = tavilyClient ?? TavilyClient();

  final OpenRouterClient _openRouter;
  final TavilyClient _tavily;

  /// Plans the next action step.
  ///
  /// [screenshotPath] is the path to the latest screenshot PNG. When provided,
  /// it's sent as a vision image so the LLM can see the actual screen state
  /// and choose accurate coordinates.
  ///
  /// [uiContext] is a pre-formatted text block listing the UI elements parsed
  /// from the accessibility tree. When non-empty it is injected into the
  /// system prompt so the model can reference element positions directly.
  Future<StepPlanResult> planNextStep({
    required String openRouterKey,
    required String tavilyKey,
    required String model,
    required String webMode,
    required String task,
    required int stepNumber,
    required List<Map<String, String>> history,
    required Map<String, dynamic> screenContext,
    required List<Map<String, dynamic>> attachments,
    String? screenshotPath,
    String uiContext = '',
  }) async {
    if (openRouterKey.trim().isEmpty) {
      throw ArgumentError('OpenRouter API key is missing.');
    }
    if (model.trim().isEmpty) {
      throw ArgumentError('Model is required.');
    }

    final webContext = await _maybeWebContext(
      tavilyKey: tavilyKey,
      webMode: webMode,
      task: task,
    );

    final attachmentSummary = attachments
        .map((a) {
          final name = a['name'] ?? 'file';
          final summary = (a['summary'] ?? '').toString();
          return '- $name: ${summary.length > 400 ? summary.substring(0, 400) : summary}';
        })
        .join('\n');

    final compactHistory = history.length > 8
        ? history.sublist(history.length - 8)
        : history;
    final historyLines = compactHistory.map((h) {
      final detail = h['detail'] ?? '';
      return '- ${h['step_id'] ?? ''} | ${h['status'] ?? ''} | '
          '${h['title'] ?? ''} | ${detail.length > 180 ? detail.substring(0, 180) : detail}';
    }).join('\n');

    final systemPrompt = '''You are a desktop automation agent. You can SEE the screen via the attached screenshot AND you receive a structured list of UI elements parsed from the accessibility tree.
You control the mouse and keyboard to accomplish tasks the way a normal person would — using visible UI elements, menus, and buttons.

## Screen info
${jsonEncode(screenContext)}
The screenshot has been resized to match these logical pixel dimensions exactly.
Pixel coordinates in the screenshot == mouse coordinates. No scaling needed.

## Actions you can produce (pick ONE per turn)
- click: {element_id, position?, button?, clicks?} — click a UI element by its [id] from the element list below. The system resolves exact screen coordinates. "position" is optional: "center" (default), "top_left", "top_right", "bottom_left", "bottom_right". "button" defaults to "left", set "right" for context menus.
- type_text: {text} — type text into the currently focused input
- press_keys: {keys: ["key1"]} — press Enter, Escape, Tab, or arrow keys
- wait: {seconds} — pause

## MANDATORY: Element-based clicking
- NEVER invent pixel coordinates. ALWAYS use element_id from the UI element list.
- Find the element you want to click by matching its role and label/desc, then use its [id].
- In your "reason", state which element: e.g., "Clicking [6] Explorer Section: Arya".
- Use "position": "top_left" for large containers where you want to hit the header/label area.
- If the target element is truly NOT in the list, you may use raw {x, y} as a fallback — but you MUST explain why no element matches.

## CRITICAL: Verify before proceeding
After every step, you receive a fresh screenshot and updated UI elements. BEFORE planning:
1. Check whether the PREVIOUS step achieved its intended effect.
2. If NOT (wrong menu, missed target, text missing), produce a corrective action.
3. If it DID work, proceed to the next logical step.
4. Only report done=true when you can visually confirm the task is complete.

## Safety constraints — STRICTLY ENFORCED
- NEVER open, click on, or interact with terminals, command lines, shells, or consoles. Do NOT click on "Terminal" tabs/panels. Do NOT type shell commands. You are a GUI-only agent.
- Do NOT use keyboard shortcuts (Cmd+anything, Ctrl+anything). Only plain keys like Enter/Escape/Tab.
- Do NOT switch apps or open new windows.
- Do NOT use actions called 'analyze', 'think', or 'observe'.
- If a task seems to require a terminal, find the GUI equivalent (e.g., right-click → New File).
${uiContext.isNotEmpty ? '\n$uiContext\n' : ''}
## Chained actions ("then")
When a click will produce a transient input or dialog that needs immediate interaction (e.g., "New File" opens an inline text field, a rename dialog appears, a search box opens), add a "then" field. The system executes chained actions with smart delays (800 ms after click→type_text to let Electron/GUI create and focus the input, 400 ms otherwise). You can override with "wait_ms" if needed.
Example: click "New File…" then type the filename and confirm:
{"step": {"id":"step_N","title":"Create file","action":"click","args":{"element_id":29}, "then": {"action":"type_text","args":{"text":"sample.txt"}, "then": {"action":"press_keys","args":{"keys":["Enter"]}}}}}
Custom delay example (slow dialog): {"then": {"wait_ms": 1200, "action":"type_text","args":{"text":"name"}}}
Use "then" whenever an action will create a short-lived input that must be acted on before the next planning cycle.

## Response format — return ONLY this JSON:
{"done": false, "reason": "<which element [id] and why>", "step": {"id":"step_N","title":"...","action":"...","args":{...}}}
When finished: {"done": true, "reason":"<what confirms completion>", "step": null}
''';

    final userPrompt = '''Task: $task
Current step number: $stepNumber

Attachments: ${attachmentSummary.isEmpty ? '[none]' : attachmentSummary}

Steps executed so far:
${historyLines.isEmpty ? '[none yet]' : historyLines}

${webContext.isNotEmpty ? webContext : ''}

Look at the attached screenshot of the current screen state and produce the next concrete mouse/keyboard action.''';

    final userContent = await _buildUserContent(userPrompt, screenshotPath);

    debugPrint('[Planner] Calling LLM (model=$model, step=$stepNumber, '
        'screenshot=${screenshotPath != null ? "yes" : "no"}, '
        'uiElements=${uiContext.isEmpty ? 0 : uiContext.split('\n').length} lines)');
    debugPrint('[Planner] UI context:\n$uiContext');
    debugPrint('[Planner] History: $historyLines');

    final raw = await _openRouter.chatCompletion(
      apiKey: openRouterKey,
      model: model,
      messages: [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userContent},
      ],
    );

    debugPrint('[Planner] LLM raw response:\n$raw');

    final parsed = _extractJsonObject(raw);
    if (parsed == null) {
      debugPrint('[Planner] Failed to parse JSON from response');
      return StepPlanResult(
        done: false,
        reason: '',
        step: {
          'id': 'step_$stepNumber',
          'title': 'Wait for context',
          'action': 'wait',
          'args': {'seconds': 1.0},
        },
      );
    }

    return StepPlanResult(
      done: parsed['done'] as bool? ?? false,
      reason: (parsed['reason'] as String?) ?? '',
      step: parsed['step'] as Map<String, dynamic>?,
    );
  }

  /// Builds the user message content. If a screenshot path is available,
  /// returns a multimodal content array with text + image. Otherwise plain text.
  Future<dynamic> _buildUserContent(
    String textPrompt,
    String? screenshotPath,
  ) async {
    if (screenshotPath == null) return textPrompt;

    try {
      final file = File(screenshotPath);
      if (!await file.exists()) return textPrompt;
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.isEmpty) return textPrompt;

      final b64 = base64Encode(bytes);
      return [
        {'type': 'text', 'text': textPrompt},
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,$b64'},
        },
      ];
    } catch (_) {
      return textPrompt;
    }
  }

  Future<String> _maybeWebContext({
    required String tavilyKey,
    required String webMode,
    required String task,
  }) async {
    if (tavilyKey.trim().isEmpty) return '';
    if (webMode == 'never') return '';
    if (webMode == 'auto') {
      final lower = task.toLowerCase();
      const hints = ['latest', 'today', 'current', 'recent', 'new', 'version', 'news'];
      if (!hints.any(lower.contains)) return '';
    }

    final results = await _tavily.search(
      apiKey: tavilyKey,
      query: task,
      maxResults: 4,
    );
    if (results.isEmpty) return '';

    final lines = <String>[];
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      lines.add('[${i + 1}] ${r.title}\nURL: ${r.url}\nSnippet: ${r.snippet}');
    }
    return 'Web context:\n\n${lines.join('\n\n')}';
  }

  /// Extracts the first balanced JSON object from [raw].
  ///
  /// Some models (notably gpt-5.4 via OpenRouter) occasionally duplicate
  /// their JSON output separated by a blank line. Using `lastIndexOf('}')`
  /// would span both copies and fail to parse. Instead we track brace depth
  /// to find the first complete `{…}` and parse only that.
  static Map<String, dynamic>? _extractJsonObject(String raw) {
    raw = raw.trim();
    if (raw.isEmpty) return null;

    // Fast path: entire string is valid JSON.
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) return parsed;
    } catch (_) {}

    // Slow path: find the first balanced {…}.
    final start = raw.indexOf('{');
    if (start < 0) return null;

    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < raw.length; i++) {
      final c = raw.codeUnitAt(i);
      if (escape) {
        escape = false;
        continue;
      }
      if (c == 0x5C /* \ */ && inString) {
        escape = true;
        continue;
      }
      if (c == 0x22 /* " */) {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == 0x7B /* { */) depth++;
      if (c == 0x7D /* } */) {
        depth--;
        if (depth == 0) {
          try {
            final parsed = jsonDecode(raw.substring(start, i + 1));
            if (parsed is Map<String, dynamic>) return parsed;
          } catch (_) {}
          break;
        }
      }
    }
    return null;
  }
}

class StepPlanResult {
  const StepPlanResult({
    required this.done,
    required this.reason,
    this.step,
  });

  final bool done;
  final String reason;
  final Map<String, dynamic>? step;
}
