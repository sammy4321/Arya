import 'package:arya_app/src/core/app_constants.dart';
import 'package:arya_app/src/core/window_helpers.dart';
import 'package:arya_app/src/features/assistant/models/chat_models.dart';
import 'package:arya_app/src/features/assistant/services/ai_service.dart';
import 'package:arya_app/src/features/assistant/views/chat_view.dart';
import 'package:arya_app/src/features/assistant/views/home_view.dart';
import 'package:arya_app/src/features/assistant/views/take_action_view.dart';
import 'package:arya_app/src/features/assistant/widgets/model_selector.dart';
import 'package:arya_app/src/features/settings/settings_workspace.dart';
import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Main floating assistant button and popup window.
class FloatingButtonScreen extends StatefulWidget {
  const FloatingButtonScreen({super.key});

  @override
  State<FloatingButtonScreen> createState() => _FloatingButtonScreenState();
}

class _FloatingButtonScreenState extends State<FloatingButtonScreen> {
  bool _isWindowOpen = false;
  AssistantView _currentView = AssistantView.home;
  final List<ChatMessage> _chatMessages = [];
  bool _isLoading = false;
  int _takeActionResetKey = 0;

  // Predefined menu items for the home screen
  static const List<AssistantMenuItem> _assistantMenuItems = [
    AssistantMenuItem(
      icon: Icons.chat_bubble,
      title: 'Chat',
      subtitle: 'Ask me anything',
      view: AssistantView.chat,
    ),
    AssistantMenuItem(
      icon: Icons.bolt,
      title: 'Take Action',
      subtitle: 'Automate this task',
      view: AssistantView.takeAction,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              right: 16,
              bottom: 16,
              child: GestureDetector(
                onPanStart: (_) => _startNativeDrag(),
                behavior: HitTestBehavior.translucent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: _isWindowOpen
                          ? MediaQuery(
                              data: MediaQuery.of(
                                context,
                              ).copyWith(textScaler: TextScaler.noScaling),
                              child: Container(
                                key: const ValueKey('popup'),
                                width: _currentView == AssistantView.home
                                    ? assistantHomePopupWidth
                                    : (MediaQuery.of(context).size.width - 32)
                                          .clamp(
                                            assistantHomePopupWidth,
                                            _currentView ==
                                                    AssistantView.settings
                                                ? assistantSettingsPopupWidth
                                                : assistantDetailPopupWidth,
                                          ),
                                height: _currentView == AssistantView.home
                                    ? null
                                    : (MediaQuery.of(context).size.height - 96)
                                          .clamp(
                                            0.0,
                                            MediaQuery.of(context).size.height,
                                          ),
                                margin: const EdgeInsets.only(bottom: 12),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: ColoredBox(
                                    color: const Color(0xFF47505A),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize:
                                          _currentView == AssistantView.home
                                          ? MainAxisSize.min
                                          : MainAxisSize.max,
                                      children: [
                                        _buildHeader(),
                                        const Divider(
                                          height: 1,
                                          color: Color(0xFF5B626C),
                                        ),
                                        _currentView == AssistantView.home
                                            ? _buildHomeContent()
                                            : Expanded(
                                                child: _buildCurrentView(),
                                              ),
                                        if (_currentView == AssistantView.home)
                                          _buildFooter(),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(key: ValueKey('empty')),
                    ),
                    FloatingActionButton(
                      onPressed: _toggleWindow,
                      tooltip: '',
                      backgroundColor: const Color(0xFF1F80E9),
                      foregroundColor: Colors.white,
                      child: Icon(
                        _isWindowOpen
                            ? Icons.close
                            : Icons.auto_awesome_rounded,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return GestureDetector(
      onPanStart: (_) => _startNativeDrag(),
      behavior: HitTestBehavior.translucent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Row(
          children: [
            if (_currentView == AssistantView.home) ...[
              const Icon(Icons.circle, color: Color(0xFF1F7ACF), size: 9),
              const SizedBox(width: 10),
              Text(
                _getViewTitle(_currentView),
                style: const TextStyle(
                  color: Color(0xFFE8E9EB),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ] else ...[
              Expanded(
                child: SizedBox(
                  height: 28,
                  child: Stack(
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            InkWell(
                              onTap: _goBackToHome,
                              borderRadius: BorderRadius.circular(8),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 6,
                                ),
                                child: Icon(
                                  Icons.arrow_back_ios_new,
                                  size: 14,
                                  color: Color(0xFFD2D8DF),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _getViewTitle(_currentView),
                              style: const TextStyle(
                                color: Color(0xFFE8E9EB),
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_currentView == AssistantView.chat ||
                          _currentView == AssistantView.takeAction)
                        const Align(
                          alignment: Alignment.center,
                          child: SizedBox(
                            width: 220,
                            child: ModelSelector(
                              onModelSelected: _noopModelSelected,
                            ),
                          ),
                        ),
                      if (_currentView == AssistantView.chat ||
                          _currentView == AssistantView.takeAction)
                        Align(
                          alignment: Alignment.centerRight,
                          child: Tooltip(
                            message: 'Start New Chat',
                            child: InkWell(
                              onTap: _clearChat,
                              borderRadius: BorderRadius.circular(8),
                              child: const Padding(
                                padding: EdgeInsets.all(6),
                                child: Icon(
                                  Icons.refresh,
                                  size: 16,
                                  color: Color(0xFFD2D8DF),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static void _noopModelSelected(String _) {}

  Widget _buildHomeContent() {
    return HomeView(onViewSelected: _openView);
  }

  Widget _buildCurrentView() {
    switch (_currentView) {
      case AssistantView.chat:
        return ChatView(
          messages: _chatMessages,
          isLoading: _isLoading,
          onSendMessage: _handleUserMessage,
          onEditUserMessage: _handleEditUserMessage,
        );
      case AssistantView.takeAction:
        return TakeActionView(key: ValueKey(_takeActionResetKey));
      case AssistantView.settings:
        return const SettingsWorkspace();
      case AssistantView.home:
        return const SizedBox.shrink();
    }
  }

  Widget _buildFooter() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF4E5661),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(11)),
      ),
      child: Row(
        children: [
          const Text(
            'Powered by AgentOS',
            style: TextStyle(color: Color(0xFFA4AAB2), fontSize: 10.5),
          ),
          const Spacer(),
          InkWell(
            onTap: () => _openView(AssistantView.settings),
            borderRadius: BorderRadius.circular(14),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.settings, size: 15, color: Color(0xFFA4AAB2)),
            ),
          ),
        ],
      ),
    );
  }

  String _getViewTitle(AssistantView view) {
    switch (view) {
      case AssistantView.home:
        return 'Agent Assistant';
      case AssistantView.chat:
        return 'Chat';
      case AssistantView.takeAction:
        return 'Take Action';
      case AssistantView.settings:
        return 'Settings';
    }
  }

  Future<void> _toggleWindow() async {
    final nextState = !_isWindowOpen;
    if (supportsDesktopWindowControls) {
      await resizeWindowKeepingBottomRightAnchor(
        nextState
            ? await _getWindowSizeForView(_currentView)
            : compactWindowSize,
      );
    }
    if (!mounted) return;
    setState(() => _isWindowOpen = nextState);
  }

  Future<void> _openView(AssistantView view) async {
    if (supportsDesktopWindowControls) {
      await resizeWindowKeepingBottomRightAnchor(
        await _getWindowSizeForView(view),
      );
    }
    if (!mounted) return;
    setState(() => _currentView = view);
  }

  Future<void> _goBackToHome() async {
    if (supportsDesktopWindowControls) {
      await resizeWindowKeepingBottomRightAnchor(await _getHomeWindowSize());
    }
    if (!mounted) return;
    setState(() => _currentView = AssistantView.home);
  }

  void _clearChat() {
    setState(() {
      if (_currentView == AssistantView.takeAction) {
        _takeActionResetKey++;
      } else {
        _chatMessages.clear();
      }
    });
  }

  Future<void> _handleUserMessage(ChatMessage userMessage) async {
    setState(() {
      _chatMessages.add(userMessage);
      _isLoading = true;
    });

    await _requestAssistantReply();
  }

  Future<void> _handleEditUserMessage(int index, String newContent) async {
    if (_isLoading) return;
    if (index < 0 || index >= _chatMessages.length) return;

    final original = _chatMessages[index];
    if (!original.isUser) return;

    final edited = ChatMessage(
      content: newContent,
      isUser: true,
      attachments: original.attachments,
    );
    final truncated = <ChatMessage>[..._chatMessages.take(index), edited];

    setState(() {
      _chatMessages
        ..clear()
        ..addAll(truncated);
      _isLoading = true;
    });

    await _requestAssistantReply();
  }

  Future<void> _requestAssistantReply() async {
    try {
      final result = await AiService.instance.sendChatMessage(_chatMessages);

      if (!mounted) return;

      setState(() {
        _chatMessages.add(
          ChatMessage(
            content: result.content,
            isUser: false,
            latencyMs: result.latencyMs,
          ),
        );
        _isLoading = false;
      });
    } on AiException catch (e) {
      if (!mounted) return;

      setState(() {
        _chatMessages.add(ChatMessage(content: e.message, isUser: false));
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      String errorMessage;
      if (e.toString().contains('timeout') ||
          e.toString().contains('TimeoutException')) {
        errorMessage = 'Request timed out. Please try again.';
      } else {
        errorMessage = 'Error: ${e.toString()}';
      }

      setState(() {
        _chatMessages.add(ChatMessage(content: errorMessage, isUser: false));
        _isLoading = false;
      });
    }
  }

  Future<Size> _getHomeWindowSize() async {
    final display = await screenRetriever.getPrimaryDisplay();
    final visibleSize = display.visibleSize ?? display.size;
    final maxWidth = (visibleSize.width - (windowMarginRight * 2)).toDouble();
    final maxHeight = (visibleSize.height - (windowMarginBottom * 2))
        .toDouble();
    final targetHeight =
        assistantHomeHeaderHeight +
        assistantHomeTopPadding +
        (_assistantMenuItems.length * assistantRowEstimatedHeight) +
        assistantHomeBottomPadding +
        assistantHomeFooterHeight +
        assistantFabDockHeight;

    return Size(
      assistantHomeWindowWidth <= maxWidth
          ? assistantHomeWindowWidth
          : maxWidth,
      targetHeight <= maxHeight ? targetHeight : maxHeight,
    );
  }

  Future<Size> _getWindowSizeForView(AssistantView view) async {
    if (view == AssistantView.home) {
      return _getHomeWindowSize();
    }

    final display = await screenRetriever.getPrimaryDisplay();
    final visibleSize = display.visibleSize ?? display.size;
    final maxWidth = (visibleSize.width - (windowMarginRight * 2)).toDouble();
    final maxHeight = (visibleSize.height - (windowMarginBottom * 2))
        .toDouble();
    final targetHeight = visibleSize.height * 0.9;
    final targetWidth = view == AssistantView.settings
        ? assistantSettingsPopupWidth + 32
        : assistantDetailPopupWidth + 32;

    return Size(
      targetWidth <= maxWidth ? targetWidth : maxWidth,
      targetHeight <= maxHeight ? targetHeight : maxHeight,
    );
  }

  Future<void> _startNativeDrag() async {
    if (!supportsDesktopWindowControls) return;
    await windowManager.startDragging();
  }
}
