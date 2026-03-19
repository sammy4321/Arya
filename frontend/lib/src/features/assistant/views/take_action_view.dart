import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arya_app/src/core/window_helpers.dart';
import 'package:arya_app/src/features/assistant/models/chat_models.dart';
import 'package:arya_app/src/features/assistant/services/action_executor_service.dart';
import 'package:arya_app/src/features/assistant/services/screenshot_service.dart';
import 'package:arya_app/src/features/assistant/services/step_planner.dart';
import 'package:arya_app/src/features/assistant/services/ui_parser_service.dart';
import 'package:arya_app/src/features/settings/ai_settings_store.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

const _maxSteps = 12;
const _maxConsecutiveAnalyze = 1;
const _maxConsecutiveFailures = 2;

class TakeActionView extends StatefulWidget {
  const TakeActionView({super.key});

  @override
  State<TakeActionView> createState() => _TakeActionViewState();
}

class _TakeActionViewState extends State<TakeActionView> {
  final _controller = TextEditingController();
  bool _isLoading = false;
  String _webMode = 'auto';
  String? _abortReason;
  final List<_CapturedScreenshot> _capturedScreenshots = [];
  final List<ChatAttachment> _pendingAttachments = [];
  final List<_ActionStep> _steps = [];
  final List<String> _logs = [];
  String? _latestScreenshotPath;
  List<UIElement> _latestUIElements = [];
  int? _targetAppPid;

  @override
  void initState() {
    super.initState();
    UIParserService.instance.warmUp();
    ActionExecutorService.instance.warmUp();
  }

  @override
  void dispose() {
    _controller.dispose();
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
      _isLoading = true;
      _steps.clear();
      _logs.clear();
      _capturedScreenshots.clear();
      _abortReason = null;
      _pendingAttachments.clear();
      _latestScreenshotPath = null;
      _targetAppPid = null;
      ActionExecutorService.instance.targetAppPid = null;
    });
    _controller.clear();

    await _runAdaptiveLoop(
      task: text,
      model: model,
      attachments: attachments,
    );

    if (mounted) setState(() => _isLoading = false);
  }

  final StepPlanner _planner = StepPlanner();

  Future<void> _runAdaptiveLoop({
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
    final scaleFactor = (screenContext['scaleFactor'] as num?)?.toDouble() ?? 1.0;

    final captureRegion = CaptureRegion(
      x: regionLeft,
      y: regionTop,
      width: regionWidth,
      height: regionHeight,
    );

    _log('Session started on current screen');
    _log('Screen region: ($regionLeft,$regionTop) '
        '${regionWidth}x$regionHeight scale=$scaleFactor');

    final attachmentMaps = attachments.map(_toAttachmentMap).toList();
    final history = <Map<String, String>>[];
    var consecutiveAnalyze = 0;
    var consecutiveFailures = 0;

    await _captureScreenshotAndUI('Initial context', region: captureRegion);

    for (var stepNum = 1; stepNum <= _maxSteps; stepNum++) {
      if (!mounted || !_isLoading) return;

      _log('Planning step #$stepNum...');

      StepPlanResult planResult;
      try {
        planResult = await _planner.planNextStep(
          openRouterKey: openRouterKey,
          tavilyKey: tavilyKey,
          model: model,
          webMode: _webMode,
          task: task,
          stepNumber: stepNum,
          history: history,
          screenContext: screenContext,
          attachments: attachmentMaps,
          screenshotPath: _latestScreenshotPath,
          uiContext: formatUIElementsForPrompt(_latestUIElements),
        );
      } catch (e) {
        _log('Planning failed: $e');
        _setAbort('Planning failed: $e');
        return;
      }

      debugPrint('[TakeAction] Planner result: done=${planResult.done}, '
          'reason="${planResult.reason}", step=${planResult.step}');

      if (planResult.done) {
        final reason = planResult.reason.trim().isNotEmpty
            ? planResult.reason.trim()
            : 'Task completed.';
        if (!_hasRealExecution(history)) {
          consecutiveFailures++;
          history.add({
            'step_id': 'step_${stepNum}_done_rejected',
            'title': 'Done rejected',
            'status': 'failed',
            'detail': 'No concrete actions executed yet.',
          });
          _log('Completion rejected — no real actions taken yet');
          if (consecutiveFailures >= _maxConsecutiveFailures) {
            _setAbort('Could not verify task completion.');
            return;
          }
          continue;
        }
        _log('Done: $reason');
        return;
      }

      final stepData = planResult.step;
      if (stepData == null) {
        _log('Planner returned no step — retrying');
        continue;
      }

      final action = (stepData['action'] as String? ?? '').toLowerCase().trim();
      final stepId = stepData['id'] as String? ?? 'step_$stepNum';
      final title = stepData['title'] as String? ?? 'Step $stepNum';

      if ({'analyze', 'think', 'observe', 'element_not_found'}.contains(action)) {
        consecutiveAnalyze++;
        final detail = action == 'element_not_found'
            ? 'Element not found: ${stepData['args']?['description'] ?? 'unknown'}. '
                'Re-capture screen and retry.'
            : 'Analyze actions do nothing — produce a concrete action.';
        if (consecutiveAnalyze > _maxConsecutiveAnalyze) {
          history.add({
            'step_id': stepId,
            'title': title,
            'status': 'failed',
            'detail': detail,
          });
          consecutiveFailures++;
          _log('$action detected — forcing replan');
          if (consecutiveFailures >= _maxConsecutiveFailures) {
            _setAbort('Planner stuck ($action loop).');
            return;
          }
          // Re-capture to get fresh UI elements before retrying.
          if (action == 'element_not_found') {
            await _captureScreenshotAndUI('Re-capture for retry',
                hideWindow: false, region: captureRegion);
          }
          continue;
        }
      } else {
        consecutiveAnalyze = 0;
      }

      _addStep(stepId, title, 'started');
      _log('Executing: $title');

      // Resolve element_id → region-relative coordinates, then add region
      // offset for absolute screen coordinates.
      final resolvedStep = _resolveElementClick(stepData, _latestUIElements);
      final adjustedStep = _offsetCoordinates(resolvedStep, regionLeft, regionTop);
      final result = await ActionExecutorService.instance.executeStep(adjustedStep);

      if (result.ok) {
        consecutiveFailures = 0;
        history.add({
          'step_id': stepId,
          'title': title,
          'status': 'completed',
          'detail': result.detail,
        });
        _updateStep(stepId, 'completed', result.detail);
        _log('$title: ${result.detail}');

        // Execute chained "then" actions immediately (no re-plan cycle).
        await _executeChainedActions(
          stepData,
          stepId: stepId,
          history: history,
          regionLeft: regionLeft,
          regionTop: regionTop,
        );

        await Future.delayed(const Duration(milliseconds: 500));
        await _captureScreenshotAndUI('After: $title',
            hideWindow: false, region: captureRegion);
      } else {
        consecutiveFailures++;
        history.add({
          'step_id': stepId,
          'title': title,
          'status': 'failed',
          'detail': result.detail,
        });
        _updateStep(stepId, 'failed', result.detail);
        _log('Failed: $title — ${result.detail}');

        if (consecutiveFailures >= _maxConsecutiveFailures) {
          _setAbort('Multiple steps failed. Execution stopped.');
          return;
        }
      }
    }

    _log('Reached maximum step limit.');
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
    required int regionLeft,
    required int regionTop,
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

      final resolved = _resolveElementClick(current, _latestUIElements);
      final adjusted = _offsetCoordinates(resolved, regionLeft, regionTop);
      final chainResult =
          await ActionExecutorService.instance.executeStep(adjusted);

      history.add({
        'step_id': chainTitle,
        'title': chainTitle,
        'status': chainResult.ok ? 'completed' : 'failed',
        'detail': chainResult.detail,
      });
      _log('Chain [$chainIndex] ${chainResult.ok ? "OK" : "FAIL"}: '
          '${chainResult.detail}');

      if (!chainResult.ok) break;
      prevAction = chainAction;
      current = current['then'];
    }
  }

  /// Resolves element_id → region-relative (x, y) using the parsed UI tree.
  ///
  /// The LLM outputs {"element_id": 6, "position": "center"} and this method
  /// looks up element 6, computes the click point based on position, and
  /// replaces element_id/position with concrete x/y in the args. If no
  /// element_id is present (fallback), the step is returned unchanged.
  Map<String, dynamic> _resolveElementClick(
    Map<String, dynamic> step,
    List<UIElement> elements,
  ) {
    final action = (step['action'] as String? ?? '').toLowerCase();
    if (action != 'click') return step;

    final args = step['args'];
    if (args is! Map<String, dynamic>) return step;

    final elementId = args['element_id'];
    if (elementId == null) return step;

    final id = (elementId as num).toInt();
    final match = elements.where((e) => e.id == id);
    if (match.isEmpty) {
      debugPrint('[TakeAction] ⚠ Element [$id] not found — '
          '${elements.length} elements available');
      return step;
    }

    final el = match.first;
    final position =
        (args['position'] as String? ?? 'center').toLowerCase();

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
        x = el.centerX;
        y = el.centerY;
    }

    debugPrint('[TakeAction] Resolved [$id] "${el.label}" '
        'pos=$position → region-relative ($x, $y)');

    final resolvedArgs = Map<String, dynamic>.from(args)
      ..remove('element_id')
      ..remove('position')
      ..['x'] = x
      ..['y'] = y;

    return Map<String, dynamic>.from(step)..['args'] = resolvedArgs;
  }

  /// Converts region-relative coordinates to absolute screen coordinates.
  Map<String, dynamic> _offsetCoordinates(
    Map<String, dynamic> step,
    int offsetX,
    int offsetY,
  ) {
    if (offsetX == 0 && offsetY == 0) return step;

    final args = step['args'];
    if (args is! Map<String, dynamic>) return step;

    final action = (step['action'] as String? ?? '').toLowerCase();
    if (!{'click', 'move_mouse'}.contains(action)) return step;

    final adjustedArgs = Map<String, dynamic>.from(args);
    if (adjustedArgs.containsKey('x')) {
      adjustedArgs['x'] = (adjustedArgs['x'] as num).toInt() + offsetX;
    }
    if (adjustedArgs.containsKey('y')) {
      adjustedArgs['y'] = (adjustedArgs['y'] as num).toInt() + offsetY;
    }

    debugPrint('[TakeAction] Offset coordinates: '
        '(${args['x']},${args['y']}) → (${adjustedArgs['x']},${adjustedArgs['y']})');

    return Map<String, dynamic>.from(step)..['args'] = adjustedArgs;
  }

  bool _hasRealExecution(List<Map<String, String>> history) {
    return history.any((h) =>
        h['status'] == 'completed' &&
        !{'analysis step completed.', 'waited'}.any(
          (skip) => (h['detail'] ?? '').toLowerCase().startsWith(skip),
        ));
  }

  /// Captures a screenshot and parses the accessibility tree.
  ///
  /// When [hideWindow] is true we manage the hide/show cycle ourselves so that
  /// both the screenshot and UI parse happen while the target app is frontmost.
  /// The target PID is captured on the first call and reused for subsequent
  /// calls (where [hideWindow] is false) so we always parse the right app.
  Future<void> _captureScreenshotAndUI(
    String label, {
    bool hideWindow = true,
    CaptureRegion? region,
  }) async {
    if (hideWindow && supportsDesktopWindowControls) {
      await windowManager.hide();
      await Future.delayed(const Duration(milliseconds: 220));
    }

    // Capture the target PID while our window is hidden (first call) so we
    // know which app to parse on later calls when we don't hide.
    // Pass the capture region so on multi-monitor setups we only consider
    // windows on the same screen.
    _targetAppPid ??=
        await UIParserService.instance.getFrontmostPid(region: region);
    ActionExecutorService.instance.targetAppPid = _targetAppPid;

    // Screenshot without its own hide/show — we handle that.
    String? path = await ScreenshotService.instance.captureFullScreen(
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

    // Parse the target app's accessibility tree using the cached PID.
    final elements = await UIParserService.instance.parseScreen(
      region: region,
      targetPid: _targetAppPid,
    );

    if (hideWindow && supportsDesktopWindowControls) {
      await windowManager.show();
    }

    if (!mounted) return;
    if (path != null && path.isNotEmpty) {
      _latestScreenshotPath = path;
    }
    _latestUIElements = elements;

    setState(() {
      if (path != null && path.isNotEmpty) {
        _capturedScreenshots.add(
          _CapturedScreenshot(path: path, label: label, createdAt: DateTime.now()),
        );
        _logs.add('$label (screenshot + ${elements.length} UI elements)');
      } else {
        _logs.add('$label (screenshot failed, ${elements.length} UI elements)');
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

  void _addStep(String id, String title, String status) {
    if (!mounted) return;
    setState(() {
      _steps.add(_ActionStep(id: id, title: title, status: status, detail: ''));
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
      extensions: ['pdf', 'txt', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final ext = file.name.split('.').last.toLowerCase();
    final isImage = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'].contains(ext);
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
        _buildInput(),
      ],
    );
  }

  Widget _buildControlsRow() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF373E47),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          _StatusBadge(
            label: _isLoading ? 'Running' : 'Idle',
            color: _isLoading
                ? const Color(0xFF64B5F6)
                : const Color(0xFF6B7585),
          ),
          const SizedBox(width: 8),
          const Text(
            'Web:',
            style: TextStyle(color: Color(0xFF9EA5AF), fontSize: 12),
          ),
          const SizedBox(width: 8),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _webMode,
              dropdownColor: const Color(0xFF2A3441),
              style: const TextStyle(color: Color(0xFFE8E9EB), fontSize: 12),
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
    if (_steps.isEmpty && _logs.isEmpty) {
      return const Center(
        child: SelectableText(
          'Describe the action you want me to take',
          style: TextStyle(color: Color(0xFF9EA5AF), fontSize: 14),
        ),
      );
    }

    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_abortReason != null)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFE57373).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE57373)),
              ),
              child: Text(
                'Aborted: $_abortReason',
                style: const TextStyle(
                  color: Color(0xFFFFCDD2),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          for (final step in _steps)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF4E5661),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _statusColor(step.status)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _statusIcon(step.status),
                    size: 14,
                    color: _statusColor(step.status),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          step.title,
                          style: const TextStyle(
                            color: Color(0xFFE8E9EB),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (step.detail.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            step.detail,
                            style: const TextStyle(
                              color: Color(0xFFCDD4DE),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (_capturedScreenshots.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text(
              'Screenshots',
              style: TextStyle(
                color: Color(0xFF9EA5AF),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 110,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _capturedScreenshots.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final shot = _capturedScreenshots[index];
                  return _ScreenshotTile(shot: shot);
                },
              ),
            ),
          ],
          if (_logs.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text(
              'Logs',
              style: TextStyle(
                color: Color(0xFF9EA5AF),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            for (final log in _logs.take(50).toList().reversed)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '- $log',
                  style: const TextStyle(color: Color(0xFFCDD4DE), fontSize: 11),
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
                      child: const Icon(Icons.add, color: Color(0xFFD2D8DF), size: 20),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      style: const TextStyle(color: Color(0xFFE8E9EB), fontSize: 14),
                      maxLines: 5,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _isLoading ? null : unawaited(_submit()),
                      decoration: const InputDecoration(
                        hintText: 'Describe the action you want me to take...',
                        hintStyle: TextStyle(color: Color(0xFF9EA5AF), fontSize: 14),
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
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _isLoading ? const Color(0xFF677281) : const Color(0xFF1F80E9),
              borderRadius: BorderRadius.circular(12),
            ),
            child: InkWell(
              onTap: _isLoading ? null : () => unawaited(_submit()),
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (!_isLoading)
                    const Icon(Icons.send, color: Colors.white, size: 18),
                  if (_isLoading)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'completed':
        return const Color(0xFF81C784);
      case 'started':
        return const Color(0xFF64B5F6);
      case 'failed':
        return const Color(0xFFE57373);
      default:
        return const Color(0xFF6B7585);
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'completed':
        return Icons.check_circle;
      case 'started':
        return Icons.sync;
      case 'failed':
        return Icons.error;
      default:
        return Icons.radio_button_unchecked;
    }
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

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
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

class _ScreenshotTile extends StatelessWidget {
  const _ScreenshotTile({required this.shot});

  final _CapturedScreenshot shot;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 170,
      decoration: BoxDecoration(
        color: const Color(0xFF4E5661),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                File(shot.path),
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(
                  color: Color(0xFF2F3640),
                  child: Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Color(0xFF9EA5AF),
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            shot.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFD2D8DF), fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}
