import 'dart:convert';
import 'dart:io';

import 'package:arya_app/src/features/assistant/services/ai_validation.dart';
import 'package:arya_app/src/features/assistant/services/openrouter_client.dart';
import 'package:arya_app/src/features/assistant/services/tavily_client.dart';
import 'package:arya_app/src/features/assistant/services/ui_parser_service.dart';
import 'package:arya_app/src/features/assistant/services/web_context_helper.dart';
import 'package:flutter/foundation.dart';

class PlannerTrace {
  const PlannerTrace({
    required this.label,
    required this.model,
    required this.hasScreenshot,
    required this.systemPrompt,
    required this.userPrompt,
    required this.requestPayload,
    required this.rawResponse,
  });

  final String label;
  final String model;
  final bool hasScreenshot;
  final String systemPrompt;
  final String userPrompt;
  final String requestPayload;
  final String rawResponse;
}

typedef PlannerTraceLogger = void Function(PlannerTrace trace);

// ---------------------------------------------------------------------------
// Verification criteria — checked locally after each step (no LLM call).
// ---------------------------------------------------------------------------

class VerifyCriteria {
  const VerifyCriteria({required this.type, this.role, this.labelContains});

  final String type; // element_visible, element_gone, text_visible, any
  final String? role;
  final String? labelContains;

  factory VerifyCriteria.fromJson(Map<String, dynamic> json) {
    return VerifyCriteria(
      type: json['type'] as String? ?? 'any',
      role: json['role'] as String?,
      labelContains: json['label_contains'] as String?,
    );
  }

  bool check(List<UIElement> elements) {
    switch (type) {
      case 'element_visible':
        return elements.any((e) => _matches(e));
      case 'element_gone':
        return !elements.any((e) => _matches(e));
      case 'text_visible':
        final q = (labelContains ?? '').toLowerCase();
        if (q.isEmpty) return true;
        return elements.any(
          (e) =>
              e.label.toLowerCase().contains(q) ||
              e.value.toLowerCase().contains(q),
        );
      case 'any':
      default:
        return true;
    }
  }

  bool _matches(UIElement e) {
    if (role != null && e.role != role) return false;
    if (labelContains != null &&
        !e.label.toLowerCase().contains(labelContains!.toLowerCase()) &&
        !e.value.toLowerCase().contains(labelContains!.toLowerCase()) &&
        !e.description.toLowerCase().contains(labelContains!.toLowerCase())) {
      return false;
    }
    return true;
  }

  @override
  String toString() =>
      'Verify($type${role != null ? ', role=$role' : ''}'
      '${labelContains != null ? ', contains="$labelContains"' : ''})';
}

// ---------------------------------------------------------------------------
// A single planned step produced by the LLM.
// ---------------------------------------------------------------------------

class PlannedStep {
  const PlannedStep({
    required this.id,
    required this.title,
    required this.action,
    required this.args,
    this.thenChain,
    required this.verify,
  });

  final String id;
  final String title;
  final String action;
  final Map<String, dynamic> args;
  final Map<String, dynamic>? thenChain;
  final VerifyCriteria verify;

  factory PlannedStep.fromJson(Map<String, dynamic> json) {
    return PlannedStep(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      action: json['action'] as String? ?? '',
      args: (json['args'] as Map<String, dynamic>?) ?? {},
      thenChain: json['then'] as Map<String, dynamic>?,
      verify: json['verify'] is Map<String, dynamic>
          ? VerifyCriteria.fromJson(json['verify'] as Map<String, dynamic>)
          : const VerifyCriteria(type: 'any'),
    );
  }

  Map<String, dynamic> toStepMap() => {
    'id': id,
    'title': title,
    'action': action,
    'args': args,
    if (thenChain != null) 'then': thenChain,
  };
}

// ---------------------------------------------------------------------------
// StepPlanner — generates a full plan upfront, re-plans only on failure.
// ---------------------------------------------------------------------------

class StepPlanner {
  StepPlanner({
    OpenRouterClient? openRouterClient,
    TavilyClient? tavilyClient,
    PlannerTraceLogger? traceLogger,
  }) : _traceLogger = traceLogger,
       _openRouter = openRouterClient ?? OpenRouterClient(),
       _tavily = tavilyClient ?? TavilyClient();

  final OpenRouterClient _openRouter;
  final TavilyClient _tavily;
  final PlannerTraceLogger? _traceLogger;

  // Shared prompt fragments ------------------------------------------------

  static String _safetyBlock() => '''
## Safety constraints — STRICTLY ENFORCED
- NEVER open, click on, or interact with terminals, command lines, shells, or consoles.
- Do NOT use keyboard shortcuts (Cmd+anything, Ctrl+anything). Only plain keys like Enter/Escape/Tab.
- Do NOT switch apps or open new windows.
- If a task seems to require a terminal, find the GUI equivalent (e.g., right-click → New File).''';

  static String _actionsBlock() => '''
## Available actions
- click: {element_id, position?, button?, clicks?} — click a UI element by [id]. Position: "center" (default), "top_left", "top_right", "bottom_left", "bottom_right". Button: "left" (default) or "right".
  For LATER steps where the UI will have changed after earlier steps, use match instead of element_id:
  click: {match_role?, match_label?, position?, button?} — the system finds the first element whose role equals match_role AND whose label/desc/value contains match_label, then clicks it.
- type_text: {text}
- press_keys: {keys: ["Enter"]}
- wait: {seconds}''';

  static String _thenBlock() => '''
## Chained actions ("then")
When a click will produce a transient input (e.g., "New File" opens an inline text field), chain the follow-up so it executes immediately (~800 ms after click→type_text) without a new planning cycle:
{"action":"click","args":{"element_id":29}, "then": {"action":"type_text","args":{"text":"name"}, "then": {"action":"press_keys","args":{"keys":["Enter"]}}}}
Use "wait_ms" to override delay: {"then": {"wait_ms": 1200, "action":"type_text","args":{"text":"x"}}}''';

  static String _verifyBlock() => '''
## Verification ("verify")
Each step MUST include a "verify" object. After execution, the system does a quick UI parse (no LLM) and checks the criterion. If it fails, you'll be called to re-plan.
Types:
- "element_visible": pass if an element with matching role/label_contains exists
- "element_gone": pass if NO such element exists (e.g., menu dismissed)
- "text_visible": pass if any element's label or value contains label_contains
- "any": always pass

IMPORTANT verification rules:
- For type_text: use text_visible with a SHORT fragment (first 3-5 words) of the typed text. The accessibility tree exposes text field values, so this detects if typing actually landed in the target field.
- For press_keys: use "any" (key presses have side effects that are hard to verify generically).
- For click that opens a menu/dialog: use element_visible for the NEW element that should appear.
- For click that dismisses something: use element_gone for the element that should disappear.
- For click on a submit/confirm/commit button: use element_gone to confirm the button was actually pressed (e.g., a "Commit" button should disappear or the view should change after pressing it). NEVER use "any" for important action buttons.
- Verify must check for a CHANGE caused by the step — never check for an element that was already visible before the step.
- ONLY use "any" for trivial navigation clicks or press_keys where no verifiable UI change occurs. For any important action (submit, commit, save, delete, send), ALWAYS verify with element_visible, element_gone, or text_visible.
Example: {"type": "text_visible", "label_contains": "first few words"}
Example: {"type": "element_visible", "role": "MenuItem", "label_contains": "New File"}
Example: {"type": "element_gone", "role": "Button", "label_contains": "Commit"}''';

  // -----------------------------------------------------------------------
  // generateFullPlan — one LLM call, returns all steps.
  // -----------------------------------------------------------------------

  Future<List<PlannedStep>> generateFullPlan({
    required String openRouterKey,
    required String model,
    required String task,
    required Map<String, dynamic> screenContext,
    required String uiContext,
    String? screenshotPath,
    String tavilyKey = '',
    String webMode = 'auto',
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    _validateKeys(openRouterKey, model);

    final webContext = await _maybeWebContext(
      tavilyKey: tavilyKey,
      webMode: webMode,
      task: task,
    );
    final attachmentSummary = _formatAttachments(attachments);

    final hasScreenshot = screenshotPath != null;
    final systemPrompt =
        '''You are a desktop automation agent. You receive a structured list of UI elements parsed from the accessibility tree of the target application.${hasScreenshot ? ' A screenshot is also attached for visual reference.' : ''} Use the element list as your primary source of truth for planning actions.

## Screen info
${jsonEncode(screenContext)}
Element coordinates are in screen pixels matching this region. No scaling needed.

${_actionsBlock()}

## MANDATORY: Element-based clicking
- For the FIRST step: use element_id from the UI element list below (IDs are current).
- For LATER steps: use match_role and/or match_label instead (the UI will change after earlier steps execute, so current IDs become stale).
- match_label MUST be specific enough to uniquely identify ONE element. Use the FULL label text from the element list, not just a keyword. Example: "Commit to main" not "Commit". If multiple elements share similar text, include enough of the label to distinguish the target.
- ALWAYS provide match_role together with match_label for maximum precision.
- NEVER invent pixel coordinates.
- CRITICAL: Verify you select the correct element TYPE. A "Button" and a "TextArea" with similar names are NOT the same. To click a button, select the element with role=Button. To type in a field, select the TextArea/TextField/ComboBox. Read each element's role carefully before choosing.

${_thenBlock()}

${_verifyBlock()}

${_safetyBlock()}

${uiContext.isNotEmpty ? '\n$uiContext\n' : ''}
## Response format — return ONLY a JSON array:
[
  {"id":"step_1","title":"...","action":"click","args":{"element_id":N,...},"then":{...},"verify":{"type":"...","role":"...","label_contains":"..."}},
  {"id":"step_2","title":"...","action":"click","args":{"match_role":"MenuItem","match_label":"New File"},"verify":{"type":"element_gone","role":"Menu"}},
  ...
]
Return ALL steps needed to complete the task from current state to finish. Be thorough — include closing menus, confirming dialogs, etc.''';

    final userPrompt =
        '''Task: $task

Attachments: ${attachmentSummary.isEmpty ? '[none]' : attachmentSummary}
${webContext.isNotEmpty ? '\n$webContext' : ''}

Analyze the UI elements${hasScreenshot ? ' and attached screenshot' : ''}, then produce a COMPLETE plan (JSON array) to accomplish this task.''';

    return _callAndParsePlan(
      openRouterKey: openRouterKey,
      model: model,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      screenshotPath: screenshotPath,
      label: 'generateFullPlan',
      uiContext: uiContext,
    );
  }

  // -----------------------------------------------------------------------
  // replanFromFailure — called when a verification criterion fails.
  // -----------------------------------------------------------------------

  Future<List<PlannedStep>> replanFromFailure({
    required String openRouterKey,
    required String model,
    required String task,
    required Map<String, dynamic> screenContext,
    required String uiContext,
    required List<Map<String, String>> history,
    required PlannedStep failedStep,
    required String failureDetail,
    required List<PlannedStep> remainingSteps,
    String? screenshotPath,
  }) async {
    _validateKeys(openRouterKey, model);

    final historyLines = history
        .map((h) {
          final detail = h['detail'] ?? '';
          return '- ${h['step_id']} | ${h['status']} | ${h['title']} | '
              '${detail.length > 180 ? detail.substring(0, 180) : detail}';
        })
        .join('\n');

    final remainingDesc = remainingSteps
        .map((s) => '  ${s.id}: ${s.title} (${s.action})')
        .join('\n');

    final systemPrompt =
        '''You are a desktop automation agent. A plan failed at one step. Re-plan from the current state. A screenshot is attached so you can see the actual screen alongside the UI element list.

## Screen info
${jsonEncode(screenContext)}

${_actionsBlock()}

## Element resolution
Use match_role / match_label for all clicks (current element IDs are in the UI list below).
You may also use element_id if you see an exact match in the current UI elements.
match_label MUST be the FULL label text that uniquely identifies the element — not a keyword. Always provide match_role too.

${_thenBlock()}

${_verifyBlock()}

${_safetyBlock()}

${uiContext.isNotEmpty ? '\n$uiContext\n' : ''}
## Response format — return ONLY a JSON array of remaining steps.
Every step MUST have: "id" (e.g. "step_6"), "title", "action", "args", "verify".
Return [] (empty array) if the task is already complete.''';

    final userPrompt =
        '''Task: $task

## Steps already completed:
${historyLines.isEmpty ? '[none]' : historyLines}

## Failed / checkpoint step:
${failedStep.id}: "${failedStep.title}" — action=${failedStep.action}
Verification expected: ${failedStep.verify}
Failure: $failureDetail

## Remaining steps that were planned:
${remainingDesc.isEmpty ? '[none]' : remainingDesc}

Look at the current UI elements${screenshotPath != null ? ' and attached screenshot' : ''}. Produce a NEW plan (JSON array) to complete the ORIGINAL task from this point.
- If a type_text action "succeeded" but verification failed, the text was likely typed — move forward rather than retrying.
- You may retry a failed step differently, skip it, or take a completely different approach.
- If the task is already fully complete, return [].''';

    return _callAndParsePlan(
      openRouterKey: openRouterKey,
      model: model,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      screenshotPath: screenshotPath,
      label: 'replanFromFailure',
      uiContext: uiContext,
    );
  }

  // -----------------------------------------------------------------------
  // Shared LLM call + JSON array parsing
  // -----------------------------------------------------------------------

  Future<List<PlannedStep>> _callAndParsePlan({
    required String openRouterKey,
    required String model,
    required String systemPrompt,
    required String userPrompt,
    required String label,
    required String uiContext,
    String? screenshotPath,
  }) async {
    final userContent = await _buildUserContent(userPrompt, screenshotPath);

    debugPrint(
      '[Planner:$label] Calling LLM (model=$model, '
      'screenshot=${screenshotPath != null ? "yes" : "no"}, '
      'uiElements=${uiContext.isEmpty ? 0 : uiContext.split('\n').length} lines)',
    );
    final requestMessages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userContent},
    ];
    final requestPayload = <String, dynamic>{
      'model': model,
      'messages': requestMessages,
    };
    final logPayload = _sanitizePayloadForLog(requestPayload);
    debugPrint('[Planner:$label] REQUEST_PAYLOAD=${jsonEncode(logPayload)}');

    final raw = await _openRouter.chatCompletion(
      apiKey: openRouterKey,
      model: model,
      messages: requestMessages,
    );
    _traceLogger?.call(
      PlannerTrace(
        label: label,
        model: model,
        hasScreenshot: screenshotPath != null,
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        requestPayload: jsonEncode(logPayload),
        rawResponse: raw,
      ),
    );

    debugPrint('[Planner:$label] LLM raw response=${_toSingleLineLog(raw)}');

    final steps = _extractJsonArray(raw);
    if (steps == null || steps.isEmpty) {
      debugPrint('[Planner:$label] Failed to parse JSON array');
      return [];
    }

    return steps.map((s) => PlannedStep.fromJson(s)).toList();
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  void _validateKeys(String openRouterKey, String model) {
    validateOpenRouterConfig(apiKey: openRouterKey, model: model);
  }

  String _formatAttachments(List<Map<String, dynamic>> attachments) {
    return attachments
        .map((a) {
          final name = a['name'] ?? 'file';
          final summary = (a['summary'] ?? '').toString();
          return '- $name: ${summary.length > 400 ? summary.substring(0, 400) : summary}';
        })
        .join('\n');
  }

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
    final shouldSearch = shouldRunWebSearch(
      mode: webMode,
      tavilyKey: tavilyKey,
      queryText: task,
      autoHints: plannerAutoWebHints,
    );
    if (!shouldSearch) return '';

    final results = await _tavily.search(
      apiKey: tavilyKey,
      query: task,
      maxResults: 4,
    );
    if (results.isEmpty) return '';

    return formatTavilyResultsContext(results: results, intro: 'Web context:');
  }

  /// Extracts the first balanced JSON array from [raw].
  static List<Map<String, dynamic>>? _extractJsonArray(String raw) {
    raw = raw.trim();
    if (raw.isEmpty) return null;

    // Fast path: entire string is a valid JSON array.
    try {
      final parsed = jsonDecode(raw);
      if (parsed is List) {
        return parsed.whereType<Map<String, dynamic>>().toList();
      }
    } catch (_) {}

    // Slow path: find the first balanced [ … ].
    final start = raw.indexOf('[');
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
      if (c == 0x5C && inString) {
        escape = true;
        continue;
      }
      if (c == 0x22) {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == 0x5B) depth++;
      if (c == 0x5D) {
        depth--;
        if (depth == 0) {
          try {
            final parsed = jsonDecode(raw.substring(start, i + 1));
            if (parsed is List) {
              return parsed.whereType<Map<String, dynamic>>().toList();
            }
          } catch (_) {}
          break;
        }
      }
    }
    return null;
  }

  static String _toSingleLineLog(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
  }

  static dynamic _sanitizePayloadForLog(dynamic value) {
    if (value is Map) {
      final map = <String, dynamic>{};
      for (final entry in value.entries) {
        map[entry.key.toString()] = _sanitizePayloadForLog(entry.value);
      }
      final imageUrl = map['image_url'];
      if (imageUrl is Map<String, dynamic>) {
        final url = imageUrl['url'];
        if (url is String && url.startsWith('data:image/')) {
          final commaIndex = url.indexOf(',');
          final header = commaIndex >= 0 ? url.substring(0, commaIndex) : url;
          final data = commaIndex >= 0 ? url.substring(commaIndex + 1) : '';
          final preview = data.length > 24 ? data.substring(0, 24) : data;
          imageUrl['url'] =
              '$header,<base64 ${data.length} chars preview=$preview...>';
        }
      }
      return map;
    }
    if (value is List) {
      return value.map(_sanitizePayloadForLog).toList();
    }
    return value;
  }
}
