import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arya_app/src/core/window_helpers.dart';
import 'package:arya_app/src/features/assistant/models/chat_models.dart';
import 'package:arya_app/src/features/assistant/services/attachment_policy.dart';
import 'package:arya_app/src/features/assistant/services/action_executor_service.dart';
import 'package:arya_app/src/features/assistant/services/screenshot_service.dart';
import 'package:arya_app/src/features/assistant/services/step_planner.dart';
import 'package:arya_app/src/features/assistant/services/task_strategy_planner.dart';
import 'package:arya_app/src/features/assistant/services/ui_parser_service.dart';
import 'package:arya_app/src/features/assistant/widgets/copy_button.dart';
import 'package:arya_app/src/features/settings/ai_settings_store.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

const _maxSteps = 15;
const _maxReplans = 3;

class TakeActionView extends StatefulWidget {
  const TakeActionView({super.key});

  @override
  State<TakeActionView> createState() => _TakeActionViewState();
}

class _TakeActionViewState extends State<TakeActionView> {
  final _controller = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  bool _isLoading = false;
  bool _isPlanning = false;
  bool _isEditingTask = false;
  String _webMode = 'auto';
  String? _abortReason;
  String? _taskText;
  final List<_CapturedScreenshot> _capturedScreenshots = [];
  final List<ChatAttachment> _pendingAttachments = [];
  final List<_ActionStep> _steps = [];
  final List<String> _logs = [];
  final List<PlannerTrace> _plannerTraces = [];
  String _latestPlannerReasoning = '';
  bool _isPlannerThinking = false;
  bool _isThinkingModelSelected = false;
  String? _latestScreenshotPath;
  List<UIElement> _latestUIElements = [];
  int? _targetAppPid;
  late final StepPlanner _planner;
  late final TaskStrategyPlanner _strategyPlanner;
  StrategyResult? _activeStrategy;
  String _resolvedAppName = '';

  @override
  void initState() {
    super.initState();
    _planner = StepPlanner(
      traceLogger: _recordPlannerTrace,
      reasoningLogger: _onPlannerReasoningUpdate,
    );
    _strategyPlanner = TaskStrategyPlanner();
    UIParserService.instance.warmUp();
    ActionExecutorService.instance.warmUp();
  }

  @override
  void dispose() {
    _controller.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final model = await AiSettingsStore.instance.getModel();
    if (model.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a model first.')),
      );
      return;
    }

    final attachments = List<ChatAttachment>.from(_pendingAttachments);
    setState(() {
      _taskText = text;
      _isLoading = true;
      _isPlanning = false;
      _isEditingTask = false;
      _isThinkingModelSelected = _looksLikeThinkingModel(model);
      _steps.clear();
      _logs.clear();
      _plannerTraces.clear();
      _latestPlannerReasoning = '';
      _isPlannerThinking = false;
      _capturedScreenshots.clear();
      _abortReason = null;
      _pendingAttachments.clear();
      _latestScreenshotPath = null;
      _targetAppPid = null;
      _activeStrategy = null;
      _resolvedAppName = '';
      ActionExecutorService.instance.targetAppPid = null;
    });
    _controller.clear();

    await _runPlanBasedLoop(task: text, model: model, attachments: attachments);

    if (mounted) setState(() => _isLoading = false);
  }

  void _stopExecution() {
    if (!_isLoading) return;
    final lastTask = _taskText ?? '';
    setState(() {
      _isLoading = false;
      _isPlanning = false;
      if (lastTask.isNotEmpty) {
        _controller.value = TextEditingValue(
          text: lastTask,
          selection: TextSelection.collapsed(offset: lastTask.length),
        );
      }
      _logs.add('Stopped by user.');
    });
  }

  void _editCurrentTask() {
    final task = _taskText?.trim() ?? '';
    if (task.isEmpty || _isLoading) return;
    _controller.value = TextEditingValue(
      text: task,
      selection: TextSelection.collapsed(offset: task.length),
    );
    setState(() => _isEditingTask = true);
    _inputFocusNode.requestFocus();
  }

  void _cancelTaskEditMode() {
    if (_isLoading) return;
    setState(() {
      _isEditingTask = false;
      _controller.clear();
    });
  }

  // =========================================================================
  // Plan-based execution loop
  //
  // 1. Screenshot + UI parse → LLM generates FULL plan (one call).
  // 2. Execute each step deterministically (no LLM between steps).
  // 3. After each step: quick UI parse → check verify criteria.
  // 4. If criteria pass → next step.
  // 5. If criteria fail → screenshot + LLM re-plan (max _maxReplans).
  // =========================================================================

  Future<void> _runPlanBasedLoop({
    required String task,
    required String model,
    required List<ChatAttachment> attachments,
  }) async {
    final store = AiSettingsStore.instance;
    final openRouterKey = await store.getApiKey();
    final tavilyKey = await store.getTavilyApiKey();

    if (openRouterKey.isEmpty) {
      _setAbort('OpenRouter API key is missing. Set it in Settings.');
      return;
    }

    final screenContext = await getCurrentWindowDisplayRegion() ?? {};
    final regionLeft = (screenContext['left'] as num?)?.toInt() ?? 0;
    final regionTop = (screenContext['top'] as num?)?.toInt() ?? 0;
    final regionWidth = (screenContext['width'] as num?)?.toInt() ?? 1800;
    final regionHeight = (screenContext['height'] as num?)?.toInt() ?? 1066;
    final scaleFactor =
        (screenContext['scaleFactor'] as num?)?.toDouble() ?? 1.0;

    final captureRegion = CaptureRegion(
      x: regionLeft,
      y: regionTop,
      width: regionWidth,
      height: regionHeight,
    );

    _log(
      'Screen region: ($regionLeft,$regionTop) '
      '${regionWidth}x$regionHeight scale=$scaleFactor',
    );

    final attachmentMaps = attachments.map(_toAttachmentMap).toList();
    final history = <Map<String, String>>[];

    // --- Phase 1: Initial capture (UI elements only) + full plan ---
    if (mounted) setState(() => _isPlanning = true);
    await _captureContext('Initial context', region: captureRegion);
    final appContext = await _buildTargetAppContext();
    final plannerScreenContext = {...screenContext, ...appContext};
    _resolvedAppName =
        (appContext['target_app_name'] as String?)?.trim().toLowerCase() ?? '';

    // Strategy resolution — cache probe → LLM fallback.
    String strategyHint = '';
    try {
      final strategy = await _strategyPlanner.resolve(
        openRouterKey: openRouterKey,
        model: model,
        task: task,
        appName: _resolvedAppName,
      );
      if (strategy != null) {
        _activeStrategy = strategy;
        strategyHint = strategy.bestApproachText;
        _log(
          'Strategy resolved (${strategy.source}): '
          'pattern="${strategy.taskPattern}" '
          'approach="${strategyHint.length > 80 ? '${strategyHint.substring(0, 80)}…' : strategyHint}"',
        );
      }
    } catch (e) {
      debugPrint('[Strategy] Error during resolve: $e');
    }

    _log('Generating plan…');
    List<PlannedStep> plan;
    try {
      plan = await _planner.generateFullPlan(
        openRouterKey: openRouterKey,
        model: model,
        task: task,
        screenContext: plannerScreenContext,
        uiContext: formatUIElementsForPrompt(_latestUIElements),
        screenshotPath: _latestScreenshotPath,
        tavilyKey: tavilyKey,
        webMode: _webMode,
        attachments: attachmentMaps,
        strategyHint: strategyHint,
      );
    } catch (e) {
      if (mounted) setState(() => _isPlanning = false);
      _setAbort('Plan generation failed: $e');
      return;
    }

    if (mounted) setState(() => _isPlanning = false);

    if (plan.isEmpty) {
      _setAbort('LLM returned an empty plan.');
      return;
    }

    _setPlanSteps(plan);
    _log('Plan: ${plan.length} steps');
    for (final s in plan) {
      _log('  ${s.id}: ${s.title} [${s.action}]');
    }

    // --- Phase 2: Deterministic execution with completion verification ---
    var replansUsed = 0;
    var totalSteps = 0;
    PlannedStep? lastExecutedStep;

    while (totalSteps < _maxSteps) {
      // Execute current plan steps.
      while (plan.isNotEmpty && totalSteps < _maxSteps) {
        if (!mounted || !_isLoading) return;

        final step = plan.removeAt(0);
        totalSteps++;
        lastExecutedStep = step;

        _updateStep(step.id, 'started', '');
        _log('Executing: ${step.title}');

        final stepMap = step.toStepMap();
        final resolvedStep = _resolveClickTarget(stepMap, _latestUIElements);
        final resolvedEl =
            (resolvedStep['args'] as Map?)?['_resolved_element'] as String?;
        if (resolvedEl != null) {
          _log('  → Target: $resolvedEl');
        }
        final adjustedStep = resolvedStep;

        final result = await ActionExecutorService.instance.executeStep(
          adjustedStep,
        );

        if (!result.ok) {
          _updateStep(step.id, 'failed', result.detail);
          _log('FAILED: ${step.title} — ${result.detail}');
          history.add({
            'step_id': step.id,
            'title': step.title,
            'status': 'failed',
            'detail': result.detail,
          });

          if (replansUsed >= _maxReplans) {
            _setAbort('Max re-plans ($replansUsed) exhausted.');
            _recordStrategyOutcome(success: false);
            return;
          }
          plan = await _replan(
            task: task,
            model: model,
            openRouterKey: openRouterKey,
            screenContext: screenContext,
            history: history,
            failedStep: step,
            failureDetail: 'Execution failed: ${result.detail}',
            remainingSteps: plan,
            captureRegion: captureRegion,
          );
          _setPlanSteps(plan);
          replansUsed++;
          continue;
        }

        // Execution succeeded.
        history.add({
          'step_id': step.id,
          'title': step.title,
          'status': 'completed',
          'detail': result.detail,
        });
        _updateStep(step.id, 'completed', result.detail);
        _log('${step.title}: ${result.detail}');

        if (step.thenChain != null) {
          await _executeChainedActions(
            stepMap,
            stepId: step.id,
            history: history,
          );
        }

        // --- Per-step verification ---
        await Future.delayed(const Duration(milliseconds: 500));
        final verifyElements = await UIParserService.instance.parseScreen(
          targetPid: _targetAppPid,
        );
        _latestUIElements = verifyElements;

        final passed = step.verify.check(verifyElements);
        if (passed) {
          _log('✓ Verify passed: ${step.verify}');
          continue;
        }

        _log('✗ Verify FAILED: ${step.verify}');
        if (replansUsed >= _maxReplans) {
          _setAbort('Verification failed and max re-plans exhausted.');
          _recordStrategyOutcome(success: false);
          return;
        }

        plan = await _replan(
          task: task,
          model: model,
          openRouterKey: openRouterKey,
          screenContext: screenContext,
          history: history,
          failedStep: step,
          failureDetail: 'Verification failed: expected ${step.verify}',
          remainingSteps: plan,
          captureRegion: captureRegion,
        );
        _setPlanSteps(plan);
        replansUsed++;
      }

      // --- Task-level completion check ---
      if (_abortReason != null || !mounted || !_isLoading) return;
      if (totalSteps >= _maxSteps || lastExecutedStep == null) break;
      if (replansUsed >= _maxReplans) break;

      _log('Verifying task completion…');
      plan = await _replan(
        task: task,
        model: model,
        openRouterKey: openRouterKey,
        screenContext: plannerScreenContext,
        history: history,
        failedStep: lastExecutedStep,
        failureDetail:
            'All planned steps were executed. '
            'Verify whether the original task "$task" was fully '
            'accomplished by examining the current UI state. '
            'Return an empty array [] if complete, '
            'or provide additional steps if more work is needed.',
        remainingSteps: [],
        captureRegion: captureRegion,
      );

      if (plan.isEmpty) {
        _log('✓ Task verified as complete.');
        _recordStrategyOutcome(success: true);
        break;
      }

      _log('Task needs ${plan.length} more steps.');
      _setPlanSteps(plan);
      replansUsed++;
    }

    if (totalSteps >= _maxSteps) {
      _log('Reached maximum step limit ($_maxSteps).');
      _recordStrategyOutcome(success: false);
    }
  }

  /// Captures fresh context and calls LLM to produce a new plan.
  Future<List<PlannedStep>> _replan({
    required String task,
    required String model,
    required String openRouterKey,
    required Map<String, dynamic> screenContext,
    required List<Map<String, String>> history,
    required PlannedStep failedStep,
    required String failureDetail,
    required List<PlannedStep> remainingSteps,
    required CaptureRegion captureRegion,
  }) async {
    _log('Re-planning (capturing fresh context + screenshot)…');
    await _captureContext(
      'Re-plan context',
      captureScreenshot: true,
      region: captureRegion,
    );
    final plannerScreenContext = {
      ...screenContext,
      ...await _buildTargetAppContext(),
    };

    try {
      final newPlan = await _planner.replanFromFailure(
        openRouterKey: openRouterKey,
        model: model,
        task: task,
        screenContext: plannerScreenContext,
        uiContext: formatUIElementsForPrompt(_latestUIElements),
        history: history,
        failedStep: failedStep,
        failureDetail: failureDetail,
        remainingSteps: remainingSteps,
        screenshotPath: _latestScreenshotPath,
      );
      _log('Re-plan received: ${newPlan.length} steps');
      for (final s in newPlan) {
        _log('  ${s.id}: ${s.title} [${s.action}] verify=${s.verify}');
      }
      return newPlan;
    } catch (e) {
      _log('Re-plan failed: $e');
      return [];
    }
  }

  /// Walks the "then" chain in a step and executes each follow-up action
  /// with a settle delay that adapts to context. After a click that chains
  /// into type_text, Electron apps (VS Code, etc.) need ~800ms to create
  /// and focus the inline input; a flat 300ms causes keystrokes to arrive
  /// before the input exists, producing error sounds.
  ///
  /// Delay logic:
  ///   1. If the chain item specifies `wait_ms`, use that.
  ///   2. If previous action was click and this is type_text → 800ms
  ///      (accounts for Electron menu → inline-input creation).
  ///   3. Otherwise → 400ms default.
  ///
  /// Chains up to 3 levels deep to prevent runaway loops.
  Future<void> _executeChainedActions(
    Map<String, dynamic> stepData, {
    required String stepId,
    required List<Map<String, String>> history,
  }) async {
    var current = stepData['then'];
    var prevAction = (stepData['action'] as String? ?? '').toLowerCase();
    var chainIndex = 0;
    const maxChain = 3;

    while (current is Map<String, dynamic> && chainIndex < maxChain) {
      chainIndex++;
      final chainAction = (current['action'] as String? ?? '').toLowerCase();
      final chainTitle = '${stepId}_then_$chainIndex ($chainAction)';

      final explicitWait = current['wait_ms'] as num?;
      final int delayMs;
      if (explicitWait != null) {
        delayMs = explicitWait.toInt().clamp(100, 5000);
      } else if (prevAction == 'click' && chainAction == 'type_text') {
        delayMs = 800;
      } else {
        delayMs = 400;
      }

      _log('Chain [$chainIndex]: $chainAction (wait ${delayMs}ms)');
      await Future.delayed(Duration(milliseconds: delayMs));

      final resolved = _resolveClickTarget(current, _latestUIElements);
      final chainResult = await ActionExecutorService.instance.executeStep(
        resolved,
      );

      history.add({
        'step_id': chainTitle,
        'title': chainTitle,
        'status': chainResult.ok ? 'completed' : 'failed',
        'detail': chainResult.detail,
      });
      _log(
        'Chain [$chainIndex] ${chainResult.ok ? "OK" : "FAIL"}: '
        '${chainResult.detail}',
      );

      if (!chainResult.ok) break;
      prevAction = chainAction;
      current = current['then'];
    }
  }

  /// Resolves a click target to concrete (x, y) coordinates.
  ///
  /// Supports two modes:
  /// 1. **element_id** — direct lookup by parsed ID (used for step 1).
  /// 2. **match_role / match_label** — descriptive search (used for later
  ///    steps where the UI has changed and IDs are stale).
  ///
  /// Also applies position ("center", "top_left", etc.) with padding.
  Map<String, dynamic> _resolveClickTarget(
    Map<String, dynamic> step,
    List<UIElement> elements,
  ) {
    final action = (step['action'] as String? ?? '').toLowerCase();
    if (action != 'click') return step;

    final args = step['args'];
    if (args is! Map<String, dynamic>) return step;

    UIElement? el;

    // Mode 1: element_id.
    final elementId = args['element_id'];
    if (elementId != null) {
      final id = (elementId as num).toInt();
      final match = elements.where((e) => e.id == id);
      if (match.isNotEmpty) {
        el = match.first;
        debugPrint('[TakeAction] Resolved by id [$id] "${el.label}"');
      } else {
        debugPrint(
          '[TakeAction] ⚠ Element [$id] not found — '
          '${elements.length} elements available',
        );
      }
    }

    // Mode 2: match_role / match_label — scored matching.
    //
    // Scoring: exact match > starts-with > contains.
    // This prevents "Commit" from matching "Commit description" when a
    // "Commit to main" button is available.
    if (el == null) {
      final matchRole = args['match_role'] as String?;
      final matchLabel = (args['match_label'] as String?)?.toLowerCase();

      if (matchRole != null || matchLabel != null) {
        UIElement? bestMatch;
        int bestScore = -1;

        for (final e in elements) {
          if (matchRole != null && e.role != matchRole) continue;
          if (matchLabel == null) {
            bestMatch = e;
            break;
          }

          final label = e.label.toLowerCase();
          final value = e.value.toLowerCase();
          final desc = e.description.toLowerCase();

          int score;
          if (label == matchLabel ||
              value == matchLabel ||
              desc == matchLabel) {
            score = 100;
          } else if (label.startsWith(matchLabel) ||
              value.startsWith(matchLabel)) {
            score = 50;
          } else if (label.contains(matchLabel) ||
              value.contains(matchLabel) ||
              desc.contains(matchLabel)) {
            score = 10;
          } else {
            continue;
          }

          debugPrint(
            '[TakeAction] Match candidate: [${e.id}] '
            '"${e.label}" role=${e.role} score=$score',
          );

          if (score > bestScore) {
            bestScore = score;
            bestMatch = e;
          }
        }

        el = bestMatch;
        if (el != null) {
          debugPrint(
            '[TakeAction] Best match: [${el.id}] "${el.label}" '
            'role=${el.role} score=$bestScore',
          );
        } else {
          debugPrint(
            '[TakeAction] ⚠ No element matched '
            'role=$matchRole label=$matchLabel',
          );
        }
      }
    }

    // If no element resolved, return step unchanged (raw x/y fallback).
    if (el == null) return step;

    final position = (args['position'] as String? ?? 'center').toLowerCase();

    const pad = 10;
    int x, y;
    switch (position) {
      case 'top_left':
        x = el.x + pad;
        y = el.y + pad;
      case 'top_right':
        x = el.x + el.width - pad;
        y = el.y + pad;
      case 'bottom_left':
        x = el.x + pad;
        y = el.y + el.height - pad;
      case 'bottom_right':
        x = el.x + el.width - pad;
        y = el.y + el.height - pad;
      default:
        // ComboBox / PopUpButton: clicking center often hits the dropdown
        // button instead of the text input area. Bias toward the left side
        // where the editable text portion lives.
        if (el.role == 'ComboBox' || el.role == 'PopUpButton') {
          x = el.x + (el.width * 0.3).round().clamp(pad, el.width - pad);
          y = el.centerY;
        } else {
          x = el.centerX;
          y = el.centerY;
        }
    }

    debugPrint(
      '[TakeAction] Click target: [${el.id}] "${el.label}" '
      'role=${el.role} pos=$position → ($x, $y)',
    );

    final resolvedArgs = Map<String, dynamic>.from(args)
      ..remove('element_id')
      ..remove('match_role')
      ..remove('match_label')
      ..remove('position')
      ..['x'] = x
      ..['y'] = y
      ..['_resolved_element'] = '[${el.id}] ${el.role}: "${el.label}"';

    return Map<String, dynamic>.from(step)..['args'] = resolvedArgs;
  }

  /// Resolves the target app PID, parses its accessibility tree, and
  /// optionally captures a screenshot for re-plan calls.
  ///
  /// PID resolution uses `getFrontmostPid` which already skips our own PID
  /// by walking the window list. The UI parser queries the target app's
  /// accessibility tree directly by PID — no need to hide Arya or change
  /// window focus. `activateTargetApp` is called once (on first capture)
  /// to ensure macOS provides a complete accessibility tree.
  Future<void> _captureContext(
    String label, {
    bool captureScreenshot = false,
    CaptureRegion? region,
  }) async {
    final isFirstCapture = _targetAppPid == null;
    _targetAppPid ??= await UIParserService.instance.getFrontmostPid(
      region: region,
    );
    ActionExecutorService.instance.targetAppPid = _targetAppPid;

    if (isFirstCapture && _targetAppPid != null) {
      await ActionExecutorService.instance.activateTargetApp(force: true);
      await Future.delayed(const Duration(milliseconds: 150));
    }

    String? path;
    if (captureScreenshot) {
      path = await ScreenshotService.instance.captureFullScreen(
        hideWindow: false,
        region: region,
      );
      if (path == null) {
        await Future.delayed(const Duration(milliseconds: 220));
        path = await ScreenshotService.instance.captureFullScreen(
          hideWindow: false,
          region: region,
        );
      }
    }

    final elements = await UIParserService.instance.parseScreen(
      targetPid: _targetAppPid,
    );

    if (!mounted) return;
    if (path != null && path.isNotEmpty) {
      _latestScreenshotPath = path;
    }
    _latestUIElements = elements;

    setState(() {
      if (captureScreenshot && path != null && path.isNotEmpty) {
        _capturedScreenshots.add(
          _CapturedScreenshot(
            path: path,
            label: label,
            createdAt: DateTime.now(),
          ),
        );
        _logs.add('$label (screenshot + ${elements.length} UI elements)');
      } else {
        _logs.add('$label (${elements.length} UI elements)');
      }
    });
  }

  void _log(String message) {
    debugPrint('[TakeAction] $message');
    if (!mounted) return;
    setState(() => _logs.add(message));
  }

  void _setAbort(String reason) {
    debugPrint('[TakeAction] *** ABORT: $reason');
    if (!mounted) return;
    setState(() {
      _abortReason = reason;
      _logs.add('Aborted: $reason');
    });
  }

  void _updateStep(String id, String status, String detail) {
    if (!mounted) return;
    setState(() {
      final index = _steps.indexWhere((s) => s.id == id);
      if (index >= 0) {
        _steps[index] = _steps[index].copyWith(status: status, detail: detail);
      }
    });
  }

  void _setPlanSteps(List<PlannedStep> plan) {
    if (!mounted) return;
    setState(() {
      _steps.removeWhere((s) => s.status == 'pending');
      for (final s in plan) {
        _steps.add(
          _ActionStep(id: s.id, title: s.title, status: 'pending', detail: ''),
        );
      }
    });
  }

  void _recordPlannerTrace(PlannerTrace trace) {
    if (!mounted) return;
    setState(() {
      _plannerTraces.add(trace);
      if (trace.reasoning.trim().isNotEmpty) {
        _latestPlannerReasoning = trace.reasoning.trim();
      }
    });
  }

  void _onPlannerReasoningUpdate(String label, String reasoning, bool done) {
    if (!mounted) return;
    setState(() {
      _isPlannerThinking = !done;
      if (reasoning.trim().isNotEmpty) {
        _latestPlannerReasoning = reasoning.trim();
      }
    });
  }

  void _recordStrategyOutcome({required bool success}) {
    final strategy = _activeStrategy;
    if (strategy == null || _resolvedAppName.isEmpty) return;
    if (success) {
      _strategyPlanner.recordSuccess(
        appName: _resolvedAppName,
        taskPattern: strategy.taskPattern,
      );
      _log('Strategy "${strategy.taskPattern}" marked as successful.');
    } else {
      _strategyPlanner.recordFailure(
        appName: _resolvedAppName,
        taskPattern: strategy.taskPattern,
      );
      _log('Strategy "${strategy.taskPattern}" marked as failed.');
    }
  }

  bool _looksLikeThinkingModel(String model) {
    final m = model.toLowerCase();
    const hints = <String>[
      'thinking',
      'reason',
      'r1',
      '/o1',
      '/o3',
      '/o4',
      'grok-',
    ];
    return hints.any(m.contains);
  }

  Future<Map<String, dynamic>> _buildTargetAppContext() async {
    final pid = _targetAppPid;
    final windowTitle = _extractPrimaryWindowTitle(_latestUIElements);
    if (pid == null) {
      return {
        if (windowTitle != null) 'target_window_title': windowTitle,
      };
    }

    final exePath = await _resolveExecutablePath(pid);
    final exeName = _executableNameFromPath(exePath);
    final appName = exeName.replaceAll('.app', '');

    return {
      'target_pid': pid,
      if (appName.isNotEmpty) 'target_app_name': appName,
      if (exePath.isNotEmpty) 'target_executable_path': exePath,
      if (windowTitle != null) 'target_window_title': windowTitle,
    };
  }

  String? _extractPrimaryWindowTitle(List<UIElement> elements) {
    for (final el in elements) {
      if ((el.role == 'Window' || el.role == 'Dialog' || el.role == 'Sheet') &&
          el.title.trim().isNotEmpty) {
        return el.title.trim();
      }
    }
    return null;
  }

  Future<String> _resolveExecutablePath(int pid) async {
    try {
      final result = await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
      if (result.exitCode != 0) return '';
      return (result.stdout as String).trim();
    } catch (_) {
      return '';
    }
  }

  String _executableNameFromPath(String path) {
    if (path.isEmpty) return '';
    final pieces = path.split('/');
    if (pieces.isEmpty) return path;
    final raw = pieces.last.trim();
    if (raw.isEmpty) return path;
    return raw;
  }

  Map<String, dynamic> _toAttachmentMap(ChatAttachment a) {
    String summary;
    if (a.isImage) {
      summary = '[Image: ${a.name}]';
    } else if (a.name.toLowerCase().endsWith('.pdf')) {
      summary = '[PDF: ${a.name}]';
    } else {
      try {
        summary = utf8.decode(a.bytes);
      } catch (_) {
        summary = '[Binary: ${a.name}]';
      }
    }
    if (summary.length > 4000) summary = '${summary.substring(0, 4000)}...';
    return {'name': a.name, 'is_image': a.isImage, 'summary': summary};
  }

  Future<void> _pickFileFromComputer() async {
    const typeGroup = XTypeGroup(
      label: 'Supported files',
      extensions: [...supportedAttachmentExtensions],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!isSupportedAttachmentFile(file.name) || bytes.isEmpty) {
      return;
    }
    final isImage = isImageAttachmentFile(file.name);
    setState(() {
      _pendingAttachments.add(
        ChatAttachment(name: file.name, bytes: bytes, isImage: isImage),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            color: const Color(0xFF373E47),
            child: _buildProgressPanel(),
          ),
        ),
        _buildControlsRow(),
        if (_isEditingTask)
          _EditTaskModeBanner(
            isLoading: _isLoading,
            onCancel: _cancelTaskEditMode,
          ),
        _buildInput(),
      ],
    );
  }

  Widget _buildControlsRow() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF373E47),
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Row(
        children: [
          const Spacer(),
          const Text(
            'Web:',
            style: TextStyle(color: Color(0xFF6B7585), fontSize: 11),
          ),
          const SizedBox(width: 4),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _webMode,
              dropdownColor: const Color(0xFF2A3441),
              isDense: true,
              style: const TextStyle(color: Color(0xFF9EA5AF), fontSize: 11),
              items: const [
                DropdownMenuItem(value: 'auto', child: Text('Auto')),
                DropdownMenuItem(value: 'always', child: Text('Always')),
                DropdownMenuItem(value: 'never', child: Text('Never')),
              ],
              onChanged: _isLoading
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() => _webMode = value);
                    },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressPanel() {
    if (_taskText == null && _steps.isEmpty && _logs.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.touch_app_outlined, color: Color(0xFF4E5661), size: 32),
            SizedBox(height: 12),
            Text(
              'Describe the action you want me to take',
              style: TextStyle(color: Color(0xFF6B7585), fontSize: 14),
            ),
          ],
        ),
      );
    }

    final isComplete = !_isLoading && _steps.isNotEmpty && _abortReason == null;

    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          if (_taskText != null) ...[
            _TaskBubbleWithActions(
              text: _taskText!,
              canEdit: !_isLoading,
              onEdit: _editCurrentTask,
            ),
            const SizedBox(height: 16),
          ],
          if (_activeStrategy != null) ...[
            _StrategyBadge(strategy: _activeStrategy!),
            const SizedBox(height: 8),
          ],
          if (_isPlanning) ...[
            const _PlanningIndicator(),
            const SizedBox(height: 12),
          ],
          if (_isThinkingModelSelected &&
              (_isPlanning ||
                  _isPlannerThinking ||
                  _latestPlannerReasoning.isNotEmpty)) ...[
            _PlannerReasoningBanner(
              isThinking: _isPlanning || _isPlannerThinking,
              reasoning: _latestPlannerReasoning,
            ),
            const SizedBox(height: 12),
          ],
          if (_steps.isNotEmpty)
            for (var i = 0; i < _steps.length; i++)
              _StepTimelineRow(
                step: _steps[i],
                isFirst: i == 0,
                isLast: i == _steps.length - 1,
              ),
          if (isComplete) ...[
            const SizedBox(height: 8),
            const _ResultBanner(
              icon: Icons.check_circle_outline,
              color: Color(0xFF81C784),
              text: 'All steps completed',
            ),
          ],
          if (_abortReason != null) ...[
            const SizedBox(height: 8),
            _ResultBanner(
              icon: Icons.error_outline,
              color: const Color(0xFFE57373),
              text: _abortReason!,
            ),
          ],
          if (_logs.isNotEmpty || _plannerTraces.isNotEmpty) ...[
            const SizedBox(height: 14),
            _CollapsibleLogSection(
              logs: _logs,
              plannerTraces: _plannerTraces,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInput() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF4E5661),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(11)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 120),
              decoration: BoxDecoration(
                color: const Color(0xFF373E47),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: InkWell(
                      onTap: _pickFileFromComputer,
                      borderRadius: BorderRadius.circular(8),
                      child: const Icon(
                        Icons.add,
                        color: Color(0xFFD2D8DF),
                        size: 20,
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _inputFocusNode,
                      style: const TextStyle(
                        color: Color(0xFFE8E9EB),
                        fontSize: 14,
                      ),
                      maxLines: 5,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) =>
                          _isLoading ? null : unawaited(_submit()),
                      decoration: const InputDecoration(
                        hintText: 'Describe the action you want me to take...',
                        hintStyle: TextStyle(
                          color: Color(0xFF9EA5AF),
                          fontSize: 14,
                        ),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        isCollapsed: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: _isLoading ? 'Stop current task' : 'Run task',
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _isLoading
                  ? InkWell(
                      key: const ValueKey('take_action_loading_stop_button'),
                      onTap: _stopExecution,
                      borderRadius: BorderRadius.circular(20),
                      child: SizedBox(
                        width: 38,
                        height: 38,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            const SizedBox(
                              width: 38,
                              height: 38,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Color(0xFF9CC8FF),
                              ),
                            ),
                            Container(
                              width: 30,
                              height: 30,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xFF5F6C7B),
                              ),
                              child: const Icon(
                                Icons.stop_rounded,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : InkWell(
                      key: const ValueKey('take_action_idle_send_button'),
                      onTap: () => unawaited(_submit()),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1F80E9),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.send, color: Colors.white, size: 18),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionStep {
  const _ActionStep({
    required this.id,
    required this.title,
    required this.status,
    required this.detail,
  });

  final String id;
  final String title;
  final String status;
  final String detail;

  _ActionStep copyWith({String? status, String? detail}) {
    return _ActionStep(
      id: id,
      title: title,
      status: status ?? this.status,
      detail: detail ?? this.detail,
    );
  }
}

class _CapturedScreenshot {
  const _CapturedScreenshot({
    required this.path,
    required this.label,
    required this.createdAt,
  });

  final String path;
  final String label;
  final DateTime createdAt;
}

// ---------------------------------------------------------------------------
// UI Widgets
// ---------------------------------------------------------------------------

class _TaskBubble extends StatelessWidget {
  const _TaskBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1F80E9),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

class _TaskBubbleWithActions extends StatelessWidget {
  const _TaskBubbleWithActions({
    required this.text,
    required this.canEdit,
    required this.onEdit,
  });

  final String text;
  final bool canEdit;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          _TaskBubble(text: text),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: canEdit ? onEdit : null,
                iconSize: 14,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                color: const Color(0xFFB8C1CC),
                disabledColor: const Color(0xFF6D7682),
                tooltip: canEdit ? 'Edit task' : 'Running',
                style: IconButton.styleFrom(
                  splashFactory: NoSplash.splashFactory,
                  highlightColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                ),
                icon: const Icon(Icons.edit_outlined),
              ),
              const SizedBox(width: 2),
              CopyButton(
                textToCopy: text,
                iconColor: const Color(0xFFB8C1CC),
                copiedIconColor: const Color(0xFFD2D8DF),
                size: 14,
                tooltip: 'Copy Message',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StrategyBadge extends StatelessWidget {
  const _StrategyBadge({required this.strategy});

  final StrategyResult strategy;

  @override
  Widget build(BuildContext context) {
    final isCached = strategy.source == 'cache';
    final icon = isCached ? Icons.cached : Icons.auto_awesome_outlined;
    final label = isCached ? 'Cached strategy' : 'New strategy';
    final pattern = strategy.taskPattern;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF2A3441),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isCached
              ? const Color(0xFF4E886B)
              : const Color(0xFF4E6288),
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 14,
            color: isCached
                ? const Color(0xFF81C784)
                : const Color(0xFF90CAF9),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$label: "$pattern"',
              style: TextStyle(
                color: isCached
                    ? const Color(0xFF81C784)
                    : const Color(0xFF90CAF9),
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanningIndicator extends StatelessWidget {
  const _PlanningIndicator();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: Color(0xFF9EA5AF),
          ),
        ),
        SizedBox(width: 10),
        Text(
          'Analyzing screen and planning…',
          style: TextStyle(
            color: Color(0xFF9EA5AF),
            fontSize: 13,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }
}

class _PlannerReasoningBanner extends StatefulWidget {
  const _PlannerReasoningBanner({
    required this.isThinking,
    required this.reasoning,
  });

  final bool isThinking;
  final String reasoning;

  @override
  State<_PlannerReasoningBanner> createState() => _PlannerReasoningBannerState();
}

class _PlannerReasoningBannerState extends State<_PlannerReasoningBanner> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.isThinking || widget.reasoning.isNotEmpty;
  }

  @override
  void didUpdateWidget(covariant _PlannerReasoningBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isThinking && !_expanded) {
      setState(() => _expanded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasReasoning = widget.reasoning.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF303845),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF4E5661)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                    color: const Color(0xFFD2D8DF),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.psychology_alt_outlined,
                    size: 15,
                    color: Color(0xFFD2D8DF),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Planner thinking',
                    style: TextStyle(
                      color: Color(0xFFD2D8DF),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (widget.isThinking) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.7,
                        color: Color(0xFFD2D8DF),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text(
                hasReasoning
                    ? widget.reasoning
                    : (widget.isThinking
                          ? 'Thinking through the next best action plan...'
                          : 'No reasoning returned by the model.'),
                style: const TextStyle(
                  color: Color(0xFFD2D8DF),
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EditTaskModeBanner extends StatelessWidget {
  const _EditTaskModeBanner({required this.isLoading, required this.onCancel});

  final bool isLoading;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF313945),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.edit_note, size: 16, color: Color(0xFFD2D8DF)),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Editing task. Press send to run the updated task.',
              style: TextStyle(color: Color(0xFFD2D8DF), fontSize: 12),
            ),
          ),
          IconButton(
            onPressed: isLoading ? null : onCancel,
            iconSize: 16,
            tooltip: 'Cancel edit',
            color: const Color(0xFFE8E9EB),
            disabledColor: const Color(0xFF7A838F),
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            padding: const EdgeInsets.all(4),
            splashRadius: 14,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _StepTimelineRow extends StatelessWidget {
  const _StepTimelineRow({
    required this.step,
    required this.isFirst,
    required this.isLast,
  });

  final _ActionStep step;
  final bool isFirst;
  final bool isLast;

  static const _lineColor = Color(0xFF4E5661);

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Column(
              children: [
                Container(
                  width: 1.5,
                  height: 4,
                  color: isFirst ? Colors.transparent : _lineColor,
                ),
                _StatusDot(status: step.status),
                Expanded(
                  child: Container(
                    width: 1.5,
                    color: isLast ? Colors.transparent : _lineColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.title,
                    style: TextStyle(
                      color: _titleColor,
                      fontSize: 13,
                      fontWeight: step.status == 'pending'
                          ? FontWeight.w400
                          : FontWeight.w500,
                    ),
                  ),
                  if (step.detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      step.detail,
                      style: const TextStyle(
                        color: Color(0xFF6B7585),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color get _titleColor {
    switch (step.status) {
      case 'completed':
        return const Color(0xFFCDD4DE);
      case 'started':
        return const Color(0xFFE8E9EB);
      case 'failed':
        return const Color(0xFFE57373);
      default:
        return const Color(0xFF6B7585);
    }
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case 'completed':
        return const Icon(
          Icons.check_circle,
          size: 16,
          color: Color(0xFF81C784),
        );
      case 'started':
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF64B5F6),
          ),
        );
      case 'failed':
        return const Icon(Icons.cancel, size: 16, color: Color(0xFFE57373));
      default:
        return Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF4E5661), width: 1.5),
          ),
        );
    }
  }
}

class _ResultBanner extends StatelessWidget {
  const _ResultBanner({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CollapsibleLogSection extends StatefulWidget {
  const _CollapsibleLogSection({
    required this.logs,
    required this.plannerTraces,
  });
  final List<String> logs;
  final List<PlannerTrace> plannerTraces;

  @override
  State<_CollapsibleLogSection> createState() => _CollapsibleLogSectionState();
}

class _CollapsibleLogSectionState extends State<_CollapsibleLogSection> {
  bool _isExpanded = false;
  bool _plannerExpanded = false;
  final Set<int> _expandedTraceIndexes = <int>{};

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _isExpanded = !_isExpanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _isExpanded ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: const Color(0xFF6B7585),
                ),
                const SizedBox(width: 4),
                Text(
                  'Activity log (${widget.logs.length})',
                  style: const TextStyle(
                    color: Color(0xFF6B7585),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_isExpanded) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF2A3038),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final log in widget.logs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      log,
                      style: const TextStyle(
                        color: Color(0xFF9EA5AF),
                        fontSize: 11,
                        fontFamily: 'monospace',
                        height: 1.4,
                      ),
                    ),
                  ),
                if (widget.plannerTraces.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: () {
                      setState(() => _plannerExpanded = !_plannerExpanded);
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            _plannerExpanded
                                ? Icons.expand_more
                                : Icons.chevron_right,
                            size: 15,
                            color: const Color(0xFF8A95A5),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'LLM prompts & responses (${widget.plannerTraces.length})',
                            style: const TextStyle(
                              color: Color(0xFF8A95A5),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_plannerExpanded) ...[
                    const SizedBox(height: 4),
                    for (var i = 0; i < widget.plannerTraces.length; i++)
                      _PlannerTraceTile(
                        index: i,
                        trace: widget.plannerTraces[i],
                        expanded: _expandedTraceIndexes.contains(i),
                        onToggle: () {
                          setState(() {
                            if (_expandedTraceIndexes.contains(i)) {
                              _expandedTraceIndexes.remove(i);
                            } else {
                              _expandedTraceIndexes.add(i);
                            }
                          });
                        },
                      ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _PlannerTraceTile extends StatelessWidget {
  const _PlannerTraceTile({
    required this.index,
    required this.trace,
    required this.expanded,
    required this.onToggle,
  });

  final int index;
  final PlannerTrace trace;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final title =
        '#${index + 1} ${trace.label} • ${trace.model}${trace.hasScreenshot ? ' • screenshot' : ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF242A32),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 14,
                    color: const Color(0xFF9EA5AF),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFFB8C1CC),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TraceSection(label: 'System prompt', content: trace.systemPrompt),
                  const SizedBox(height: 6),
                  _TraceSection(label: 'User prompt', content: trace.userPrompt),
                  const SizedBox(height: 6),
                  _TraceSection(
                    label: 'Request payload (sanitized)',
                    content: trace.requestPayload,
                  ),
                  const SizedBox(height: 6),
                  _TraceSection(label: 'Raw response', content: trace.rawResponse),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TraceSection extends StatelessWidget {
  const _TraceSection({required this.label, required this.content});

  final String label;
  final String content;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF8A95A5),
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 3),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF1D222A),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            content.isEmpty ? '[empty]' : content,
            style: const TextStyle(
              color: Color(0xFF9EA5AF),
              fontSize: 10.5,
              fontFamily: 'monospace',
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}
