import 'dart:io';

import 'package:arya_app/src/features/assistant/models/chat_models.dart';
import 'package:arya_app/src/features/assistant/services/attachment_policy.dart';
import 'package:arya_app/src/features/assistant/services/screenshot_service.dart';
import 'package:arya_app/src/features/assistant/widgets/chat_input.dart';
import 'package:arya_app/src/features/assistant/widgets/chat_message_bubble.dart';
import 'package:arya_app/src/features/assistant/widgets/copy_button.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// The chat view with full messaging functionality.
///
/// This is a stateful widget that manages its own pending attachments
/// but delegates message sending to the parent via [onSendMessage].
class ChatView extends StatefulWidget {
  const ChatView({
    required this.messages,
    required this.isLoading,
    required this.onSendMessage,
    required this.onEditUserMessage,
    required this.onStopGenerating,
    super.key,
  });

  final List<ChatMessage> messages;
  final bool isLoading;
  final ValueChanged<ChatMessage> onSendMessage;
  final Future<void> Function(int index, String newContent) onEditUserMessage;
  final ChatMessage? Function() onStopGenerating;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final List<ChatAttachment> _pendingAttachments = [];
  final List<String> _loadingAttachmentNames = [];
  int? _editingMessageIndex;
  bool _isCapturingScreenshot = false;
  bool _isDragOver = false;
  bool _isAttachingFiles = false;
  int _lastMessageCount = 0;
  int _lastContentLength = 0;
  int _lastReasoningLength = 0;
  bool _lastWasStreaming = false;

  @override
  void dispose() {
    _controller.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeAutoScroll() {
    final count = widget.messages.length;
    if (count == 0) return;
    final last = widget.messages.last;
    final contentLen = last.content.length;
    final reasoningLen = last.reasoning.length;
    final isStreaming = last.isStreaming;
    final changed = count != _lastMessageCount ||
        contentLen != _lastContentLength ||
        reasoningLen != _lastReasoningLength ||
        isStreaming != _lastWasStreaming;
    if (!changed) return;

    _lastMessageCount = count;
    _lastContentLength = contentLen;
    _lastReasoningLength = reasoningLen;
    _lastWasStreaming = isStreaming;

    _scrollToBottom(immediate: isStreaming);
  }

  void _scrollToBottom({bool immediate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (immediate) {
        _scrollController.jumpTo(target);
      } else {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _startEditingMessage(int index) {
    final message = widget.messages[index];
    final text = message.content;
    setState(() {
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _pendingAttachments.clear();
      _editingMessageIndex = index;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _inputFocusNode.requestFocus();
    });
  }

  void _cancelEditingMessage() {
    setState(() {
      _controller.clear();
      _pendingAttachments.clear();
      _editingMessageIndex = null;
    });
  }

  Future<void> _pickFileFromComputer() async {
    const typeGroup = XTypeGroup(
      label: 'Supported files',
      extensions: [...supportedAttachmentExtensions],
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;

    await _attachXFile(file);
  }

  Future<void> _attachXFile(XFile file) async {
    if (_isAttachingFiles) return;
    setState(() => _isAttachingFiles = true);
    await Future<void>.delayed(Duration.zero);

    _markFileLoading(file.name);
    if (!isSupportedAttachmentFile(file.name)) {
      _showAttachmentError('Unsupported file type: ${file.name}');
      _clearFileLoading(file.name);
      if (mounted) {
        setState(() => _isAttachingFiles = false);
      }
      return;
    }

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      _showAttachmentError('Could not attach empty file: ${file.name}');
      _clearFileLoading(file.name);
      if (mounted) {
        setState(() => _isAttachingFiles = false);
      }
      return;
    }

    final isImage = isImageAttachmentFile(file.name);
    if (!mounted) return;
    setState(() {
      _pendingAttachments.add(
        ChatAttachment(name: file.name, bytes: bytes, isImage: isImage),
      );
      _removeFirstLoadingByName(file.name);
      _isAttachingFiles = false;
    });
  }

  Future<void> _attachFilesFromPaths(List<String> paths) async {
    if (_isAttachingFiles) return;
    setState(() => _isAttachingFiles = true);
    await Future<void>.delayed(Duration.zero);

    int attachedCount = 0;
    try {
      for (final path in paths) {
        final file = File(path);
        if (!await file.exists()) continue;

        final fileName = p.basename(path);
        _markFileLoading(fileName);
        if (!isSupportedAttachmentFile(fileName)) {
          _clearFileLoading(fileName);
          continue;
        }

        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          _clearFileLoading(fileName);
          continue;
        }

        attachedCount++;
        if (!mounted) return;
        setState(() {
          _pendingAttachments.add(
            ChatAttachment(
              name: fileName,
              bytes: bytes,
              isImage: isImageAttachmentFile(fileName),
            ),
          );
          _removeFirstLoadingByName(fileName);
        });
      }

      if (attachedCount == 0) {
        _showAttachmentError('No supported files found.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingAttachmentNames.clear();
          _isAttachingFiles = false;
        });
      }
    }
  }

  void _markFileLoading(String fileName) {
    if (!mounted) return;
    setState(() => _loadingAttachmentNames.add(fileName));
  }

  void _clearFileLoading(String fileName) {
    if (!mounted) return;
    setState(() => _removeFirstLoadingByName(fileName));
  }

  void _removeFirstLoadingByName(String fileName) {
    final index = _loadingAttachmentNames.indexOf(fileName);
    if (index >= 0) {
      _loadingAttachmentNames.removeAt(index);
    }
  }

  void _setDragOver(bool value) {
    if (!mounted || _isDragOver == value) return;
    setState(() => _isDragOver = value);
  }

  Widget _buildDragOverlay() {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _isDragOver ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          color: Colors.black.withValues(alpha: 0.35),
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF27303B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF7C8795), width: 1.2),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.upload_file, color: Color(0xFFB7C0CC), size: 20),
                SizedBox(width: 10),
                Text(
                  'Drop files to attach',
                  style: TextStyle(
                    color: Color(0xFFE8EEF7),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAttachLoader() {
    if (!_isAttachingFiles) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: const Color(0xFF313945),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: const Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFF8DC5FF),
            ),
          ),
          SizedBox(width: 8),
          Text(
            'Attaching file(s)...',
            style: TextStyle(color: Color(0xFFD2D8DF), fontSize: 12),
          ),
        ],
      ),
    );
  }

  void _showAttachmentError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _captureAndAttachScreenshot() async {
    if (_isCapturingScreenshot) return;

    setState(() => _isCapturingScreenshot = true);

    try {
      final screenshotPath = await ScreenshotService.instance
          .captureFullScreen();

      if (screenshotPath == null) {
        throw Exception(
          'Screenshot capture is not available on this platform.',
        );
      }

      final screenshotFile = File(screenshotPath);
      if (!await screenshotFile.exists()) {
        throw Exception('Screenshot file was not created.');
      }

      final bytes = await screenshotFile.readAsBytes();
      if (bytes.isEmpty) {
        throw Exception('Screenshot file is empty.');
      }

      final fileName =
          'screenshot_${DateTime.now().millisecondsSinceEpoch}.png';

      setState(() {
        _pendingAttachments.add(
          ChatAttachment(name: fileName, bytes: bytes, isImage: true),
        );
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to capture screenshot: $e'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isCapturingScreenshot = false);
      }
    }
  }

  void _sendMessage() {
    if (_isAttachingFiles) return;
    final text = _controller.text.trim();
    final editingIndex = _editingMessageIndex;

    if (editingIndex != null) {
      final original = widget.messages[editingIndex];
      if (text.isEmpty && original.attachments.isEmpty) return;
      if (text == original.content) {
        _cancelEditingMessage();
        return;
      }
      widget.onEditUserMessage(editingIndex, text);
      _controller.clear();
      setState(() => _editingMessageIndex = null);
      return;
    }

    if (text.isEmpty && _pendingAttachments.isEmpty) return;

    final attachments = List<ChatAttachment>.from(_pendingAttachments);
    widget.onSendMessage(
      ChatMessage(content: text, isUser: true, attachments: attachments),
    );

    _controller.clear();
    setState(() => _pendingAttachments.clear());
  }

  void _stopGenerationAndRestoreInput() {
    final restored = widget.onStopGenerating();
    if (restored == null) return;

    setState(() {
      _editingMessageIndex = null;
      _pendingAttachments
        ..clear()
        ..addAll(restored.attachments);
      _controller.value = TextEditingValue(
        text: restored.content,
        selection: TextSelection.collapsed(offset: restored.content.length),
      );
    });
    _inputFocusNode.requestFocus();
  }

  void _removeAttachment(int index) {
    setState(() => _pendingAttachments.removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
    _maybeAutoScroll();
    return DropTarget(
      onDragEntered: (_) => _setDragOver(true),
      onDragUpdated: (_) => _setDragOver(true),
      onDragExited: (_) => _setDragOver(false),
      onDragDone: (details) {
        _setDragOver(false);
        final droppedPaths = details.files
            .map((item) => item.path)
            .where((path) => path.isNotEmpty)
            .toList();
        if (droppedPaths.isNotEmpty) {
          _attachFilesFromPaths(droppedPaths);
        }
      },
      child: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  color: const Color(0xFF373E47),
                  child: widget.messages.isEmpty
                      ? const _EmptyChatPlaceholder()
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(12),
                          itemCount: widget.messages.length,
                          itemBuilder: (context, index) {
                            final message = widget.messages[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Row(
                                children: [
                                  if (message.isUser)
                                    _UserMessageWithEditControl(
                                      message: message,
                                      isEditing: _editingMessageIndex == index,
                                      canEdit: !widget.isLoading,
                                      onEdit: () => _startEditingMessage(index),
                                    )
                                  else
                                    AssistantMessageBubble(message: message),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),
              _buildAttachLoader(),
              if (_editingMessageIndex != null)
                _EditModeBanner(
                  isLoading: widget.isLoading,
                  onCancel: _cancelEditingMessage,
                ),
              ChatInput(
                controller: _controller,
                focusNode: _inputFocusNode,
                attachments: _pendingAttachments,
                loadingFileNames: _loadingAttachmentNames,
                isLoading: widget.isLoading,
                isCapturingScreenshot: _isCapturingScreenshot,
                onSend: _sendMessage,
                onStop: _stopGenerationAndRestoreInput,
                onAttachmentRemove: _removeAttachment,
                onPickFile: _pickFileFromComputer,
                onScreenshot: _captureAndAttachScreenshot,
                onPasteFiles: _attachFilesFromPaths,
              ),
            ],
          ),
          _buildDragOverlay(),
        ],
      ),
    );
  }
}

class _UserMessageWithEditControl extends StatelessWidget {
  const _UserMessageWithEditControl({
    required this.message,
    required this.isEditing,
    required this.canEdit,
    required this.onEdit,
  });

  final ChatMessage message;
  final bool isEditing;
  final bool canEdit;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          UserMessageBubble(message: message),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: canEdit && !isEditing ? onEdit : null,
                iconSize: 14,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(
                  minWidth: 22,
                  minHeight: 22,
                ),
                color: const Color(0xFFB8C1CC),
                disabledColor: const Color(0xFF6D7682),
                tooltip: isEditing ? 'Editing' : 'Edit message',
                style: IconButton.styleFrom(
                  splashFactory: NoSplash.splashFactory,
                  highlightColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                ),
                icon: const Icon(Icons.edit_outlined),
              ),
              if (message.content.isNotEmpty) ...[
                const SizedBox(width: 2),
                CopyButton(
                  textToCopy: message.content,
                  iconColor: const Color(0xFFB8C1CC),
                  copiedIconColor: const Color(0xFFD2D8DF),
                  size: 14,
                  tooltip: 'Copy Message',
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _EditModeBanner extends StatelessWidget {
  const _EditModeBanner({required this.isLoading, required this.onCancel});

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
              'Editing message. Press send in input to regenerate from here.',
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

class _EmptyChatPlaceholder extends StatelessWidget {
  const _EmptyChatPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Chat messages will appear here',
        style: TextStyle(color: Color(0xFF9EA5AF), fontSize: 14),
      ),
    );
  }
}
