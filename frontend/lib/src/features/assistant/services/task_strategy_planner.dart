import 'dart:convert';

import 'package:arya_app/src/features/assistant/models/ai_provider.dart';
import 'package:arya_app/src/features/assistant/services/ai_validation.dart';
import 'package:arya_app/src/features/assistant/services/openrouter_client.dart';
import 'package:arya_app/src/features/assistant/services/ollama_client.dart';
import 'package:flutter/foundation.dart';

class MilestoneApproach {
  const MilestoneApproach({
    required this.title,
    required this.confidence,
    required this.milestoneStrategies,
  });

  final String title;
  final double confidence;
  final List<String> milestoneStrategies;

  String strategyForMilestone(int milestoneIndex, String milestoneLabel) {
    if (milestoneIndex >= 0 && milestoneIndex < milestoneStrategies.length) {
      final strategy = milestoneStrategies[milestoneIndex].trim();
      if (strategy.isNotEmpty) return strategy;
    }
    return milestoneLabel;
  }
}

class TaskDecomposition {
  const TaskDecomposition({
    required this.taskPattern,
    required this.milestones,
    required this.approaches,
    required this.source,
  });

  final String taskPattern;
  final List<String> milestones;
  final List<MilestoneApproach> approaches;
  final String source;
}

class TaskStrategyPlanner {
  TaskStrategyPlanner({
    OpenRouterClient? openRouterClient,
    OllamaClient? ollamaClient,
  }) : _openRouter = openRouterClient ?? OpenRouterClient(),
       _ollama = ollamaClient ?? OllamaClient();

  final OpenRouterClient _openRouter;
  final OllamaClient _ollama;

  Future<TaskDecomposition> decompose({
    required AiProvider provider,
    required String openRouterKey,
    required String ollamaBaseUrl,
    required String model,
    required String task,
    required String appName,
    String uiSummary = '',
  }) async {
    if (isTrivialTask(task)) {
      debugPrint('[Preplanner] Trivial task — using heuristic decomposition');
      return _fallbackDecomposition(task, source: 'heuristic');
    }

    if (provider == AiProvider.openrouter) {
      validateOpenRouterConfig(apiKey: openRouterKey, model: model);
    }

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': _buildSystemPrompt()},
      {
        'role': 'user',
        'content': _buildUserPrompt(
          task: task,
          appName: appName,
          uiSummary: uiSummary,
        ),
      },
    ];

    try {
      final raw = switch (provider) {
        AiProvider.openrouter => await _openRouter.chatCompletion(
            apiKey: openRouterKey,
            model: model,
            messages: messages,
          ),
        AiProvider.ollama => await _ollama.chatCompletion(
            baseUrl: ollamaBaseUrl,
            model: model,
            messages: messages,
          ),
      };
      debugPrint(
        '[Preplanner] LLM raw: ${raw.length > 300 ? '${raw.substring(0, 300)}…' : raw}',
      );
      final parsed = _parseResponse(raw);
      if (parsed != null) {
        return parsed;
      }
      debugPrint('[Preplanner] Parse failed — using fallback decomposition');
    } catch (e) {
      debugPrint('[Preplanner] LLM call failed: $e');
    }

    return _fallbackDecomposition(task, source: 'fallback');
  }

  static bool isTrivialTask(String task) {
    final words = task.trim().split(RegExp(r'\s+')).length;
    if (words > 8) return false;
    final lower = task.toLowerCase();
    const trivialPrefixes = [
      'click ',
      'press ',
      'open ',
      'close ',
      'scroll ',
      'type ',
    ];
    return trivialPrefixes.any(lower.startsWith);
  }

  static String _roughPattern(String task) {
    var s = task.toLowerCase().trim();
    const stopwords = ['a ', 'an ', 'the ', 'my ', 'this ', 'that '];
    for (final w in stopwords) {
      s = s.replaceAll(w, '');
    }
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length > 60) s = s.substring(0, 60);
    return s;
  }

  static TaskDecomposition _fallbackDecomposition(
    String task, {
    required String source,
  }) {
    final normalized = _roughPattern(task);
    return TaskDecomposition(
      taskPattern: normalized.isEmpty ? 'complete task' : normalized,
      milestones: [task.trim()],
      approaches: [
        MilestoneApproach(
          title: 'Direct completion',
          confidence: 1.0,
          milestoneStrategies: [task.trim()],
        ),
      ],
      source: source,
    );
  }

  static String _buildSystemPrompt() => '''
You are a task decomposition planner for a desktop automation system.

Given a user task and target application, produce:

1. task_pattern:
- a short canonical phrase (max 8 words, lowercase)
- generalize away names, exact message text, filenames, and other specific payloads

2. milestones:
- 1 to 6 minimal milestone goals
- each milestone should describe a meaningful checkpoint, not a click sequence
- milestones should be ordered and as basic as possible

3. approaches:
- 1 to 3 realistic ways to complete the task
- each approach must include one strategy sentence per milestone
- strategy sentences describe how that approach would achieve that milestone
- no UI element ids, no coordinates, no code, no terminal instructions

You may also receive a compact summary of the CURRENT UI state.
- Use it to choose better milestone boundaries and better approach ranking.
- Treat it as transient context, not a strict script.
- Do NOT mirror raw UI labels into every milestone unless they are essential.
- Prefer approaches that fit the current visible state when that clearly reduces work.

## Response format — return ONLY valid JSON:
{
  "task_pattern": "send message to contact",
  "milestones": [
    "Open the target conversation",
    "Focus the message input",
    "Send the message"
  ],
  "approaches": [
    {
      "title": "Use visible conversation list",
      "confidence": 0.88,
      "milestone_strategies": [
        "Find and open the conversation directly from the visible list",
        "Click the composer area in the open conversation",
        "Type and send the message using the standard send flow"
      ]
    }
  ]
}

## Rules
- milestone_strategies length MUST equal milestones length
- milestones must be outcome-oriented, not implementation-heavy
- approaches should be diverse but realistic
- prefer GUI-first, reliable flows over shortcuts
- return ONLY JSON, no markdown fences, no explanation

## Milestone quality
- Prefer FEWER milestones with clear outcome boundaries over many granular steps
- Combine milestones that happen in the same view or dialog into one milestone
- A good milestone boundary is a visible UI state change: a new screen loads, a dialog opens or closes, navigation occurs
- Each milestone should be independently verifiable: "how would I know this is done just by looking at the screen?"

## Strategy quality
- Each strategy sentence should describe WHAT to interact with (e.g., "the sidebar navigation menu", "the search bar at the top"), not just the outcome
- Strategies should reference concrete UI patterns that the planner can match against real elements
- Avoid vague strategies like "complete the form" — instead say "fill in the Name and Email fields in the registration form"''';

  static String _buildUserPrompt({
    required String task,
    required String appName,
    required String uiSummary,
  }) {
    final buffer = StringBuffer()
      ..writeln('Target app: ${appName.isEmpty ? 'unknown' : appName}')
      ..writeln('Task: $task');
    if (uiSummary.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Current UI summary:')
        ..write(uiSummary.trim());
    }
    return buffer.toString();
  }

  static TaskDecomposition? _parseResponse(String raw) {
    raw = raw.trim();
    if (raw.startsWith('```')) {
      final firstNewline = raw.indexOf('\n');
      if (firstNewline > 0) raw = raw.substring(firstNewline + 1);
      if (raw.endsWith('```')) raw = raw.substring(0, raw.length - 3);
      raw = raw.trim();
    }

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      final start = raw.indexOf('{');
      final end = raw.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try {
          final decoded = jsonDecode(raw.substring(start, end + 1));
          if (decoded is Map<String, dynamic>) json = decoded;
        } catch (_) {}
      }
    }
    if (json == null) return null;

    final taskPattern =
        (json['task_pattern'] as String?)?.trim().toLowerCase() ?? '';
    final milestones = (json['milestones'] as List? ?? const [])
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList();
    final approachesRaw = json['approaches'];
    if (taskPattern.isEmpty || milestones.isEmpty || approachesRaw is! List) {
      return null;
    }

    final approaches = <MilestoneApproach>[];
    for (final item in approachesRaw.whereType<Map<String, dynamic>>()) {
      final title = (item['title'] as String?)?.trim() ?? '';
      final confidence = (item['confidence'] as num?)?.toDouble() ?? 0.5;
      final strategyList = (item['milestone_strategies'] as List? ?? const [])
          .map((strategy) => strategy.toString().trim())
          .toList();
      if (title.isEmpty) continue;
      final normalizedStrategies = <String>[
        for (var i = 0; i < milestones.length; i++)
          i < strategyList.length && strategyList[i].isNotEmpty
              ? strategyList[i]
              : milestones[i],
      ];
      approaches.add(
        MilestoneApproach(
          title: title,
          confidence: confidence,
          milestoneStrategies: normalizedStrategies,
        ),
      );
    }
    if (approaches.isEmpty) return null;
    approaches.sort((a, b) => b.confidence.compareTo(a.confidence));

    return TaskDecomposition(
      taskPattern: taskPattern,
      milestones: milestones,
      approaches: approaches,
      source: 'llm',
    );
  }
}
