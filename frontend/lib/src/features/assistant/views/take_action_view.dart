import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arya_app/src/core/window_helpers.dart';
import 'package:arya_app/src/features/assistant/models/ai_provider.dart';
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
  TaskDecomposition? _taskDecomposition;
  final List<_MilestoneProgressItem> _milestoneProgress = [];
  int _activeMilestoneIndex = 0;
  int _activeApproachIndex = 0;
  String _latestCompletionLabel = '';
  String _latestCompletionReason = '';
  _SpeculativeMilestonePlan? _speculativePlan;
  String? _activeSpeculativePlanKey;
  int _speculativePlanEpoch = 0;
  _BulkPlanCache? _bulkPlanCache;

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
      _taskDecomposition = null;
      _milestoneProgress.clear();
      _activeMilestoneIndex = 0;
      _activeApproachIndex = 0;
      _latestCompletionLabel = '';
      _latestCompletionReason = '';
      _speculativePlan = null;
      _activeSpeculativePlanKey = null;
      _speculativePlanEpoch++;
      _bulkPlanCache = null;
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
    _invalidateSpeculativePlan(discardBulkCache: true);
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
  // Milestone-based execution loop
  //
  // 1. First LLM call decomposes the task into milestones + approaches.
  // 2. The UI-aware planner generates a plan only for the current milestone.
  // 3. Execution proceeds deterministically with per-step verification.
  // 4. Re-plan stays within the same milestone/approach while recoverable.
  // 5. If the current approach is exhausted for the milestone, try next one.
  // 6. After milestone completion, advance to the next milestone.
  // =========================================================================

  Future<void> _runPlanBasedLoop({
    required String task,
    required String model,
    required List<ChatAttachment> attachments,
  }) async {
    final store = AiSettingsStore.instance;

    // Load all settings and screen region in parallel.
    final settingsAndRegion = await Future.wait([
      store.getProvider(),           // 0
      store.getOpenRouterApiKey(),   // 1
      store.getOllamaBaseUrl(),      // 2
      store.getTavilyApiKey(),       // 3
      store.getDecompositionModel(), // 4
      store.getPlanningModel(),      // 5
      store.getCompletionModel(),    // 6
      getCurrentWindowDisplayRegion().then((v) => v ?? <String, dynamic>{}), // 7
    ]);

    final provider = settingsAndRegion[0] as AiProvider;
    final openRouterKey = settingsAndRegion[1] as String;
    final ollamaBaseUrl = settingsAndRegion[2] as String;
    final tavilyKey = settingsAndRegion[3] as String;
    final decompositionModel = settingsAndRegion[4] as String;
    final planningModel = settingsAndRegion[5] as String;
    final completionModel = settingsAndRegion[6] as String;
    final screenContext = settingsAndRegion[7] as Map<String, dynamic>;

    if (decompositionModel.isEmpty ||
        planningModel.isEmpty ||
        completionModel.isEmpty) {
      _setAbort('Select a model before running Take Action.');
      return;
    }
    if (provider == AiProvider.openrouter && openRouterKey.isEmpty) {
      _setAbort('OpenRouter API key is missing. Set it in Settings.');
      return;
    }
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
    // --- Phase 1: Initial capture + decomposition prepass ---
    if (mounted) setState(() => _isPlanning = true);

    // For trivial tasks the decomposition uses a heuristic (no LLM, no UI
    // summary needed), so we can fire it in parallel with the UI capture
    // instead of waiting.
    final isTrivial = TaskStrategyPlanner.isTrivialTask(task);
    final captureFuture = _captureContext('Initial context', region: captureRegion);

    TaskDecomposition? earlyDecomposition;
    if (isTrivial) {
      // Start heuristic decomposition without waiting for capture.
      final decompFuture = _strategyPlanner.decompose(
        provider: provider,
        openRouterKey: openRouterKey,
        ollamaBaseUrl: ollamaBaseUrl,
        model: decompositionModel,
        task: task,
        appName: '',
        uiSummary: '',
      );
      final results = await Future.wait([captureFuture, decompFuture]);
      earlyDecomposition = results[1] as TaskDecomposition;
    } else {
      await captureFuture;
    }

    final appContext = await _buildTargetAppContext();
    final appName =
        (appContext['target_app_name'] as String?)?.trim().toLowerCase() ?? '';
    try {
      final decomposition = earlyDecomposition ?? await _strategyPlanner.decompose(
        provider: provider,
        openRouterKey: openRouterKey,
        ollamaBaseUrl: ollamaBaseUrl,
        model: decompositionModel,
        task: task,
        appName: appName,
        uiSummary: _buildInitialPlanningUiSummary(),
      );
      if (!mounted || !_isLoading) return;
      setState(() {
        _taskDecomposition = decomposition;
        _milestoneProgress
          ..clear()
          ..addAll(
            [
              for (var i = 0; i < decomposition.milestones.length; i++)
                _MilestoneProgressItem(
                  title: decomposition.milestones[i],
                  status: i == 0 ? 'active' : 'pending',
                  detail: i == 0 ? 'Preparing first approach' : '',
                  approaches: [
                    for (final approach in decomposition.approaches)
                      _ApproachProgressItem(title: approach.title, status: 'pending'),
                  ],
                ),
            ],
          );
        _activeMilestoneIndex = 0;
        _activeApproachIndex = 0;
      });
      _log(
        'Pre-plan (${decomposition.source}): '
        '${decomposition.milestones.length} milestones, '
        '${decomposition.approaches.length} approaches',
      );
      for (var i = 0; i < decomposition.milestones.length; i++) {
        _log('  Milestone ${i + 1}: ${decomposition.milestones[i]}');
      }

      // --- Bulk planning: plan ALL milestones upfront in one LLM call ---
      // Only attempted when there are 2+ milestones and a primary approach.
      // Falls back to per-milestone planning on failure.
      if (decomposition.milestones.length >= 2) {
        final primaryApproach = decomposition.approaches.first;
        try {
          final plannerScreenContext = {
            ...screenContext,
            ...appContext,
          };
          _log(
            'Bulk planning ${decomposition.milestones.length} milestones '
            'with approach: ${primaryApproach.title}',
          );
          final bulkPlan = await _planner.generateBulkPlan(
            provider: provider,
            openRouterKey: openRouterKey,
            ollamaBaseUrl: ollamaBaseUrl,
            model: planningModel,
            task: task,
            milestones: decomposition.milestones,
            approachTitle: primaryApproach.title,
            milestoneStrategies: primaryApproach.milestoneStrategies,
            screenContext: plannerScreenContext,
            uiContext: formatUIElementsForPrompt(_latestUIElements),
            screenshotPath: null,
            tavilyKey: tavilyKey,
            webMode: _webMode,
            attachments: attachmentMaps,
          );

          final parsedCount = bulkPlan.milestonePlans
              .where((p) => p != null)
              .length;
          _log(
            'Bulk plan ready: $parsedCount/${decomposition.milestones.length} '
            'milestones planned upfront.',
          );

          _bulkPlanCache = _BulkPlanCache(
            milestonePlans: bulkPlan.milestonePlans.toList(),
            uiSnapshot: _buildUiValidationSnapshot(_latestUIElements),
            approachTitle: primaryApproach.title,
          );
        } catch (e) {
          _log('Bulk planning failed, will plan per-milestone: $e');
          _bulkPlanCache = null;
        }
      }

      if (mounted) setState(() => _isPlanning = false);

      var totalSteps = 0;
      for (var milestoneIndex = 0;
          milestoneIndex < decomposition.milestones.length;
          milestoneIndex++) {
        if (!mounted || !_isLoading) return;

        final milestone = decomposition.milestones[milestoneIndex];
        final completedMilestones =
            decomposition.milestones.take(milestoneIndex).toList();
        var milestoneCompleted = false;

        _log(
          'Starting milestone ${milestoneIndex + 1}/${decomposition.milestones.length}: '
          '$milestone',
        );
        _setMilestoneStatus(
          milestoneIndex,
          'active',
          detail: 'Working on this milestone',
        );

        for (var approachIndex = 0;
            approachIndex < decomposition.approaches.length;
            approachIndex++) {
          if (!mounted || !_isLoading) return;
          if (milestoneCompleted) break;

          final approach = decomposition.approaches[approachIndex];
          final milestoneStrategy =
              approach.strategyForMilestone(milestoneIndex, milestone);
          final fallbackApproachTitles = decomposition.approaches
              .skip(approachIndex + 1)
              .map((a) => a.title)
              .toList();

          setState(() {
            _activeMilestoneIndex = milestoneIndex;
            _activeApproachIndex = approachIndex;
          });
          _setApproachStatus(
            milestoneIndex,
            approachIndex,
            'active',
            detail: 'Current approach',
          );

          if (milestoneIndex != 0 || approachIndex != 0) {
            await _captureContext('Milestone context', region: captureRegion);
          }

          final plannerScreenContext = {
            ...screenContext,
            ...await _buildTargetAppContext(),
          };

          late MilestonePlan milestonePlan;
          List<PlannedStep> plan;
          try {
            // Priority 1: Check the speculative plan (generated in background
            // during the previous milestone's final steps).
            final speculativePlan = _takeValidatedSpeculativePlan(
              milestoneIndex: milestoneIndex,
              approachIndex: approachIndex,
              approachTitle: approach.title,
            );
            if (speculativePlan != null) {
              milestonePlan = speculativePlan;
            }
            // Priority 2: Check the bulk plan cache (generated upfront for
            // all milestones in one LLM call).
            else if (_takeBulkPlanForMilestone(
              milestoneIndex: milestoneIndex,
              approachIndex: approachIndex,
              approachTitle: approach.title,
            ) case final bulkPlan?) {
              milestonePlan = bulkPlan;
            }
            // Priority 3: Generate a fresh per-milestone plan.
            // If a bulk cache exists but didn't yield a plan for this
            // milestone, it was invalidated due to UI drift — inform
            // the planner so it plans fresh without assumptions.
            else {
              final isBulkFallback = _bulkPlanCache != null &&
                  approachIndex == 0 &&
                  milestoneIndex > 0;
              if (mounted) setState(() => _isPlanning = true);
              _log(
                'Planning milestone ${milestoneIndex + 1} with approach '
                '${approachIndex + 1}/${decomposition.approaches.length}: '
                '${approach.title}'
                '${isBulkFallback ? ' (bulk plan invalidated, replanning fresh)' : ''}',
              );
              milestonePlan = await _planner.generateFullPlan(
                provider: provider,
                openRouterKey: openRouterKey,
                ollamaBaseUrl: ollamaBaseUrl,
                model: planningModel,
                task: task,
                milestones: decomposition.milestones,
                milestoneIndex: milestoneIndex,
                approachTitle: approach.title,
                milestoneStrategy: milestoneStrategy,
                completedMilestones: completedMilestones,
                fallbackApproachTitles: fallbackApproachTitles,
                screenContext: plannerScreenContext,
                uiContext: formatUIElementsForPrompt(_latestUIElements),
                screenshotPath: null,
                tavilyKey: tavilyKey,
                webMode: _webMode,
                attachments: attachmentMaps,
                isBulkFallback: isBulkFallback,
              );
            }
            plan = List<PlannedStep>.from(milestonePlan.steps);
          } catch (e) {
            if (mounted) setState(() => _isPlanning = false);
            _log('Plan generation failed for approach "${approach.title}": $e');
            _setPlanSteps(const <PlannedStep>[]);
            if (approachIndex + 1 < decomposition.approaches.length) {
              _setApproachStatus(
                milestoneIndex,
                approachIndex,
                'failed',
                detail: 'Planning failed',
              );
              _log(
                'Milestone ${milestoneIndex + 1}: '
                'approach ${approachIndex + 1} failed, trying approach '
                '${approachIndex + 2}.',
              );
              continue;
            }
            _setAbort(
              'Unable to plan milestone ${milestoneIndex + 1}: $milestone',
            );
            return;
          }
          if (mounted) setState(() => _isPlanning = false);

          if (plan.isEmpty) {
            _log('✓ Milestone ${milestoneIndex + 1} already complete.');
            milestoneCompleted = true;
            _setApproachStatus(
              milestoneIndex,
              approachIndex,
              'completed',
              detail: 'Milestone already satisfied',
            );
            _setMilestoneStatus(
              milestoneIndex,
              'completed',
              detail: 'Already complete',
            );
            _setPlanSteps(const <PlannedStep>[]);
            break;
          }

          final history = <Map<String, String>>[];
          var replansUsed = 0;
          var approachExhausted = false;
          PlannedStep? lastExecutedStep;

          _setPlanSteps(
            plan,
            milestoneIndex: milestoneIndex,
            approachTitle: approach.title,
          );
          _log('Plan: ${plan.length} steps');
          for (final s in plan) {
            _log('  ${s.id}: ${s.title} [${s.action}]');
          }

          while (!milestoneCompleted &&
              !approachExhausted &&
              totalSteps < _maxSteps) {
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

              final result = await ActionExecutorService.instance.executeStep(
                resolvedStep,
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
                  approachExhausted = true;
                  _setApproachStatus(
                    milestoneIndex,
                    approachIndex,
                    'failed',
                    detail: 'Execution retries exhausted',
                  );
                  _log(
                    'Approach "${approach.title}" exhausted for milestone '
                    '${milestoneIndex + 1}.',
                  );
                  break;
                }

                _invalidateSpeculativePlan(
                  invalidateBulkFrom: milestoneIndex + 1,
                );
                milestonePlan = await _replan(
                  provider: provider,
                  task: task,
                  milestones: decomposition.milestones,
                  milestoneIndex: milestoneIndex,
                  approachTitle: approach.title,
                  milestoneStrategy: milestoneStrategy,
                  completedMilestones: completedMilestones,
                  fallbackApproachTitles: fallbackApproachTitles,
                  model: planningModel,
                  openRouterKey: openRouterKey,
                  ollamaBaseUrl: ollamaBaseUrl,
                  screenContext: screenContext,
                  history: history,
                  failedStep: step,
                  failureDetail: 'Execution failed: ${result.detail}',
                  remainingSteps: plan,
                  captureRegion: captureRegion,
                );
                plan = List<PlannedStep>.from(milestonePlan.steps);
                _setPlanSteps(
                  plan,
                  milestoneIndex: milestoneIndex,
                  approachTitle: approach.title,
                );
                replansUsed++;
                continue;
              }

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

              await Future.delayed(const Duration(milliseconds: 500));
              final verifyElements = await UIParserService.instance.parseScreen(
                targetPid: _targetAppPid,
              );
              _latestUIElements = verifyElements;

              final passed = step.verify.check(verifyElements);
              if (passed) {
                _log('✓ Verify passed: ${step.verify}');
                _maybeStartSpeculativeNextMilestonePlan(
                  task: task,
                  decomposition: decomposition,
                  currentMilestoneIndex: milestoneIndex,
                  provider: provider,
                  openRouterKey: openRouterKey,
                  ollamaBaseUrl: ollamaBaseUrl,
                  model: planningModel,
                  tavilyKey: tavilyKey,
                  screenContext: screenContext,
                  attachments: attachmentMaps,
                  replansUsed: replansUsed,
                  remainingSteps: plan.length,
                );
                continue;
              }

              _log('✗ Verify FAILED: ${step.verify}');
              if (replansUsed >= _maxReplans) {
                approachExhausted = true;
                _setApproachStatus(
                  milestoneIndex,
                  approachIndex,
                  'failed',
                  detail: 'Verification retries exhausted',
                );
                _log(
                  'Approach "${approach.title}" exhausted for milestone '
                  '${milestoneIndex + 1}.',
                );
                break;
              }

              _invalidateSpeculativePlan(
                invalidateBulkFrom: milestoneIndex + 1,
              );
              milestonePlan = await _replan(
                provider: provider,
                task: task,
                milestones: decomposition.milestones,
                milestoneIndex: milestoneIndex,
                approachTitle: approach.title,
                milestoneStrategy: milestoneStrategy,
                completedMilestones: completedMilestones,
                fallbackApproachTitles: fallbackApproachTitles,
                model: planningModel,
                openRouterKey: openRouterKey,
                ollamaBaseUrl: ollamaBaseUrl,
                screenContext: screenContext,
                history: history,
                failedStep: step,
                failureDetail: 'Verification failed: expected ${step.verify}',
                remainingSteps: plan,
                captureRegion: captureRegion,
              );
              plan = List<PlannedStep>.from(milestonePlan.steps);
              _setPlanSteps(
                plan,
                milestoneIndex: milestoneIndex,
                approachTitle: approach.title,
              );
              replansUsed++;
            }

            if (_abortReason != null || !mounted || !_isLoading) return;
            if (approachExhausted ||
                milestoneCompleted ||
                totalSteps >= _maxSteps) {
              break;
            }
            if (lastExecutedStep == null) {
              approachExhausted = true;
              break;
            }

            final localCompletion = _evaluateCompletionContract(
              milestonePlan.completionContract,
              _latestUIElements,
            );
            _log(
              'Local completion check: ${localCompletion.label} '
              '(${localCompletion.reason})',
            );
            if (mounted) {
              setState(() {
                _latestCompletionLabel = localCompletion.label;
                _latestCompletionReason = localCompletion.reason;
              });
            }

            var milestoneComplete = localCompletion.isComplete;
            if (localCompletion.isAmbiguous &&
                milestonePlan.completionContract.requiresLlmIfUnclear) {
              _log('Ambiguous completion, escalating to LLM check…');
              if (milestonePlan
                  .completionContract
                  .recommendScreenshotOnAmbiguity) {
                await _captureContext(
                  'Milestone ambiguity context',
                  captureScreenshot: true,
                  region: captureRegion,
                );
              }
              final plannerScreenContext = {
                ...screenContext,
                ...await _buildTargetAppContext(),
              };
              milestoneComplete = await _planner.checkMilestoneCompletion(
                provider: provider,
                openRouterKey: openRouterKey,
                ollamaBaseUrl: ollamaBaseUrl,
                model: completionModel,
                task: task,
                milestones: decomposition.milestones,
                milestoneIndex: milestoneIndex,
                approachTitle: approach.title,
                milestoneStrategy: milestoneStrategy,
                completedMilestones: completedMilestones,
                screenContext: plannerScreenContext,
                uiContext: formatUIElementsForPrompt(_latestUIElements),
                screenshotPath: milestonePlan
                        .completionContract
                        .recommendScreenshotOnAmbiguity
                    ? _latestScreenshotPath
                    : null,
              );
              _log(
                milestoneComplete
                    ? 'LLM completion check: complete'
                    : 'LLM completion check: incomplete',
              );
              if (mounted) {
                setState(() {
                  _latestCompletionLabel =
                      milestoneComplete ? 'complete' : 'incomplete';
                  _latestCompletionReason = milestoneComplete
                      ? 'Confirmed by LLM completion check'
                      : 'LLM determined milestone is incomplete';
                });
              }
            }

            if (milestoneComplete) {
              _log('✓ Milestone ${milestoneIndex + 1} complete.');
              milestoneCompleted = true;
              _setApproachStatus(
                milestoneIndex,
                approachIndex,
                'completed',
                detail: 'Completed this milestone',
              );
              _setMilestoneStatus(
                milestoneIndex,
                'completed',
                detail: _latestCompletionReason,
              );
              _setPlanSteps(const <PlannedStep>[]);
              break;
            }

            _log('Milestone incomplete, requesting additional steps…');
            _invalidateSpeculativePlan(
              invalidateBulkFrom: milestoneIndex + 1,
            );
            milestonePlan = await _replan(
              provider: provider,
              task: task,
              milestones: decomposition.milestones,
              milestoneIndex: milestoneIndex,
              approachTitle: approach.title,
              milestoneStrategy: milestoneStrategy,
              completedMilestones: completedMilestones,
              fallbackApproachTitles: fallbackApproachTitles,
              model: planningModel,
              openRouterKey: openRouterKey,
              ollamaBaseUrl: ollamaBaseUrl,
              screenContext: screenContext,
              history: history,
              failedStep: lastExecutedStep,
              failureDetail:
                  'All planned steps for milestone "$milestone" were executed, '
                  'but the milestone is not yet complete in the current UI '
                  'state. Produce additional steps for the same milestone.',
              remainingSteps: const [],
              captureRegion: captureRegion,
            );
            plan = List<PlannedStep>.from(milestonePlan.steps);

            if (replansUsed >= _maxReplans) {
              approachExhausted = true;
              _setApproachStatus(
                milestoneIndex,
                approachIndex,
                'failed',
                detail: 'Milestone remained incomplete',
              );
              _setPlanSteps(const <PlannedStep>[]);
              _log(
                'Approach "${approach.title}" exhausted for milestone '
                '${milestoneIndex + 1}.',
              );
              break;
            }

            _log('Milestone needs ${plan.length} more steps.');
            _setPlanSteps(
              plan,
              milestoneIndex: milestoneIndex,
              approachTitle: approach.title,
            );
            replansUsed++;
          }

          if (milestoneCompleted) {
            break;
          }

          _setPlanSteps(const <PlannedStep>[]);
          if (totalSteps >= _maxSteps) {
            _setAbort('Reached maximum step limit ($_maxSteps).');
            return;
          }
          if (approachIndex + 1 < decomposition.approaches.length) {
            _invalidateSpeculativePlan(discardBulkCache: true);
            _setApproachStatus(
              milestoneIndex,
              approachIndex,
              'failed',
              detail: 'Switching to next approach',
            );
            _log(
              'Milestone ${milestoneIndex + 1}: approach ${approachIndex + 1} '
              'failed, trying approach ${approachIndex + 2}.',
            );
          }
        }

        if (!milestoneCompleted) {
          _setMilestoneStatus(
            milestoneIndex,
            'failed',
            detail: 'All approaches exhausted',
          );
          _setAbort(
            'All approaches exhausted for milestone '
            '${milestoneIndex + 1}: $milestone',
          );
          return;
        }

        if (milestoneIndex + 1 < decomposition.milestones.length) {
          _setMilestoneStatus(
            milestoneIndex + 1,
            'active',
            detail: 'Queued next milestone',
          );
        }
      }

      _invalidateSpeculativePlan(discardBulkCache: true);
      _log('✓ Task verified as complete.');
    } catch (e) {
      if (mounted) setState(() => _isPlanning = false);
      _setAbort('Pre-planning failed: $e');
      return;
    }
  }

  /// Captures fresh context and calls LLM to produce a new plan.
  Future<MilestonePlan> _replan({
    required AiProvider provider,
    required String task,
    required List<String> milestones,
    required int milestoneIndex,
    required String approachTitle,
    required String milestoneStrategy,
    required List<String> completedMilestones,
    required List<String> fallbackApproachTitles,
    required String model,
    required String openRouterKey,
    required String ollamaBaseUrl,
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
        provider: provider,
        openRouterKey: openRouterKey,
        ollamaBaseUrl: ollamaBaseUrl,
        model: model,
        task: task,
        milestones: milestones,
        milestoneIndex: milestoneIndex,
        approachTitle: approachTitle,
        milestoneStrategy: milestoneStrategy,
        completedMilestones: completedMilestones,
        fallbackApproachTitles: fallbackApproachTitles,
        screenContext: plannerScreenContext,
        uiContext: formatUIElementsForPrompt(_latestUIElements),
        history: history,
        failedStep: failedStep,
        failureDetail: failureDetail,
        remainingSteps: remainingSteps,
        screenshotPath: _latestScreenshotPath,
      );
      _log('Re-plan received: ${newPlan.steps.length} steps');
      for (final s in newPlan.steps) {
        _log('  ${s.id}: ${s.title} [${s.action}] verify=${s.verify}');
      }
      return newPlan;
    } catch (e) {
      _log('Re-plan failed: $e');
      return MilestonePlan(
        steps: const [],
        completionContract: const CompletionContract(
          primary: VerifyCriteria(type: 'any'),
          recommendScreenshotOnAmbiguity: true,
        ),
      );
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
    _invalidateSpeculativePlan(discardBulkCache: true);
  }

  void _setMilestoneStatus(int milestoneIndex, String status, {String detail = ''}) {
    if (!mounted) return;
    if (milestoneIndex < 0 || milestoneIndex >= _milestoneProgress.length) return;
    setState(() {
      final current = _milestoneProgress[milestoneIndex];
      _milestoneProgress[milestoneIndex] = current.copyWith(
        status: status,
        detail: detail.isNotEmpty ? detail : current.detail,
      );
    });
  }

  void _setApproachStatus(
    int milestoneIndex,
    int approachIndex,
    String status, {
    String detail = '',
  }) {
    if (!mounted) return;
    if (milestoneIndex < 0 || milestoneIndex >= _milestoneProgress.length) return;
    final milestone = _milestoneProgress[milestoneIndex];
    if (approachIndex < 0 || approachIndex >= milestone.approaches.length) return;
    setState(() {
      final updatedApproaches = List<_ApproachProgressItem>.from(
        _milestoneProgress[milestoneIndex].approaches,
      );
      final current = updatedApproaches[approachIndex];
      updatedApproaches[approachIndex] = current.copyWith(
        status: status,
        detail: detail.isNotEmpty ? detail : current.detail,
      );
      _milestoneProgress[milestoneIndex] = _milestoneProgress[milestoneIndex]
          .copyWith(approaches: updatedApproaches);
    });
  }

  /// Invalidates the speculative plan and optionally invalidates bulk plan
  /// cache entries.
  ///
  /// If [invalidateBulkFrom] is provided, all bulk cache entries from that
  /// milestone index onward are invalidated (used when a replan occurs and
  /// later bulk plans are based on a now-stale UI assumption).
  ///
  /// If [discardBulkCache] is true, the entire bulk cache is discarded
  /// (used when switching approaches, since the bulk cache was generated
  /// for the primary approach only).
  void _invalidateSpeculativePlan({
    int? invalidateBulkFrom,
    bool discardBulkCache = false,
  }) {
    _speculativePlanEpoch++;
    if (discardBulkCache) {
      _bulkPlanCache = null;
    } else if (invalidateBulkFrom != null) {
      _bulkPlanCache?.invalidateFrom(invalidateBulkFrom);
    }
    if (!mounted) {
      _speculativePlan = null;
      _activeSpeculativePlanKey = null;
      return;
    }
    setState(() {
      _speculativePlan = null;
      _activeSpeculativePlanKey = null;
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

  void _setPlanSteps(
    List<PlannedStep> plan, {
    int? milestoneIndex,
    String? approachTitle,
  }) {
    if (!mounted) return;
    setState(() {
      _steps.removeWhere((s) => s.status == 'pending');
      for (final s in plan) {
        _steps.add(
          _ActionStep(
            id: s.id,
            title: s.title,
            status: 'pending',
            detail: '',
            milestoneIndex: milestoneIndex,
            approachTitle: approachTitle,
          ),
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

  _LocalCompletionResult _evaluateCompletionContract(
    CompletionContract contract,
    List<UIElement> elements,
  ) {
    final hasMeaningfulPrimary = contract.primary.type != 'any';
    final primaryPass = contract.primary.check(elements);
    final secondaryPasses = contract.secondary
        .where((criteria) => criteria.check(elements))
        .length;

    if (!hasMeaningfulPrimary && contract.secondary.isEmpty) {
      return const _LocalCompletionResult.ambiguous(
        'No machine-readable completion criteria',
      );
    }
    if (primaryPass && contract.secondary.isEmpty) {
      return const _LocalCompletionResult.complete('Primary criterion passed');
    }
    if (primaryPass && secondaryPasses > 0) {
      return _LocalCompletionResult.complete(
        'Primary + $secondaryPasses secondary criteria passed',
      );
    }
    if (primaryPass && contract.secondary.isNotEmpty && secondaryPasses == 0) {
      return const _LocalCompletionResult.ambiguous(
        'Primary passed but secondary criteria did not confirm',
      );
    }
    if (!primaryPass && secondaryPasses > 0) {
      return _LocalCompletionResult.ambiguous(
        '$secondaryPasses secondary criteria passed without primary',
      );
    }
    return const _LocalCompletionResult.incomplete('Primary criterion failed');
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

  String _buildInitialPlanningUiSummary() {
    if (_latestUIElements.isEmpty) {
      return '';
    }

    final topLabeled = <String>[];
    final seenLabels = <String>{};
    for (final el in _latestUIElements) {
      final label = el.label.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (label.isEmpty) continue;
      final normalized = label.toLowerCase();
      if (!seenLabels.add(normalized)) continue;
      topLabeled.add('${el.role}: $label');
      if (topLabeled.length >= 8) break;
    }

    final dialogs = _latestUIElements
        .where(
          (el) =>
              el.role == 'Dialog' || el.role == 'Sheet' || el.role == 'Alert',
        )
        .toList();
    final editableCount = _latestUIElements
        .where(
          (el) =>
              el.role == 'TextArea' ||
              el.role == 'TextField' ||
              el.role == 'SearchField' ||
              el.role == 'ComboBox',
        )
        .length;
    final buttonsCount =
        _latestUIElements.where((el) => el.role == 'Button').length;
    final selectedWindowTitle = _extractPrimaryWindowTitle(_latestUIElements);

    final stateHints = <String>[
      if (selectedWindowTitle != null && selectedWindowTitle.isNotEmpty)
        'window="$selectedWindowTitle"',
      if (dialogs.isNotEmpty) 'dialog_or_sheet_visible',
      if (editableCount > 0) '$editableCount editable_input_controls_visible',
      if (buttonsCount > 0) '$buttonsCount buttons_visible',
    ];

    final buffer = StringBuffer();
    if (stateHints.isNotEmpty) {
      buffer.writeln('State hints: ${stateHints.join(', ')}');
    }
    if (topLabeled.isNotEmpty) {
      buffer.writeln('High-signal visible elements:');
      for (final line in topLabeled) {
        buffer.writeln('- $line');
      }
    }
    return buffer.toString().trim();
  }

  String _buildUiValidationKey({
    required int milestoneIndex,
    required int approachIndex,
    required String approachTitle,
  }) => '$milestoneIndex::$approachIndex::$approachTitle';

  _UiValidationSnapshot _buildUiValidationSnapshot(List<UIElement> elements) {
    final labels = <String>{};
    for (final el in elements) {
      final label = el.label.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
      if (label.isEmpty) continue;
      labels.add('${el.role.toLowerCase()}:$label');
      if (labels.length >= 10) break;
    }

    String bucket(int count) {
      if (count <= 0) return '0';
      if (count == 1) return '1';
      if (count <= 4) return '2-4';
      return '5+';
    }

    final dialogs = elements
        .where(
          (el) =>
              el.role == 'Dialog' || el.role == 'Sheet' || el.role == 'Alert',
        )
        .length;
    final editable = elements
        .where(
          (el) =>
              el.role == 'TextArea' ||
              el.role == 'TextField' ||
              el.role == 'SearchField' ||
              el.role == 'ComboBox',
        )
        .length;
    final buttons = elements.where((el) => el.role == 'Button').length;

    return _UiValidationSnapshot(
      windowTitle: (_extractPrimaryWindowTitle(elements) ?? '').trim().toLowerCase(),
      labels: labels,
      dialogBucket: bucket(dialogs),
      editableBucket: bucket(editable),
      buttonBucket: bucket(buttons),
    );
  }

  bool _isUiValidationSnapshotCompatible(
    _UiValidationSnapshot expected,
    _UiValidationSnapshot actual,
  ) {
    if (expected.windowTitle.isNotEmpty &&
        actual.windowTitle.isNotEmpty &&
        expected.windowTitle != actual.windowTitle) {
      return false;
    }
    if (expected.dialogBucket != actual.dialogBucket ||
        expected.editableBucket != actual.editableBucket) {
      return false;
    }
    if (expected.labels.isEmpty) {
      return true;
    }
    final overlap = expected.labels.intersection(actual.labels).length;
    return overlap / expected.labels.length >= 0.5;
  }

  void _maybeStartSpeculativeNextMilestonePlan({
    required String task,
    required TaskDecomposition decomposition,
    required int currentMilestoneIndex,
    required AiProvider provider,
    required String openRouterKey,
    required String ollamaBaseUrl,
    required String model,
    required String tavilyKey,
    required Map<String, dynamic> screenContext,
    required List<Map<String, dynamic>> attachments,
    required int replansUsed,
    required int remainingSteps,
  }) {
    final nextMilestoneIndex = currentMilestoneIndex + 1;
    if (nextMilestoneIndex >= decomposition.milestones.length) return;
    if (replansUsed > 0 || remainingSteps > 1) return;

    // Skip speculative planning if the bulk cache already has a plan for the
    // next milestone — no need to start a redundant background LLM call.
    if (_bulkPlanCache != null &&
        nextMilestoneIndex < _bulkPlanCache!.milestonePlans.length &&
        _bulkPlanCache!.milestonePlans[nextMilestoneIndex] != null) {
      return;
    }

    final approach = decomposition.approaches.first;
    final requestKey = _buildUiValidationKey(
      milestoneIndex: nextMilestoneIndex,
      approachIndex: 0,
      approachTitle: approach.title,
    );
    if (_activeSpeculativePlanKey == requestKey) return;
    if (_speculativePlan != null && _speculativePlan!.requestKey == requestKey) {
      return;
    }

    final assumedCompletedMilestones =
        decomposition.milestones.take(currentMilestoneIndex + 1).toList();
    final fallbackApproachTitles = decomposition.approaches
        .skip(1)
        .map((a) => a.title)
        .toList();
    final uiSnapshot = _buildUiValidationSnapshot(_latestUIElements);
    final uiSummary = _buildInitialPlanningUiSummary();
    final requestEpoch = ++_speculativePlanEpoch;

    if (mounted) {
      setState(() => _activeSpeculativePlanKey = requestKey);
    } else {
      _activeSpeculativePlanKey = requestKey;
    }

    _log(
      'Starting speculative plan for milestone ${nextMilestoneIndex + 1} '
      'with approach 1/${decomposition.approaches.length}: ${approach.title}',
    );

    unawaited(() async {
      try {
        final plannerScreenContext = {
          ...screenContext,
          ...await _buildTargetAppContext(),
        };
        final plan = await _planner.generateFullPlan(
          provider: provider,
          openRouterKey: openRouterKey,
          ollamaBaseUrl: ollamaBaseUrl,
          model: model,
          task: task,
          milestones: decomposition.milestones,
          milestoneIndex: nextMilestoneIndex,
          approachTitle: approach.title,
          milestoneStrategy: approach.strategyForMilestone(
            nextMilestoneIndex,
            decomposition.milestones[nextMilestoneIndex],
          ),
          completedMilestones: assumedCompletedMilestones,
          fallbackApproachTitles: fallbackApproachTitles,
          screenContext: plannerScreenContext,
          uiContext: formatUIElementsForPrompt(_latestUIElements),
          screenshotPath: null,
          tavilyKey: tavilyKey,
          webMode: _webMode,
          attachments: attachments,
        );

        if (!mounted ||
            !_isLoading ||
            requestEpoch != _speculativePlanEpoch ||
            _activeSpeculativePlanKey != requestKey) {
          return;
        }

        setState(() {
          _speculativePlan = _SpeculativeMilestonePlan(
            requestKey: requestKey,
            milestoneIndex: nextMilestoneIndex,
            approachIndex: 0,
            approachTitle: approach.title,
            uiSummary: uiSummary,
            uiSnapshot: uiSnapshot,
            plan: plan,
          );
          _activeSpeculativePlanKey = null;
        });
        _log(
          'Speculative plan ready for milestone ${nextMilestoneIndex + 1} '
          '(${plan.steps.length} steps).',
        );
      } catch (e) {
        if (mounted &&
            requestEpoch == _speculativePlanEpoch &&
            _activeSpeculativePlanKey == requestKey) {
          setState(() => _activeSpeculativePlanKey = null);
        }
        _log('Speculative planning skipped: $e');
      }
    }());
  }

  MilestonePlan? _takeValidatedSpeculativePlan({
    required int milestoneIndex,
    required int approachIndex,
    required String approachTitle,
  }) {
    final speculativePlan = _speculativePlan;
    if (speculativePlan == null) return null;
    if (speculativePlan.milestoneIndex != milestoneIndex ||
        speculativePlan.approachIndex != approachIndex ||
        speculativePlan.approachTitle != approachTitle) {
      return null;
    }

    final liveSnapshot = _buildUiValidationSnapshot(_latestUIElements);
    if (!_isUiValidationSnapshotCompatible(
      speculativePlan.uiSnapshot,
      liveSnapshot,
    )) {
      _log(
        'Discarded speculative plan for milestone ${milestoneIndex + 1}: '
        'UI drifted beyond validation guardrails.',
      );
      _invalidateSpeculativePlan();
      return null;
    }

    final plan = speculativePlan.plan;
    _log(
      'Using speculative plan for milestone ${milestoneIndex + 1} '
      '(${plan.steps.length} steps).',
    );
    _invalidateSpeculativePlan();
    return plan;
  }

  /// Attempts to retrieve a pre-computed plan for [milestoneIndex] from the
  /// bulk plan cache.
  ///
  /// Returns `null` (and falls through to per-milestone planning) when:
  /// - No bulk cache exists.
  /// - The cache was built for a different approach.
  /// - This is not the primary approach (index 0).
  /// - The UI has drifted beyond compatibility thresholds.
  ///
  /// On UI drift, all plans from [milestoneIndex] onward are invalidated
  /// (they were planned from an increasingly stale UI estimate).
  MilestonePlan? _takeBulkPlanForMilestone({
    required int milestoneIndex,
    required int approachIndex,
    required String approachTitle,
  }) {
    final cache = _bulkPlanCache;
    if (cache == null) return null;

    // Bulk plans are only generated for the primary approach.
    if (approachIndex != 0 || cache.approachTitle != approachTitle) {
      return null;
    }

    // For milestone 0 the UI hasn't changed since bulk planning, so skip
    // the drift check.  For later milestones, validate against live UI.
    if (milestoneIndex > 0) {
      final liveSnapshot = _buildUiValidationSnapshot(_latestUIElements);
      if (!_isUiValidationSnapshotCompatible(
        cache.uiSnapshot,
        liveSnapshot,
      )) {
        _log(
          'Bulk plan cache invalidated from milestone ${milestoneIndex + 1} '
          'onward: UI drifted beyond validation guardrails.',
        );
        cache.invalidateFrom(milestoneIndex);
        return null;
      }
    }

    final plan = cache.consume(milestoneIndex);
    if (plan == null) return null;

    _log(
      'Using bulk-planned steps for milestone ${milestoneIndex + 1} '
      '(${plan.steps.length} steps).',
    );
    return plan;
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

    final isComplete = !_isLoading &&
        _taskDecomposition != null &&
        _milestoneProgress.isNotEmpty &&
        _milestoneProgress.every((item) => item.status == 'completed') &&
        _abortReason == null;
    final totalMilestones = _taskDecomposition?.milestones.length ?? 0;
    final completedMilestones =
        _milestoneProgress.where((item) => item.status == 'completed').length;
    final safeMilestoneIndex = _milestoneProgress.isEmpty
        ? 0
        : _activeMilestoneIndex.clamp(0, _milestoneProgress.length - 1);
    final activeMilestone = _milestoneProgress.isEmpty
        ? null
        : _milestoneProgress[safeMilestoneIndex];
    final safeApproachIndex =
        activeMilestone == null || activeMilestone.approaches.isEmpty
        ? 0
        : _activeApproachIndex.clamp(
            0,
            activeMilestone.approaches.length - 1,
          );
    final activeApproach =
        activeMilestone == null || activeMilestone.approaches.isEmpty
        ? null
        : activeMilestone.approaches[safeApproachIndex];
    final groupedSteps = <int, List<_ActionStep>>{};
    for (final step in _steps) {
      final key = step.milestoneIndex ?? -1;
      groupedSteps.putIfAbsent(key, () => <_ActionStep>[]).add(step);
    }

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
          _SummaryCard(
            task: _taskText,
            totalMilestones: totalMilestones,
            completedMilestones: completedMilestones,
            isRunning: _isLoading,
            isPlanning: _isPlanning,
            abortReason: _abortReason,
            totalSteps: _steps.length,
          ),
          if (_taskDecomposition != null) ...[
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Milestones',
              subtitle: 'Progress across milestones and fallback approaches',
              icon: Icons.route_outlined,
              child: _MilestoneProgressBoard(
                milestones: _milestoneProgress,
                activeMilestoneIndex: _activeMilestoneIndex,
                activeApproachIndex: _activeApproachIndex,
              ),
            ),
          ],
          if (activeMilestone != null) ...[
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Active execution',
              subtitle: 'Current milestone, selected approach, and completion state',
              icon: Icons.bolt_outlined,
              child: _ActiveMilestoneCard(
                milestoneTitle: activeMilestone.title,
                milestoneIndex: _activeMilestoneIndex,
                totalMilestones: totalMilestones,
                milestoneStatus: activeMilestone.status,
                milestoneDetail: activeMilestone.detail,
                approachTitle: activeApproach?.title ?? 'Waiting for approach',
                approachStatus: activeApproach?.status ?? 'pending',
                approachDetail: activeApproach?.detail ?? '',
                completionLabel: _latestCompletionLabel,
                completionReason: _latestCompletionReason,
                isPlanning: _isPlanning,
              ),
            ),
          ],
          if (_steps.isNotEmpty || _isPlanning) ...[
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Execution',
              subtitle: 'Grouped by milestone so active work stays easy to scan',
              icon: Icons.timeline_outlined,
              child: Column(
                children: [
                  if (_isPlanning) ...[
                    const _PlanningIndicator(),
                    const SizedBox(height: 12),
                  ],
                  if (_steps.isNotEmpty)
                    for (final entry in groupedSteps.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _MilestoneStepGroup(
                          title: entry.key >= 0 &&
                                  entry.key < _milestoneProgress.length
                              ? _milestoneProgress[entry.key].title
                              : 'Execution history',
                          subtitle: entry.key >= 0 &&
                                  entry.key < _milestoneProgress.length
                              ? _milestoneProgress[entry.key]
                                  .approaches
                                  .where((item) => item.status != 'pending')
                                  .map((item) => item.title)
                                  .join(' • ')
                              : '',
                          steps: entry.value,
                          isActive: entry.key == _activeMilestoneIndex,
                        ),
                      ),
                ],
              ),
            ),
          ],
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
          if ((_isThinkingModelSelected &&
                  (_isPlanning ||
                      _isPlannerThinking ||
                      _latestPlannerReasoning.isNotEmpty)) ||
              _logs.isNotEmpty ||
              _plannerTraces.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Diagnostics',
              subtitle: 'Reasoning, activity, and planner traces',
              icon: Icons.analytics_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_isThinkingModelSelected &&
                      (_isPlanning ||
                          _isPlannerThinking ||
                          _latestPlannerReasoning.isNotEmpty)) ...[
                    _PlannerReasoningBanner(
                      isThinking: _isPlanning || _isPlannerThinking,
                      reasoning: _latestPlannerReasoning,
                    ),
                    if (_logs.isNotEmpty || _plannerTraces.isNotEmpty)
                      const SizedBox(height: 12),
                  ],
                  if (_logs.isNotEmpty || _plannerTraces.isNotEmpty)
                    _CollapsibleLogSection(
                      logs: _logs,
                      plannerTraces: _plannerTraces,
                    ),
                ],
              ),
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
    this.milestoneIndex,
    this.approachTitle,
  });

  final String id;
  final String title;
  final String status;
  final String detail;
  final int? milestoneIndex;
  final String? approachTitle;

  _ActionStep copyWith({
    String? status,
    String? detail,
    int? milestoneIndex,
    String? approachTitle,
  }) {
    return _ActionStep(
      id: id,
      title: title,
      status: status ?? this.status,
      detail: detail ?? this.detail,
      milestoneIndex: milestoneIndex ?? this.milestoneIndex,
      approachTitle: approachTitle ?? this.approachTitle,
    );
  }
}

class _ApproachProgressItem {
  const _ApproachProgressItem({
    required this.title,
    required this.status,
    this.detail = '',
  });

  final String title;
  final String status;
  final String detail;

  _ApproachProgressItem copyWith({
    String? title,
    String? status,
    String? detail,
  }) {
    return _ApproachProgressItem(
      title: title ?? this.title,
      status: status ?? this.status,
      detail: detail ?? this.detail,
    );
  }
}

class _MilestoneProgressItem {
  const _MilestoneProgressItem({
    required this.title,
    required this.status,
    required this.approaches,
    this.detail = '',
  });

  final String title;
  final String status;
  final String detail;
  final List<_ApproachProgressItem> approaches;

  _MilestoneProgressItem copyWith({
    String? title,
    String? status,
    String? detail,
    List<_ApproachProgressItem>? approaches,
  }) {
    return _MilestoneProgressItem(
      title: title ?? this.title,
      status: status ?? this.status,
      detail: detail ?? this.detail,
      approaches: approaches ?? this.approaches,
    );
  }
}

class _LocalCompletionResult {
  const _LocalCompletionResult._({
    required this.state,
    required this.reason,
  });

  const _LocalCompletionResult.complete(String reason)
      : this._(state: _LocalCompletionState.complete, reason: reason);

  const _LocalCompletionResult.incomplete(String reason)
      : this._(state: _LocalCompletionState.incomplete, reason: reason);

  const _LocalCompletionResult.ambiguous(String reason)
      : this._(state: _LocalCompletionState.ambiguous, reason: reason);

  final _LocalCompletionState state;
  final String reason;

  bool get isComplete => state == _LocalCompletionState.complete;
  bool get isAmbiguous => state == _LocalCompletionState.ambiguous;

  String get label => switch (state) {
    _LocalCompletionState.complete => 'complete',
    _LocalCompletionState.incomplete => 'incomplete',
    _LocalCompletionState.ambiguous => 'ambiguous',
  };
}

enum _LocalCompletionState { complete, incomplete, ambiguous }

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

class _UiValidationSnapshot {
  const _UiValidationSnapshot({
    required this.windowTitle,
    required this.labels,
    required this.dialogBucket,
    required this.editableBucket,
    required this.buttonBucket,
  });

  final String windowTitle;
  final Set<String> labels;
  final String dialogBucket;
  final String editableBucket;
  final String buttonBucket;
}

class _SpeculativeMilestonePlan {
  const _SpeculativeMilestonePlan({
    required this.requestKey,
    required this.milestoneIndex,
    required this.approachIndex,
    required this.approachTitle,
    required this.uiSummary,
    required this.uiSnapshot,
    required this.plan,
  });

  final String requestKey;
  final int milestoneIndex;
  final int approachIndex;
  final String approachTitle;
  final String uiSummary;
  final _UiValidationSnapshot uiSnapshot;
  final MilestonePlan plan;
}

/// Holds pre-computed plans for ALL milestones from a single bulk LLM call.
///
/// Each milestone entry starts non-null and is set to `null` once consumed
/// or invalidated due to UI drift.  The [uiSnapshot] is taken at bulk-plan
/// time and compared against the live UI at each milestone boundary.
///
/// Only used for approach index 0 (the primary approach). If the primary
/// approach fails and the system falls back to a secondary approach, the
/// bulk cache is discarded entirely and per-milestone planning takes over.
class _BulkPlanCache {
  _BulkPlanCache({
    required this.milestonePlans,
    required this.uiSnapshot,
    required this.approachTitle,
  });

  /// Indexed by milestone order. `null` = consumed or invalidated.
  final List<MilestonePlan?> milestonePlans;

  /// UI snapshot taken at bulk-planning time for drift detection.
  final _UiValidationSnapshot uiSnapshot;

  /// The approach these plans were generated for.
  final String approachTitle;

  /// Consume the plan for [milestoneIndex], returning it and setting the
  /// slot to `null` so it cannot be reused.
  MilestonePlan? consume(int milestoneIndex) {
    if (milestoneIndex < 0 || milestoneIndex >= milestonePlans.length) {
      return null;
    }
    final plan = milestonePlans[milestoneIndex];
    milestonePlans[milestoneIndex] = null;
    return plan;
  }

  /// Invalidate all plans from [fromIndex] onward (inclusive).
  void invalidateFrom(int fromIndex) {
    for (var i = fromIndex; i < milestonePlans.length; i++) {
      milestonePlans[i] = null;
    }
  }

  /// Whether any unconsumed plans remain.
  bool get hasRemainingPlans =>
      milestonePlans.any((plan) => plan != null);
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

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF252C35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF39424E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: const Color(0xFF303845),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 16, color: const Color(0xFFD2D8DF)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFFE8E9EB),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFF8A95A5),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.task,
    required this.totalMilestones,
    required this.completedMilestones,
    required this.isRunning,
    required this.isPlanning,
    required this.abortReason,
    required this.totalSteps,
  });

  final String? task;
  final int totalMilestones;
  final int completedMilestones;
  final bool isRunning;
  final bool isPlanning;
  final String? abortReason;
  final int totalSteps;

  @override
  Widget build(BuildContext context) {
    final statusLabel = abortReason != null
        ? 'Needs attention'
        : isRunning
        ? (isPlanning ? 'Planning' : 'Executing')
        : completedMilestones > 0 && completedMilestones == totalMilestones
        ? 'Completed'
        : 'Ready';
    final statusColor = abortReason != null
        ? const Color(0xFFE57373)
        : isRunning
        ? const Color(0xFF64B5F6)
        : completedMilestones > 0 && completedMilestones == totalMilestones
        ? const Color(0xFF81C784)
        : const Color(0xFFB8C1CC);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF2A313C), Color(0xFF222831)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF3C4552)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_awesome_outlined,
                size: 16,
                color: Color(0xFFE8E9EB),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Take Action workspace',
                  style: TextStyle(
                    color: Color(0xFFE8E9EB),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _StatusPill(label: statusLabel, color: statusColor),
            ],
          ),
          if (task != null && task!.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              task!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFB8C1CC),
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetricChip(
                label: 'Milestones',
                value: totalMilestones == 0
                    ? 'Pending'
                    : '$completedMilestones/$totalMilestones',
              ),
              _MetricChip(label: 'Tracked steps', value: '$totalSteps'),
              _MetricChip(
                label: 'Phase',
                value: isPlanning
                    ? 'Planning'
                    : (isRunning ? 'Executing' : 'Idle'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MilestoneProgressBoard extends StatelessWidget {
  const _MilestoneProgressBoard({
    required this.milestones,
    required this.activeMilestoneIndex,
    required this.activeApproachIndex,
  });

  final List<_MilestoneProgressItem> milestones;
  final int activeMilestoneIndex;
  final int activeApproachIndex;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < milestones.length; i++) ...[
          _MilestoneProgressTile(
            item: milestones[i],
            index: i,
            isActive: i == activeMilestoneIndex,
            activeApproachIndex: i == activeMilestoneIndex
                ? activeApproachIndex
                : -1,
          ),
          if (i != milestones.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _MilestoneProgressTile extends StatelessWidget {
  const _MilestoneProgressTile({
    required this.item,
    required this.index,
    required this.isActive,
    required this.activeApproachIndex,
  });

  final _MilestoneProgressItem item;
  final int index;
  final bool isActive;
  final int activeApproachIndex;

  @override
  Widget build(BuildContext context) {
    final accent = _statusColor(item.status);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFF2C3541) : const Color(0xFF20262E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? accent : const Color(0xFF323A45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: accent,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.title,
                  style: const TextStyle(
                    color: Color(0xFFE8E9EB),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _StatusPill(
                label: _statusLabel(item.status),
                color: accent,
              ),
            ],
          ),
          if (item.detail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              item.detail,
              style: const TextStyle(
                color: Color(0xFF8A95A5),
                fontSize: 11.5,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < item.approaches.length; i++)
                _ApproachChip(
                  approach: item.approaches[i],
                  isActive: isActive && i == activeApproachIndex,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ApproachChip extends StatelessWidget {
  const _ApproachChip({
    required this.approach,
    required this.isActive,
  });

  final _ApproachProgressItem approach;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(approach.status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isActive
            ? color.withValues(alpha: 0.14)
            : const Color(0xFF262D36),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isActive ? color : const Color(0xFF39424E),
        ),
      ),
      child: Text(
        approach.title,
        style: TextStyle(
          color: isActive ? color : const Color(0xFFB8C1CC),
          fontSize: 11.5,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
  }
}

class _ActiveMilestoneCard extends StatelessWidget {
  const _ActiveMilestoneCard({
    required this.milestoneTitle,
    required this.milestoneIndex,
    required this.totalMilestones,
    required this.milestoneStatus,
    required this.milestoneDetail,
    required this.approachTitle,
    required this.approachStatus,
    required this.approachDetail,
    required this.completionLabel,
    required this.completionReason,
    required this.isPlanning,
  });

  final String milestoneTitle;
  final int milestoneIndex;
  final int totalMilestones;
  final String milestoneStatus;
  final String milestoneDetail;
  final String approachTitle;
  final String approachStatus;
  final String approachDetail;
  final String completionLabel;
  final String completionReason;
  final bool isPlanning;

  @override
  Widget build(BuildContext context) {
    final milestoneColor = _statusColor(milestoneStatus);
    final approachColor = _statusColor(approachStatus);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Milestone ${milestoneIndex + 1}${totalMilestones > 0 ? ' of $totalMilestones' : ''}',
                style: const TextStyle(
                  color: Color(0xFF8A95A5),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _StatusPill(
              label: _statusLabel(milestoneStatus),
              color: milestoneColor,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          milestoneTitle,
          style: const TextStyle(
            color: Color(0xFFE8E9EB),
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (milestoneDetail.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            milestoneDetail,
            style: const TextStyle(
              color: Color(0xFFB8C1CC),
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF20262E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF323A45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Selected approach',
                      style: TextStyle(
                        color: Color(0xFF8A95A5),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _StatusPill(
                    label: _statusLabel(approachStatus),
                    color: approachColor,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                approachTitle,
                style: const TextStyle(
                  color: Color(0xFFE8E9EB),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (approachDetail.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  approachDetail,
                  style: const TextStyle(
                    color: Color(0xFFB8C1CC),
                    fontSize: 11.5,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MetricChip(
              label: 'Completion signal',
              value: completionLabel.isEmpty ? 'Pending' : completionLabel,
            ),
            _MetricChip(
              label: 'Mode',
              value: isPlanning ? 'Planning next steps' : 'Execution live',
            ),
          ],
        ),
        if (completionReason.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF20262E),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF323A45)),
            ),
            child: Text(
              completionReason,
              style: const TextStyle(
                color: Color(0xFFB8C1CC),
                fontSize: 11.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF20262E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF323A45)),
      ),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontFamily: 'inherit'),
          children: [
            TextSpan(
              text: '$label  ',
              style: const TextStyle(
                color: Color(0xFF8A95A5),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                color: Color(0xFFE8E9EB),
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

Color _statusColor(String status) {
  switch (status) {
    case 'completed':
      return const Color(0xFF81C784);
    case 'active':
    case 'started':
      return const Color(0xFF64B5F6);
    case 'failed':
      return const Color(0xFFE57373);
    default:
      return const Color(0xFFB8C1CC);
  }
}

String _statusLabel(String status) {
  switch (status) {
    case 'completed':
      return 'Completed';
    case 'active':
      return 'Active';
    case 'started':
      return 'Running';
    case 'failed':
      return 'Failed';
    default:
      return 'Pending';
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

class _MilestoneStepGroup extends StatelessWidget {
  const _MilestoneStepGroup({
    required this.title,
    required this.subtitle,
    required this.steps,
    required this.isActive,
  });

  final String title;
  final String subtitle;
  final List<_ActionStep> steps;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: isActive ? 1 : 0.72,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF20262E) : const Color(0xFF1C2128),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive
                ? const Color(0xFF3F4A58)
                : const Color(0xFF2C333D),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Color(0xFFE8E9EB),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _StatusPill(
                  label: isActive ? 'Active' : 'History',
                  color: isActive
                      ? const Color(0xFF64B5F6)
                      : const Color(0xFF8A95A5),
                ),
              ],
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF8A95A5),
                  fontSize: 11.5,
                ),
              ),
            ],
            const SizedBox(height: 10),
            for (var i = 0; i < steps.length; i++)
              _StepTimelineRow(
                step: steps[i],
                isFirst: i == 0,
                isLast: i == steps.length - 1,
              ),
          ],
        ),
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

class _TraceSection extends StatefulWidget {
  const _TraceSection({required this.label, required this.content});

  final String label;
  final String content;

  @override
  State<_TraceSection> createState() => _TraceSectionState();
}

class _TraceSectionState extends State<_TraceSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1D222A),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(5),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 14,
                    color: const Color(0xFF8A95A5),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: const TextStyle(
                        color: Color(0xFF8A95A5),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                widget.content.isEmpty ? '[empty]' : widget.content,
                style: const TextStyle(
                  color: Color(0xFF9EA5AF),
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
