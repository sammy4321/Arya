import 'dart:convert';

import 'package:arya_app/src/features/assistant/services/ai_validation.dart';
import 'package:arya_app/src/features/assistant/services/openrouter_client.dart';
import 'package:arya_app/src/features/assistant/services/strategy_cache.dart';
import 'package:flutter/foundation.dart';

/// Result of the strategy LLM call — a normalized task pattern plus ranked
/// approaches that can be cached and reused across similar tasks.
class StrategyResult {
  const StrategyResult({
    required this.taskPattern,
    required this.approaches,
    required this.source,
  });

  final String taskPattern;
  final List<StrategyApproach> approaches;

  /// "cache" when served from SQLite, "llm" when freshly generated.
  final String source;

  /// Convenience — the best approach text, or empty if none.
  String get bestApproachText =>
      approaches.isNotEmpty ? approaches.first.approach : '';
}

/// Orchestrates the two-tier strategy flow:
///
/// 1. Check `StrategyCache` for a matching (app, task_pattern).
/// 2. If miss → call LLM to produce a normalised `task_pattern` and ranked
///    approaches → store in cache.
/// 3. Return the best approach so the execution planner can incorporate it.
///
/// Also exposes `recordSuccess` / `recordFailure` for feedback.
class TaskStrategyPlanner {
  TaskStrategyPlanner({OpenRouterClient? openRouterClient})
      : _openRouter = openRouterClient ?? OpenRouterClient();

  final OpenRouterClient _openRouter;
  final StrategyCache _cache = StrategyCache.instance;

  /// Resolve a strategy for [task] running in [appName].
  ///
  /// Fast-path: if [_isTrivialTask] returns true, skips both cache and LLM.
  Future<StrategyResult?> resolve({
    required String openRouterKey,
    required String model,
    required String task,
    required String appName,
  }) async {
    if (_isTrivialTask(task)) {
      debugPrint('[Strategy] Trivial task — skipping cache+LLM');
      return null;
    }

    // Phase 1 — cache probe.
    // We need the normalised pattern. Try a quick LLM-free keyword match
    // against existing cache entries for this app.
    final candidatePattern = _roughPattern(task);
    final cached = await _cache.lookup(
      appName: appName,
      taskPattern: candidatePattern,
    );

    if (cached != null) {
      final best = cached.bestApproach;
      if (best != null) {
        debugPrint(
          '[Strategy] Cache HIT for "$appName / $candidatePattern" '
          '(uses=${cached.useCount}, fails=${cached.failCount})',
        );
        await _cache.recordSuccess(
          appName: appName,
          taskPattern: cached.taskPattern,
        );
        return StrategyResult(
          taskPattern: cached.taskPattern,
          approaches: cached.approaches,
          source: 'cache',
        );
      }
    }

    // Phase 2 — strategy LLM call.
    debugPrint('[Strategy] Cache miss — calling strategy LLM');
    validateOpenRouterConfig(apiKey: openRouterKey, model: model);

    final systemPrompt = _buildSystemPrompt();
    final userPrompt = _buildUserPrompt(task: task, appName: appName);

    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userPrompt},
    ];

    String raw;
    try {
      raw = await _openRouter.chatCompletion(
        apiKey: openRouterKey,
        model: model,
        messages: messages,
      );
    } catch (e) {
      debugPrint('[Strategy] LLM call failed: $e');
      return null;
    }

    debugPrint('[Strategy] LLM raw: ${raw.length > 300 ? '${raw.substring(0, 300)}…' : raw}');

    final parsed = _parseResponse(raw);
    if (parsed == null) {
      debugPrint('[Strategy] Failed to parse strategy JSON');
      return null;
    }

    // Store in cache.
    await _cache.store(
      appName: appName,
      taskPattern: parsed.taskPattern,
      approaches: parsed.approaches,
    );

    return parsed;
  }

  /// Record successful task completion.
  Future<void> recordSuccess({
    required String appName,
    required String taskPattern,
  }) async {
    await _cache.recordSuccess(appName: appName, taskPattern: taskPattern);
  }

  /// Record task failure (replan exhaustion).
  Future<void> recordFailure({
    required String appName,
    required String taskPattern,
  }) async {
    await _cache.recordFailure(appName: appName, taskPattern: taskPattern);
  }

  // ---------------------------------------------------------------------------
  // Trivial task detection — single obvious action, no strategy needed.
  // ---------------------------------------------------------------------------

  static bool _isTrivialTask(String task) {
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

  // ---------------------------------------------------------------------------
  // Rough pattern — a cheap, LLM-free normalisation for cache probing.
  //
  // Strips articles, lowercases, and trims to max 60 chars. Only used for
  // cache lookup — the LLM produces the authoritative pattern for storage.
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Prompt construction
  // ---------------------------------------------------------------------------

  static String _buildSystemPrompt() => '''
You are a task strategy analyst for a desktop automation system. Given a user's task description and the target application, produce:

1. **task_pattern** — a short, canonical phrase (max 8 words, lowercase) that captures the *intent* independent of specific details. Examples:
   - "send message to contact" (not "send hi to John on WhatsApp")
   - "create new file in project" (not "create index.html in my React app")
   - "commit changes with message"

2. **approaches** — a ranked list (1-4) of high-level strategies to accomplish the task, each with a confidence score (0.0–1.0). Approaches describe *how* to achieve the goal via GUI interaction patterns, NOT concrete click sequences.

## Response format — return ONLY valid JSON:
{
  "task_pattern": "short canonical intent",
  "approaches": [
    {"approach": "Description of strategy 1", "confidence": 0.9},
    {"approach": "Description of strategy 2", "confidence": 0.6}
  ]
}

## Rules:
- task_pattern must generalise across similar tasks (strip names, filenames, specific text).
- Approaches should describe GUI navigation paths, not code or API calls.
- Rank by reliability: prefer approaches that use clearly labeled buttons/menus over shortcuts.
- Confidence reflects how likely the approach succeeds in a typical desktop automation context.
- Return ONLY the JSON object, no markdown fences, no explanation.''';

  static String _buildUserPrompt({
    required String task,
    required String appName,
  }) =>
      'Target app: $appName\nTask: $task';

  // ---------------------------------------------------------------------------
  // Response parsing
  // ---------------------------------------------------------------------------

  static StrategyResult? _parseResponse(String raw) {
    raw = raw.trim();

    // Strip markdown fences if present.
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
      // Try to extract the first { ... } block.
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
    if (taskPattern.isEmpty) return null;

    final approachesRaw = json['approaches'];
    if (approachesRaw is! List || approachesRaw.isEmpty) return null;

    final approaches = approachesRaw
        .whereType<Map<String, dynamic>>()
        .map(StrategyApproach.fromJson)
        .where((a) => a.approach.trim().isNotEmpty)
        .toList();

    if (approaches.isEmpty) return null;

    // Sort by confidence descending.
    approaches.sort((a, b) => b.confidence.compareTo(a.confidence));

    return StrategyResult(
      taskPattern: taskPattern,
      approaches: approaches,
      source: 'llm',
    );
  }
}
