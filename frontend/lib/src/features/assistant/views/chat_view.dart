import 'dart:io';

import 'package:arya_app/src/features/assistant/models/chat_models.dart';
import 'package:arya_app/src/features/assistant/services/screenshot_service.dart';
import 'package:arya_app/src/features/assistant/widgets/chat_input.dart';
import 'package:arya_app/src/features/assistant/widgets/chat_message_bubble.dart';
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
    super.key,
  });

  final List<ChatMessage> messages;
  final bool isLoading;
  final ValueChanged<ChatMessage> onSendMessage;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  static const Set<String> _supportedExtensions = {
    'pdf',
    'txt',
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
  };

  static const Set<String> _imageExtensions = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
  };

  final TextEditingController _controller = TextEditingController();
  final List<ChatAttachment> _pendingAttachments = [];
  final List<String> _loadingAttachmentNames = [];
  bool _isCapturingScreenshot = false;
  bool _isDragOver = false;
  bool _isAttachingFiles = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickFileFromComputer() async {
    const typeGroup = XTypeGroup(
      label: 'Supported files',
      extensions: ['pdf', 'txt', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
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
    final ext = p.extension(file.name).replaceFirst('.', '').toLowerCase();
    if (!_supportedExtensions.contains(ext)) {
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

    final isImage = _imageExtensions.contains(ext);
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
        final ext = p.extension(fileName).replaceFirst('.', '').toLowerCase();
        if (!_supportedExtensions.contains(ext)) {
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
              isImage: _imageExtensions.contains(ext),
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
    final message = _controller.text.trim();
    if (message.isEmpty && _pendingAttachments.isEmpty) return;

    final attachments = List<ChatAttachment>.from(_pendingAttachments);

    widget.onSendMessage(
      ChatMessage(content: message, isUser: true, attachments: attachments),
    );

    _controller.clear();
    setState(() => _pendingAttachments.clear());
  }

  void _removeAttachment(int index) {
    setState(() => _pendingAttachments.removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
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
                          padding: const EdgeInsets.all(12),
                          itemCount: widget.messages.length,
                          itemBuilder: (context, index) {
                            final message = widget.messages[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Row(
                                children: [
                                  if (message.isUser)
                                    UserMessageBubble(message: message)
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
              ChatInput(
                controller: _controller,
                attachments: _pendingAttachments,
                loadingFileNames: _loadingAttachmentNames,
                isLoading: widget.isLoading || _isAttachingFiles,
                isCapturingScreenshot: _isCapturingScreenshot,
                onSend: _sendMessage,
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
